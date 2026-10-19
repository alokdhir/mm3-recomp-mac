/**
 * Metal renderer for the NV2A pushbuffer executor. See nv2a_d3d11.h, whose
 * interface this implements on macOS.
 *
 * A port of xboxrecomp's src/video/nv2a_d3d11.c, kept in the same order and
 * with its logic intact so the two can be compared section by section:
 *   surfaces  -- render targets and depth buffers, keyed by physical address
 *   textures  -- guest texture memory decoded to BGRA, cached by content hash
 *   draw      -- one uber pixel shader evaluates the register combiners and
 *                texture-stage modes from a constant buffer
 *   present   -- the finished surface (plus the PVIDEO overlay) scaled into
 *                the window's CAMetalLayer
 *
 * What changes with the API:
 *   - D3D11's immediate context becomes one open command buffer with at most
 *     one open encoder. Binding targets selects the render pass; the encoder
 *     is opened lazily by the next draw and every draw sets its whole state.
 *     Anything that is not a draw into the bound targets (uploads, copies,
 *     resolves) ends the encoder; the next pass loads what was there.
 *   - UpdateSubresource becomes a copy from a staging ring, keeping its place
 *     in the command stream. Map(NO_OVERWRITE) rings stay rings, waiting for
 *     the GPU only when they wrap.
 *   - MSAA targets resolve into their single-sample texture at the end of
 *     every pass (StoreAndMultisampleResolve), so "resolve" ends the pass.
 *   - Specialised pixel shaders are function-constant specialisations of the
 *     precompiled library, built on a background queue.
 *   - Depth is Depth32Float_Stencil8: Apple GPUs have no D24S8.
 *
 * Manual reference counting (no ARC), as the D3D11 code's COM references.
 * Everything here runs on the one thread that executes the pushbuffer.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#include <ctype.h>
#include <dispatch/dispatch.h>
#include <float.h>
#include <math.h>
#include <sched.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

/* Not windows.h: its BOOL and GetCurrentThread clash with the Objective-C
 * and Carbon ones. The few Win32 names this file uses: */
typedef uint32_t DWORD;
typedef unsigned int UINT;
extern DWORD GetTickCount(void);

#include "nv2a_d3d11.h"
#include "fb_present.h"
#include "fb_window_macos.h"
#include "platform/recomp_profile.h"
#include "../d3d/d3d8_swizzle.h"

extern ptrdiff_t xbox_GetMemoryOffset(void);

#define CONTIG_BASE 0x80000000u
#define CONTIG_SIZE 0x04000000u

static id<MTLDevice>        s_dev;
static id<MTLCommandQueue>  s_queue;
static id<MTLLibrary>       s_lib;
static int                  s_init_state;      /* 0 untried, 1 ok, -1 failed */

/* ------------------------------------------------------------ timing */

/* QPC stand-in: nanoseconds of uptime, frequency 1e9. */
static int64_t qpc(void)
{
    return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
#define QPC_FREQ 1000000000LL

/* RECOMP_D3D_PROFILE: per-frame cost of each stage, printed once a second. */
enum { PROF_VERTEX, PROF_TEXTURE, PROF_DRAW, PROF_SYNC, PROF_WRITEBACK,
       PROF_PRESENT, PROF_PACE, PROF_EXEC, PROF_COUNT };
static const char *const s_prof_name[PROF_COUNT] = {
    "vertex", "texture", "draw", "cpu-sync", "writeback", "present", "pace", "exec(all)" };
static int64_t s_prof[PROF_COUNT];
static uint64_t s_prof_verts, s_prof_draws;
static uint64_t s_prof_ps_uploads, s_prof_ps_reused;
static int s_prof_on = -1;

void nv2a_d3d_prof_add(int slot, int64_t ticks, uint32_t verts)
{
    s_prof[slot] += ticks;
    s_prof_verts += verts;
}

int nv2a_d3d_prof_enabled(void)
{
    if (s_prof_on < 0) s_prof_on = getenv("RECOMP_D3D_PROFILE") != NULL || getenv("RECOMP_SPIKE_CAPTURE") != NULL;
    return s_prof_on;
}

/* GPU time of the command buffers committed, from their completion
 * handlers (profiling only). */
static _Atomic uint64_t s_prof_gpu_ns;
/* Render passes and blit encoders opened, and what broke a pass for a blit:
 * on a tile-based GPU each break stores and reloads the targets. */
enum { BRK_UPLOAD, BRK_FEEDBACK, BRK_CHAIN, BRK_MIPS, BRK_WRITEBACK, BRK_PRESENT, BRK_CLEAR,
       BRK_Y16, BRK_SPAN, BRK_OTHER, BRK_COUNT };
static const char *const s_brk_name[BRK_COUNT] = {
    "upload", "feedback", "chain", "mips", "writeback", "present", "clear", "y16", "span",
    "other" };
/* A pass of its own (clear, Y16 view, span blit) is about to end the open one. */
#define NOTE_OWN_PASS(cause) do { s_prof_passes++; if (s_enc) s_prof_brk[cause]++; } while (0)
static uint64_t s_prof_passes, s_prof_blits, s_prof_brk[BRK_COUNT];
static uint64_t s_prof_vdraws[2][6];      /* [ubershader][variant] draws */
static uint64_t s_prof_ring_stalls;       /* ring wraps that waited for the GPU */
static uint64_t s_prof_queries;           /* visibility reports read (each waits for the GPU) */
static uint64_t s_prof_dropped;           /* draws given up (no program, no ring space) */
static int s_brk_cause = BRK_OTHER;

/* RECOMP_PASS_LOG=1: every pass and blit of one frame in 300, with its
 * targets and draws (finding passes that cost bandwidth). */
static int s_pass_log = -1, s_pass_log_now;
static uint64_t s_pass_log_draws0;
static void pass_log_frame(void)
{
    static int n;
    if (s_pass_log < 0) s_pass_log = getenv("RECOMP_PASS_LOG") != NULL;
    if (!s_pass_log) return;
    if (s_pass_log_now) {
        extern void nv2a_metal_pass_log_flush(void);
        nv2a_metal_pass_log_flush();
        fprintf(stderr, "[PASS] ---- end of frame\n");
    }
    s_pass_log_now = (++n % 60) == 0;
    if (s_pass_log_now) fprintf(stderr, "[PASS] ---- frame %d\n", n);
}
static void pass_log_tex(const char *what, id<MTLTexture> t)
{
    if (t) fprintf(stderr, " %s %lux%lu x%lu %s", what, (unsigned long)t.width, (unsigned long)t.height,
                   (unsigned long)t.sampleCount, t.storageMode == MTLStorageModeMemoryless ? "mem" : "");
}

/* GPU time per pass of the logged frame: timestamps at the stage
 * boundaries of each encoder (Apple GPUs sample there only). */
#define PASS_STAMPS 160
static id<MTLCounterSampleBuffer> s_stamp_buf;
static int s_stamp_n, s_stamp_ok = -1;
static char s_stamp_label[PASS_STAMPS][96];
static int stamp_begin(const char *label)
{
    if (!s_pass_log_now) return -1;
    if (s_stamp_ok < 0) {
        s_stamp_ok = 0;
        if ([s_dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
            for (id<MTLCounterSet> cs in [s_dev counterSets])
                if ([[cs name] isEqualToString:MTLCommonCounterSetTimestamp]) {
                    MTLCounterSampleBufferDescriptor *d = [[MTLCounterSampleBufferDescriptor alloc] init];
                    NSError *err = nil;
                    d.counterSet = cs;
                    d.sampleCount = PASS_STAMPS * 4;
                    d.storageMode = MTLStorageModeShared;
                    s_stamp_buf = [s_dev newCounterSampleBufferWithDescriptor:d error:&err];
                    [d release];
                    s_stamp_ok = s_stamp_buf != nil;
                }
        }
        if (!s_stamp_ok) fprintf(stderr, "[PASS] no GPU timestamps on this device\n");
    }
    if (!s_stamp_ok || s_stamp_n >= PASS_STAMPS) return -1;
    snprintf(s_stamp_label[s_stamp_n], sizeof s_stamp_label[0], "%s", label);
    return s_stamp_n++;
}
static void stamp_render(MTLRenderPassDescriptor *d, const char *label)
{
    int i = stamp_begin(label);
    if (i < 0) return;
    d.sampleBufferAttachments[0].sampleBuffer = s_stamp_buf;
    d.sampleBufferAttachments[0].startOfVertexSampleIndex = 4 * i;
    d.sampleBufferAttachments[0].endOfVertexSampleIndex = 4 * i + 1;
    d.sampleBufferAttachments[0].startOfFragmentSampleIndex = 4 * i + 2;
    d.sampleBufferAttachments[0].endOfFragmentSampleIndex = 4 * i + 3;
}
static void stamp_report(void)
{
    NSData *data;
    const MTLCounterResultTimestamp *ts;
    MTLTimestamp c0, g0, c1, g1;
    double per_tick = 1.0, total = 0;
    int i;
    if (!s_stamp_n) return;
    [s_dev sampleTimestamps:&c0 gpuTimestamp:&g0];
    data = [s_stamp_buf resolveCounterRange:NSMakeRange(0, (NSUInteger)s_stamp_n * 4)];
    usleep(20000);
    [s_dev sampleTimestamps:&c1 gpuTimestamp:&g1];
    if (g1 > g0) per_tick = (double)(c1 - c0) / (double)(g1 - g0);   /* ns per GPU tick */
    ts = data ? (const MTLCounterResultTimestamp *)[data bytes] : NULL;
    {
        uint64_t lo = UINT64_MAX, hi = 0;
#define STAMP_OK(v) ((v) && (v) != MTLCounterErrorValue)
        for (i = 0; ts && i < s_stamp_n * 4; i++)
            if (STAMP_OK(ts[i].timestamp) && ((i & 3) >= 2 || strncmp(s_stamp_label[i / 4], "blit", 4))) {
                if (ts[i].timestamp < lo) lo = ts[i].timestamp;
                if (ts[i].timestamp > hi) hi = ts[i].timestamp;
            }
        for (i = 0; ts && i < s_stamp_n; i++) {
            uint64_t a = ts[4 * i].timestamp, b = ts[4 * i + 1].timestamp,
                     c = ts[4 * i + 2].timestamp, e = ts[4 * i + 3].timestamp;
            int blit = !strncmp(s_stamp_label[i], "blit", 4);
            double vs = !blit && STAMP_OK(a) && STAMP_OK(b) && b >= a ? (b - a) * per_tick / 1e3 : 0;
            double fs = STAMP_OK(c) && STAMP_OK(e) && e >= c ? (e - c) * per_tick / 1e3 : 0;
            double at = !blit && STAMP_OK(a) ? (a - lo) * per_tick / 1e3 : STAMP_OK(c) ? (c - lo) * per_tick / 1e3 : -1;
            double end = STAMP_OK(e) ? (e - lo) * per_tick / 1e3 : -1;
            total += vs > fs ? vs : fs;
            fprintf(stderr, "[GPU] %7.0f us frag %6.0f us vert  @%6.0f..%6.0f  %s\n", fs, vs, at, end,
                    s_stamp_label[i]);
        }
        fprintf(stderr, "[GPU] total (max of stages, overlap ignored) %.2f ms over %d encoders, span %.2f ms\n",
                total / 1e3, s_stamp_n, hi > lo ? (hi - lo) * per_tick / 1e6 : 0.0);
#undef STAMP_OK
    }
    s_stamp_n = 0;
}

static void prof_report(void)
{
    static int64_t last, frames, prev, worst;
    int64_t now = qpc();
    int i;
    static int print = -1;
    if (!nv2a_d3d_prof_enabled()) return;
    if (print < 0) print = getenv("RECOMP_D3D_PROFILE") != NULL;
    frames++;
    if (prev && now - prev > worst) worst = now - prev;
    prev = now;
    if (!last) { last = now; return; }
    if (now - last < QPC_FREQ) return;
    if (!print) goto reset;
    fprintf(stderr, "[METAL_PROF] %.1f fps (worst %.1f ms) |",
            frames * (double)QPC_FREQ / (double)(now - last), worst * 1000.0 / (double)QPC_FREQ);
    for (i = 0; i < PROF_COUNT; i++)
        fprintf(stderr, " %s %.2f", s_prof_name[i],
                s_prof[i] * 1000.0 / (double)QPC_FREQ / (double)frames);
    fprintf(stderr, " gpu %.2f",
            (double)atomic_exchange(&s_prof_gpu_ns, 0) / 1e6 / (double)frames);
    fprintf(stderr, " ring-stalls %llu queries %.1f dropped %llu", (unsigned long long)s_prof_ring_stalls,
            (double)s_prof_queries / frames, (unsigned long long)s_prof_dropped);
    s_prof_ring_stalls = s_prof_queries = s_prof_dropped = 0;
    fprintf(stderr, " ms/frame | passes %.1f blits %.1f breaks",
            (double)s_prof_passes / frames, (double)s_prof_blits / frames);
    for (i = 0; i < BRK_COUNT; i++)
        if (s_prof_brk[i]) fprintf(stderr, " %s %.1f", s_brk_name[i], (double)s_prof_brk[i] / frames);
    {   /* draws: s = specialised, u = ubershader; z = W-buffer, c = writes coverage */
        uint64_t sp = 0, ub = 0, wz = 0, cv = 0; int v;
        for (v = 0; v < 6; v++) {
            sp += s_prof_vdraws[0][v]; ub += s_prof_vdraws[1][v];
            if (v & 2) wz += s_prof_vdraws[0][v] + s_prof_vdraws[1][v];
            if (!(v & 4)) cv += s_prof_vdraws[0][v] + s_prof_vdraws[1][v];
        }
        fprintf(stderr, " | spec %.0f uber %.0f wdepth %.0f coverage %.0f",
                (double)sp / frames, (double)ub / frames, (double)wz / frames, (double)cv / frames);
        memset(s_prof_vdraws, 0, sizeof s_prof_vdraws);
    }
    fprintf(stderr, " | %llu verts %llu draws/frame | ps-constants %llu uploaded %llu reused/frame\n",
            (unsigned long long)(s_prof_verts / frames), (unsigned long long)(s_prof_draws / frames),
            (unsigned long long)(s_prof_ps_uploads / frames), (unsigned long long)(s_prof_ps_reused / frames));
    fflush(stderr);
reset:
    memset(s_prof, 0, sizeof s_prof);
    memset(s_prof_brk, 0, sizeof s_prof_brk);
    s_prof_passes = s_prof_blits = 0;
    s_prof_verts = s_prof_draws = 0;
    s_prof_ps_uploads = s_prof_ps_reused = 0;
    frames = 0;
    worst = 0;
    last = now;
}

static uint32_t             s_frame = 1;
/* Bumped at every pushbuffer kick: the CPU can only have written guest memory
 * between kicks, so a surface needs checking at most once per kick. */
static uint32_t             s_epoch = 1;

void nv2a_d3d_kick(void)
{
    s_epoch++;
}

/* Internal resolution relative to the guest's: s_scale vertically, and
 * horizontally too except on display-sized surfaces, which are also widened
 * to the display aspect (see nv2a_d3d_display_aspect). s_cur_sx/sy are the
 * bound target's. */
static float s_scale = 1.0f, s_cur_sx = 1.0f, s_cur_sy = 1.0f;
/* Host MSAA sample count for linear render targets and the anisotropy of
 * linearly filtered textures: RECOMP_MSAA (1/2/4/8), RECOMP_ANISO (1..16). */
static NSUInteger s_msaa = 4, s_aniso = 16;
#define GUEST_W 640u
#define GUEST_H 480u

/* A title's placement of screen-space 2D on a widened target (header). */
static NvOverlayHooks s_overlay;

void nv2a_d3d_set_overlay_hooks(const NvOverlayHooks *hooks)
{
    memset(&s_overlay, 0, sizeof s_overlay);
    if (hooks) s_overlay = *hooks;
}

/* nv2a_d3d_set_depth_view_remap: x = scale, y = knee (see y16d_ps). */
static float s_zview_remap[4] = { 1.0f, 1.0f, 0.0f, 0.0f };
static int s_depth_hazed;               /* depth read as Y16 this frame */

void nv2a_d3d_set_depth_view_remap(float scale, float knee)
{
    if (!(scale >= 1.0f) || !(knee > 0.0f && knee <= 1.0f)) { scale = 1.0f; knee = 1.0f; }
    s_zview_remap[1] = knee;
    s_zview_remap[0] = scale;
}

/* The aspect the image is rendered at, never narrower than the title's
 * 4:3: RECOMP_ASPECT (e.g. 16:9, 21:9, 1.6, 4:3), else the game window's
 * client area, following it as the window is resized (see display_config). */
static volatile float s_aspect;     /* 0 until decided */

static float clamp_aspect(float a)
{
    return a < 4.0f / 3.0f ? 4.0f / 3.0f : a > 4.0f ? 4.0f : a;
}

static float env_aspect(void)
{
    const char *e = getenv("RECOMP_ASPECT");
    float w, h;
    if (e && sscanf(e, "%f:%f", &w, &h) == 2 && h > 0 && w > 0) return clamp_aspect(w / h);
    if (e && sscanf(e, "%f", &w) == 1 && w > 0) return clamp_aspect(w);
    return 0;
}

/* The window's drawable size in pixels; 0 if there is no window or it is
 * minimised. */
static int client_size(UINT *w, UINT *h)
{
    unsigned cw, ch;
    if (!xbox_FramebufferClientPixels(&cw, &ch) || !cw || !ch) return 0;
    *w = cw;
    *h = ch;
    return 1;
}

float nv2a_d3d_display_aspect(void)
{
    float a = s_aspect;
    UINT w, h;
    unsigned sw, sh;
    if (a) return a;
    if ((a = env_aspect()) != 0) return s_aspect = a;
    if (client_size(&w, &h)) return s_aspect = clamp_aspect((float)w / (float)h);
    /* No window yet (sizing it): the screen it will open on. */
    if (xbox_FramebufferScreenSize(&sw, &sh) && sh)
        return clamp_aspect((float)sw / (float)sh);
    return 4.0f / 3.0f;
}

/* How much wider than 4:3 a display-sized surface is rendered. */
static float widen(void)
{
    return nv2a_d3d_display_aspect() * 3.0f / 4.0f;
}

static void fail(const char *what, NSError *err)
{
    fprintf(stderr, "[METAL] %s failed%s%s\n", what, err ? ": " : "",
            err ? [[err localizedDescription] UTF8String] : "");
    fflush(stderr);
}

static int guest_ok(uint32_t va, size_t bytes)
{
    if (va < 0x10000u) return 0;
    if (va < 0x08000000u) return (uint64_t)va + bytes <= 0x08000000u;
    if (va >= CONTIG_BASE && va < CONTIG_BASE + CONTIG_SIZE)
        return (uint64_t)va + bytes <= (uint64_t)CONTIG_BASE + CONTIG_SIZE;
    return 0;
}

static const uint8_t *guest(uint32_t va)
{
    return (const uint8_t *)xbox_GetMemoryOffset() + va;
}

/* The GPU's name for memory: the physical address, whichever window the
 * executor resolved it through. */
static uint32_t phys(uint32_t va)
{
    return va >= CONTIG_BASE ? va - CONTIG_BASE : va;
}

#include "nv2a_texture_hash.h"

/* ------------------------------------------------- command stream and passes
 *
 * s_cmd is the open command buffer; s_enc the open render encoder (into
 * s_pass_color/s_pass_depth) or s_blit the open blit encoder, never both.
 * The bound targets (s_want_*) take effect when a draw opens the encoder. */
static id<MTLCommandBuffer>        s_cmd;
static id<MTLRenderCommandEncoder> s_enc;
static id<MTLBlitCommandEncoder>   s_blit;
static id<MTLTexture> s_pass_color, s_pass_resolve, s_pass_depth;
static id<MTLTexture> s_want_color, s_want_resolve, s_want_depth;
static UINT s_vp_w, s_vp_h;                 /* the bound targets' size */
static id<MTLCommandBuffer> s_last_commit;  /* most recently committed */

/* Occlusion counting (see visibility tests below). */
static id<MTLBuffer> s_vis_buf;
#define VIS_SLOTS 4096
static int s_query_active;
static uint32_t s_vis_next, s_vis_first;    /* slots used by the active query */
static int s_vis_enc_slot = -1;             /* the open encoder's slot */

static id<MTLCommandBuffer> cmd(void)
{
    if (!s_cmd) {
        s_cmd = [[s_queue commandBuffer] retain];
        [s_cmd setLabel:@"nv2a"];
    }
    return s_cmd;
}

static void end_encoders_at(int line)
{
    if (s_enc && s_pass_log_now)
        fprintf(stderr, "[PASS]   %llu draws, ended at line %d\n",
                (unsigned long long)(s_prof_draws - s_pass_log_draws0), line);
    if (s_enc) {
        [s_enc endEncoding];
        [s_enc release];
        s_enc = nil;
        s_vis_enc_slot = -1;
    }
    if (s_blit) {
        [s_blit endEncoding];
        [s_blit release];
        s_blit = nil;
    }
    s_pass_color = s_pass_resolve = s_pass_depth = nil;
}
#define end_encoders() end_encoders_at(__LINE__)

/* Submit what has been recorded; wait: until the GPU has finished it. */
/* ------------------------------------------------------------- staging rings
 *
 * CPU-written buffers the GPU reads in command order: vertex data, indices
 * and uploads. Space is handed out front to back. Each commit marks how far
 * the ring had got; a request that does not fit wraps to the start once the
 * command buffer that last read that space has finished -- the first one
 * committed after the lap passed it, normally long done -- rather than
 * everything in flight (a wrap used to stall the frame on the GPU). Data is
 * only ever read by the command buffer it was written for (see s_vb_gen),
 * so nothing still being encoded can need the space. */
#define RING_MARKS 256
typedef struct {
    id<MTLBuffer> buf;
    uint8_t *base;
    size_t cap, pos;
    uint32_t wraps;                 /* times it has started over */
    uint32_t stalls;                /* wraps that had to wait for the GPU */
    const char *name;
    int marks;                      /* this lap's commits: */
    size_t mark_pos[RING_MARKS];    /*   how far the ring had got */
    id<MTLCommandBuffer> mark_cb[RING_MARKS];
} Ring;

static Ring s_vb_ring, s_ib_ring, s_up_ring;
/* Generation of what the vertex ring caches across draws (the vertex program
 * and constants): a wrap and every commit start a new one, so a command
 * buffer only reads data written while it was being encoded. */
static uint32_t s_vb_gen;

/* After a commit: remember how far each ring had got and by which buffer.
 * A full list folds into its last entry -- a later buffer covers more. */
static void ring_mark(Ring *r, id<MTLCommandBuffer> cb)
{
    if (r->marks == RING_MARKS) {
        [r->mark_cb[RING_MARKS - 1] release];
        r->marks--;
    }
    r->mark_pos[r->marks] = r->pos;
    r->mark_cb[r->marks] = [cb retain];
    r->marks++;
}

static void ring_new_lap(Ring *r)
{
    int i;
    for (i = 0; i < r->marks; i++) [r->mark_cb[i] release];
    r->marks = 0;
}

static void submit(int wait)
{
    end_encoders();
    if (s_cmd) {
        if (nv2a_d3d_prof_enabled())
            [s_cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                double t = [cb GPUEndTime] - [cb GPUStartTime];
                if (t > 0) atomic_fetch_add(&s_prof_gpu_ns, (uint64_t)(t * 1e9));
            }];
        [s_cmd commit];
        if (s_last_commit) [s_last_commit release];
        s_last_commit = s_cmd;              /* keeps the reference */
        s_cmd = nil;
        ring_mark(&s_vb_ring, s_last_commit);
        ring_mark(&s_ib_ring, s_last_commit);
        ring_mark(&s_up_ring, s_last_commit);
        s_vb_gen++;
    }
    if (wait && s_last_commit)
        [s_last_commit waitUntilCompleted];
}

static id<MTLBlitCommandEncoder> blit_encoder_for(int cause)
{
    if (s_blit) return s_blit;
    s_prof_blits++;
    if (s_enc) s_prof_brk[cause]++;
    end_encoders();
    if (s_pass_log_now) fprintf(stderr, "[PASS] blit (%s%s)\n", s_brk_name[cause], s_enc ? ", broke the pass" : "");
    {
        int i = stamp_begin(s_brk_name[cause]);
        if (i >= 0) {
            MTLBlitPassDescriptor *d = [MTLBlitPassDescriptor blitPassDescriptor];
            char *l = s_stamp_label[i];
            memmove(l + 5, l, strlen(l) + 1 < 90 ? strlen(l) + 1 : 90);
            memcpy(l, "blit ", 5);
            d.sampleBufferAttachments[0].sampleBuffer = s_stamp_buf;
            d.sampleBufferAttachments[0].startOfEncoderSampleIndex = 4 * i + 2;
            d.sampleBufferAttachments[0].endOfEncoderSampleIndex = 4 * i + 3;
            s_blit = [[cmd() blitCommandEncoderWithDescriptor:d] retain];
        } else {
            s_blit = [[cmd() blitCommandEncoder] retain];
        }
    }
    return s_blit;
}

static MTLRenderPassDescriptor *pass_descriptor(id<MTLTexture> color, id<MTLTexture> resolve,
                                                id<MTLTexture> depth)
{
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
    if (color) {
        d.colorAttachments[0].texture = color;
        d.colorAttachments[0].loadAction = MTLLoadActionLoad;
        if (resolve) {
            d.colorAttachments[0].resolveTexture = resolve;
            d.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
        } else {
            d.colorAttachments[0].storeAction = MTLStoreActionStore;
        }
    }
    if (depth) {
        d.depthAttachment.texture = depth;
        d.depthAttachment.loadAction = MTLLoadActionLoad;
        d.depthAttachment.storeAction = MTLStoreActionStore;
        d.stencilAttachment.texture = depth;
        d.stencilAttachment.loadAction = MTLLoadActionLoad;
        d.stencilAttachment.storeAction = MTLStoreActionStore;
    }
    if (!color && !depth) {
        d.renderTargetWidth = 1;
        d.renderTargetHeight = 1;
    }
    d.visibilityResultBuffer = s_vis_buf;
    return d;
}

static void vis_begin_encoder(void);

/* The render encoder for the bound targets, opened if need be. */
static id<MTLRenderCommandEncoder> render_encoder(void)
{
    if (s_enc && s_pass_color == s_want_color && s_pass_depth == s_want_depth &&
        s_pass_resolve == s_want_resolve)
        return s_enc;
    end_encoders();
    if (!s_want_color && !s_want_depth) return nil;
    {
        MTLRenderPassDescriptor *d = pass_descriptor(s_want_color, s_want_resolve, s_want_depth);
        if (s_pass_log_now) {
            char l[96];
            snprintf(l, sizeof l, "render %lux%lu x%lu%s (pass %llu)",
                     (unsigned long)(s_want_color ? s_want_color.width : s_want_depth.width),
                     (unsigned long)(s_want_color ? s_want_color.height : s_want_depth.height),
                     (unsigned long)(s_want_color ? s_want_color.sampleCount : s_want_depth.sampleCount),
                     s_want_depth ? "+depth" : "", (unsigned long long)s_prof_passes);
            stamp_render(d, l);
        }
        s_enc = [[cmd() renderCommandEncoderWithDescriptor:d] retain];
    }
    s_prof_passes++;
    if (s_pass_log_now) {
        fprintf(stderr, "[PASS] render");
        pass_log_tex("color", s_want_color); pass_log_tex("resolve", s_want_resolve);
        pass_log_tex("depth", s_want_depth);
        fprintf(stderr, "\n");
        s_pass_log_draws0 = s_prof_draws;
    }
    s_pass_color = s_want_color;
    s_pass_resolve = s_want_resolve;
    s_pass_depth = s_want_depth;
    [s_enc setDepthClipMode:MTLDepthClipModeClamp];
    vis_begin_encoder();
    return s_enc;
}

/* A pass that only clears: colour (if given) to rgba, depth to 1 and stencil
 * to 0 (if given). */
static void clear_pass(id<MTLTexture> color, id<MTLTexture> resolve, id<MTLTexture> depth,
                       const float rgba[4])
{
    MTLRenderPassDescriptor *d;
    id<MTLRenderCommandEncoder> e;
    NOTE_OWN_PASS(BRK_CLEAR);
    end_encoders();
    d = pass_descriptor(color, resolve, depth);
    d.visibilityResultBuffer = nil;
    if (color) {
        d.colorAttachments[0].loadAction = MTLLoadActionClear;
        d.colorAttachments[0].clearColor = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
    }
    if (depth) {
        d.depthAttachment.loadAction = MTLLoadActionClear;
        d.depthAttachment.clearDepth = 1.0;
        d.stencilAttachment.loadAction = MTLLoadActionClear;
        d.stencilAttachment.clearStencil = 0;
    }
    stamp_render(d, "clear pass");
    if (s_pass_log_now) {
        fprintf(stderr, "[PASS] clear");
        pass_log_tex("color", color); pass_log_tex("resolve", resolve); pass_log_tex("depth", depth);
        fprintf(stderr, "\n");
    }
    e = [cmd() renderCommandEncoderWithDescriptor:d];
    [e endEncoding];
}

#define VB_BYTES (32u << 20)
#define IB_BYTES (16u << 20)
#define UP_BYTES (64u << 20)

static int ring_init(Ring *r, size_t cap, const char *name)
{
    r->buf = [s_dev newBufferWithLength:cap options:MTLResourceStorageModeShared |
                                                   MTLResourceCPUCacheModeWriteCombined];
    if (!r->buf) return 0;
    r->base = (uint8_t *)[r->buf contents];
    r->cap = cap;
    r->pos = 0;
    r->name = name;
    return 1;
}

/* bytes of ring space (aligned to align); *off is its offset. NULL if it can
 * never fit. */
static uint8_t *ring_alloc(Ring *r, size_t bytes, size_t align, size_t *off)
{
    size_t at = (r->pos + align - 1) & ~(align - 1);
    if (bytes > r->cap) return NULL;
    if (at + bytes > r->cap) {
        int i;
        /* One mark later than strictly needed: a fallback commit between a
         * draw's allocations credits its data to the buffer before the one
         * that reads it. */
        for (i = 0; i < r->marks && r->mark_pos[i] < bytes; i++)
            ;
        if (i + 1 < r->marks) i++;
        if (i < r->marks) {
            if ([r->mark_cb[i] status] < MTLCommandBufferStatusCompleted) {
                r->stalls++;
                s_prof_ring_stalls++;
                [r->mark_cb[i] waitUntilCompleted];
            }
        } else {
            /* Nothing committed past that space this lap: the buffer being
             * encoded may still read it. */
            r->stalls++;
            s_prof_ring_stalls++;
            submit(1);
        }
        ring_new_lap(r);
        at = 0;
        r->wraps++;
        if (r == &s_vb_ring) s_vb_gen++;
    }
    r->pos = at + bytes;
    *off = at;
    return r->base + at;
}

/* UpdateSubresource: pixels into one level/slice of tex, in stream order. */
static int upload_region(id<MTLTexture> tex, NSUInteger slice, NSUInteger level,
                         NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h,
                         const void *pixels, NSUInteger row_bytes, NSUInteger rows)
{
    size_t off, bytes = (size_t)row_bytes * rows;
    uint8_t *p = ring_alloc(&s_up_ring, bytes, 256, &off);
    if (!p) return 0;
    memcpy(p, pixels, bytes);
    [blit_encoder_for(BRK_UPLOAD) copyFromBuffer:s_up_ring.buf sourceOffset:off
                  sourceBytesPerRow:row_bytes sourceBytesPerImage:bytes
                         sourceSize:MTLSizeMake(w, h, 1)
                          toTexture:tex destinationSlice:slice destinationLevel:level
                  destinationOrigin:MTLOriginMake(x, y, 0)];
    return 1;
}

/* ---------------------------------------------------------------- shaders */

/* Constant layouts shared with nv2a.metal. */
typedef struct {
    uint32_t c_icw[8], a_icw[8], c_ocw[8], a_ocw[8];
    float cf0[8][4], cf1[8][4], fin_c0[4], fin_c1[4];
    uint32_t fin0, fin1, rc_control, stage_prog;
    uint32_t alpha_func, alpha_ref, ps_flags, clip_plane;
    uint32_t other_input, dot_map, pad0, pad1;
    uint32_t tex_info[4][4];
    float tex_scale[4][4];
    float fog_color[4];
    float bump_mat[4][4], bump_lum[4][4];
    float zp0[4], zp1[4];
    float wclip[8][4];
    uint32_t wclip_mode, wclip_pad[3];
    float lod_bias[4];           /* Metal samplers have no MipLODBias */
} PSConsts;

typedef struct {
    uint32_t at[16][4];          /* byte offset, stride, type, size (0: DEF) */
    float def[16][4];
    uint32_t info[4];            /* start slot, program, dx offset, - */
    float map[4];                /* 2/w, 2/h, 1/zmax, squeeze */
    uint32_t fogi[4];
    float fogf[4];
    float place[4];              /* x shift (NDC), y scale, pixel-0 snap, screen offset */
} UbConsts;

typedef struct {
    float dst_rect[4], src_uv[4], src_size[4];
    float ovl_out[4], ovl_walk[4], ovl_in[4];
    uint32_t ovl_flags[4];
    float force_alpha[4];
} PresentConsts;

static id<MTLFunction> s_fn_ub_vs, s_fn_present_vs, s_fn_present_ps, s_fn_clear_vs, s_fn_clear_ps;
static id<MTLFunction> s_fn_y16_vs, s_fn_y16_ps[2], s_fn_y16d_ps[2];
static id<MTLFunction> s_fn_psv[6];          /* [variant], the ubershader */
/* Measuring only: RECOMP_EXP_FILE names a file holding a bitmask, re-read
 * every half second -- 1 no W-buffer depth, 2 diffuse-only shaders, 4
 * diffuse x texture 0 shaders. */
static int s_exp;
static id<MTLFunction> s_fn_dbg, s_fn_dbg_tex;
static void exp_poll(void)
{
    static const char *path;
    static int n, init;
    FILE *f;
    if (!init) { init = 1; path = getenv("RECOMP_EXP_FILE"); }
    if (!path || ++n % 30) return;
    if ((f = fopen(path, "r"))) {
        int v = 0;
        if (fscanf(f, "%d", &v) == 1 && v != s_exp) {
            s_exp = v;
            fprintf(stderr, "[EXP] mode %d\n", s_exp);
        }
        fclose(f);
    }
}
static id<MTLSamplerState> s_linear_clamp, s_point_clamp;
static id<MTLDepthStencilState> s_ds_off;
static id<MTLTexture> s_null_2d, s_null_cube, s_null_vol;

#define PIX_BGRA   MTLPixelFormatBGRA8Unorm
#define PIX_Y16    MTLPixelFormatRGBA16Unorm
#define PIX_DEPTH  MTLPixelFormatDepth32Float_Stencil8

/* Variant bits: 1 flat shading, 2 W-buffer depth, 4 no coverage output
 * (only without 2). */
static const char *const s_psv_names[6] = { "ps_main", "ps_main_flat", "ps_wdepth", "ps_wdepth_flat",
                                            "ps_main_nc", "ps_main_flat_nc" };

/* The library built beside the executable (nv2a.metallib), or next to the
 * app's resources. */
#include "nv2a_metal_source.inc"

/* The shaders: the library built beside the executable or in the app's
 * resources (nv2a.metallib, when the build had Xcode's Metal compiler), else
 * the embedded source compiled now -- about half a second -- with the same
 * language version and relaxed math (inf and NaN kept) as the offline build.
 * RECOMP_METALLIB names a library; RECOMP_METAL_FROM_SOURCE=1 skips it. */
static id<MTLLibrary> load_library(void)
{
    NSError *err = nil;
    NSString *path = nil;
    const char *env = getenv("RECOMP_METALLIB"), *src_only = getenv("RECOMP_METAL_FROM_SOURCE");
    id<MTLLibrary> lib = nil;
    if (!(src_only && *src_only && strcmp(src_only, "0"))) {
        if (env) path = [NSString stringWithUTF8String:env];
        if (!path) path = [[NSBundle mainBundle] pathForResource:@"nv2a" ofType:@"metallib"];
        if (!path) {
            NSString *exe = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
            path = [exe stringByAppendingPathComponent:@"nv2a.metallib"];
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            lib = [s_dev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
            if (!lib) fail([[NSString stringWithFormat:@"loading %@", path] UTF8String], err);
            return lib;
        }
    }
    {
        NSString *source = [NSString stringWithUTF8String:(const char *)nv2a_metal_source];
        MTLCompileOptions *opt = [[MTLCompileOptions alloc] init];
        int64_t t0 = qpc();
        opt.languageVersion = MTLLanguageVersion3_1;
        if (@available(macOS 15.0, *)) {
            opt.mathMode = MTLMathModeRelaxed;
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            opt.fastMathEnabled = NO;               /* precise: keeps inf and NaN */
#pragma clang diagnostic pop
        }
        err = nil;
        lib = [s_dev newLibraryWithSource:source options:opt error:&err];
        [opt release];
        if (!lib) { fail("compiling the shaders", err); return nil; }
        fprintf(stderr, "[METAL] shaders compiled from source in %.0f ms\n",
                (double)(qpc() - t0) * 1000.0 / (double)QPC_FREQ);
    }
    return lib;
}

static id<MTLFunction> function(NSString *name)
{
    id<MTLFunction> f = [s_lib newFunctionWithName:name];
    if (!f) fprintf(stderr, "[METAL] shader %s missing from the library\n", [name UTF8String]);
    return f;
}

/* A function that declares function constants, with none of them set: the
 * pixel shaders' ubershader form (see SPEC in nv2a.metal). */
static id<MTLFunction> function_unspecialised(NSString *name)
{
    NSError *err = nil;
    MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
    id<MTLFunction> f = [s_lib newFunctionWithName:name constantValues:cv error:&err];
    [cv release];
    if (!f) fail([[NSString stringWithFormat:@"shader %@", name] UTF8String], err);
    return f;
}

/* ------------------------------------------------------- pipeline states
 *
 * A Metal pipeline fixes what D3D11 binds separately: shaders, target
 * formats, sample count and blend state. Keyed together; built on demand. */
typedef struct {
    void *vs, *fs;                         /* id<MTLFunction> */
    uint32_t color_fmt, depth_fmt, samples;
    uint32_t blend;                        /* enable | mask << 1 | factors/op, below */
    uint32_t sf, df, eq;
} PipeKey;

typedef struct {
    PipeKey key;
    id<MTLRenderPipelineState> pso;
    int used;
} PipeSlot;

#define PIPE_SLOTS 4096
static PipeSlot *s_pipes;

static MTLBlendFactor blend_factor(uint32_t f, int alpha)
{
    switch (f) {
    case 0x0000: return MTLBlendFactorZero;
    case 0x0001: return MTLBlendFactorOne;
    case 0x0300: return alpha ? MTLBlendFactorSourceAlpha : MTLBlendFactorSourceColor;
    case 0x0301: return alpha ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusSourceColor;
    case 0x0302: return MTLBlendFactorSourceAlpha;
    case 0x0303: return MTLBlendFactorOneMinusSourceAlpha;
    case 0x0304: return MTLBlendFactorDestinationAlpha;
    case 0x0305: return MTLBlendFactorOneMinusDestinationAlpha;
    case 0x0306: return alpha ? MTLBlendFactorDestinationAlpha : MTLBlendFactorDestinationColor;
    case 0x0307: return alpha ? MTLBlendFactorOneMinusDestinationAlpha : MTLBlendFactorOneMinusDestinationColor;
    case 0x0308: return MTLBlendFactorSourceAlphaSaturated;
    case 0x8001: case 0x8003: return MTLBlendFactorBlendColor;
    case 0x8002: case 0x8004: return MTLBlendFactorOneMinusBlendColor;
    default: return MTLBlendFactorOne;
    }
}

static MTLBlendOperation blend_op(uint32_t e)
{
    switch (e) {
    /* F005/F006 are the signed (reverse-subtract / add) equations; the
     * signed range isn't emulated, and their nominal ops wash out a title's
     * daytime scenes, so they keep the mapping that matches its output. */
    case 0x800A: case 0xF005: return MTLBlendOperationSubtract;
    case 0x800B: case 0xF006: return MTLBlendOperationReverseSubtract;
    case 0x8007: return MTLBlendOperationMin;
    case 0x8008: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

/* D3D11's colour write bits (R=1 G=2 B=4 A=8) as Metal's. */
static MTLColorWriteMask metal_write_mask(uint32_t m)
{
    MTLColorWriteMask o = MTLColorWriteMaskNone;
    if (m & 1) o |= MTLColorWriteMaskRed;
    if (m & 2) o |= MTLColorWriteMaskGreen;
    if (m & 4) o |= MTLColorWriteMaskBlue;
    if (m & 8) o |= MTLColorWriteMaskAlpha;
    return o;
}
#define WRITE_R 1u
#define WRITE_G 2u
#define WRITE_B 4u
#define WRITE_A 8u
#define WRITE_ALL 15u

static uint64_t pipe_hash(const PipeKey *k)
{
    return hash_mem((const uint8_t *)k, sizeof *k);
}

/* ------------------------------------------------ the pipeline binary archive
 * Building a pipeline for the ubershader -- what a draw uses until its
 * specialised shader is ready -- takes the GPU compiler 100 ms or more, on the
 * render thread: a hitch whenever a race shows a new combination. Every
 * pipeline built is added (in the background) to a Metal binary archive in
 * the app's Caches folder, saved now and then, and loaded at the next launch,
 * where building a pipeline it holds is a lookup. The file is named for the
 * shaders' hash, so a changed shader starts a new one. RECOMP_PSO_ARCHIVE=0
 * leaves it out. */
static id<MTLBinaryArchive> s_archive;
static NSURL *s_archive_url;
static dispatch_queue_t s_archive_queue;
static _Atomic int s_archive_dirty;
static pthread_mutex_t s_archive_lock = PTHREAD_MUTEX_INITIALIZER;

/* The executable's LC_UUID, new with every link: pipelines depend on the
 * renderer's code as well as the shader source. */
static uint64_t build_id(void)
{
    const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(0);
    const uint8_t *p = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; h && i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_UUID) {
            const uint8_t *u = ((const struct uuid_command *)lc)->uuid;
            uint64_t a, b;
            memcpy(&a, u, 8); memcpy(&b, u + 8, 8);
            return a ^ (b * 0x9E3779B97F4A7C15ull);
        }
        p += lc->cmdsize;
    }
    return 0;
}

static void archive_init(uint64_t shader_hash)
{
    const char *e = getenv("RECOMP_PSO_ARCHIVE");
    NSString *dir;
    MTLBinaryArchiveDescriptor *d;
    NSError *err = nil;
    if (e && !strcmp(e, "0")) return;
    dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (!dir) return;
    dir = [dir stringByAppendingPathComponent:@"org.mm3-port.midtown-madness-3"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    /* One archive per build: a pipeline cached by another build (the same
     * shader source, different renderer code) drew the car selector's floor
     * over the car. Archives of other builds are removed. */
    shader_hash ^= build_id() * 0xBF58476D1CE4E5B9ull;
    NSString *name = [NSString stringWithFormat:@"nv2a-pipelines-%016llx.binarchive", (unsigned long long)shader_hash];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
        if ([f hasPrefix:@"nv2a-pipelines-"] && [f hasSuffix:@".binarchive"] && ![f isEqualToString:name])
            [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
    s_archive_url = [[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]] retain];
    d = [[MTLBinaryArchiveDescriptor alloc] init];
    if ([[NSFileManager defaultManager] fileExistsAtPath:[s_archive_url path]]) d.url = s_archive_url;
    s_archive = [s_dev newBinaryArchiveWithDescriptor:d error:&err];
    if (!s_archive && d.url) {                   /* unreadable: start afresh */
        [[NSFileManager defaultManager] removeItemAtURL:s_archive_url error:nil];
        d.url = nil;
        s_archive = [s_dev newBinaryArchiveWithDescriptor:d error:&err];
    }
    fprintf(stderr, "[METAL] pipeline archive: %s (%s)\n", s_archive ? [[s_archive_url path] UTF8String] : "off",
            d.url ? "loaded" : "new");
    [d release];
    s_archive_queue = dispatch_queue_create("nv2a.archive", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
}

/* Build d's pipeline, from the archive when it holds it; a new one joins the
 * archive in the background. Any thread. */
static id<MTLRenderPipelineState> build_pso(MTLRenderPipelineDescriptor *d, NSError **err)
{
    id<MTLRenderPipelineState> pso;
    int64_t t0 = qpc();
    double ms;
    if (s_archive) d.binaryArchives = @[ s_archive ];
    pso = [s_dev newRenderPipelineStateWithDescriptor:d error:err];
    ms = (double)(qpc() - t0) * 1000.0 / (double)QPC_FREQ;
    if (ms > 10.0)
        fprintf(stderr, "[METAL] pipeline %s built in %.0f ms%s\n", [[d.fragmentFunction name] UTF8String], ms,
                [NSThread isMainThread] ? " (main thread)" : "");
    if (pso && s_archive && ms > 2.0) {          /* a quick one came from the archive */
        MTLRenderPipelineDescriptor *copy = [d copy];
        dispatch_async(s_archive_queue, ^{
            NSError *e2 = nil;
            pthread_mutex_lock(&s_archive_lock);
            if ([s_archive addRenderPipelineFunctionsWithDescriptor:copy error:&e2])
                atomic_store(&s_archive_dirty, 1);
            pthread_mutex_unlock(&s_archive_lock);
            [copy release];
        });
    }
    return pso;
}

/* Saved every so often (from the frame loop) while new pipelines arrive. */
static void archive_save_maybe(void)
{
    static int64_t last;
    int64_t now = qpc();
    if (!s_archive || now - last < 20 * QPC_FREQ || !atomic_exchange(&s_archive_dirty, 0)) return;
    last = now;
    dispatch_async(s_archive_queue, ^{
        NSError *e = nil;
        pthread_mutex_lock(&s_archive_lock);
        if (![s_archive serializeToURL:s_archive_url error:&e])
            fprintf(stderr, "[METAL] pipeline archive not saved: %s\n", [[e description] UTF8String]);
        pthread_mutex_unlock(&s_archive_lock);
    });
}

/* The pipeline for these shaders, targets and blend; nil if it cannot be
 * built. blend: enable | write mask << 1. */
static id<MTLRenderPipelineState> pipeline(id<MTLFunction> vs, id<MTLFunction> fs,
                                           MTLPixelFormat color, MTLPixelFormat depth,
                                           NSUInteger samples, int enable, uint32_t mask,
                                           uint32_t sf, uint32_t df, uint32_t eq)
{
    PipeKey k;
    uint64_t h;
    uint32_t i;
    PipeSlot *slot = NULL;
    memset(&k, 0, sizeof k);
    k.vs = (void *)vs; k.fs = (void *)fs;
    k.color_fmt = (uint32_t)color; k.depth_fmt = (uint32_t)depth;
    k.samples = (uint32_t)samples;
    k.blend = (enable ? 1u : 0u) | ((mask & 15u) << 1);
    if (enable) { k.sf = sf; k.df = df; k.eq = eq; }
    h = pipe_hash(&k);
    for (i = 0; i < PIPE_SLOTS; i++) {
        PipeSlot *s = &s_pipes[(h + i) & (PIPE_SLOTS - 1)];
        if (!s->used) { slot = s; break; }
        if (!memcmp(&s->key, &k, sizeof k)) return s->pso;
    }
    if (!slot) {                         /* full: replace the home slot */
        slot = &s_pipes[h & (PIPE_SLOTS - 1)];
        [slot->pso release];
        slot->used = 0;
    }
    @autoreleasepool {
        MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
        NSError *err = nil;
        d.vertexFunction = vs;
        d.fragmentFunction = fs;
        d.rasterSampleCount = samples ? samples : 1;
        if (color != MTLPixelFormatInvalid) {
            MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0];
            a.pixelFormat = color;
            a.writeMask = metal_write_mask(mask);
            a.blendingEnabled = enable ? YES : NO;
            if (enable) {
                a.sourceRGBBlendFactor = blend_factor(sf, 0);
                a.destinationRGBBlendFactor = blend_factor(df, 0);
                a.sourceAlphaBlendFactor = blend_factor(sf, 1);
                a.destinationAlphaBlendFactor = blend_factor(df, 1);
                a.rgbBlendOperation = a.alphaBlendOperation = blend_op(eq);
            }
        }
        if (depth != MTLPixelFormatInvalid) {
            d.depthAttachmentPixelFormat = depth;
            d.stencilAttachmentPixelFormat = depth;
        }
        slot->pso = build_pso(d, &err);
        if (!slot->pso) fail([[NSString stringWithFormat:@"pipeline %@/%@", vs.name, fs.name] UTF8String], err);
        [d release];
    }
    slot->key = k;
    slot->used = 1;
    return slot->pso;
}

/* -------------------------------------------------- specialised pixel shaders
 * The ubershader interprets the register combiners per pixel, with dynamic
 * register indexing the compiler cannot keep in registers. Each combiner
 * configuration gets its own variant with the control words as function
 * constants, built on a background queue; draws use the ubershader until it
 * is ready, so output never changes. Only the control words are keyed;
 * factors and other floats stay in the constants. RECOMP_PS_SPEC=0 disables
 * this. */
typedef struct {
    uint32_t c_icw[8], a_icw[8], c_ocw[8], a_ocw[8];
    uint32_t fin0, fin1, rc_control, stage_prog, alpha_func, ps_flags;
    uint32_t clip_plane, other_input, dot_map, variant;
    uint32_t tex_info[4][3];
} PsKey;

typedef struct {
    PsKey key;
    _Atomic int state;              /* 0 empty, 1 queued, 2 ready, 3 failed */
    id<MTLFunction> fn;             /* valid once state is 2 */
    uint64_t draws, pixels_hint;    /* RECOMP_SPEC_DUMP: draws that used it */
} PsSpec;

#define PS_SPEC_SLOTS 4096          /* power of two */
static PsSpec *s_spec;
static int s_spec_enabled = -1;
static dispatch_queue_t s_spec_queue;
static _Atomic long s_spec_ready;

static void spec_dump(void);
static void spec_init(void)
{
    const char *v;
    if (s_spec_enabled >= 0) return;
    v = getenv("RECOMP_PS_SPEC");
    s_spec_enabled = !(v && *v == '0');
    if (s_spec_enabled) s_spec = (PsSpec *)calloc(PS_SPEC_SLOTS, sizeof *s_spec);
    if (s_spec && getenv("RECOMP_SPEC_DUMP")) atexit(spec_dump);
    if (!s_spec) { s_spec_enabled = 0; return; }
    s_spec_queue = dispatch_queue_create("nv2a.spec", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0));
}

static PsSpec *spec_find(const PsKey *k)
{
    static PsSpec *last;
    uint64_t hash;
    uint32_t h, i;
    if (last && atomic_load(&last->state) && !memcmp(&last->key, k, sizeof *k)) return last;
    hash = hash_mem((const uint8_t *)k, sizeof *k);
    h = (uint32_t)(hash ^ (hash >> 32));
    for (i = 0; i < PS_SPEC_SLOTS; i++) {
        PsSpec *e = &s_spec[(h + i) & (PS_SPEC_SLOTS - 1)];
        if (!atomic_load(&e->state)) return e;
        if (!memcmp(&e->key, k, sizeof *k)) { last = e; return e; }
    }
    return NULL;
}

static void spec_build(PsSpec *e)
{
    @autoreleasepool {
        const PsKey *k = &e->key;
        MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
        uint32_t vals[53];
        NSError *err = nil;
        id<MTLFunction> fn;
        int i, n = 0;
        for (i = 0; i < 8; i++) vals[n++] = k->c_icw[i];
        for (i = 0; i < 8; i++) vals[n++] = k->a_icw[i];
        for (i = 0; i < 8; i++) vals[n++] = k->c_ocw[i];
        for (i = 0; i < 8; i++) vals[n++] = k->a_ocw[i];
        vals[n++] = k->fin0; vals[n++] = k->fin1; vals[n++] = k->rc_control;
        vals[n++] = k->stage_prog; vals[n++] = k->alpha_func; vals[n++] = k->ps_flags;
        vals[n++] = k->clip_plane; vals[n++] = k->other_input; vals[n++] = k->dot_map;
        for (i = 0; i < 4; i++) {
            vals[n++] = k->tex_info[i][0]; vals[n++] = k->tex_info[i][1]; vals[n++] = k->tex_info[i][2];
        }
        [cv setConstantValues:vals type:MTLDataTypeUInt withRange:NSMakeRange(0, 53)];
        fn = [s_lib newFunctionWithName:[NSString stringWithUTF8String:s_psv_names[k->variant & 7]]
                         constantValues:cv error:&err];
        [cv release];
        if (fn) {
            long ready;
            e->fn = fn;
            atomic_store(&e->state, 2);
            ready = atomic_fetch_add(&s_spec_ready, 1) + 1;
            if (!(ready & (ready - 1)))
                fprintf(stderr, "[METAL] %ld specialised pixel shaders\n", ready);
        } else {
            fail("specialised pixel shader", err);
            atomic_store(&e->state, 3);
        }
    }
}

/* The specialised function for this configuration, or nil (not ready yet). */
static id<MTLFunction> spec_ps(const PSConsts *pc, uint32_t variant)
{
    PsKey k;
    PsSpec *e;
    uint32_t i;
    int state;
    spec_init();
    if (!s_spec_enabled) return nil;
    memset(&k, 0, sizeof k);
    memcpy(k.c_icw, pc->c_icw, sizeof k.c_icw);
    memcpy(k.a_icw, pc->a_icw, sizeof k.a_icw);
    memcpy(k.c_ocw, pc->c_ocw, sizeof k.c_ocw);
    memcpy(k.a_ocw, pc->a_ocw, sizeof k.a_ocw);
    k.fin0 = pc->fin0; k.fin1 = pc->fin1; k.rc_control = pc->rc_control;
    k.stage_prog = pc->stage_prog; k.alpha_func = pc->alpha_func; k.ps_flags = pc->ps_flags;
    k.clip_plane = pc->clip_plane; k.other_input = pc->other_input; k.dot_map = pc->dot_map;
    k.variant = variant;
    for (i = 0; i < 4; i++) {
        k.tex_info[i][0] = pc->tex_info[i][0]; k.tex_info[i][1] = pc->tex_info[i][1];
        k.tex_info[i][2] = pc->tex_info[i][2];
    }
    e = spec_find(&k);
    if (!e) return nil;
    state = atomic_load(&e->state);
    e->draws++;
    if (state == 2) return e->fn;
    if (state) return nil;
    e->key = k;
    atomic_store(&e->state, 1);
    dispatch_async(s_spec_queue, ^{ spec_build(e); });
    return nil;
}

/* RECOMP_SPEC_DUMP=file: at exit, every configuration with its draw count,
 * one line each (variant, then the 53 constants in function-constant order),
 * for mac/tests/bench_ps.m. */
static void spec_dump(void)
{
    const char *path = getenv("RECOMP_SPEC_DUMP");
    FILE *f;
    int i, j;
    if (!path || !s_spec || !(f = fopen(path, "w"))) return;
    for (i = 0; i < PS_SPEC_SLOTS; i++) {
        const PsSpec *e = &s_spec[i];
        const PsKey *k = &e->key;
        if (!e->draws) continue;
        fprintf(f, "%llu %u", (unsigned long long)e->draws, k->variant);
        for (j = 0; j < 8; j++) fprintf(f, " %x", k->c_icw[j]);
        for (j = 0; j < 8; j++) fprintf(f, " %x", k->a_icw[j]);
        for (j = 0; j < 8; j++) fprintf(f, " %x", k->c_ocw[j]);
        for (j = 0; j < 8; j++) fprintf(f, " %x", k->a_ocw[j]);
        fprintf(f, " %x %x %x %x %x %x %x %x %x", k->fin0, k->fin1, k->rc_control, k->stage_prog,
                k->alpha_func, k->ps_flags, k->clip_plane, k->other_input, k->dot_map);
        for (j = 0; j < 4; j++) fprintf(f, " %x %x %x", k->tex_info[j][0], k->tex_info[j][1], k->tex_info[j][2]);
        fprintf(f, "\n");
    }
    fclose(f);
}

/* Specialised pipelines are built off the render thread as well: until one
 * is ready the draw uses the ubershader's. */
typedef struct {
    PipeKey key;
    _Atomic int state;              /* 0 empty, 1 building, 2 ready, 3 failed */
    id<MTLRenderPipelineState> pso;
} SpecPipe;

#define SPEC_PIPE_SLOTS 8192
static SpecPipe *s_spec_pipes;

static id<MTLRenderPipelineState> spec_pipeline(id<MTLFunction> vs, id<MTLFunction> fs,
                                                MTLPixelFormat color, MTLPixelFormat depth,
                                                NSUInteger samples, int enable, uint32_t mask,
                                                uint32_t sf, uint32_t df, uint32_t eq)
{
    PipeKey k;
    uint64_t h;
    uint32_t i;
    SpecPipe *e = NULL;
    if (!s_spec_pipes && !(s_spec_pipes = (SpecPipe *)calloc(SPEC_PIPE_SLOTS, sizeof *s_spec_pipes)))
        return nil;
    memset(&k, 0, sizeof k);
    k.vs = (void *)vs; k.fs = (void *)fs;
    k.color_fmt = (uint32_t)color; k.depth_fmt = (uint32_t)depth;
    k.samples = (uint32_t)samples;
    k.blend = (enable ? 1u : 0u) | ((mask & 15u) << 1);
    if (enable) { k.sf = sf; k.df = df; k.eq = eq; }
    h = pipe_hash(&k);
    for (i = 0; i < SPEC_PIPE_SLOTS; i++) {
        SpecPipe *s = &s_spec_pipes[(h + i) & (SPEC_PIPE_SLOTS - 1)];
        if (!atomic_load(&s->state)) { e = s; break; }
        if (!memcmp(&s->key, &k, sizeof k))
            return atomic_load(&s->state) == 2 ? s->pso : nil;
    }
    if (!e) return nil;
    e->key = k;
    atomic_store(&e->state, 1);
    dispatch_async(s_spec_queue, ^{
        @autoreleasepool {
            MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
            NSError *err = nil;
            MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0];
            d.vertexFunction = vs;
            d.fragmentFunction = fs;
            d.rasterSampleCount = samples ? samples : 1;
            if (color != MTLPixelFormatInvalid) {
                a.pixelFormat = color;
                a.writeMask = metal_write_mask(mask);
                a.blendingEnabled = enable ? YES : NO;
                if (enable) {
                    a.sourceRGBBlendFactor = blend_factor(sf, 0);
                    a.destinationRGBBlendFactor = blend_factor(df, 0);
                    a.sourceAlphaBlendFactor = blend_factor(sf, 1);
                    a.destinationAlphaBlendFactor = blend_factor(df, 1);
                    a.rgbBlendOperation = a.alphaBlendOperation = blend_op(eq);
                }
            }
            if (depth != MTLPixelFormatInvalid) {
                d.depthAttachmentPixelFormat = depth;
                d.stencilAttachmentPixelFormat = depth;
            }
            e->pso = build_pso(d, &err);
            [d release];
            atomic_store(&e->state, e->pso ? 2 : 3);
        }
    });
    return nil;
}

/* ------------------------------------------------------------------ init */

static void display_config(int now);

static id<MTLTexture> make_texture_storage(UINT w, UINT h, UINT levels, MTLPixelFormat f,
                                           MTLTextureUsage usage, int cube, UINT samples,
                                           MTLStorageMode storage);

static id<MTLTexture> make_texture_ms(UINT w, UINT h, UINT levels, UINT array, MTLPixelFormat f,
                                      MTLTextureUsage usage, int cube, UINT samples)
{
    (void)array;
    return make_texture_storage(w, h, levels, f, usage, cube, samples, MTLStorageModePrivate);
}

static id<MTLTexture> make_texture_storage(UINT w, UINT h, UINT levels, MTLPixelFormat f,
                                           MTLTextureUsage usage, int cube, UINT samples,
                                           MTLStorageMode storage)
{
    MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
    id<MTLTexture> t;
    d.width = w ? w : 1;
    d.height = h ? h : 1;
    d.pixelFormat = f;
    d.mipmapLevelCount = levels ? levels : 1;
    d.sampleCount = samples ? samples : 1;
    d.textureType = cube ? MTLTextureTypeCube :
                    samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
    d.arrayLength = 1;
    d.usage = usage;
    d.storageMode = storage;
    t = [s_dev newTextureWithDescriptor:d];
    [d release];
    return t;
}

/* A BGRA volume (3D) texture the CPU fills with replaceRegion. */
static id<MTLTexture> make_volume(UINT w, UINT h, UINT depth, UINT levels)
{
    MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
    id<MTLTexture> t;
    d.textureType = MTLTextureType3D;
    d.width = w ? w : 1;
    d.height = h ? h : 1;
    d.depth = depth ? depth : 1;
    d.pixelFormat = PIX_BGRA;
    d.mipmapLevelCount = levels ? levels : 1;
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    t = [s_dev newTextureWithDescriptor:d];
    [d release];
    return t;
}

static id<MTLTexture> make_texture(UINT w, UINT h, UINT levels, UINT array, MTLPixelFormat f,
                                   MTLTextureUsage usage, int cube)
{
    return make_texture_ms(w, h, levels, array, f, usage, cube, 1);
}

/* Full mip chain length for w x h. */
static UINT full_levels(UINT w, UINT h)
{
    UINT n = 1, m = w > h ? w : h;
    while (m > 1) { m >>= 1; n++; }
    return n;
}

int nv2a_d3d_init(void)
{
    const char *e;
    if (s_init_state)
        return s_init_state > 0;
    s_init_state = -1;
    nv2a_d3d_prof_enabled();
    @autoreleasepool {
        int v;
        s_dev = MTLCreateSystemDefaultDevice();
        if (!s_dev) { fail("MTLCreateSystemDefaultDevice", nil); return 0; }
        fprintf(stderr, "[METAL] device: %s\n", [[s_dev name] UTF8String]);
        s_queue = [s_dev newCommandQueue];
        if (!(s_lib = load_library())) return 0;
        archive_init(hash_mem(nv2a_metal_source, sizeof nv2a_metal_source));
        for (v = 0; v < 6; v++)
            if (!(s_fn_psv[v] = function_unspecialised([NSString stringWithUTF8String:s_psv_names[v]]))) return 0;
        s_fn_dbg = function_unspecialised(@"ps_dbg");
        s_fn_dbg_tex = function_unspecialised(@"ps_dbg_tex");
        if (!(s_fn_ub_vs = function(@"ub_vs")) ||
            !(s_fn_present_vs = function(@"present_vs")) ||
            !(s_fn_present_ps = function(@"present_ps")) ||
            !(s_fn_clear_vs = function(@"clear_vs")) ||
            !(s_fn_clear_ps = function(@"clear_ps")) ||
            !(s_fn_y16_vs = function(@"y16_vs")) ||
            !(s_fn_y16_ps[0] = function(@"y16_ps")) ||
            !(s_fn_y16_ps[1] = function(@"y16_ps_ms")) ||
            !(s_fn_y16d_ps[0] = function(@"y16d_ps")) ||
            !(s_fn_y16d_ps[1] = function(@"y16d_ps_ms")))
            return 0;
        if (!ring_init(&s_vb_ring, VB_BYTES, "vertex") || !ring_init(&s_ib_ring, IB_BYTES, "index") ||
            !ring_init(&s_up_ring, UP_BYTES, "upload")) {
            fail("ring buffers", nil);
            return 0;
        }
        s_vis_buf = [s_dev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared];
        s_pipes = (PipeSlot *)calloc(PIPE_SLOTS, sizeof *s_pipes);
        if (!s_vis_buf || !s_pipes) { fail("state tables", nil); return 0; }
        {
            MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
            sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
            sd.mipFilter = MTLSamplerMipFilterLinear;
            sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
            s_linear_clamp = [s_dev newSamplerStateWithDescriptor:sd];
            sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
            sd.mipFilter = MTLSamplerMipFilterNearest;
            s_point_clamp = [s_dev newSamplerStateWithDescriptor:sd];
            [sd release];
        }
        {
            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = MTLCompareFunctionAlways;
            dd.depthWriteEnabled = NO;
            s_ds_off = [s_dev newDepthStencilStateWithDescriptor:dd];
            [dd release];
        }
        {
            /* Unbound texture slots read zero, as an unbound D3D SRV does. */
            static const uint32_t zero[6] = { 0 };
            int f;
            s_null_2d = make_texture(1, 1, 1, 1, PIX_BGRA, MTLTextureUsageShaderRead, 0);
            s_null_cube = make_texture(1, 1, 1, 6, PIX_BGRA, MTLTextureUsageShaderRead, 1);
            upload_region(s_null_2d, 0, 0, 0, 0, 1, 1, zero, 4, 1);
            for (f = 0; f < 6; f++)
                upload_region(s_null_cube, (NSUInteger)f, 0, 0, 0, 1, 1, zero, 4, 1);
            s_null_vol = make_volume(1, 1, 1, 1);
            if (s_null_vol)
                [s_null_vol replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:0
                                withBytes:zero bytesPerRow:4 bytesPerImage:4];
        }
    }
    display_config(1);
    if ((e = getenv("RECOMP_MSAA")) != NULL) s_msaa = (NSUInteger)atoi(e);
    if ((e = getenv("RECOMP_ANISO")) != NULL) s_aniso = (NSUInteger)atoi(e);
    if (s_aniso < 1) s_aniso = 1;
    if (s_aniso > 16) s_aniso = 16;
    if (s_msaa > 8) s_msaa = 8;
    for (; s_msaa > 1; s_msaa /= 2)
        if ([s_dev supportsTextureSampleCount:s_msaa]) break;
    if (s_msaa < 1) s_msaa = 1;
    spec_init();
    s_init_state = 1;
    fprintf(stderr, "[METAL] renderer ready: %ux%u internal, display aspect %.3f, %lux MSAA, %lux AF\n",
            (uint32_t)(GUEST_W * s_scale * widen() + 0.5f), (uint32_t)(GUEST_H * s_scale + 0.5f),
            nv2a_d3d_display_aspect(), (unsigned long)s_msaa, (unsigned long)s_aniso);
    fflush(stderr);
    return 1;
}

int nv2a_d3d_active(void)
{
    return s_init_state > 0;
}

/* --------------------------------------------------------------- surfaces */

typedef struct {
    uint32_t phys, va, pitch, bpp, w, h, iw, ih;
    uint32_t color_fmt;             /* SURFACE_FORMAT colour code */
    float sx, sy;                   /* host pixels per guest pixel */
    int swizzled;
    id<MTLTexture> tex;             /* single-sample; what is sampled */
    id<MTLTexture> ms;              /* MSAA target draws go into, or nil */
    int ms_dirty;                   /* ms drawn in a pass not yet ended */
    uint32_t gen, y16_gen;          /* drawn count; when y16 was built */
    id<MTLTexture> y16;             /* LU_IMAGE_Y16 view (see y16_ps) */
    id<MTLTexture> mip;             /* mip-mapped copy for reductions */
    uint32_t mip_gen;
    id<MTLTexture> chain;           /* this target plus the levels rendered below it */
    int chain_levels;
    uint32_t chain_gen[16];
    uint8_t *shadow;                /* guest bytes as of the last sync */
    int gpu_dirty;                  /* drawn since guest memory was updated */
    int cpu_present_pending;        /* idle CPU update not yet shown successfully */
    uint32_t drawn, shown_drawn;    /* GPU writes; how many the last present showed */
    uint32_t synced_frame, used_frame;
    uint32_t seq;                   /* bind order; see surface_find */
} Surface;

typedef struct {
    uint32_t phys, iw, ih, samples;
    id<MTLTexture> tex;             /* depth/stencil, sampled for y16 too */
    id<MTLTexture> y16;             /* LU_IMAGE_Y16 view (see y16d_ps) */
    int y16_light;                  /* y16 holds the local-light view */
    float y16_scale, y16_knee;      /* the remap y16 was built with */
    uint32_t zf, w, h;              /* zeta format code, guest size last bound with */
    uint32_t gen, y16_gen, seq;     /* as Surface */
    uint32_t used_frame;
} Depth;

#define MAX_SURFACES 32
#define MAX_DEPTHS 16
static Surface s_surf[MAX_SURFACES];
static Depth s_depth[MAX_DEPTHS];
static Surface *s_cur_rt;
/* Anti-aliased surfaces store 2x (CENTER_CORNER_2) or 2x2 (SQUARE_OFFSET_4)
 * samples per pixel of the coordinate space the title draws in. */
static uint32_t s_aa_x = 1, s_aa_y = 1;
static Depth *s_cur_ds;

#define USAGE_RT (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)

static uint32_t surface_color_bpp(uint32_t fmt)
{
    switch (fmt & 0xF) {
    case 0x1: case 0x2: case 0x3: case 0xA: return 2;
    case 0x4: case 0x5: case 0x6: case 0x7: case 0x8: return 4;
    case 0x9: return 1;
    default: return 0;
    }
}

/* Formats with no stored alpha hold a fixed value there: Z..=0, O..=1. */
static int surface_alpha_mode(uint32_t fmt)
{
    switch (fmt & 0xF) {
    case 0x1: case 0x4: case 0x6: return 0;     /* zero */
    case 0x2: case 0x3: case 0x5: case 0x7: return 1;   /* one */
    default: return -1;                         /* real alpha */
    }
}

/* What a draw into s renders into, and what that resolves into. */
static id<MTLTexture> surface_rt(const Surface *s) { return s->ms ? s->ms : s->tex; }
static id<MTLTexture> surface_rs(const Surface *s) { return s->ms ? s->tex : nil; }

/* Bring a surface's single-sample texture up to date with its MSAA target
 * before anything reads tex: the pass drawing into it resolves as it ends. */
static void surface_resolve(Surface *s)
{
    if (s->ms && s->ms_dirty) {
        if (s_pass_color == s->ms) end_encoders();
        s->ms_dirty = 0;
    }
}

static void unbind_targets(void)
{
    end_encoders();
    s_want_color = s_want_resolve = s_want_depth = nil;
    s_cur_rt = NULL;
    s_cur_ds = NULL;
}

/* Draw columns [u0, u1) of `src` into columns [x0, x1) of the target `dst`
 * (resolving into `dst_resolve` when multisampled), full height. With a mask,
 * only the pixels it marks are replaced. */
static int blit_span(id<MTLTexture> src, id<MTLTexture> mask, id<MTLTexture> dst,
                     id<MTLTexture> dst_resolve, UINT dst_w, UINT dst_h, float alpha,
                     float x0, float x1, float u0, float u1)
{
    PresentConsts pc;
    id<MTLRenderPipelineState> pso;
    id<MTLRenderCommandEncoder> e;
    if (!src || !dst) return 0;
    memset(&pc, 0, sizeof pc);
    pc.dst_rect[0] = x0 * 2 - 1; pc.dst_rect[1] = 1; pc.dst_rect[2] = x1 * 2 - 1; pc.dst_rect[3] = -1;
    pc.src_uv[0] = u0; pc.src_uv[2] = u1; pc.src_uv[3] = 1;
    pc.src_size[0] = pc.src_size[1] = pc.src_size[2] = pc.src_size[3] = 1;
    pc.force_alpha[0] = alpha;
    pc.ovl_flags[3] = mask ? 1 : 0;
    pso = pipeline(s_fn_present_vs, s_fn_present_ps, [dst pixelFormat], MTLPixelFormatInvalid,
                   [dst sampleCount], 0, WRITE_ALL, 0, 0, 0);
    if (!pso) return 0;
    NOTE_OWN_PASS(BRK_SPAN);
    unbind_targets();
    {
        MTLRenderPassDescriptor *d = pass_descriptor(dst, dst_resolve, nil);
        stamp_render(d, "span blit pass");
        e = [cmd() renderCommandEncoderWithDescriptor:d];
    }
    [e setRenderPipelineState:pso];
    [e setViewport:(MTLViewport){ 0, 0, (double)dst_w, (double)dst_h, 0, 1 }];
    [e setScissorRect:(MTLScissorRect){ 0, 0, dst_w, dst_h }];
    [e setDepthStencilState:s_ds_off];
    [e setVertexBytes:&pc length:sizeof pc atIndex:0];
    [e setFragmentBytes:&pc length:sizeof pc atIndex:0];
    [e setFragmentTexture:src atIndex:0];
    [e setFragmentTexture:mask ? mask : s_null_2d atIndex:1];
    [e setFragmentSamplerState:s_linear_clamp atIndex:0];
    [e setFragmentSamplerState:s_point_clamp atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
    return 1;
}

/* Where a surface's guest pixels live in its host texture, as fractions of
 * the width: all of it, or on a widened surface the centred 4:3 region --
 * the same place 2D overlays are drawn -- so a CPU-drawn image keeps its
 * proportions and write-back reads back exactly what was uploaded. */
static void guest_span(const Surface *s, float *x0, float *x1)
{
    float f = s->sx > s->sy * 1.001f ? s->sy / s->sx : 1.0f;
    *x0 = (1.0f - f) * 0.5f;
    *x1 = (1.0f + f) * 0.5f;
}

/* Guest rows of a surface as BGRA, with the format's fixed alpha. */
static void surface_rows_to_bgra(const Surface *s, const uint8_t *src,
                                 uint32_t pitch, uint32_t *out)
{
    int amode = surface_alpha_mode(s->color_fmt);
    uint32_t x, y;
    for (y = 0; y < s->h; y++) {
        const uint8_t *row = src + (size_t)y * pitch;
        uint32_t *dst = out + (size_t)y * s->w;
        if (s->bpp == 4) {
            memcpy(dst, row, (size_t)s->w * 4);
            if (amode >= 0)
                for (x = 0; x < s->w; x++)
                    dst[x] = (dst[x] & 0xFFFFFFu) | (amode ? 0xFF000000u : 0);
        } else if (s->bpp == 2) {
            const uint16_t *p = (const uint16_t *)row;
            for (x = 0; x < s->w; x++) {
                uint32_t v = p[x], r, g, b, a;
                if ((s->color_fmt & 0xF) == 0x3) {
                    r = d3d8_expand_channel((v >> 11) & 31, 5);
                    g = d3d8_expand_channel((v >> 5) & 63, 6);
                    b = d3d8_expand_channel(v & 31, 5);
                } else {
                    r = d3d8_expand_channel((v >> 10) & 31, 5);
                    g = d3d8_expand_channel((v >> 5) & 31, 5);
                    b = d3d8_expand_channel(v & 31, 5);
                }
                a = amode == 0 ? 0 : 255;
                dst[x] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        } else {
            memset(dst, 0, (size_t)s->w * 4);
        }
    }
}

/* Upload textures for guest images, reused while the size holds. A texture
 * rewritten while earlier draws still sample it would change those draws,
 * so each upload takes the next of a small rotation. */
#define UP_ROTATE 8
static id<MTLTexture> s_up_tex[2][UP_ROTATE];
static UINT s_up_w[2][UP_ROTATE], s_up_h[2][UP_ROTATE];
static unsigned s_up_next[2];
static uint32_t *s_up_pixels, *s_mask_pixels;
static size_t s_up_cap, s_mask_cap;
static uint8_t *s_swz_rows;
static size_t s_swz_cap;

/* slot 0: image, slot 1: change mask */
static id<MTLTexture> upload_slot(int k, const uint32_t *pixels, UINT w, UINT h)
{
    unsigned i = s_up_next[k]++ % UP_ROTATE;
    if (!s_up_tex[k][i] || s_up_w[k][i] != w || s_up_h[k][i] != h) {
        [s_up_tex[k][i] release];
        s_up_tex[k][i] = make_texture(w, h, 1, 1, PIX_BGRA, MTLTextureUsageShaderRead, 0);
        if (!s_up_tex[k][i]) return nil;
        s_up_w[k][i] = w; s_up_h[k][i] = h;
    }
    if (!upload_region(s_up_tex[k][i], 0, 0, 0, 0, w, h, pixels, (NSUInteger)w * 4, h))
        return nil;
    return s_up_tex[k][i];
}

static id<MTLTexture> upload_image(const uint32_t *pixels, UINT w, UINT h)
{
    return upload_slot(0, pixels, w, h);
}

static uint32_t *scratch_pixels(size_t count)
{
    if (count > s_up_cap) {
        free(s_up_pixels);
        s_up_pixels = (uint32_t *)malloc(count * 4);
        s_up_cap = s_up_pixels ? count : 0;
    }
    return s_up_pixels;
}

/* The shadow and change mask describe logical pixels. Swizzled targets
 * need the same CPU-write detection after undoing their Morton layout. */
static const uint8_t *surface_guest_rows(const Surface *s, uint32_t *pitch)
{
    size_t bytes;
    *pitch = s->pitch;
    if (!s->swizzled) return guest(s->va);
    *pitch = s->w * s->bpp;
    bytes = (size_t)*pitch * s->h;
    if (bytes > s_swz_cap) {
        free(s_swz_rows);
        s_swz_rows = (uint8_t *)malloc(bytes);
        s_swz_cap = s_swz_rows ? bytes : 0;
    }
    if (!s_swz_rows) return NULL;
    xbox_unswizzle_rect(s_swz_rows, guest(s->va), s->w, s->h, s->bpp);
    return s_swz_rows;
}

/* A single reusable pending shadow keeps CPU writes made during submission
 * visible to the next sync. Only successfully submitted bytes become the
 * surface shadow; swapping buffers avoids copying them again on commit. */
static uint8_t *s_sync_rows;
static size_t s_sync_cap;

/* Guest memory is the authority for what the CPU writes. A shadow copy of
 * each surface's guest bytes says which pixels the CPU changed since the last
 * look; only those replace what the GPU drew. A loading screen drawn by the
 * GPU and then animated by CPU writes keeps both. */
static void surface_sync_impl(Surface *s, int force)
{
    uint32_t rowb = s->w * s->bpp, y, x, x0 = 0xFFFFFFFFu, x1 = 0, y0 = 0xFFFFFFFFu, y1 = 0;
    uint32_t pitch;
    size_t bytes = (size_t)rowb * s->h, count = (size_t)s->w * s->h;
    uint32_t *px, *mask;
    const uint8_t *g;
    id<MTLTexture> srv, msk = nil;
    float span0, span1;
    if (!s->bpp || !guest_ok(s->va, (size_t)s->pitch * s->h))
        return;
    if (!force && s->synced_frame == s_epoch)
        return;
    /* A forced sync can fail after an earlier successful sync in this epoch. */
    s->synced_frame = s_epoch - 1;
    g = surface_guest_rows(s, &pitch);
    if (!g) return;
    if (s->shadow) {
        /* The common unchanged path allocates and copies nothing. */
        for (y = 0; y < s->h; y++)
            if (memcmp(g + (size_t)y * pitch, s->shadow + (size_t)y * rowb, rowb))
                break;
        if (y == s->h) { s->synced_frame = s_epoch; return; }
    }
    if (bytes > s_sync_cap) {
        uint8_t *rows = (uint8_t *)realloc(s_sync_rows, bytes);
        if (!rows) return;
        s_sync_rows = rows;
        s_sync_cap = bytes;
    }
    for (y = 0; y < s->h; y++)
        memcpy(s_sync_rows + (size_t)y * rowb, g + (size_t)y * pitch, rowb);
    if (s->shadow) {
        if (s_mask_cap < count) {
            uint32_t *pixels = (uint32_t *)realloc(s_mask_pixels, count * 4);
            if (!pixels) return;
            s_mask_pixels = pixels;
            s_mask_cap = count;
        }
        memset(s_mask_pixels, 0, count * 4);
        for (y = 0; y < s->h; y++) {
            const uint8_t *row = s_sync_rows + (size_t)y * rowb;
            const uint8_t *sh = s->shadow + (size_t)y * rowb;
            if (!memcmp(row, sh, rowb)) continue;
            if (y0 == 0xFFFFFFFFu) y0 = y;
            y1 = y;
            mask = s_mask_pixels + (size_t)y * s->w;
            for (x = 0; x < s->w; x++)
                if (memcmp(row + x * s->bpp, sh + x * s->bpp, s->bpp)) {
                    mask[x] = 0xFFFFFFFFu;
                    if (x < x0) x0 = x;
                    if (x > x1) x1 = x;
                }
        }
        if (y0 == 0xFFFFFFFFu) { s->synced_frame = s_epoch; return; }
        if (getenv("RECOMP_D3D_TRACE"))
            fprintf(stderr, "[METAL] CPU wrote surface %08X (frame %u) %u,%u-%u,%u\n",
                    s->phys, s_frame, x0, y0, x1, y1);
    }
    px = scratch_pixels(count);
    if (!px) return;
    surface_rows_to_bgra(s, s_sync_rows, rowb, px);
    srv = upload_slot(0, px, s->w, s->h);
    if (!srv) return;
    if (s->shadow) {
        msk = upload_slot(1, s_mask_pixels, s->w, s->h);
        if (!msk) return;
    }
    guest_span(s, &span0, &span1);
    if (!blit_span(srv, msk, surface_rt(s), surface_rs(s), s->iw, s->ih, -1.0f, span0, span1, 0, 1))
        return;
    {
        uint8_t *old_shadow = s->shadow;
        s->shadow = s_sync_rows;
        s_sync_rows = old_shadow;
        s_sync_cap = old_shadow ? bytes : 0;
    }
    s->synced_frame = s_epoch;
    s->ms_dirty = 0;                 /* the blit's pass resolved as it ended */
    s->gen++;
}

static void surface_sync(Surface *s, int force)
{
    int64_t t0 = s_prof_on > 0 ? qpc() : 0;
    RECOMP_PROFILE_BEGIN("Metal surface sync");
    surface_sync_impl(s, force);
    RECOMP_PROFILE_END();
    if (s_prof_on > 0) s_prof[PROF_SYNC] += qpc() - t0;
}

static void writeback_drop_surface(Surface *s);

static void surface_release(Surface *s)
{
    writeback_drop_surface(s);
    if (s_cur_rt == s) unbind_targets();
    if (s_pass_color && (s_pass_color == s->tex || s_pass_color == s->ms)) end_encoders();
    [s->ms release];
    [s->y16 release];
    [s->mip release];
    [s->chain release];
    [s->tex release];
    free(s->shadow);
    memset(s, 0, sizeof *s);
}

/* Titles reuse one block of memory as targets of different shapes. Each shape keeps its own
 * host surface; the address resolves to the one bound most recently. */
static uint32_t s_surf_seq;

static Surface *surface_find(uint32_t p)
{
    Surface *best = NULL;
    int i;
    for (i = 0; i < MAX_SURFACES; i++)
        if (s_surf[i].tex && s_surf[i].phys == p && (!best || s_surf[i].seq > best->seq))
            best = &s_surf[i];
    return best;
}

static Surface *surface_get(uint32_t va, uint32_t pitch, uint32_t fmt,
                            uint32_t w, uint32_t h, int swizzled)
{
    uint32_t p = phys(va), bpp = surface_color_bpp(fmt);
    Surface *s = NULL, *victim = NULL;
    int i;
    for (i = 0; i < MAX_SURFACES; i++) {
        Surface *c = &s_surf[i];
        if (c->tex && c->phys == p && c->w >= w && c->h >= h && c->pitch == pitch &&
            c->bpp == bpp && c->swizzled == swizzled) {
            c->color_fmt = fmt;
            c->used_frame = s_frame;
            c->seq = ++s_surf_seq;
            return c;
        }
    }
    /* Same shape grown in place starts again from guest memory; another
     * shape at this address gets a surface of its own. */
    for (i = 0; i < MAX_SURFACES && !s; i++)
        if (s_surf[i].tex && s_surf[i].phys == p && s_surf[i].pitch == pitch &&
            s_surf[i].bpp == bpp && s_surf[i].swizzled == swizzled)
            s = &s_surf[i];
    if (s) {
        if (w < s->w && s->pitch == pitch) w = s->w;
        if (h < s->h && s->pitch == pitch) h = s->h;
        victim = s;
        fprintf(stderr, "[SURF] frame %u grow %08X %ux%u -> %ux%u (used frame %u)\n",
                s_frame, p, s->w, s->h, w, h, s->used_frame);
    } else {
        for (i = 0; i < MAX_SURFACES && !victim; i++)
            if (!s_surf[i].tex) victim = &s_surf[i];
        if (!victim) {
            for (i = 0; i < MAX_SURFACES; i++)
                if (!victim || s_surf[i].used_frame < victim->used_frame)
                    victim = &s_surf[i];
            if (victim)
                fprintf(stderr, "[SURF] frame %u evict %08X %ux%u (used frame %u) for %08X %ux%u\n",
                        s_frame, victim->phys, victim->w, victim->h, victim->used_frame, p, w, h);
        }
        if (!victim) victim = &s_surf[0];
    }
    surface_release(victim);
    s = victim;
    s->phys = p; s->va = va; s->pitch = pitch; s->bpp = bpp;
    s->w = w; s->h = h; s->color_fmt = fmt; s->swizzled = swizzled;
    /* Display-sized surfaces carry the widescreen image; everything else
     * (environment maps, blur buffers, meters) keeps its aspect. */
    s->sy = s_scale;
    s->sx = (!swizzled && w == GUEST_W && h == GUEST_H) ? s_scale * widen() : s_scale;
    s->iw = (uint32_t)(w * s->sx + 0.5f);
    s->ih = (uint32_t)(h * s->sy + 0.5f);
    s->tex = make_texture(s->iw, s->ih, 1, 1, PIX_BGRA, USAGE_RT, 0);
    if (!s->tex) { fail("surface texture", nil); memset(s, 0, sizeof *s); return NULL; }
    /* Render-to-texture (swizzled) targets stay single-sample. */
    if (s_msaa > 1 && !swizzled)
        s->ms = make_texture_ms(s->iw, s->ih, 1, 1, PIX_BGRA, USAGE_RT, 0, (UINT)s_msaa);
    s->used_frame = s_frame;
    s->seq = ++s_surf_seq;
    {
        static const float zero[4] = { 0, 0, 0, 0 };
        clear_pass(surface_rt(s), surface_rs(s), nil, zero);
        s->gen++;
    }
    surface_sync(s, 1);
    if (getenv("RECOMP_D3D_TRACE"))
        fprintf(stderr, "[METAL] surface %08X %ux%u pitch %u fmt %X%s\n", p, w, h,
                pitch, fmt & 0xF, swizzled ? " swizzled" : "");
    return s;
}

static void depth_release(Depth *d)
{
    if (d->tex && s_pass_depth == d->tex) end_encoders();
    [d->y16 release];
    [d->tex release];
    memset(d, 0, sizeof *d);
}

/* The Z24S8 depth buffer most recently bound at p, or NULL. */
static Depth *depth_find(uint32_t p)
{
    Depth *best = NULL;
    int i;
    for (i = 0; i < MAX_DEPTHS; i++)
        if (s_depth[i].tex && s_depth[i].phys == p && s_depth[i].zf != 1 &&
            (!best || s_depth[i].seq > best->seq))
            best = &s_depth[i];
    return best;
}

static Depth *depth_get(uint32_t va, uint32_t iw, uint32_t ih, UINT samples)
{
    uint32_t p = phys(va);
    Depth *d, *victim = NULL;
    int i;
    for (i = 0; i < MAX_DEPTHS; i++) {
        d = &s_depth[i];
        if (d->tex && d->phys == p && d->iw == iw && d->ih == ih && d->samples == samples) {
            d->used_frame = s_frame;
            return d;
        }
    }
    for (i = 0; i < MAX_DEPTHS && !victim; i++)
        if (!s_depth[i].tex) victim = &s_depth[i];
    for (i = 0; i < MAX_DEPTHS; i++)
        if (!victim || s_depth[i].used_frame < victim->used_frame)
            victim = &s_depth[i];
    d = victim;
    if (d->tex)
        fprintf(stderr, "[SURF] frame %u depth evict %08X %ux%u (used frame %u) for %08X %ux%u\n",
                s_frame, d->phys, d->iw, d->ih, d->used_frame, p, iw, ih);
    if (s_cur_ds == d) unbind_targets();
    depth_release(d);
    /* Sampled too, when the title reads it back as a texture (depth_y16). */
    d->tex = make_texture_ms(iw, ih, 1, 1, PIX_DEPTH, USAGE_RT, 0, samples);
    if (!d->tex) return NULL;
    clear_pass(nil, nil, d->tex, NULL);
    d->phys = p; d->iw = iw; d->ih = ih; d->samples = samples; d->used_frame = s_frame;
    return d;
}

/* The colour surface and depth buffer a draw or clear writes, bound. Returns
 * the colour surface (may be NULL for a depth-only pass) via *out. */
static int bind_targets(const NvD3DState *st, int want_depth, Surface **out,
                        Depth **dout, uint32_t *gw, uint32_t *gh)
{
    uint32_t fmt = st->surface_format, w, h;
    int swizzled = ((fmt >> 8) & 0xF) == 2;
    Surface *s = NULL;
    Depth *d = NULL;
    uint32_t aa = (fmt >> 12) & 0xF;
    s_aa_x = aa ? 2 : 1;
    s_aa_y = aa == 2 ? 2 : 1;
    if (swizzled) {
        w = 1u << ((fmt >> 16) & 0xF);
        /* NV097 surface log-height is bits 24..31, after log-width 16..23.
         * Reading bit 20 collapsed a 0x07070228 surface to one row. */
        h = 1u << ((fmt >> 24) & 0xF);
        s_aa_x = s_aa_y = 1;
    } else {
        w = (st->clip_x + st->clip_w) * s_aa_x;
        h = (st->clip_y + st->clip_h) * s_aa_y;
    }
    if (!w || !h || w > 4096 || h > 4096)
        return 0;
    if (st->color_addr && surface_color_bpp(fmt) &&
        guest_ok(st->color_addr, (size_t)(swizzled ? w * surface_color_bpp(fmt) : st->color_pitch) * h)) {
        s = surface_get(st->color_addr, swizzled ? w * surface_color_bpp(fmt) : st->color_pitch,
                        fmt, w, h, swizzled);
        if (s) surface_sync(s, 0);
    }
    if (want_depth && st->zeta_addr && ((fmt >> 4) & 0xF)) {
        float wx = (w == GUEST_W && h == GUEST_H) ? s_scale * widen() : s_scale;
        uint32_t iw = s ? s->iw : (uint32_t)(w * wx + 0.5f);
        uint32_t ih = s ? s->ih : (uint32_t)(h * s_scale + 0.5f);
        UINT ns = s ? (s->ms ? (UINT)s_msaa : 1) : (swizzled ? 1 : (UINT)s_msaa);
        d = depth_get(st->zeta_addr, iw, ih, ns);
    }
    if (!s && !d)
        return 0;
    if (s && d && (d->iw != s->iw || d->ih != s->ih))
        d = NULL;
    if (s) { s->ms_dirty = 1; s->gen++; }
    if (d) { d->gen++; d->seq = ++s_surf_seq; d->zf = (fmt >> 4) & 0xF; d->w = w; d->h = h; }
    s_want_color = s ? surface_rt(s) : nil;
    s_want_resolve = s ? surface_rs(s) : nil;
    s_want_depth = d ? d->tex : nil;
    s_cur_rt = s;
    s_cur_ds = d;
    s_vp_w = s ? s->iw : d->iw;
    s_vp_h = s ? s->ih : d->ih;
    s_cur_sx = s ? s->sx : (float)d->iw / (float)w;
    s_cur_sy = s ? s->sy : (float)d->ih / (float)h;
    *out = s; *dout = d;
    *gw = (s ? s->w : w) / s_aa_x;
    *gh = (s ? s->h : h) / s_aa_y;
    return 1;
}

/* --------------------------------------------------------------- textures */

enum { K_SWZ, K_LIN, K_DXT };

/* Bytes per texel and layout of an NV097 texture colour format; 0 if the
 * format is not one this decodes. */
static int tex_format(uint32_t c, int *kind)
{
    switch (c) {
    case 0x00: case 0x01: case 0x0B: case 0x19: *kind = K_SWZ; return 1;
    case 0x02: case 0x03: case 0x04: case 0x05: case 0x1A: case 0x27:
    case 0x28: case 0x29: case 0x2C: case 0x2D: case 0x32: case 0x38: case 0x39:
        *kind = K_SWZ; return 2;
    case 0x06: case 0x07: case 0x2A: case 0x2B: case 0x3A: case 0x3B: case 0x3C:
        *kind = K_SWZ; return 4;
    case 0x0C: *kind = K_DXT; return 8;
    case 0x0E: case 0x0F: *kind = K_DXT; return 16;
    case 0x13: case 0x1B: case 0x1F: *kind = K_LIN; return 1;
    case 0x10: case 0x11: case 0x16: case 0x17: case 0x1C: case 0x1D: case 0x20:
    case 0x24: case 0x25: case 0x30: case 0x31: case 0x35: case 0x37:
    case 0x3D: case 0x3E:
        *kind = K_LIN; return 2;
    case 0x12: case 0x1E: case 0x2E: case 0x2F: case 0x3F: case 0x40: case 0x41:
        *kind = K_LIN; return 4;
    default: return 0;
    }
}

static uint32_t x5(uint32_t v) { return d3d8_expand_channel(v & 31, 5); }
static uint32_t x6(uint32_t v) { return d3d8_expand_channel(v & 63, 6); }
static uint32_t x4(uint32_t v) { return d3d8_expand_channel(v & 15, 4); }
static uint32_t argb(uint32_t a, uint32_t r, uint32_t g, uint32_t b)
{
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/* One texel, as ARGB (= BGRA bytes). */
static uint32_t texel(uint32_t c, const uint8_t *p, const uint32_t *pal)
{
    uint32_t v;
    switch (c) {
    case 0x00: case 0x13: return argb(255, p[0], p[0], p[0]);           /* Y8  */
    case 0x01: case 0x1B: return argb(p[0], p[0], p[0], p[0]);          /* AY8 */
    case 0x19: case 0x1F: return argb(p[0], 255, 255, 255);             /* A8  */
    case 0x0B: return pal ? pal[p[0]] : argb(255, p[0], p[0], p[0]);    /* I8  */
    case 0x1A: case 0x20: return argb(p[1], p[0], p[0], p[0]);          /* A8Y8 */
    case 0x06: case 0x12: memcpy(&v, p, 4); return v;
    case 0x07: case 0x1E: memcpy(&v, p, 4); return v | 0xFF000000u;
    case 0x3A: case 0x3F: memcpy(&v, p, 4);                              /* A8B8G8R8 */
        return (v & 0xFF00FF00u) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF);
    case 0x3B: case 0x40: memcpy(&v, p, 4);                              /* B8G8R8A8 */
        return argb(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24);
    case 0x3C: case 0x41: memcpy(&v, p, 4);                              /* R8G8B8A8 */
        return argb(v & 0xFF, v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF);
    case 0x2A: case 0x2B: case 0x2E: case 0x2F: memcpy(&v, p, 4);        /* depth */
        return argb(255, v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF);
    }
    v = (uint32_t)p[0] | ((uint32_t)p[1] << 8);
    switch (c) {
    case 0x02: case 0x10: return argb(v & 0x8000 ? 255 : 0, x5(v >> 10), x5(v >> 5), x5(v));
    case 0x03: case 0x1C: return argb(255, x5(v >> 10), x5(v >> 5), x5(v));
    case 0x04: case 0x1D: return argb(x4(v >> 12), x4(v >> 8), x4(v >> 4), x4(v));
    case 0x05: case 0x11: return argb(255, x5(v >> 11), x6(v >> 5), x5(v));
    case 0x27: case 0x37: return argb(255, x6(v >> 10), x5(v >> 5), x5(v));  /* R6G5B5 */
    case 0x28: case 0x17: return argb(255, 0, v >> 8, v & 0xFF);              /* G8B8 */
    case 0x29: case 0x16: return argb(255, v >> 8, 0, v & 0xFF);              /* R8B8 */
    case 0x38: case 0x3D: return argb(v & 1 ? 255 : 0, x5(v >> 11), x5(v >> 6), x5(v >> 1));
    case 0x39: case 0x3E: return argb(x4(v), x4(v >> 12), x4(v >> 8), x4(v >> 4));
    case 0x2C: case 0x2D: case 0x30: case 0x31: case 0x32: case 0x35:
        return argb(255, v >> 8, v >> 8, v >> 8);
    }
    {   /* Magenta marks an undecoded format; say which, once each. */
        static uint64_t s_unknown[2];
        if (c < 128 && !(s_unknown[c >> 6] & (1ull << (c & 63)))) {
            s_unknown[c >> 6] |= 1ull << (c & 63);
            fprintf(stderr, "[METAL] texture format 0x%02X not decoded (drawn magenta)\n", c);
        }
    }
    return 0xFFFF00FFu;
}

static void yuv_pair(const uint8_t *g, int uyvy, uint32_t out[2])
{
    int yo = uyvy ? 1 : 0, k;
    int cu = (int)g[1 - yo] - 128, cv = (int)g[3 - yo] - 128;
    for (k = 0; k < 2; k++) {
        int c = (int)g[k * 2 + yo] - 16;
        int r = (298 * c + 409 * cv + 128) >> 8;
        int gg = (298 * c - 100 * cu - 208 * cv + 128) >> 8;
        int b = (298 * c + 516 * cu + 128) >> 8;
        r = r < 0 ? 0 : r > 255 ? 255 : r;
        gg = gg < 0 ? 0 : gg > 255 ? 255 : gg;
        b = b < 0 ? 0 : b > 255 ? 255 : b;
        out[k] = argb(255, (uint32_t)r, (uint32_t)gg, (uint32_t)b);
    }
}

typedef struct TexEntry {
    uint32_t phys, format, pitch, w, h, palette, palette_len, used;
    uint32_t depth;                 /* > 1: a volume (volume_get) */
    uint64_t hash, pal_hash;
    uint32_t checked_epoch;
    size_t bytes;
    id<MTLTexture> tex;
    struct TexEntry *next;
} TexEntry;

#define TEX_BUCKETS 1024
static TexEntry *s_tex_bucket[TEX_BUCKETS];
static size_t s_tex_bytes, s_tex_count;
#define TEX_BUDGET ((size_t)768 << 20)

/* Where each level/face lives, and the span to hash. */
typedef struct {
    int kind, bpp, levels, faces, volume;
    uint32_t level_off[16], level_w[16], level_h[16], level_d[16];
    size_t face_stride, total;
} TexLayout;

/* DIMENSIONALITY 3 in SET_TEXTURE_FORMAT: a volume, depth BASE_SIZE_P. */
static int texture_is_volume(const NvD3DTexture *t)
{
    return !t->cube && (t->depth > 1 || ((t->format >> 4) & 15u) == 3u);
}

static int tex_layout(const NvD3DTexture *t, TexLayout *L)
{
    uint32_t w = t->width, h = t->height, d = 1, lv, maxlv = 1, m;
    size_t off = 0;
    memset(L, 0, sizeof *L);
    L->bpp = tex_format(t->color, &L->kind);
    if (!L->bpp || !w || !h || w > 4096 || h > 4096)
        return 0;
    L->faces = t->cube ? 6 : 1;
    L->volume = texture_is_volume(t);
    if (L->volume) {
        d = t->depth ? t->depth : 1;
        if (d > 2048 || L->kind == K_LIN) return 0;
    }
    if (L->kind == K_LIN) {
        if (!t->pitch) return 0;
        L->levels = 1;
        L->level_w[0] = w; L->level_h[0] = h; L->level_d[0] = 1;
        L->total = L->face_stride = (size_t)t->pitch * h;
        L->faces = 1;
        return 1;
    }
    m = w > h ? w : h;
    if (d > m) m = d;
    for (; m > 1; m >>= 1) maxlv++;
    L->levels = t->levels ? (int)t->levels : 1;
    if (L->levels > (int)maxlv) L->levels = (int)maxlv;
    for (lv = 0; lv < (uint32_t)L->levels; lv++) {
        uint32_t lw = w >> lv ? w >> lv : 1, lh = h >> lv ? h >> lv : 1;
        uint32_t ld = d >> lv ? d >> lv : 1;
        L->level_off[lv] = (uint32_t)off;
        L->level_w[lv] = lw; L->level_h[lv] = lh; L->level_d[lv] = ld;
        off += (L->kind == K_DXT ? (size_t)((lw + 3) / 4) * ((lh + 3) / 4) * L->bpp
                                 : (size_t)lw * lh * L->bpp) * ld;
    }
    L->face_stride = L->faces > 1 ? (off + 127) & ~(size_t)127 : off;
    L->total = L->face_stride * (L->faces - 1) + off;
    return 1;
}

/* A 4x4 Morton tile is contiguous in guest memory. Copy pairs into its four
 * destination rows, keeping source cache lines hot. */
static void decode_swizzled_argb32(const uint8_t *src, uint32_t w, uint32_t h,
                                   uint32_t *out, int opaque)
{
    uint32_t mx, my, ox, oy = 0, x, y, row;
    uint64_t alpha = opaque ? 0xFF000000FF000000ull : 0;
    xbox_swizzle_masks(w, h, &mx, &my);
    mx &= ~15u; my &= ~15u;
    for (y = 0; y < h; y += 4) {
        ox = 0;
        for (x = 0; x < w; x += 4) {
            const uint8_t *tile = src + (size_t)(oy + ox) * 4;
            uint32_t *dst = out + (size_t)y * w + x;
            for (row = 0; row < 4; row++) {
                uint64_t left, right;
                uint32_t offset = (row & 1) * 8 + (row & 2) * 16;
                memcpy(&left, tile + offset, 8);
                memcpy(&right, tile + offset + 16, 8);
                left |= alpha; right |= alpha;
                memcpy(dst + (size_t)row * w, &left, 8);
                memcpy(dst + (size_t)row * w + 2, &right, 8);
            }
            ox = (ox - mx) & mx;
        }
        oy = (oy - my) & my;
    }
}

static void decode_level(const NvD3DTexture *t, const TexLayout *L, const uint8_t *src,
                         int lv, const uint32_t *pal, uint32_t *out)
{
    uint32_t w = L->level_w[lv], h = L->level_h[lv], x, y;
    if (L->kind == K_DXT) {
        uint32_t bw = (w + 3) / 4, bh = (h + 3) / 4, bx, by, px[16];
        if (!(w & 3) && !(h & 3)) {
            for (by = 0; by < bh; by++)
                for (bx = 0; bx < bw; bx++) {
                    uint32_t *dst = out + (size_t)by * 4 * w + bx * 4;
                    d3d8_dxt_decode_block(src + ((size_t)by * bw + bx) * L->bpp, t->color, px);
                    memcpy(dst, px, 16);
                    memcpy(dst + w, px + 4, 16);
                    memcpy(dst + 2 * w, px + 8, 16);
                    memcpy(dst + 3 * w, px + 12, 16);
                }
            return;
        }
        for (by = 0; by < bh; by++)
            for (bx = 0; bx < bw; bx++) {
                d3d8_dxt_decode_block(src + ((size_t)by * bw + bx) * L->bpp, t->color, px);
                for (y = 0; y < 4 && by * 4 + y < h; y++)
                    for (x = 0; x < 4 && bx * 4 + x < w; x++)
                        out[(size_t)(by * 4 + y) * w + bx * 4 + x] = px[y * 4 + x];
            }
        return;
    }
    if ((t->color == 0x06 || t->color == 0x07) && w >= 4 && h >= 4 &&
        !(w & (w - 1)) && !(h & (h - 1))) {
        decode_swizzled_argb32(src, w, h, out, t->color == 0x07);
        return;
    }
    if (L->kind == K_LIN) {
        for (y = 0; y < h; y++) {
            const uint8_t *row = src + (size_t)y * t->pitch;
            uint32_t *dst = out + (size_t)y * w;
            if (t->color == 0x24 || t->color == 0x25) {
                for (x = 0; x + 1 < w; x += 2)
                    yuv_pair(row + x * 2, t->color == 0x25, dst + x);
            } else if (t->color == 0x12) {
                memcpy(dst, row, (size_t)w * 4);
            } else {
                for (x = 0; x < w; x++)
                    dst[x] = texel(t->color, row + (size_t)x * L->bpp, pal);
            }
        }
        return;
    }
    {
        /* Swizzled: undo the Morton order a texel at a time. */
        uint32_t mx, my, oy = 0;
        xbox_swizzle_masks(w, h, &mx, &my);
        for (y = 0; y < h; y++) {
            uint32_t ox = 0, *dst = out + (size_t)y * w;
            for (x = 0; x < w; x++) {
                dst[x] = texel(t->color, src + (size_t)(oy + ox) * L->bpp, pal);
                ox = (ox - mx) & mx;
            }
            oy = (oy - my) & my;
        }
    }
}

/* A cached on/off environment switch: def unless set, "0" off, else on. */
static int env_switch(const char *name, int *cache, int def)
{
    if (*cache < 0) {
        const char *e = getenv(name);
        *cache = e && *e ? strcmp(e, "0") != 0 : def;
    }
    return *cache;
}

/* Bisection switches for this renderer's GPU-side choices (see the uses). */
static int s_sw_ps_nc = -1, s_sw_tex_blit = -1;
#define PS_NC()     env_switch("RECOMP_PS_NC", &s_sw_ps_nc, 1)
#define TEX_BLIT()  env_switch("RECOMP_TEX_BLIT", &s_sw_tex_blit, 0)

/* The title's textures live in shared storage and are written by the CPU
 * (replaceRegion) instead of copied in the command stream: a blit there ends
 * the open render pass, and at 1440p with 4x MSAA each pass break stores and
 * reloads every sample of the colour and depth targets. Contents that change
 * get a new texture (texture_get), so no write ever reaches one the GPU may
 * still be reading. */
static id<MTLTexture> guest_texture(UINT w, UINT h, UINT levels, MTLPixelFormat f, int cube)
{
    return make_texture_storage(w, h, levels, f, MTLTextureUsageShaderRead, cube, 1,
                                TEX_BLIT() ? MTLStorageModePrivate : MTLStorageModeShared);
}

/* RECOMP_TEX_BLIT=1: the previous way, uploads copied in the command stream. */
static void texture_write(id<MTLTexture> tex, NSUInteger slice, NSUInteger level,
                          NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h,
                          const void *pixels, NSUInteger row_bytes, NSUInteger rows)
{
    if (TEX_BLIT()) {
        upload_region(tex, slice, level, x, y, w, h, pixels, row_bytes, rows);
        return;
    }
    [tex replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:level slice:slice
             withBytes:pixels bytesPerRow:row_bytes bytesPerImage:0];
}

static void tex_free(TexEntry *e)
{
    [e->tex release];
    s_tex_bytes -= e->bytes;
    s_tex_count--;
    free(e);
}

static void tex_evict(void)
{
    /* Least recently used, until under budget. */
    while (s_tex_bytes > TEX_BUDGET) {
        TexEntry **best = NULL, **pp;
        int b;
        for (b = 0; b < TEX_BUCKETS; b++)
            for (pp = &s_tex_bucket[b]; *pp; pp = &(*pp)->next)
                if ((*pp)->used != s_frame && (!best || (*pp)->used < (*best)->used))
                    best = pp;
        if (!best) return;
        {
            TexEntry *e = *best;
            *best = e->next;
            tex_free(e);
        }
    }
}

/* One mip level below src: a 2x2 box (a dimension already 1 stays 1).
 * src == dst is safe: each output is written only after reading its complete
 * source footprint, and precedes the next footprint in forward row order. */
static void halve_bgra(const uint32_t *src, uint32_t w, uint32_t h, uint32_t *dst)
{
    uint32_t nw = w > 1 ? w / 2 : 1, nh = h > 1 ? h / 2 : 1, x, y, c;
    for (y = 0; y < nh; y++)
        for (x = 0; x < nw; x++) {
            uint32_t x0 = w > 1 ? 2 * x : x, y0 = h > 1 ? 2 * y : y;
            uint32_t x1 = w > 1 ? x0 + 1 : x0, y1 = h > 1 ? y0 + 1 : y0, out = 0;
            for (c = 0; c < 32; c += 8)
                out |= ((((src[y0 * w + x0] >> c) & 255) + ((src[y0 * w + x1] >> c) & 255) +
                         ((src[y1 * w + x0] >> c) & 255) + ((src[y1 * w + x1] >> c) & 255) + 2) / 4) << c;
            dst[y * nw + x] = out;
        }
}

/* Mip levels the host texture gets. Titles shipped short chains to save
 * memory, so distant surfaces kept sampling a level far finer than their
 * footprint -- grain and shimmer. A chain the title started is completed
 * down to 1x1 from its own smallest level; a single level stays single. */
static int host_levels(const TexLayout *L, const NvD3DTexture *t)
{
    int n = 1;
    uint32_t m = t->width > t->height ? t->width : t->height;
    if (L->levels < 2) return L->levels;
    while (m > 1) { m >>= 1; n++; }
    return n > L->levels ? n : L->levels;
}

/* Guest DXT blocks already have the BC1/2/3 layout. Keep short chains in BGRA
 * so their generated mips retain the same filtering; BC base dimensions must
 * be multiples of four. */
static MTLPixelFormat texture_host_format(const NvD3DTexture *t, const TexLayout *L, int hl)
{
    static int bc = -1;
    if (bc < 0) bc = [s_dev supportsBCTextureCompression] ? 1 : 0;
    if (!bc || L->kind != K_DXT || hl != L->levels || (t->width & 3) || (t->height & 3))
        return PIX_BGRA;
    return t->color == 0x0C ? MTLPixelFormatBC1_RGBA :
           t->color == 0x0E ? MTLPixelFormatBC2_RGBA : MTLPixelFormatBC3_RGBA;
}

/* ------------------------------------------------- texture dump and packs
 *
 * RECOMP_TEX_DUMP_DIR=<dir>: each guest texture, the first time its contents are
 * seen, as level 0 decoded the way the GPU samples it, to <dir>/<key>.png
 * (straight alpha). A replacement pack -- RECOMP_TEX_PACK=<dir>, else texpack/
 * beside game_files -- holds PNGs named by the same key (anything after its
 * 16 hex digits is ignored), drawn in place of the title's texture at
 * whatever size they are, with mip levels built from them. Keys hash the
 * texture's bytes, palette, format and size, so they hold across runs and
 * wherever the title loads it. Cube maps are left as they are. */
static NSMutableDictionary *s_pack_files;      /* NSNumber key -> NSString path */
static NSMutableDictionary *s_pack_tex;        /* NSNumber key -> id<MTLTexture> */
static NSMutableSet *s_dumped;                 /* NSNumber keys written (or found) */
static char s_dump_dir[1024];
static int s_pack_ready;
static unsigned s_dump_count;
#define TEX_DUMP_MAX 50000u

static int s_tex_replaced;                     /* the last texture_get came from the pack */
/* Debug > Texture Pack: whether the pack is drawn (to compare it with the
 * originals in place). The render thread applies a change at a flip by
 * dropping the texture cache, so every texture is looked up again. */
static int s_pack_on = 1;
static _Atomic int s_pack_toggle;

void nv2a_metal_toggle_texture_pack(void)
{
    atomic_store(&s_pack_toggle, 1);
}

static void tex_free(struct TexEntry *e);

static void texpack_apply_toggle(void)
{
    int b;
    if (!atomic_exchange(&s_pack_toggle, 0)) return;
    s_pack_on = !s_pack_on;
    for (b = 0; b < TEX_BUCKETS; b++) {
        TexEntry *e = s_tex_bucket[b], *n;
        for (; e; e = n) { n = e->next; tex_free(e); }
        s_tex_bucket[b] = NULL;
    }
    fprintf(stderr, "[TEXPACK] pack %s\n", s_pack_on ? "on" : "off (originals)");
}

static uint64_t pack_key(const NvD3DTexture *t, uint64_t h, uint64_t ph)
{
    uint64_t k = h ^ (ph * 0x9E3779B97F4A7C15ull);
    k ^= ((uint64_t)t->color << 56) ^ (((uint64_t)t->width << 20 | t->height) * 0xC2B2AE3D27D4EB4Full);
    return k;
}

static uint64_t key_from_name(NSString *name, int *ok)
{
    const char *c = [name UTF8String];
    uint64_t k = 0;
    int i;
    *ok = 0;
    for (i = 0; i < 16; i++) {
        int d = isdigit((unsigned char)c[i]) ? c[i] - '0' :
                (c[i] >= 'a' && c[i] <= 'f') ? c[i] - 'a' + 10 :
                (c[i] >= 'A' && c[i] <= 'F') ? c[i] - 'A' + 10 : -1;
        if (d < 0) return 0;
        k = k << 4 | (uint64_t)d;
    }
    *ok = 1;
    return k;
}

static void texpack_init(void)
{
    const char *d, *p;
    NSString *dir;
    NSArray *names;
    if (s_pack_ready) return;
    s_pack_ready = 1;
    if ((d = getenv("RECOMP_TEX_DUMP_DIR")) && *d) {
        snprintf(s_dump_dir, sizeof s_dump_dir, "%s", d);
        mkdir(s_dump_dir, 0755);
        s_dumped = [[NSMutableSet alloc] init];
        for (NSString *n in [[NSFileManager defaultManager]
                             contentsOfDirectoryAtPath:[NSString stringWithUTF8String:s_dump_dir] error:nil]) {
            int ok;
            uint64_t k = key_from_name(n, &ok);
            if (ok) [s_dumped addObject:@(k)];
        }
        fprintf(stderr, "[TEXPACK] dumping new textures to %s (%lu already there)\n",
                s_dump_dir, (unsigned long)[s_dumped count]);
    }
    p = getenv("RECOMP_TEX_PACK");
    dir = p && *p ? [NSString stringWithUTF8String:p] : @"texpack";
    names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    if (!names) return;
    s_pack_files = [[NSMutableDictionary alloc] init];
    s_pack_tex = [[NSMutableDictionary alloc] init];
    for (NSString *n in names) {
        int ok;
        uint64_t k;
        if (![[[n pathExtension] lowercaseString] isEqualToString:@"png"]) continue;
        k = key_from_name(n, &ok);
        if (ok) s_pack_files[@(k)] = [dir stringByAppendingPathComponent:n];
    }
    fprintf(stderr, "[TEXPACK] %lu replacement textures in %s\n",
            (unsigned long)[s_pack_files count], [dir fileSystemRepresentation]);
}

static void png_write_bgra(const char *path, const uint32_t *px, uint32_t w, uint32_t h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, px, (size_t)w * h * 4, NULL);
    /* Straight-alpha ARGB in host (little-endian) order: B, G, R, A bytes. */
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
                                   kCGBitmapByteOrder32Little | kCGImageAlphaFirst, dp, NULL,
                                   false, kCGRenderingIntentDefault);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path,
                                                           (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = url && img ?
        CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL) : NULL;
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    if (url) CFRelease(url);
    if (img) CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
}

static void texture_dump(const NvD3DTexture *t, const TexLayout *L, uint64_t key,
                         const uint32_t *pal)
{
    char path[1200];
    uint32_t *px;
    if (L->faces != 1 || [s_dumped containsObject:@(key)] || s_dump_count >= TEX_DUMP_MAX) return;
    [s_dumped addObject:@(key)];
    px = scratch_pixels((size_t)t->width * t->height);
    if (!px) return;
    decode_level(t, L, guest(t->addr) + L->level_off[0], 0, pal, px);
    snprintf(path, sizeof path, "%s/%016llx.png", s_dump_dir, (unsigned long long)key);
    png_write_bgra(path, px, L->level_w[0], L->level_h[0]);
    if (++s_dump_count % 500 == 0)
        fprintf(stderr, "[TEXPACK] %u textures dumped\n", s_dump_count);
}

/* A replacement PNG as straight-alpha BGRA, its full mip chain built here.
 * Core Graphics drawing is premultiplied only, so the decoded bytes are read
 * directly when they are plain 8-bit RGB(A); anything else is drawn and
 * unpremultiplied. */
static id<MTLTexture> png_load(NSString *path)
{
    CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path], NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    id<MTLTexture> tex = nil;
    uint32_t w, h, x, y, lv, levels;
    uint32_t *px;
    if (src) CFRelease(src);
    if (!img) return nil;
    w = (uint32_t)CGImageGetWidth(img);
    h = (uint32_t)CGImageGetHeight(img);
    px = (uint32_t *)malloc((size_t)w * h * 4);
    if (px) {
        CGImageAlphaInfo ai = CGImageGetAlphaInfo(img);
        CGBitmapInfo order = CGImageGetBitmapInfo(img) & kCGBitmapByteOrderMask;
        size_t bpc = CGImageGetBitsPerComponent(img), bpp = CGImageGetBitsPerPixel(img);
        int straight = bpc == 8 && (order == kCGBitmapByteOrderDefault || order == kCGBitmapByteOrder32Big) &&
                       ((bpp == 32 && (ai == kCGImageAlphaLast || ai == kCGImageAlphaNoneSkipLast)) ||
                        (bpp == 24 && ai == kCGImageAlphaNone));
        if (straight) {
            CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img));
            const uint8_t *b = data ? CFDataGetBytePtr(data) : NULL;
            size_t row = CGImageGetBytesPerRow(img), step = bpp / 8;
            for (y = 0; b && y < h; y++)
                for (x = 0; x < w; x++) {
                    const uint8_t *q = b + y * row + x * step;
                    uint32_t a = (bpp == 32 && ai == kCGImageAlphaLast) ? q[3] : 255;
                    px[(size_t)y * w + x] = a << 24 | (uint32_t)q[0] << 16 | (uint32_t)q[1] << 8 | q[2];
                }
            if (data) CFRelease(data);
            if (!b) { free(px); px = NULL; }
        } else {
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef c = CGBitmapContextCreate(px, w, h, 8, (size_t)w * 4, cs,
                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            if (c) {
                CGContextSetBlendMode(c, kCGBlendModeCopy);
                CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
                CGContextRelease(c);
                for (y = 0; y < (uint32_t)w * h; y++) {
                    uint32_t v = px[y], a = v >> 24;
                    if (a && a < 255) {
                        uint32_t r = ((v >> 16) & 255) * 255 / a, g = ((v >> 8) & 255) * 255 / a,
                                 bl = (v & 255) * 255 / a;
                        px[y] = a << 24 | (r > 255 ? 255 : r) << 16 | (g > 255 ? 255 : g) << 8 |
                                (bl > 255 ? 255 : bl);
                    }
                }
            } else {
                free(px); px = NULL;
            }
            CGColorSpaceRelease(cs);
        }
    }
    CGImageRelease(img);
    if (!px) return nil;
    levels = full_levels(w, h);
    tex = make_texture_storage(w, h, levels, PIX_BGRA, MTLTextureUsageShaderRead, 0, 1,
                               MTLStorageModeShared);
    for (lv = 0; tex && lv < levels; lv++) {
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:lv
                 withBytes:px bytesPerRow:(NSUInteger)w * 4];
        if (lv + 1 < levels) {
            halve_bgra(px, w, h, px);
            if (w > 1) w /= 2;
            if (h > 1) h /= 2;
        }
    }
    free(px);
    return tex;
}

/* The pack's texture for key, loaded on first use; nil when there is none. */
static id<MTLTexture> texpack_get(uint64_t key)
{
    NSNumber *k;
    NSString *path;
    id<MTLTexture> tex;
    if (!s_pack_files) return nil;
    k = @(key);
    if ((tex = s_pack_tex[k])) return tex;
    if (!(path = s_pack_files[k])) return nil;
    tex = png_load(path);
    if (!tex) {
        fprintf(stderr, "[TEXPACK] cannot load %s\n", [path fileSystemRepresentation]);
        [s_pack_files removeObjectForKey:k];
        return nil;
    }
    s_pack_tex[k] = tex;
    [tex release];                      /* the dictionary holds it */
    return tex;
}

/* The bits of v spread over the set bits of mask, low first (PDEP). */
static uint32_t bits_deposit(uint32_t v, uint32_t mask)
{
    uint32_t r = 0, bit;
    for (bit = 1; mask; bit <<= 1) {
        uint32_t low = mask & (0u - mask);
        if (v & bit) r |= low;
        mask &= mask - 1;
    }
    return r;
}

/* One level of a volume as BGRA z-planes. A compressed volume keeps four
 * consecutive z slices together inside each 4x4 block position -- neither
 * plain 2D slices nor a 3D Morton order; an uncompressed one is swizzled
 * x, y, z interleaved while each axis lasts. (Layouts as worked out in
 * lakshya16157's midtown-madness-3-PC-Native.) */
static void decode_volume_level(const NvD3DTexture *t, const TexLayout *L, const uint8_t *src,
                                int lv, const uint32_t *pal, uint32_t *out)
{
    uint32_t w = L->level_w[lv], h = L->level_h[lv], d = L->level_d[lv], x, y, z;
    if (L->kind == K_DXT) {
        uint32_t bw = (w + 3) / 4, bh = (h + 3) / 4, zs = d < 4 ? d : 4, bx, by, px[16];
        for (z = 0; z < d; z++)
            for (by = 0; by < bh; by++)
                for (bx = 0; bx < bw; bx++) {
                    size_t block = (((size_t)(z / 4) * bh + by) * bw + bx) * zs + z % 4;
                    d3d8_dxt_decode_block(src + block * L->bpp, t->color, px);
                    for (y = 0; y < 4 && by * 4 + y < h; y++)
                        for (x = 0; x < 4 && bx * 4 + x < w; x++)
                            out[((size_t)z * h + by * 4 + y) * w + bx * 4 + x] = px[y * 4 + x];
                }
        return;
    }
    {
        uint32_t mx = 0, my = 0, mz = 0, bit = 1, dest = 1;
        while (bit < w || bit < h || bit < d) {
            if (bit < w) { mx |= dest; dest <<= 1; }
            if (bit < h) { my |= dest; dest <<= 1; }
            if (bit < d) { mz |= dest; dest <<= 1; }
            bit <<= 1;
        }
        for (z = 0; z < d; z++)
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++) {
                    uint32_t a = bits_deposit(x, mx) | bits_deposit(y, my) | bits_deposit(z, mz);
                    out[((size_t)z * h + y) * w + x] = texel(t->color, src + (size_t)a * L->bpp, pal);
                }
    }
}

/* A volume texture, cached like the 2D ones (texture_get_impl) and decoded
 * to BGRA: Metal has no BC-compressed 3D textures. New contents go into a
 * new texture, as draws already encoded sampled the old one. */
static id<MTLTexture> volume_get(const NvD3DTexture *t, int *guest_levels)
{
    TexLayout L;
    uint32_t p = phys(t->addr), depth = t->depth ? t->depth : 1;
    uint32_t key = (p >> 7) ^ (t->format * 2654435761u) ^ (t->pitch << 3) ^ t->width;
    TexEntry *e, **head = &s_tex_bucket[key & (TEX_BUCKETS - 1)];
    uint32_t *px, *pal = NULL;
    uint64_t h, ph = 0;
    id<MTLTexture> tex;
    int lv, is_new;
    size_t bytes = 0;
    if (guest_levels) *guest_levels = 1;
    if (!tex_layout(t, &L) || !L.volume || !guest_ok(t->addr, L.total)) return nil;
    if (guest_levels) *guest_levels = L.levels;
    for (e = *head; e; e = e->next)
        if (e->depth == depth && e->phys == p && e->format == t->format && e->pitch == t->pitch &&
            e->w == t->width && e->h == t->height && e->palette == t->palette &&
            e->palette_len == t->palette_len)
            break;
    if (e && e->checked_epoch == s_epoch) { e->used = s_frame; return e->tex; }
    h = hash_mem(guest(t->addr), L.total);
    if (t->color == 0x0B && t->palette && guest_ok(t->palette, t->palette_len * 4)) {
        pal = (uint32_t *)guest(t->palette);
        ph = hash_mem((const uint8_t *)pal, t->palette_len * 4);
    }
    if (e && e->hash == h && e->pal_hash == ph) {
        e->checked_epoch = s_epoch;
        e->used = s_frame;
        return e->tex;
    }
    px = scratch_pixels((size_t)t->width * t->height * depth);
    if (!px) return e ? e->tex : nil;
    tex = make_volume(t->width, t->height, depth, (UINT)L.levels);
    if (!tex) { fail("volume texture", nil); return e ? e->tex : nil; }
    for (lv = 0; lv < L.levels; lv++) {
        uint32_t w = L.level_w[lv], ht = L.level_h[lv], d = L.level_d[lv];
        decode_volume_level(t, &L, guest(t->addr) + L.level_off[lv], lv, pal, px);
        [tex replaceRegion:MTLRegionMake3D(0, 0, 0, w, ht, d) mipmapLevel:(NSUInteger)lv slice:0
                 withBytes:px bytesPerRow:(NSUInteger)w * 4 bytesPerImage:(NSUInteger)w * ht * 4];
        bytes += (size_t)w * ht * d * 4;
    }
    is_new = !e;
    if (!e) {
        e = (TexEntry *)calloc(1, sizeof *e);
        if (!e) { [tex release]; return nil; }
        e->phys = p; e->format = t->format; e->pitch = t->pitch;
        e->w = t->width; e->h = t->height; e->depth = depth;
        e->palette = t->palette; e->palette_len = t->palette_len;
    } else {
        [e->tex release];
        s_tex_bytes -= e->bytes;
    }
    e->tex = tex;
    e->bytes = bytes;
    s_tex_bytes += bytes;
    e->hash = h;
    e->pal_hash = ph;
    e->checked_epoch = s_epoch;
    e->used = s_frame;
    if (is_new) {
        e->next = *head;
        *head = e;
        s_tex_count++;
    }
    {
        static int told;
        if (!told++) {
            fprintf(stderr, "[METAL] volume texture %ux%ux%u format %08X (%s)\n",
                    t->width, t->height, depth, t->format, L.kind == K_DXT ? "DXT" : "swizzled");
            fflush(stderr);
        }
    }
    tex_evict();
    return e->tex;
}

static id<MTLTexture> texture_get_impl(const NvD3DTexture *t, int *guest_levels)
{
    TexLayout L;
    uint32_t p = phys(t->addr), pal_p = t->palette;
    uint32_t key = (p >> 7) ^ (t->format * 2654435761u) ^ (t->pitch << 3) ^ t->width;
    TexEntry *e, **head = &s_tex_bucket[key & (TEX_BUCKETS - 1)];
    uint64_t h, ph = 0;
    uint32_t *pal = NULL, *px = NULL;
    MTLPixelFormat host_format;
    int hl, is_new, native;

    if (guest_levels) *guest_levels = 1;
    s_tex_replaced = 0;
    if (texture_is_volume(t)) return volume_get(t, guest_levels);
    if (!tex_layout(t, &L)) return nil;
    if (guest_levels) *guest_levels = L.levels;
    if (!guest_ok(t->addr, L.total)) return nil;
    for (e = *head; e; e = e->next)
        if (e->phys == p && e->format == t->format && e->pitch == t->pitch &&
            e->w == t->width && e->h == t->height && e->palette == pal_p &&
            e->palette_len == t->palette_len)
            break;
    /* The CPU can refill streamed textures or palettes between submissions
     * before a flip. Recheck once per kick. */
    if (e && e->checked_epoch == s_epoch) {
        e->used = s_frame;
        if (!e->bytes && e->tex) {          /* a pack texture (see below) */
            s_tex_replaced = 1;
            if (guest_levels) *guest_levels = (int)[e->tex mipmapLevelCount];
        }
        return e->tex;
    }
    h = hash_mem(guest(t->addr), L.total);
    if (t->color == 0x0B && pal_p && guest_ok(pal_p, t->palette_len * 4)) {
        pal = (uint32_t *)guest(pal_p);
        ph = hash_mem((const uint8_t *)pal, t->palette_len * 4);
    }
    if (e && e->hash == h && e->pal_hash == ph) {
        e->checked_epoch = s_epoch;
        e->used = s_frame;
        if (!e->bytes && e->tex) {
            s_tex_replaced = 1;
            if (guest_levels) *guest_levels = (int)[e->tex mipmapLevelCount];
        }
        return e->tex;
    }
    texpack_init();
    if (L.faces == 1 && (s_dump_dir[0] || (s_pack_files && s_pack_on))) {
        uint64_t key = pack_key(t, h, ph);
        id<MTLTexture> rep;
        if (s_dump_dir[0]) texture_dump(t, &L, key, pal);
        if (s_pack_on && (rep = texpack_get(key))) {
            /* The pack's image stands in; the pack owns its memory, so the
             * entry counts none against the cache budget. */
            if (!e) {
                if (!(e = (TexEntry *)calloc(1, sizeof *e))) return nil;
                e->phys = p; e->format = t->format; e->pitch = t->pitch;
                e->w = t->width; e->h = t->height; e->palette = pal_p;
                e->palette_len = t->palette_len;
                e->next = *head;
                *head = e;
                s_tex_count++;
            } else {
                [e->tex release];
                s_tex_bytes -= e->bytes;
                e->bytes = 0;
            }
            e->tex = [rep retain];
            e->hash = h;
            e->pal_hash = ph;
            e->checked_epoch = s_epoch;
            e->used = s_frame;
            if (guest_levels) *guest_levels = (int)[rep mipmapLevelCount];
            s_tex_replaced = 1;
            return e->tex;
        }
    }
    hl = host_levels(&L, t);
    host_format = texture_host_format(t, &L, hl);
    native = host_format != PIX_BGRA;
    if (!native) {
        px = scratch_pixels((size_t)t->width * t->height);
        if (!px) {
            if (e) e->used = s_frame;
            return e ? e->tex : nil;
        }
    }
    is_new = !e;
    if (!e) {
        e = (TexEntry *)calloc(1, sizeof *e);
        if (!e) return nil;
        e->tex = guest_texture(t->width, t->height, (UINT)hl, host_format, L.faces == 6);
        if (!e->tex) { fail("texture", nil); free(e); return nil; }
        e->phys = p; e->format = t->format; e->pitch = t->pitch;
        e->w = t->width; e->h = t->height; e->palette = pal_p;
        e->palette_len = t->palette_len;
        {
            uint32_t w = t->width, ht = t->height;
            int lv;
            for (lv = 0; lv < hl; lv++) {
                e->bytes += native ? (size_t)((w + 3) / 4) * ((ht + 3) / 4) * L.bpp * L.faces
                                   : (size_t)w * ht * 4 * L.faces;
                if (w > 1) w /= 2;
                if (ht > 1) ht /= 2;
            }
        }
    } else if (!TEX_BLIT()) {
        /* New contents go into a new texture: the draws already encoded
         * sampled the old one, which their command buffer keeps alive. */
        id<MTLTexture> fresh = guest_texture(t->width, t->height, (UINT)hl, host_format,
                                             L.faces == 6);
        if (fresh) { [e->tex release]; e->tex = fresh; }
    }
    {
        int f, lv;
        for (f = 0; f < L.faces; f++) {
            uint32_t w, h2;
            for (lv = 0; lv < L.levels; lv++) {
                const uint8_t *src = guest(t->addr) + f * L.face_stride + L.level_off[lv];
                if (native) {
                    /* Blocks cover the whole level, also below 4x4. */
                    uint32_t bw = (L.level_w[lv] + 3) / 4, bh = (L.level_h[lv] + 3) / 4;
                    texture_write(e->tex, (NSUInteger)f, (NSUInteger)lv, 0, 0,
                                  L.level_w[lv], L.level_h[lv], src,
                                  (NSUInteger)bw * L.bpp, bh);
                } else {
                    decode_level(t, &L, src, lv, pal, px);
                    texture_write(e->tex, (NSUInteger)f, (NSUInteger)lv, 0, 0,
                                  L.level_w[lv], L.level_h[lv], px,
                                  (NSUInteger)L.level_w[lv] * 4, L.level_h[lv]);
                }
            }
            if (hl <= L.levels) continue;
            w = L.level_w[L.levels - 1]; h2 = L.level_h[L.levels - 1];
            /* The upload copied the pixels; keep shrinking the decoded last
             * guest mip in its scratch space. */
            for (; lv < hl; lv++) {
                halve_bgra(px, w, h2, px);
                if (w > 1) w /= 2;
                if (h2 > 1) h2 /= 2;
                texture_write(e->tex, (NSUInteger)f, (NSUInteger)lv, 0, 0, w, h2, px,
                              (NSUInteger)w * 4, h2);
            }
        }
    }
    e->hash = h;
    e->pal_hash = ph;
    e->checked_epoch = s_epoch;
    e->used = s_frame;
    if (is_new) {
        e->next = *head;
        *head = e;
        s_tex_bytes += e->bytes;
        s_tex_count++;
    }
    tex_evict();
    return e->tex;
}

static id<MTLTexture> texture_get_with_levels(const NvD3DTexture *t, int *guest_levels)
{
    int64_t t0 = s_prof_on > 0 ? qpc() : 0;
    id<MTLTexture> v;
    RECOMP_PROFILE_BEGIN("Metal texture");
    v = texture_get_impl(t, guest_levels);
    RECOMP_PROFILE_END();
    if (s_prof_on > 0) s_prof[PROF_TEXTURE] += qpc() - t0;
    return v;
}

/* -------------------------------------------------------- state objects */

typedef struct { uint64_t key; void *obj; } StateSlot;
#define STATE_SLOTS 512
static StateSlot s_ds_cache[STATE_SLOTS], s_samp_cache[STATE_SLOTS];

static void **state_slot(StateSlot *tab, uint64_t key)
{
    uint32_t i = (uint32_t)(key ^ (key >> 29) ^ (key >> 47)) * 2654435761u;
    int n;
    for (n = 0; n < STATE_SLOTS; n++) {
        StateSlot *s = &tab[(i + n) & (STATE_SLOTS - 1)];
        if (!s->obj || s->key == key) {
            s->key = key;
            return &s->obj;
        }
    }
    /* Full: evict the home slot. An encoder that bound it keeps its own
     * reference until it ends. */
    {
        StateSlot *s = &tab[i & (STATE_SLOTS - 1)];
        [(id)s->obj release];
        s->obj = NULL;
        s->key = key;
        return &s->obj;
    }
}

static MTLCompareFunction cmp(uint32_t f)
{
    switch (f) {
    case 0x200: return MTLCompareFunctionNever;
    case 0x201: return MTLCompareFunctionLess;
    case 0x202: return MTLCompareFunctionEqual;
    case 0x203: return MTLCompareFunctionLessEqual;
    case 0x204: return MTLCompareFunctionGreater;
    case 0x205: return MTLCompareFunctionNotEqual;
    case 0x206: return MTLCompareFunctionGreaterEqual;
    default: return MTLCompareFunctionAlways;
    }
}

static MTLStencilOperation sop(uint32_t o)
{
    switch (o) {
    case 0x0000: return MTLStencilOperationZero;
    case 0x1E01: return MTLStencilOperationReplace;
    case 0x1E02: return MTLStencilOperationIncrementClamp;
    case 0x1E03: return MTLStencilOperationDecrementClamp;
    case 0x150A: return MTLStencilOperationInvert;
    case 0x8507: return MTLStencilOperationIncrementWrap;
    case 0x8508: return MTLStencilOperationDecrementWrap;
    default: return MTLStencilOperationKeep;
    }
}

static id<MTLDepthStencilState> ds_state(int zt, uint32_t zf, int zw, int st,
                                         uint32_t sf, uint32_t rmask, uint32_t wmask,
                                         uint32_t fail_, uint32_t zfail, uint32_t zpass)
{
    uint64_t key = (uint64_t)(zt != 0) | ((uint64_t)(zw != 0) << 1) |
                   ((uint64_t)(st != 0) << 2) | ((uint64_t)(zf & 7) << 3) |
                   ((uint64_t)(sf & 7) << 6) | ((uint64_t)(rmask & 0xFF) << 9) |
                   ((uint64_t)(wmask & 0xFF) << 17) |
                   ((uint64_t)sop(fail_) << 25) | ((uint64_t)sop(zfail) << 29) |
                   ((uint64_t)sop(zpass) << 33);
    void **slot = state_slot(s_ds_cache, key);
    if (!*slot) {
        MTLDepthStencilDescriptor *d = [[MTLDepthStencilDescriptor alloc] init];
        /* D3D11: depth disabled means no test and no write. */
        d.depthCompareFunction = zt ? cmp(0x200 | (zf & 7)) : MTLCompareFunctionAlways;
        d.depthWriteEnabled = zt && zw ? YES : NO;
        if (st) {
            MTLStencilDescriptor *s = [[MTLStencilDescriptor alloc] init];
            s.stencilCompareFunction = cmp(0x200 | (sf & 7));
            s.stencilFailureOperation = sop(fail_);
            s.depthFailureOperation = sop(zfail);
            s.depthStencilPassOperation = sop(zpass);
            s.readMask = rmask & 0xFF;
            s.writeMask = wmask & 0xFF;
            d.frontFaceStencil = s;
            d.backFaceStencil = s;
            [s release];
        }
        *slot = (void *)[s_dev newDepthStencilStateWithDescriptor:d];
        [d release];
    }
    return (id<MTLDepthStencilState>)*slot;
}

static MTLSamplerAddressMode addr_mode(uint32_t m)
{
    switch (m) {
    case 1: return MTLSamplerAddressModeRepeat;
    case 2: return MTLSamplerAddressModeMirrorRepeat;
    case 4: return MTLSamplerAddressModeClampToBorderColor;
    default: return MTLSamplerAddressModeClampToEdge;
    }
}

/* Metal offers three border colours; the guest's is matched to the nearest. */
static MTLSamplerBorderColor border_color(uint32_t argb32)
{
    uint32_t a = argb32 >> 24, r = (argb32 >> 16) & 0xFF, g = (argb32 >> 8) & 0xFF, b = argb32 & 0xFF;
    if (a < 128) return MTLSamplerBorderColorTransparentBlack;
    return r + g + b >= 3 * 128 ? MTLSamplerBorderColorOpaqueWhite : MTLSamplerBorderColorOpaqueBlack;
}

/* Point magnification of the title's own textures, upscaled. The menus,
 * HUD and fonts were drawn texel for pixel at 480 lines, where nearest and
 * bilinear look the same; at 3x nearest turns every edge into a staircase of
 * texel-sized steps that no antialiasing of the geometry can reach. Rendering
 * above the guest's resolution they are magnified bilinearly (an alpha-tested
 * edge then follows the interpolated alpha: a smooth outline, antialiased by
 * the coverage band in shade()). RECOMP_TEXTURE_MAG=point keeps the title's
 * filter. Render targets it reads back keep exact taps (see tapbox). */

static int smooth_magnification(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("RECOMP_TEXTURE_MAG");
        on = !(e && !strcmp(e, "point"));
    }
    return on && s_scale > 1.01f;
}

/* The sampler for a stage. *bias is the LOD bias the shader applies, which a
 * D3D11 sampler carried itself. smooth: a guest texture whose point
 * magnification is lifted (smooth_magnification). */
static id<MTLSamplerState> sampler(const NvD3DTexture *t, int levels, int reduce, int smooth,
                                   float *bias)
{
    uint32_t minf = (t->filter >> 16) & 0xFF, magf = (t->filter >> 24) & 0xF;
    int bias13 = (int)(t->filter & 0x1FFF);
    uint64_t key;
    void **slot;
    if (bias13 & 0x1000) bias13 -= 0x2000;
    *bias = (float)bias13 / 256.0f;
    if (smooth && magf == 1) magf = 2;
    key = (uint64_t)minf | ((uint64_t)magf << 8) |
          ((uint64_t)(levels & 15) << 25) | ((uint64_t)(reduce != 0) << 29) |
          ((uint64_t)(t->address & 0xFFFFF) << 31);
    key ^= ((uint64_t)((t->control0 >> 6) & 0xFFFFFF) * 0xFF51AFD7ED558CCDull) ^
           ((uint64_t)border_color(t->border) * 0xC4CEB9FE1A85EC53ull);
    slot = state_slot(s_samp_cache, key);
    if (!*slot) {
        MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
        int min_lin = minf == 2 || minf == 4 || minf == 6;
        int mip_lin = minf == 5 || minf == 6;
        int mag_lin = magf != 1;
        float lo, hi;
        d.minFilter = min_lin ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        d.magFilter = mag_lin ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        d.mipFilter = mip_lin ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
        d.sAddressMode = addr_mode(t->address & 0xF);
        d.tAddressMode = addr_mode((t->address >> 8) & 0xF);
        d.rAddressMode = addr_mode((t->address >> 16) & 0xF);
        d.borderColor = border_color(t->border);
        if (min_lin && mag_lin && s_aniso > 1) d.maxAnisotropy = s_aniso;
        if (minf <= 2 || minf == 7 || levels <= 1) {
            lo = hi = 0;
        } else {
            lo = (float)((t->control0 >> 18) & 0xFFF) / 256.0f;
            hi = (float)((t->control0 >> 6) & 0xFFF) / 256.0f;
            if (hi < lo) hi = FLT_MAX;
        }
        if (reduce) {
            /* Over surface_mips: the title's min/mag filter within a level,
             * levels picked and blended by each tap's footprint. */
            d.mipFilter = MTLSamplerMipFilterLinear;
            lo = 0;
            hi = FLT_MAX;
        }
        d.lodMinClamp = lo;
        d.lodMaxClamp = hi;
        *slot = (void *)[s_dev newSamplerStateWithDescriptor:d];
        [d release];
    }
    return (id<MTLSamplerState>)*slot;
}

/* ------------------------------------------------------------------- draw */

static uint32_t mode_needs_texture(uint32_t mode)
{
    return mode == 1 || mode == 2 || mode == 3 || mode == 6 || mode == 7 ||
           mode == 9 || mode == 11 || mode == 12 || mode == 13 || mode == 14 ||
           mode == 15 || mode == 16 || mode == 18;
}

static void unpack4(uint32_t c, float o[4])
{
    o[0] = ((c >> 16) & 0xFF) / 255.0f;
    o[1] = ((c >> 8) & 0xFF) / 255.0f;
    o[2] = (c & 0xFF) / 255.0f;
    o[3] = (c >> 24) / 255.0f;
}

/* Scratch copy for render-to-texture reads of the target being drawn. */
static id<MTLTexture> s_feedback_tex;

static id<MTLTexture> feedback_copy(Surface *s)
{
    if (!s_feedback_tex || [s_feedback_tex width] != s->iw || [s_feedback_tex height] != s->ih) {
        [s_feedback_tex release];
        s_feedback_tex = make_texture(s->iw, s->ih, 1, 1, PIX_BGRA, MTLTextureUsageShaderRead, 0);
        if (!s_feedback_tex) return nil;
    }
    [blit_encoder_for(BRK_FEEDBACK) copyFromTexture:s->tex toTexture:s_feedback_tex];
    return s_feedback_tex;
}

/* Inclusive with region 0 alone (an Xbox D3D viewport): the scissor does
 * it. Anything else is tested per pixel in shade(). */
static int wclip_scissored(const NvD3DState *st)
{
    return !(st->wclip_type & 1) && (st->wclip_mask & ~1u) == 0;
}

static MTLScissorRect scissor_rect(uint32_t left, uint32_t top, uint32_t right, uint32_t bottom)
{
    MTLScissorRect r;
    if (right > s_vp_w) right = s_vp_w;
    if (bottom > s_vp_h) bottom = s_vp_h;
    if (left > right) left = right;
    if (top > bottom) top = bottom;
    r.x = left; r.y = top; r.width = right - left; r.height = bottom - top;
    return r;
}

static MTLScissorRect apply_scissor(const NvD3DState *st, uint32_t gw, uint32_t gh)
{
    uint32_t x0 = st->clip_x, y0 = st->clip_y;
    uint32_t x1 = st->clip_x + st->clip_w, y1 = st->clip_y + st->clip_h;
    if (wclip_scissored(st) && (st->wclip_mask & 1)) {
        uint32_t h = st->wclip_h[0], v = st->wclip_v[0];
        if (x0 < (h & 0xFFF)) x0 = h & 0xFFF;
        if (y0 < (v & 0xFFF)) y0 = v & 0xFFF;
        if (x1 > (h >> 16 & 0xFFF) + 1) x1 = (h >> 16 & 0xFFF) + 1;
        if (y1 > (v >> 16 & 0xFFF) + 1) y1 = (v >> 16 & 0xFFF) + 1;
    }
    if (x1 > gw) x1 = gw;
    if (y1 > gh) y1 = gh;
    if (x0 > x1) x0 = x1;
    if (y0 > y1) y0 = y1;
    return scissor_rect((uint32_t)(x0 * s_aa_x * s_cur_sx + 0.5f), (uint32_t)(y0 * s_aa_y * s_cur_sy + 0.5f),
                        (uint32_t)(x1 * s_aa_x * s_cur_sx + 0.5f), (uint32_t)(y1 * s_aa_y * s_cur_sy + 0.5f));
}

static uint32_t write_mask(const NvD3DState *st, Surface *s)
{
    uint32_t m = 0, cm = st->color_mask;
    if (cm & 0x00010000u) m |= WRITE_R;
    if (cm & 0x00000100u) m |= WRITE_G;
    if (cm & 0x00000001u) m |= WRITE_B;
    if ((cm & 0x01000000u) && (!s || surface_alpha_mode(s->color_fmt) < 0))
        m |= WRITE_A;
    return m;
}

/* What the last setup_pipeline bound: any texture, and any render target
 * stored widened (its image already spans the wide screen). */
static int s_draw_textured, s_draw_reads_wide;
static uint32_t s_draw_tex_addr;
static int s_flare_depth_test;
static int s_draw_bspline;
static uint32_t s_bspline_sf, s_bspline_df;

extern const uint32_t (*nv2a_vsh_program(uint32_t *start, uint32_t *version))[4];
extern const float (*nv2a_vsh_constants(uint32_t *version))[4];

/* The title asks for lamp glows to be tested against scene depth as on
 * D3D11, but here that test hides every lamp glow (car lights, street lamps,
 * indicators). Their own occluder taps of the frame's alpha (Flares.psh,
 * averaged over the guest pixel by tapbox) decide visibility correctly, so
 * the depth test stays off unless MM3_FLARE_DEPTH=1. */
void nv2a_d3d_set_flare_depth_test(int on)
{
    const char *e = getenv("MM3_FLARE_DEPTH");
    s_flare_depth_test = on != 0 && e && atoi(e) != 0;
}

static int flare_needs_depth(const NvD3DState *st)
{
    static int noted;
    Surface *mask;
    uint32_t address, reject = 0;
    unsigned n;
    /* 0x8421 is the native Flares program's four projective 2D stages. */
    if (!s_flare_depth_test || !st->rc_seen || st->rc.stage_program != 0x8421u)
        return 0;
    address = phys(st->tex[0].addr);
    if (!address || phys(st->tex[3].addr) == address) return 0;
    mask = surface_find(address);
    if (st->depth_test || st->depth_mask || !st->zeta_addr) reject |= 1u;
    if (!st->blend_enable || st->blend_dfactor != 1u || st->blend_equation != 0x8006u)
        reject |= 2u;
    if (!mask || mask->w != st->clip_w || mask->h != st->clip_h) reject |= 4u;
    /* MM3 Flares/Flares.psh: t0..t2 sample the screen visibility mask;
     * t3 samples the lamp texture. */
    for (n = 0; n < 3; ++n) {
        const NvD3DTexture *t = &st->tex[n];
        if (phys(t->addr) != address || t->cube || t->color != 0x12u ||
            ((t->filter >> 24) & 15u) != 2u)
            reject |= 8u;
    }
    if (reject) return 0;
    if (!noted) {
        fprintf(stderr, "[METAL] lamp visibility sprites use scene depth\n");
        noted = 1;
    }
    return 1;
}

/* A swizzled render target sampled as a mipmapped texture: titles render
 * each level of such a texture themselves, one surface per level at the
 * offsets the texture's layout puts them. The levels found are copied into
 * one host texture, each at its own (scaled) size, as the title's chain;
 * returns it and sets *levels, or nil to fall back to the single surface. */
static id<MTLTexture> surface_chain(Surface *rt, const NvD3DTexture *t, int *levels)
{
    Surface *lv[16];
    uint32_t off = 0, k, n = 0, bpp = rt->bpp;
    for (k = 0; k < t->levels && k < 16; k++) {
        uint32_t w = t->width >> k, h = t->height >> k;
        Surface *c;
        if (!w) w = 1;
        if (!h) h = 1;
        c = k ? surface_find(phys(t->addr) + off) : rt;
        if (!c || !c->swizzled || c->w != w || c->h != h || c->bpp != bpp || c == s_cur_rt)
            break;
        lv[n++] = c;
        off += w * h * bpp;
    }
    if (n < 2) return nil;
    if (!rt->chain || rt->chain_levels != (int)n) {
        [rt->chain release];
        rt->chain = make_texture(rt->iw, rt->ih, n, 1, PIX_BGRA, MTLTextureUsageShaderRead, 0);
        if (!rt->chain) return nil;
        rt->chain_levels = (int)n;
        for (k = 0; k < n; k++) rt->chain_gen[k] = lv[k]->gen - 1;
    }
    for (k = 0; k < n; k++) {
        uint32_t dw = rt->iw >> k, dh = rt->ih >> k;
        if (!dw) dw = 1;
        if (!dh) dh = 1;
        surface_sync(lv[k], 0);
        if (rt->chain_gen[k] == lv[k]->gen) continue;
        [blit_encoder_for(BRK_CHAIN) copyFromTexture:lv[k]->tex sourceSlice:0 sourceLevel:0
                           sourceOrigin:MTLOriginMake(0, 0, 0)
                             sourceSize:MTLSizeMake(lv[k]->iw < dw ? lv[k]->iw : dw,
                                                    lv[k]->ih < dh ? lv[k]->ih : dh, 1)
                              toTexture:rt->chain destinationSlice:0 destinationLevel:k
                      destinationOrigin:MTLOriginMake(0, 0, 0)];
        rt->chain_gen[k] = lv[k]->gen;
    }
    *levels = (int)n;
    return rt->chain;
}

/* A guest pass that reduces a render target (glare, luminance or
 * reflection downsamples) reads this mip-mapped copy, so each tap averages
 * the footprint it stands for. */
static id<MTLTexture> surface_mips(Surface *s)
{
    if (!s->mip) {
        s->mip = make_texture(s->iw, s->ih, full_levels(s->iw, s->ih), 1, PIX_BGRA,
                              USAGE_RT, 0);
        if (!s->mip) return nil;
        s->mip_gen = s->gen - 1;
    }
    if (s->mip_gen != s->gen) {
        id<MTLBlitCommandEncoder> b;
        surface_resolve(s);
        b = blit_encoder_for(BRK_MIPS);
        [b copyFromTexture:s->tex sourceSlice:0 sourceLevel:0 toTexture:s->mip
          destinationSlice:0 destinationLevel:0 sliceCount:1 levelCount:1];
        [b generateMipmapsForTexture:s->mip];
        s->mip_gen = s->gen;
    }
    return s->mip;
}

/* One full-target triangle into dst with fs, sampling src. */
static void y16_pass(id<MTLTexture> dst, id<MTLFunction> fs, id<MTLTexture> src,
                     const void *consts, size_t consts_bytes)
{
    id<MTLRenderPipelineState> pso = pipeline(s_fn_y16_vs, fs, PIX_Y16, MTLPixelFormatInvalid, 1,
                                              0, WRITE_ALL, 0, 0, 0);
    id<MTLRenderCommandEncoder> e;
    if (!pso) return;
    NOTE_OWN_PASS(BRK_Y16);
    unbind_targets();
    {
        MTLRenderPassDescriptor *d = pass_descriptor(dst, nil, nil);
        stamp_render(d, "y16 pass");
        e = [cmd() renderCommandEncoderWithDescriptor:d];
    }
    [e setRenderPipelineState:pso];
    [e setViewport:(MTLViewport){ 0, 0, (double)[dst width], (double)[dst height], 0, 1 }];
    [e setDepthStencilState:s_ds_off];
    [e setFragmentTexture:src atIndex:0];
    if (consts) [e setFragmentBytes:consts length:consts_bytes atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

/* Bring s's LU_IMAGE_Y16 view up to date (2 x iw by ih); nil on failure.
 * Unbinds the current targets: call before a draw binds its own. */
static id<MTLTexture> surface_y16(Surface *s)
{
    if (!s->y16) {
        s->y16 = make_texture(2 * s->iw, s->ih, 1, 1, PIX_Y16, USAGE_RT, 0);
        if (!s->y16) return nil;
        s->y16_gen = s->gen - 1;
    }
    if (s->y16_gen != s->gen) {
        if (s->ms) {
            if (s_pass_color == s->ms) end_encoders();
            y16_pass(s->y16, s_fn_y16_ps[1], s->ms, NULL, 0);
        } else {
            y16_pass(s->y16, s_fn_y16_ps[0], s->tex, NULL, 0);
        }
        s->y16_gen = s->gen;
    }
    return s->y16;
}

/* The same for a depth buffer the title reads as LU_IMAGE_Y16 (see y16d_ps).
 * light 0: fog's view, luminance through the haze remap. light 1: the view
 * MM3's Light/LightDraw.psh decodes to place each lamp and headlight volume
 * -- the stored depth, unremapped, as (1, high byte, low byte); see y16d_of.
 * (From lakshya16157's midtown-madness-3-PC-Native.) */
static id<MTLTexture> depth_y16(Depth *d, int light)
{
    float scale = light ? 1.0f : s_zview_remap[0], knee = light ? 1.0f : s_zview_remap[1];
    if (!d->tex) return nil;
    if (!light) s_depth_hazed = 1;
    if (!d->y16) {
        d->y16 = make_texture(2 * d->iw, d->ih, 1, 1, PIX_Y16, USAGE_RT, 0);
        if (!d->y16) return nil;
        d->y16_gen = d->gen - 1;
    }
    if (d->y16_gen != d->gen || d->y16_light != light ||
        d->y16_scale != scale || d->y16_knee != knee) {
        float cc[8] = { 0 };
        cc[0] = scale;
        cc[1] = knee;
        cc[2] = d->w ? 0.25f * (float)d->iw / (float)d->w : 0.0f;
        cc[3] = light ? 1.0f : 0.0f;
        if (s_pass_depth == d->tex) end_encoders();
        y16_pass(d->y16, s_fn_y16d_ps[d->samples > 1 ? 1 : 0], d->tex, cc, sizeof cc);
        d->y16_gen = d->gen;
        d->y16_light = light;
        d->y16_scale = scale;
        d->y16_knee = knee;
    }
    return d->y16;
}

/* MM3's Light/LightDraw.psh: the pass that adds each light volume into the
 * night light buffer, reading scene depth through texm3x3pad/texm3x3tex. */
static int light_draw(const NvD3DState *st)
{
    return st->rc_seen && st->rc.stage_program == 0x6C621u;
}

/* Everything a draw sets on the encoder, gathered by setup_pipeline and
 * applied once the vertex data is in place (allocating ring space can end
 * the encoder). */
typedef struct {
    PSConsts pc;
    id<MTLTexture> tex[13];         /* 2D 0-3, cube 4-7, the frame (FBK) 8, 3D 9-12 */
    id<MTLSamplerState> smp[4];
    id<MTLFunction> fs;
    uint32_t variant;
    int cull, front_ccw;
    float bias, slope;
    MTLScissorRect scissor;
    float bf[4];
    int blend_enable;
    uint32_t sf, df, eq, mask;
    id<MTLDepthStencilState> ds;
    uint32_t stencil_ref;
    MTLPrimitiveType prim;
} DrawState;
static DrawState s_draw;

/* The pipeline the draw's state calls for: the specialised shader's once it
 * is built, the ubershader's until then. */
static id<MTLRenderPipelineState> draw_pipeline(const DrawState *ds, id<MTLFunction> vs)
{
    MTLPixelFormat color = s_cur_rt ? PIX_BGRA : MTLPixelFormatInvalid;
    MTLPixelFormat depth = s_cur_ds ? PIX_DEPTH : MTLPixelFormatInvalid;
    NSUInteger samples = s_cur_rt ? (s_cur_rt->ms ? s_msaa : 1) : (s_cur_ds ? s_cur_ds->samples : 1);
    uint32_t mask = s_cur_rt ? ds->mask : 0;
    id<MTLRenderPipelineState> pso = nil;
    if (ds->fs != s_fn_psv[ds->variant])
        pso = spec_pipeline(vs, ds->fs, color, depth, samples, ds->blend_enable, mask,
                            ds->sf, ds->df, ds->eq);
    if (!pso)
        pso = pipeline(vs, s_fn_psv[ds->variant], color, depth, samples, ds->blend_enable,
                       mask, ds->sf, ds->df, ds->eq);
    return pso;
}

static int setup_pipeline(const NvD3DState *st, int topology, Surface **out_s,
                          uint32_t *out_gw, uint32_t *out_gh, uint32_t *out_zmax)
{
    Surface *s;
    Depth *d;
    uint32_t gw, gh, n, zf;
    DrawState *ds = &s_draw;
    PSConsts *pc = &ds->pc;
    int cull = 0, flare_depth = flare_needs_depth(st);
    s_draw_textured = s_draw_reads_wide = 0;
    s_draw_tex_addr = 0;
    s_draw_bspline = 0;

    {
        /* Bring-up switches: RECOMP_D3D_SKIP_CMASK / _SKIP_SFACTOR (hex) drop
         * draws with that colour mask / source blend factor. */
        static int init;
        static long skip_cmask = -1, skip_sf = -1;
        if (!init) {
            const char *e;
            init = 1;
            if ((e = getenv("RECOMP_D3D_SKIP_CMASK")) != NULL) skip_cmask = strtol(e, NULL, 16);
            if ((e = getenv("RECOMP_D3D_SKIP_SFACTOR")) != NULL) skip_sf = strtol(e, NULL, 16);
        }
        if ((skip_cmask >= 0 && st->color_mask == (uint32_t)skip_cmask) ||
            (skip_sf >= 0 && st->blend_enable && st->blend_sfactor == (uint32_t)skip_sf))
            return 0;
    }
    if (st->cull_enable)
        cull = st->cull_face == 0x404 ? 1 : st->cull_face == 0x405 ? 2 : 3;
    if (cull == 3 && topology == NV_D3D_TRIANGLES)
        return 0;                                /* front and back culled */
    /* Y16 views of 32-bit targets are drawn before this draw's targets go
     * on; see y16_ps. */
    for (n = 0; n < 4; n++) {
        const NvD3DTexture *t = &st->tex[n];
        Surface *rt;
        Depth *zt;
        if (t->color != 0x35 || t->cube || !t->addr) continue;
        /* A depth buffer wins over a colour surface at the same address:
         * titles bind one there for colour-masked stencil passes. */
        if ((zt = depth_find(phys(t->addr))) != NULL) { depth_y16(zt, light_draw(st)); continue; }
        rt = surface_find(phys(t->addr));
        if (rt && rt->bpp == 4) { surface_sync(rt, 0); surface_y16(rt); }
    }
    if (!bind_targets(st, st->depth_test || st->stencil_test || flare_depth, &s, &d, &gw, &gh))
        return 0;
    zf = (st->surface_format >> 4) & 0xF;
    if (s && write_mask(st, s)) { s->gpu_dirty = 1; s->drawn++; }

    /* Textures first: a surface sampled here may need a copy. */
    memset(ds, 0, sizeof *ds);
    for (n = 0; n < 4; n++) {
        const NvD3DTexture *t = &st->tex[n];
        uint32_t mode = (st->rc.stage_program >> (n * 5)) & 31;
        id<MTLTexture> view = nil;
        Surface *rt;
        Depth *zt;
        int kind = K_SWZ, levels = 1, reduce = 0;
        pc->tex_scale[n][0] = pc->tex_scale[n][1] = 1.0f;
        pc->tex_scale[n][2] = pc->tex_scale[n][3] = 1.0f;
        if (!st->rc_seen && n == 0)
            mode = (st->tex_used & 1) ? 1 : 0;
        if (!mode_needs_texture(mode) || !t->addr || !t->width || !t->height)
            continue;
        tex_format(t->color, &kind);
        /* A recycled target address can now hold a streamed compressed or
         * paletted image. Those layouts cannot alias a colour render target;
         * decode their guest bytes instead of sampling the cached target. */
        rt = !t->cube && !texture_is_volume(t) && kind != K_DXT && t->color != 0x0B
             ? surface_find(phys(t->addr)) : NULL;
        s_draw_textured = 1;
        if (!s_draw_tex_addr) s_draw_tex_addr = t->addr;
        if (rt && rt->sx > rt->sy * 1.001f) s_draw_reads_wide = 1;
        zt = t->color == 0x35 && !t->cube ? depth_find(phys(t->addr)) : NULL;
        if (zt && zt->y16) {
            view = zt->y16;                     /* each pixel is two texels */
            pc->tex_scale[n][0] = 1.0f / (float)(2 * zt->w);
            pc->tex_scale[n][1] = 1.0f / (float)zt->h;
        } else if (rt) {
            surface_sync(rt, 0);
            surface_resolve(rt);
            /* The target being drawn is read through a copy. Multisampled
             * too: its tex is this pass's resolve attachment, which the GPU
             * writes tile by tile while the draw samples it (D3D11 resolves
             * separately, so upstream could read tex directly). */
            view = rt == s ? feedback_copy(rt) : rt->tex;
            if (t->color == 0x35 && rt->bpp == 4 && rt->y16) {
                view = rt->y16;                 /* each pixel is two texels */
                pc->tex_scale[n][0] = 1.0f / (float)(2 * rt->w);
                pc->tex_scale[n][1] = 1.0f / (float)rt->h;
            } else if (kind == K_LIN) {
                pc->tex_scale[n][0] = 1.0f / (float)rt->w;
                pc->tex_scale[n][1] = 1.0f / (float)rt->h;
                /* A pass into a smaller target is a reduction; see surface_mips. */
                if (s && s != rt && s->iw < rt->iw && s->ih < rt->ih) {
                    id<MTLTexture> m = surface_mips(rt);
                    if (m) { view = m; reduce = 1; }
                }
            } else {
                pc->tex_scale[n][0] = (float)t->width / (float)rt->w;
                pc->tex_scale[n][1] = (float)t->height / (float)rt->h;
                if (t->levels > 1 && rt->swizzled && rt != s_cur_rt) {
                    id<MTLTexture> c = surface_chain(rt, t, &levels);
                    if (c) view = c;
                }
            }
        } else {
            view = texture_get_with_levels(t, &levels);
            /* A pack image is larger than the title's: its own mip chain,
             * picked by footprint, rather than the title's level clamps. */
            if (s_tex_replaced) reduce = 1;
            if (kind == K_LIN) {
                pc->tex_scale[n][0] = 1.0f / (float)t->width;
                pc->tex_scale[n][1] = 1.0f / (float)t->height;
            }
        }
        if (kind == K_LIN) {
            pc->tex_scale[n][2] = pc->tex_scale[n][0];
            pc->tex_scale[n][3] = pc->tex_scale[n][1];
        } else {
            pc->tex_scale[n][2] = pc->tex_scale[n][3] = 1.0f;
        }
        if (!view) continue;
        if (texture_is_volume(t) && !rt) { ds->tex[9 + n] = view; pc->tex_info[n][3] = 1; }
        else if (t->cube && !rt) ds->tex[4 + n] = view;
        else ds->tex[n] = view;
        ds->smp[n] = sampler(t, levels, reduce, !rt && !zt && smooth_magnification(),
                             &pc->lod_bias[n]);
        /* The title opts in its 256x256 DXT5 horizon panorama, magnified
         * across the skyline through destination alpha. */
        if (n == 0 && !rt && !t->cube && kind == K_DXT && t->color == 0x0F &&
            t->width == 256 && t->height == 256 && levels > 4 &&
            (((t->filter >> 16) & 0xFF) == 2 || ((t->filter >> 16) & 0xFF) == 4 ||
             ((t->filter >> 16) & 0xFF) == 6) && ((t->filter >> 24) & 0xF) != 1 &&
            s_bspline_sf && !st->depth_test && st->blend_enable &&
            st->blend_sfactor == s_bspline_sf && st->blend_dfactor == s_bspline_df)
            s_draw_bspline = 1;
        pc->tex_info[n][0] = (t->control0 >> 2) & 1;
        pc->tex_info[n][1] = t->filter >> 28;
        /* Point taps of an upscaled linear target average the guest pixel's
         * host block; see tapbox. */
        if (rt && kind == K_LIN && t->color != 0x35 && (rt->iw > rt->w || rt->ih > rt->h) &&
            ((t->filter >> 24) & 0xF) == 1 && !(((t->filter >> 16) & 0xFF) == 2 ||
            ((t->filter >> 16) & 0xFF) == 4 || ((t->filter >> 16) & 0xFF) == 6))
            pc->tex_info[n][2] = 1;
        memcpy(pc->bump_mat[n], t->bump_mat, sizeof pc->bump_mat[n]);
        pc->bump_lum[n][0] = t->bump_scale;
        pc->bump_lum[n][1] = t->bump_offset;
    }
    for (n = 0; n < 4; n++)
        if (!ds->smp[n]) ds->smp[n] = s_linear_clamp;

    /* A sampled surface's CPU upload can blit and unbind this draw's
     * outputs. Restore targets and viewport before binding its textures. */
    if ((s != s_cur_rt || d != s_cur_ds) &&
        !bind_targets(st, st->depth_test || st->stencil_test || flare_depth, &s, &d, &gw, &gh))
        return 0;

    /* Combiners. */
    for (n = 0; n < 8; n++) {
        pc->c_icw[n] = st->rc.color_icw[n];
        pc->a_icw[n] = st->rc.alpha_icw[n];
        pc->c_ocw[n] = st->rc.color_ocw[n];
        pc->a_ocw[n] = st->rc.alpha_ocw[n];
        unpack4(st->rc.factor0[n], pc->cf0[n]);
        unpack4(st->rc.factor1[n], pc->cf1[n]);
    }
    unpack4(st->rc.final_c0, pc->fin_c0);
    unpack4(st->rc.final_c1, pc->fin_c1);
    pc->fin0 = st->rc.final0;
    pc->fin1 = st->rc.final1;
    pc->rc_control = st->rc.control;
    pc->stage_prog = st->rc_seen ? st->rc.stage_program : (st->tex_used & 1);
    pc->alpha_func = st->alpha_func;
    pc->alpha_ref = st->alpha_ref;
    pc->ps_flags = (st->rc_seen ? 1u : 0u) | (st->alpha_test ? 2u : 0u) |
                   (s_draw_bspline ? 4u : 0u);
    pc->clip_plane = st->clip_plane_mode;
    pc->other_input = st->other_stage_input;
    {   /* MM3's water (Water.psh: a 2D ripple map, two dot products and a
         * reflection into the sky's cube map) is drawn blue; see ps tint. */
        static int tint = -1;
        if (tint < 0) tint = !getenv("MM3_WATER_TINT") || atoi(getenv("MM3_WATER_TINT")) != 0;
        /* The showroom's reflective floor runs the same program; the water
         * alone reads a 128x128 ripple map the game draws, and a 64x64 sky
         * cube map. */
        pc->pad0 = tint && st->rc_seen && st->rc.stage_program == 0x64621u &&
                   st->tex[3].cube && st->tex[3].width == 64 &&
                   st->tex[0].width == 128 && st->tex[0].height == 128 &&
                   surface_find(phys(st->tex[0].addr)) != NULL;
    }
    pc->dot_map = st->dot_rgb_mapping;
    /* SET_FOG_COLOR keeps red in the low byte. */
    pc->fog_color[0] = (st->fog_color & 0xFF) / 255.0f;
    pc->fog_color[1] = ((st->fog_color >> 8) & 0xFF) / 255.0f;
    pc->fog_color[2] = ((st->fog_color >> 16) & 0xFF) / 255.0f;
    pc->fog_color[3] = (st->fog_color >> 24) / 255.0f;
    int wbuf = st->z_perspective && d && !(s_exp & 1);
    if (wbuf) {
        uint32_t zm = zf == 1 ? 0xFFFFu : 0xFFFFFFu;
        if (st->poly_offset_fill) {
            pc->zp0[0] = st->poly_offset_factor;
            pc->zp0[1] = st->poly_offset_units;
        }
        pc->zp0[2] = s_cur_sx;
        pc->zp0[3] = s_cur_sy;
        pc->zp1[0] = 1.0f / ((float)zm + 1.0f);
        pc->zp1[1] = (float)zm;
        if (s_depth_hazed && st->depth_test && st->depth_mask && s_zview_remap[0] > 1.0f) {
            pc->zp1[2] = s_zview_remap[0];
            pc->zp1[3] = s_zview_remap[1];
        }
    }
    if (!wclip_scissored(st)) {
        /* Regions apply per pixel: inclusive keeps a pixel inside any
         * region the title set, exclusive one outside all of them. */
        int w;
        pc->wclip_mode = st->wclip_type & 1 ? 2u : 1u;
        for (w = 0; w < 8; w++) {
            uint32_t h = st->wclip_h[w], v = st->wclip_v[w];
            if (!(st->wclip_mask >> w & 1)) continue;
            pc->wclip[w][0] = (float)(h & 0xFFF) * s_aa_x * s_cur_sx;
            pc->wclip[w][1] = (float)(v & 0xFFF) * s_aa_y * s_cur_sy;
            pc->wclip[w][2] = (float)((h >> 16 & 0xFFF) + 1) * s_aa_x * s_cur_sx;
            pc->wclip[w][3] = (float)((v >> 16 & 0xFFF) + 1) * s_aa_y * s_cur_sy;
        }
    }
    if (s_prof_on > 0) s_prof_ps_uploads++;

    if (st->poly_offset_fill && !wbuf) {
        /* The slope term multiplies the depth change per pixel. At an
         * internal resolution s times the guest's a pixel spans 1/s as much
         * depth, so the factor scales by s to offset decals as far as the
         * NV2A does; unscaled they fight. */
        ds->bias = st->poly_offset_units;
        ds->slope = st->poly_offset_factor * s_cur_sy;
    }
    ds->prim = topology == NV_D3D_LINES ? MTLPrimitiveTypeLine :
               topology == NV_D3D_POINTS ? MTLPrimitiveTypePoint : MTLPrimitiveTypeTriangle;
    ds->variant = (st->flat_shade ? 1u : 0u) | (wbuf ? 2u : 0u);
    /* Coverage is only ever changed by the multisampled alpha test (and the
     * W-buffer's distance fade, which writes depth anyway). RECOMP_PS_NC=0
     * keeps it on every draw. */
    if (PS_NC() && !(ds->variant & 2) && (!(pc->ps_flags & 2) || !(s && s->ms)))
        ds->variant |= 4u;
    ds->fs = spec_ps(pc, ds->variant);
    if (!ds->fs) ds->fs = s_fn_psv[ds->variant];
    if ((s_exp & 2) && s_fn_dbg) ds->fs = s_fn_dbg;
    else if ((s_exp & 4) && s_fn_dbg_tex) ds->fs = s_fn_dbg_tex;
    s_prof_vdraws[ds->fs == s_fn_psv[ds->variant] ? 1 : 0][ds->variant]++;
    /* The horizon panorama reads the frame drawn so far (see bspline0). */
    if (s_draw_bspline && s) {
        surface_resolve(s);
        ds->tex[8] = feedback_copy(s);
    }
    ds->cull = cull == 3 ? 0 : cull;
    ds->front_ccw = st->front_face == 0x901;
    ds->scissor = apply_scissor(st, gw, gh);
    if ((st->blend_sfactor | st->blend_dfactor) & 0x8000) {
        float c[4];
        unpack4(st->blend_color, c);
        if (st->blend_sfactor == 0x8003 || st->blend_sfactor == 0x8004 ||
            st->blend_dfactor == 0x8003 || st->blend_dfactor == 0x8004)
            ds->bf[0] = ds->bf[1] = ds->bf[2] = ds->bf[3] = c[3];
        else
            memcpy(ds->bf, c, sizeof ds->bf);
    }
    ds->blend_enable = st->blend_enable != 0;
    ds->sf = st->blend_sfactor;
    ds->df = st->blend_dfactor;
    ds->eq = st->blend_equation;
    ds->mask = s ? write_mask(st, s) : 0;
    ds->ds = d ? ds_state(st->depth_test || flare_depth, flare_depth ? 0x203u : st->depth_func,
                          flare_depth ? 0u : st->depth_mask,
                          st->stencil_test, st->stencil_func, st->stencil_func_mask,
                          st->stencil_write_mask, st->stencil_fail,
                          st->stencil_zfail, st->stencil_zpass) : s_ds_off;
    ds->stencil_ref = st->stencil_ref & 0xFF;
    *out_s = s;
    *out_gw = gw;
    *out_gh = gh;
    *out_zmax = zf == 1 ? 0xFFFFu : 0xFFFFFFu;
    return 1;
}

/* The gathered state on the encoder, with the pipeline for vertex shader vs. */
static id<MTLRenderCommandEncoder> apply_draw_state(const DrawState *ds, id<MTLFunction> vs)
{
    id<MTLRenderCommandEncoder> e;
    id<MTLRenderPipelineState> pso = draw_pipeline(ds, vs);
    int n;
    if (!pso || !(e = render_encoder())) return nil;
    [e setRenderPipelineState:pso];
    [e setViewport:(MTLViewport){ 0, 0, (double)s_vp_w, (double)s_vp_h, 0, 1 }];
    [e setScissorRect:ds->scissor];
    [e setCullMode:ds->cull == 1 ? MTLCullModeFront : ds->cull == 2 ? MTLCullModeBack : MTLCullModeNone];
    [e setFrontFacingWinding:ds->front_ccw ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [e setDepthBias:ds->bias slopeScale:ds->slope clamp:0];
    [e setDepthStencilState:ds->ds];
    [e setStencilReferenceValue:ds->stencil_ref];
    [e setBlendColorRed:ds->bf[0] green:ds->bf[1] blue:ds->bf[2] alpha:ds->bf[3]];
    [e setFragmentBytes:&ds->pc length:sizeof ds->pc atIndex:0];
    for (n = 0; n < 4; n++) {
        [e setFragmentTexture:ds->tex[n] ? ds->tex[n] : s_null_2d atIndex:(NSUInteger)n];
        [e setFragmentTexture:ds->tex[4 + n] ? ds->tex[4 + n] : s_null_cube atIndex:(NSUInteger)(4 + n)];
        [e setFragmentSamplerState:ds->smp[n] atIndex:(NSUInteger)n];
    }
    [e setFragmentTexture:ds->tex[8] ? ds->tex[8] : s_null_2d atIndex:8];
    for (n = 0; n < 4; n++)
        [e setFragmentTexture:ds->tex[9 + n] ? ds->tex[9 + n] : s_null_vol atIndex:(NSUInteger)(9 + n)];
    if (s_pass_log_now) {
        fprintf(stderr, "[PASS]     draw fs %s v%u blend %d %x/%x scissor %lux%lu", [[ds->fs name] UTF8String],
                ds->variant, ds->blend_enable, ds->sf, ds->df,
                (unsigned long)ds->scissor.width, (unsigned long)ds->scissor.height);
        for (n = 0; n < 9; n++)
            if (ds->tex[n]) fprintf(stderr, " t%d %lux%lu%s", n, (unsigned long)ds->tex[n].width,
                                    (unsigned long)ds->tex[n].height,
                                    ds->tex[n].mipmapLevelCount > 1 ? "m" : "");
        fprintf(stderr, "\n");
    }
    return e;
}

/* An index list into the ring, rebased by sub. Flat shading takes colours
 * from a primitive's last vertex on the NV2A (GL's provoking vertex) but its
 * first on Metal, so flat primitives are rotated to lead with their last
 * vertex; rotating a triangle keeps its winding. */
static void copy_indices(uint32_t *o, const uint32_t *idx, uint32_t ni, uint32_t sub,
                         int topology, int flat)
{
    uint32_t i;
    if (flat && topology == NV_D3D_TRIANGLES) {
        for (i = 0; i + 2 < ni; i += 3) {
            o[i] = idx[i + 2] - sub; o[i + 1] = idx[i] - sub; o[i + 2] = idx[i + 1] - sub;
        }
    } else if (flat && topology == NV_D3D_LINES) {
        for (i = 0; i + 1 < ni; i += 2) {
            o[i] = idx[i + 1] - sub; o[i + 1] = idx[i] - sub;
        }
    } else {
        for (i = 0; i < ni; i++) o[i] = idx[i] - sub;
    }
}

/* ---------------------------------------------- vertex processing on the GPU
 *
 * Every draw runs ub_vs: it pulls the title's raw vertex arrays from a byte
 * buffer (any format, any alignment) and either interprets the current NV2A
 * vertex program or passes pre-transformed vertices through. */

#define NV_VSH_SLOTS 136

/* Bytes one element of an NV2A array format occupies; 0 if unknown. */
static uint32_t attr_bytes(uint32_t type, uint32_t size)
{
    if (!size || size > 4) return 0;
    switch (type) {
    case 0: case 6: return 4;                        /* D3DCOLOR, 11:11:10 */
    case 2: return 4 * size;                         /* float */
    case 4: return size;                             /* ubyte */
    case 1: case 5: return 2 * size;                 /* short */
    default: return 0;
    }
}

int nv2a_d3d_widescreen(void)
{
    return widen() > 1.001f;
}

/* Menu pointing (RECOMP_MENU_KEYS): each frame's textured screen-space quads,
 * in guest pixels, with the colour their vertices leave the vertex stage
 * with, and where the last frame landed in the window. */
typedef NvMenuRect MenuRect;
#define MENU_RECTS 1024
static MenuRect s_mr_frame[MENU_RECTS], s_mr_shown[MENU_RECTS];
static int s_mr_frame_n, s_mr_shown_n;
static float s_present_rect[4];                  /* x0, y0, w, h as client fractions */
static pthread_rwlock_t s_mr_lock = PTHREAD_RWLOCK_INITIALIZER;
static _Atomic int s_mr_on;
static const uint32_t *s_mr_tints;               /* the current draw's, see header */

void nv2a_d3d_collect_menu_rects(int on)
{
    atomic_store(&s_mr_on, on != 0);
}

int nv2a_d3d_menu_rects_on(void)
{
    return atomic_load(&s_mr_on) != 0;
}

void nv2a_d3d_set_menu_tints(const uint32_t *tints)
{
    s_mr_tints = tints;
}

int nv2a_d3d_menu_rects(NvMenuRect *out, int max, float present[4])
{
    int n;
    pthread_rwlock_rdlock(&s_mr_lock);
    n = s_mr_shown_n < max ? s_mr_shown_n : max;
    memcpy(out, s_mr_shown, (size_t)n * sizeof *out);
    memcpy(present, s_present_rect, sizeof s_present_rect);
    pthread_rwlock_unlock(&s_mr_lock);
    return n;
}

void nv2a_d3d_set_bspline_blend(uint32_t sfactor, uint32_t dfactor)
{
    s_bspline_sf = sfactor;
    s_bspline_df = dfactor;
}

/* One rect per triangle: either half of an axis-aligned quad spans the
 * whole quad, so batched quads come apart without knowing how they pair. */
static void note_menu_rects(const float (*pos)[4], const uint32_t *idx, uint32_t ni, uint32_t lo)
{
    uint32_t group = ni % 3 == 0 ? 3 : ni, k, j;
    for (k = 0; k + group <= ni && s_mr_frame_n < MENU_RECTS; k += group) {
        MenuRect r = { 1e30f, 1e30f, -1e30f, -1e30f, s_draw_tex_addr,
                       s_mr_tints ? s_mr_tints[idx[k] - lo] : 0xFFFFFFFFu };
        for (j = k; j < k + group; j++) {
            const float *v = pos[idx[j] - lo];
            if (v[3] != 1.0f) return;
            if (v[0] < r.x0) r.x0 = v[0];
            if (v[0] > r.x1) r.x1 = v[0];
            if (v[1] < r.y0) r.y0 = v[1];
            if (v[1] > r.y1) r.y1 = v[1];
        }
        if (s_mr_frame_n && !memcmp(&s_mr_frame[s_mr_frame_n - 1], &r, sizeof r))
            continue;                            /* the quad's other half */
        s_mr_frame[s_mr_frame_n++] = r;
    }
}

/* The vertex program and constants live in the vertex ring, uploaded when
 * their version changes (or the ring has wrapped over them since). */
#define s_ring_wraps (s_vb_gen)

static void draw_ub_impl(const NvD3DState *st, int topology, const NvD3DAttrib attr[16],
                         const float def[16][4], int program, const uint32_t *idx, uint32_t ni,
                         uint32_t lo, uint32_t hi, const float (*pos)[4])
{
    static uint32_t s_prog_version, s_vconst_version, s_prog_wraps, s_vconst_wraps;
    static size_t s_prog_off, s_vconst_off;
    static int s_prog_valid, s_vconst_valid;
    static float *dx;
    static uint32_t dx_cap;
    struct { const uint8_t *base; uint32_t stride, span; } grp[16];
    uint32_t ngrp = 0, i, count = hi - lo + 1, gw, gh, zmax, gof[16];
    UbConsts uc;
    Surface *s;
    uint8_t *p;
    size_t vb_off, ib_off;
    uint32_t total = 0, at = 0, ib_bytes = ni * 4;
    float squeeze = 1.0f, shift = 0.0f, yscale = 1.0f;
    int use_dx = 0;
    int64_t t_draw;
    id<MTLRenderCommandEncoder> e;

    if (!nv2a_d3d_init() || !ni || hi < lo || ib_bytes > IB_BYTES)
        return;
    memset(&uc, 0, sizeof uc);
    memcpy(uc.def, def, sizeof uc.def);
    /* Arrays: interleaved ones share one copied span. */
    for (i = 0; i < 16; i++) {
        uint32_t g, bytes = attr_bytes(attr[i].type, attr[i].size);
        if (!attr[i].enabled) continue;
        uc.at[i][2] = attr[i].type;
        uc.at[i][3] = attr[i].size;
        if (!attr[i].data || !bytes) { uc.at[i][2] = 0xFF; continue; }   /* reads (0,0,0,1) */
        for (g = 0; g < ngrp; g++)
            if (grp[g].stride == attr[i].stride && attr[i].data >= grp[g].base &&
                attr[i].data + bytes <= grp[g].base + (attr[i].stride ? attr[i].stride : 64))
                break;
        if (g == ngrp) {
            grp[g].base = attr[i].data;
            grp[g].stride = attr[i].stride;
            grp[g].span = 0;
            ngrp++;
        }
        if ((uint32_t)(attr[i].data - grp[g].base) + bytes > grp[g].span)
            grp[g].span = (uint32_t)(attr[i].data - grp[g].base) + bytes;
        gof[i] = g;
        uc.at[i][0] = (uint32_t)(attr[i].data - grp[g].base);   /* + group offset below */
        uc.at[i][1] = attr[i].stride;
    }
    for (i = 0; i < ngrp; i++)
        total += (((grp[i].stride ? (count - 1) * grp[i].stride : 0) + grp[i].span) + 15) & ~15u;
    if (total + count * 4 > VB_BYTES)
        return;

    RECOMP_PROFILE_BEGIN("Metal draw");
    t_draw = s_prof_on > 0 ? qpc() : 0;
    s_prof_draws++;
    if (s_pass_log_now)
        fprintf(stderr, "[PASS]     %u indices, %u vertices, topology %d, %s\n", ni, count, topology,
                program ? "program" : "fixed/pretransformed");
    if (!setup_pipeline(st, topology, &s, &gw, &gh, &zmax)) {
        RECOMP_PROFILE_END();
        return;
    }
    if (pos && s_draw_textured && nv2a_d3d_menu_rects_on())
        note_menu_rects(pos, idx, ni, lo);
    if (pos && s && s->sx > s->sy * 1.001f && s_overlay.place) {
        /* Screen-space 2D on a widened target spans the display unless the
         * title's overlay hooks place it otherwise. */
        float xlo = 1e30f, xhi = -1e30f, ylo = 1e30f, yhi = -1e30f;
        uint32_t k;
        int flat = 1;
        for (k = 0; k < ni && flat; k++) {
            const float *v = pos[idx[k] - lo];
            if (v[3] != 1.0f) flat = 0;
            if (v[0] < xlo) xlo = v[0];
            if (v[0] > xhi) xhi = v[0];
            if (v[1] < ylo) ylo = v[1];
            if (v[1] > yhi) yhi = v[1];
        }
        if (flat) {
            NvOverlayDraw d;
            if (count > dx_cap) {
                float *nd = realloc(dx, (size_t)count * sizeof *nd);
                if (nd) { dx = nd; dx_cap = count; }
            }
            d.pos = pos; d.idx = idx; d.attrib = attr; d.ni = ni; d.lo = lo; d.count = count;
            d.per = topology == NV_D3D_TRIANGLES ? 3 : topology == NV_D3D_LINES ? 2 : 1;
            d.gw = (float)gw; d.gh = (float)gh; d.narrow = s->sy / s->sx;
            d.x0 = xlo; d.y0 = ylo; d.x1 = xhi; d.y1 = yhi;
            d.tex = s_draw_tex_addr; d.textured = s_draw_textured; d.reads_wide = s_draw_reads_wide;
            use_dx = s_overlay.place(&d, count <= dx_cap ? dx : NULL, &squeeze, &shift);
        }
    }

    /* The vertex program and its constants, when they changed. */
    uc.info[1] = program ? 1u : 0u;
    if (program) {
        uint32_t start, pver, cver;
        const uint32_t (*prog)[4] = nv2a_vsh_program(&start, &pver);
        const float (*consts)[4] = nv2a_vsh_constants(&cver);
        uc.info[0] = start;
        if (!prog || !consts) {
            s_prof_dropped++;
            RECOMP_PROFILE_END();
            return;
        }
        if (!s_prog_valid || pver != s_prog_version || s_prog_wraps != s_ring_wraps) {
            uint8_t *q = ring_alloc(&s_vb_ring, NV_VSH_SLOTS * 16, 256, &s_prog_off);
            if (!q) { RECOMP_PROFILE_END(); return; }
            memcpy(q, prog, NV_VSH_SLOTS * 16);
            s_prog_version = pver;
            s_prog_wraps = s_ring_wraps;
            s_prog_valid = 1;
        }
        if (!s_vconst_valid || cver != s_vconst_version || s_vconst_wraps != s_ring_wraps) {
            uint8_t *q = ring_alloc(&s_vb_ring, 192 * 16, 256, &s_vconst_off);
            if (!q) { RECOMP_PROFILE_END(); return; }
            memcpy(q, consts, 192 * 16);
            s_vconst_version = cver;
            s_vconst_wraps = s_ring_wraps;
            s_vconst_valid = 1;
            /* Both are needed together: a wrap during the second one
             * overwrote the first. */
            if (s_prog_wraps != s_ring_wraps) {
                uint8_t *r = ring_alloc(&s_vb_ring, NV_VSH_SLOTS * 16, 256, &s_prog_off);
                if (!r) { RECOMP_PROFILE_END(); return; }
                memcpy(r, prog, NV_VSH_SLOTS * 16);
                s_prog_wraps = s_ring_wraps;
            }
        }
    }

    /* Vertex data for [lo, hi], one span per group, then any x shifts. */
    if (!(p = ring_alloc(&s_vb_ring, total + (use_dx ? count * 4 : 0), 256, &vb_off))) {
        s_prof_dropped++;
        RECOMP_PROFILE_END();
        return;
    }
    if (program && (s_prog_wraps != s_ring_wraps || s_vconst_wraps != s_ring_wraps)) {
        /* The vertex data wrapped the ring (or a commit started a new
         * generation) after the program and constants went in: put them in
         * again behind it. This draw used to be dropped instead -- a building,
         * a tree, a shadow or a stretch of road missing for one frame every
         * few frames. The space after the vertex data is free, so this does
         * not wrap again unless the draw is most of the ring. */
        uint32_t start, pver, cver, gen = s_ring_wraps;
        const uint32_t (*prog)[4] = nv2a_vsh_program(&start, &pver);
        const float (*consts)[4] = nv2a_vsh_constants(&cver);
        uint8_t *q = prog && consts ? ring_alloc(&s_vb_ring, NV_VSH_SLOTS * 16, 256, &s_prog_off) : NULL;
        uint8_t *r = q ? ring_alloc(&s_vb_ring, 192 * 16, 256, &s_vconst_off) : NULL;
        if (!r || s_ring_wraps != gen) {
            s_prog_valid = s_vconst_valid = 0;
            s_prof_dropped++;
            RECOMP_PROFILE_END();
            return;
        }
        memcpy(q, prog, NV_VSH_SLOTS * 16);
        memcpy(r, consts, 192 * 16);
        s_prog_version = pver; s_prog_wraps = gen; s_prog_valid = 1;
        s_vconst_version = cver; s_vconst_wraps = gen; s_vconst_valid = 1;
    }
    {
        uint32_t goff[16];
        for (i = 0; i < ngrp; i++) {
            uint32_t bytes = (grp[i].stride ? (count - 1) * grp[i].stride : 0) + grp[i].span;
            memcpy(p + at, grp[i].base + (size_t)lo * grp[i].stride, bytes);
            goff[i] = (uint32_t)vb_off + at;
            at += (bytes + 15) & ~15u;
        }
        for (i = 0; i < 16; i++)
            if (attr[i].enabled && uc.at[i][2] != 0xFF)
                uc.at[i][0] += goff[gof[i]];
        if (s_overlay.sanitize_vertex_upload)
            for (i = 0; i < 16; ++i)
                if (attr[i].enabled && attr[i].data && uc.at[i][2] != 0xFF)
                    s_overlay.sanitize_vertex_upload(s_vb_ring.base + uc.at[i][0],
                                                      &attr[i], i, lo, count);
    }
    uc.info[2] = 0xFFFFFFFFu;
    if (use_dx) {
        memcpy(p + at, dx, count * 4);
        uc.info[2] = (uint32_t)vb_off + at;
        at += count * 4;
    }
    if (!(p = ring_alloc(&s_ib_ring, ib_bytes, 256, &ib_off))) {
        RECOMP_PROFILE_END();
        return;
    }
    copy_indices((uint32_t *)p, idx, ni, lo, topology, st->flat_shade);

    uc.map[0] = 2.0f / (float)gw;
    uc.map[1] = 2.0f / (float)gh;
    uc.map[2] = 1.0f / (float)zmax;
    uc.map[3] = squeeze;
    uc.fogi[0] = st->fog_enable;
    uc.fogi[1] = st->fog_mode;
    uc.fogf[0] = st->fog_param[0];
    uc.fogf[1] = st->fog_param[1];
    uc.place[0] = shift;
    uc.place[1] = yscale;
    /* Display passes must translate position and texture interpolation
     * together. Whole-pixel menu vertices keep their placement; offscreen
     * ripple maps keep the snap. */
    uc.place[2] = s && s->w == GUEST_W && s->h == GUEST_H ? 0.0f : 1.0f;
    uc.place[3] = uc.place[2] == 0.0f ? 0.53125f : 0.0f;
    if (!(e = apply_draw_state(&s_draw, s_fn_ub_vs))) {
        RECOMP_PROFILE_END();
        return;
    }
    [e setVertexBytes:&uc length:sizeof uc atIndex:0];
    if (program) {
        [e setVertexBuffer:s_vb_ring.buf offset:s_prog_off atIndex:1];
        [e setVertexBuffer:s_vb_ring.buf offset:s_vconst_off atIndex:2];
    } else {
        [e setVertexBuffer:s_vb_ring.buf offset:0 atIndex:1];
        [e setVertexBuffer:s_vb_ring.buf offset:0 atIndex:2];
    }
    [e setVertexBuffer:s_vb_ring.buf offset:0 atIndex:3];
    [e drawIndexedPrimitives:s_draw.prim indexCount:ni indexType:MTLIndexTypeUInt32
                 indexBuffer:s_ib_ring.buf indexBufferOffset:ib_off];
    s_prof_verts += count;
    if (s_prof_on > 0) s_prof[PROF_DRAW] += qpc() - t_draw;
    RECOMP_PROFILE_END();
}

void nv2a_d3d_draw_ub(const NvD3DState *st, int topology, const NvD3DAttrib attr[16],
                      const float def[16][4], int program, const uint32_t *idx, uint32_t ni,
                      uint32_t lo, uint32_t hi, const float (*pos)[4])
{
    @autoreleasepool {
        draw_ub_impl(st, topology, attr, def, program, idx, ni, lo, hi, pos);
    }
}

void nv2a_d3d_clear(const NvD3DState *st, uint32_t flags, uint32_t color,
                    uint32_t zstencil, uint32_t x0, uint32_t y0,
                    uint32_t x1, uint32_t y1)
{
    @autoreleasepool {
    Surface *s;
    Depth *d;
    uint32_t gw, gh, zf, mask = 0;
    float cc[8];
    int zclear = (flags & 1) != 0, sclear = (flags & 2) != 0;
    id<MTLRenderPipelineState> pso;
    id<MTLRenderCommandEncoder> e;

    if (!nv2a_d3d_init())
        return;
    if (!bind_targets(st, zclear || sclear, &s, &d, &gw, &gh))
        return;
    if (s) {
        if (flags & 0x10) mask |= WRITE_R;
        if (flags & 0x20) mask |= WRITE_G;
        if (flags & 0x40) mask |= WRITE_B;
        if ((flags & 0x80) && surface_alpha_mode(s->color_fmt) < 0)
            mask |= WRITE_A;
    }
    if (!d) { zclear = sclear = 0; }
    if (!mask && !zclear && !sclear)
        return;
    if (s && mask) { s->gpu_dirty = 1; s->drawn++; }
    zf = (st->surface_format >> 4) & 0xF;
    unpack4(color, cc);
    if (s && (s->color_fmt & 0xF) == 0x3) {
        /* Quantise to what a 5:6:5 surface stores. */
        cc[0] = (float)(((color >> 19) & 31) * 255 / 31) / 255.0f;
        cc[1] = (float)(((color >> 10) & 63) * 255 / 63) / 255.0f;
        cc[2] = (float)(((color >> 3) & 31) * 255 / 31) / 255.0f;
    }
    memset(cc + 4, 0, 16);
    cc[4] = zf == 1 ? (float)(zstencil & 0xFFFF) / 65535.0f
                    : (float)(zstencil >> 8) / 16777215.0f;
    if (x1 >= gw) x1 = gw - 1;
    if (y1 >= gh) y1 = gh - 1;
    if (x0 > x1 || y0 > y1)
        return;
    pso = pipeline(s_fn_clear_vs, s_fn_clear_ps, s ? PIX_BGRA : MTLPixelFormatInvalid,
                   d ? PIX_DEPTH : MTLPixelFormatInvalid,
                   s ? (s->ms ? s_msaa : 1) : d->samples, 0, s ? mask : 0, 0, 0, 0);
    if (!pso || !(e = render_encoder()))
        return;
    [e setRenderPipelineState:pso];
    [e setViewport:(MTLViewport){ 0, 0, (double)s_vp_w, (double)s_vp_h, 0, 1 }];
    [e setScissorRect:scissor_rect((uint32_t)(x0 * s_aa_x * s_cur_sx + 0.5f),
                                   (uint32_t)(y0 * s_aa_y * s_cur_sy + 0.5f),
                                   (uint32_t)((x1 + 1) * s_aa_x * s_cur_sx + 0.5f),
                                   (uint32_t)((y1 + 1) * s_aa_y * s_cur_sy + 0.5f))];
    [e setCullMode:MTLCullModeNone];
    [e setDepthBias:0 slopeScale:0 clamp:0];
    [e setDepthStencilState:ds_state(zclear, 7, zclear, sclear, 7, 0xFF, 0xFF, 0x1E01, 0x1E01, 0x1E01)];
    [e setStencilReferenceValue:zf == 1 ? 0 : (zstencil & 0xFF)];
    [e setVertexBytes:cc length:sizeof cc atIndex:0];
    [e setFragmentBytes:cc length:sizeof cc atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
}

/* -------------------------------------------------------------- write-back */

/* What the GPU rendered goes back to guest memory when the title flips, the
 * way the NV2A wrote it before signalling the frame done. The CPU reads and
 * rewrites framebuffers (loading screens persist the display, copy it, draw
 * over it). The copies are queued at the flip; the ack thread completes the
 * read-back once the GPU is done (nv2a_d3d_writeback_busy), holding back
 * DMA_GET and fence releases until then. */
typedef struct {
    UINT w, h;
    int pending;                    /* copied, not yet read back */
    id<MTLBuffer> stage;            /* w*4 bytes per row */
    id<MTLTexture> down;            /* guest-size copy of a scaled surface */
} WbSlot;
static WbSlot s_wb[MAX_SURFACES];
static int s_wb_pending;
static uint32_t s_wb_mask;
static id<MTLCommandBuffer> s_wb_cmd;   /* the submission holding the copies */

/* A readback belongs to the surface that queued it, not the reusable cache
 * slot. A replacement of the same size must not inherit old GPU pixels. */
static void writeback_drop_surface(Surface *s)
{
    unsigned slot = (unsigned)(s - s_surf);
    s_wb[slot].pending = 0;
    s_wb_mask &= ~(1u << slot);
    s_wb_pending = s_wb_mask != 0;
}

static int wb_slot_ready(WbSlot *k, UINT w, UINT h, int need_down)
{
    if (k->stage && (k->w != w || k->h != h)) {
        [k->stage release];
        [k->down release];
        memset(k, 0, sizeof *k);
    }
    if (!k->stage) {
        k->stage = [s_dev newBufferWithLength:(NSUInteger)w * h * 4 options:MTLResourceStorageModeShared];
        if (!k->stage) return 0;
        k->w = w; k->h = h;
    }
    if (need_down && !k->down) {
        k->down = make_texture(w, h, 1, 1, PIX_BGRA, USAGE_RT, 0);
        if (!k->down) return 0;
    }
    return 1;
}

static int wb_surface_ok(const Surface *s)
{
    return s->tex && !s->swizzled && (s->bpp == 2 || s->bpp == 4) &&
           surface_find(s->phys) == s && s->shadow && guest_ok(s->va, (size_t)s->pitch * s->h);
}

/* Read back what is ready; wait: block until all of it is. 1 when none left. */
static int writeback_finish(int wait)
{
    int i;
    if (!s_wb_pending)
        return 1;
    if (s_wb_cmd) {
        if (wait) [s_wb_cmd waitUntilCompleted];
        else if ([s_wb_cmd status] < MTLCommandBufferStatusCompleted) return 0;
        [s_wb_cmd release];
        s_wb_cmd = nil;
    }
    RECOMP_PROFILE_BEGIN("Metal write-back");
    for (i = 0; i < MAX_SURFACES; i++) {
        Surface *s = &s_surf[i];
        WbSlot *k = &s_wb[i];
        uint8_t *dst;
        uint32_t x, y, rowb;
        int amode, r565;
        if (!(s_wb_mask & (1u << i)))
            continue;
        k->pending = 0;
        s_wb_mask &= ~(1u << i);
        if (!wb_surface_ok(s) || k->w != s->w || k->h != s->h)
            continue;                             /* dropped (resize) */
        dst = (uint8_t *)guest(s->va);
        rowb = s->w * s->bpp;
        amode = surface_alpha_mode(s->color_fmt);
        r565 = (s->color_fmt & 0xF) == 0x3;
        for (y = 0; y < s->h; y++) {
            const uint32_t *src = (const uint32_t *)((const uint8_t *)[k->stage contents] + (size_t)y * k->w * 4);
            uint8_t *row = dst + (size_t)y * s->pitch;
            /* A row the CPU changed since the executor last looked holds
             * writes made after this frame was submitted (the title runs
             * ahead): they win, and the next sync uploads them. */
            if (memcmp(row, s->shadow + (size_t)y * rowb, rowb))
                continue;
            if (s->bpp == 4) {
                if (amode < 0) {
                    memcpy(row, src, rowb);
                } else {
                    uint32_t a = amode ? 0xFF000000u : 0, *o = (uint32_t *)row;
                    for (x = 0; x < s->w; x++) o[x] = (src[x] & 0xFFFFFFu) | a;
                }
            } else {
                uint16_t *o = (uint16_t *)row;
                for (x = 0; x < s->w; x++) {
                    uint32_t c = src[x];
                    o[x] = r565 ? (uint16_t)(((c >> 8) & 0xF800) | ((c >> 5) & 0x07E0) | ((c >> 3) & 0x1F))
                                : (uint16_t)((amode == 0 ? 0 : 0x8000) | ((c >> 9) & 0x7C00) |
                                             ((c >> 6) & 0x03E0) | ((c >> 3) & 0x1F));
                }
            }
            memcpy(s->shadow + (size_t)y * rowb, row, rowb);
        }
    }
    RECOMP_PROFILE_END();
    s_wb_pending = 0;
    return 1;
}

int nv2a_d3d_writeback_busy(void)
{
    int busy;
    @autoreleasepool {
        busy = s_wb_pending && !writeback_finish(0);
    }
    return busy;
}

static void writeback_surfaces(void)
{
    static int enabled = -1;
    int i;
    if (enabled < 0)
        enabled = !getenv("RECOMP_D3D_NO_WRITEBACK");
    if (!enabled)
        return;
    /* The staging slots are reused, so the previous read-back must have
     * landed. While the GPU is still on it, skip this one rather than wait:
     * guest memory then trails by a frame or two under load, where waiting
     * here held every heavy frame to the GPU's pace (40 fps in dense
     * streets). Surfaces stay dirty and go with the next. */
    if (!writeback_finish(0))
        return;
    RECOMP_PROFILE_BEGIN("Metal write-back issue");
    for (i = 0; i < MAX_SURFACES; i++) {
        Surface *s = &s_surf[i];
        WbSlot *k = &s_wb[i];
        int scaled;
        id<MTLTexture> src;
        if (!s->gpu_dirty || !wb_surface_ok(s))
            continue;
        scaled = s->iw != s->w || s->ih != s->h;
        if (!wb_slot_ready(k, s->w, s->h, scaled))
            continue;
        surface_resolve(s);
        src = s->tex;
        if (scaled) {
            float x0, x1;
            guest_span(s, &x0, &x1);
            blit_span(s->tex, nil, k->down, nil, s->w, s->h, -1.0f, 0, 1, x0, x1);
            src = k->down;
        }
        [blit_encoder_for(BRK_WRITEBACK) copyFromTexture:src sourceSlice:0 sourceLevel:0
                           sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(s->w, s->h, 1)
                               toBuffer:k->stage destinationOffset:0
                 destinationBytesPerRow:(NSUInteger)s->w * 4 destinationBytesPerImage:(NSUInteger)s->w * s->h * 4];
        s->gpu_dirty = 0;                        /* later draws dirty it again */
        k->pending = 1;
        s_wb_mask |= 1u << i;
        s_wb_pending = 1;
    }
    if (s_wb_pending) {
        submit(0);
        [s_wb_cmd release];
        s_wb_cmd = [s_last_commit retain];
    }
    RECOMP_PROFILE_END();
}

/* ----------------------------------------------------- visibility tests */

/* NV097_SET_ZPASS_PIXEL_COUNT_ENABLE / CLEAR_REPORT_VALUE / GET_REPORT, as
 * Metal visibility counting. Each render pass opened while a test runs counts
 * into a slot of its own; reading the report waits for the GPU and sums them.
 * A title asks for a handful per frame and polls the report until written. */
static uint64_t s_zpass;

static void vis_begin_encoder(void)
{
    uint64_t *slots = (uint64_t *)[s_vis_buf contents];
    if (!s_query_active || !s_enc) return;
    if (s_vis_next - s_vis_first >= VIS_SLOTS) return;     /* counted as zero */
    s_vis_enc_slot = (int)(s_vis_next++ % VIS_SLOTS);
    slots[s_vis_enc_slot] = 0;
    [s_enc setVisibilityResultMode:MTLVisibilityResultModeCounting
                            offset:(NSUInteger)s_vis_enc_slot * 8];
}

static void zpass_collect(void)
{
    const uint64_t *slots;
    uint32_t i;
    if (!s_query_active) return;
    if (s_enc && s_vis_enc_slot >= 0)
        [s_enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    submit(1);
    slots = (const uint64_t *)[s_vis_buf contents];
    for (i = s_vis_first; i != s_vis_next; i++)
        s_zpass += slots[i % VIS_SLOTS];
    s_query_active = 0;
}

void nv2a_d3d_zpass_enable(int on)
{
    if (!nv2a_d3d_init()) return;
    @autoreleasepool {
        zpass_collect();
        if (on) {
            s_query_active = 1;
            s_vis_first = s_vis_next;
            vis_begin_encoder();           /* an open encoder counts from here */
        }
    }
}

void nv2a_d3d_zpass_clear(void)
{
    int was = s_query_active;
    @autoreleasepool { zpass_collect(); }
    s_zpass = 0;
    if (was) nv2a_d3d_zpass_enable(1);
}

uint32_t nv2a_d3d_zpass_read(void)
{
    int was = s_query_active;
    double px;
    static int always = -1;
    s_prof_queries++;
    /* RECOMP_ZPASS_ALWAYS=1 (diagnosis): every test reports fully visible. */
    if (env_switch("RECOMP_ZPASS_ALWAYS", &always, 0)) return 0x00FFFFFFu;
    @autoreleasepool { zpass_collect(); }
    if (was) nv2a_d3d_zpass_enable(1);
    /* In guest pixels: the host target has scale^2 as many, and an MSAA
     * target counts samples. */
    px = (double)s_zpass / ((double)s_cur_sx * s_cur_sy *
                            (s_cur_rt && s_cur_rt->ms ? (double)s_msaa : 1.0));
    return px > 4294967295.0 ? 0xFFFFFFFFu : (uint32_t)px;
}

/* ---------------------------------------------------------------- present */

static id<MTLTexture> s_ovl_tex;
static UINT s_ovl_w, s_ovl_h;
static uint32_t s_ovl_serial = 0xFFFFFFFFu;
static DWORD s_last_present, s_last_flip;
static Surface *s_shown;
static CAMetalLayer *s_layer;
static UINT s_swap_w, s_swap_h;

/* The window's layer, sized to its drawable area; 0 if there is none. */
static int ensure_swapchain(void)
{
    CAMetalLayer *layer = (CAMetalLayer *)xbox_FramebufferMetalLayer();
    UINT w, h;
    if (!layer || !client_size(&w, &h)) return 0;
    if (layer != s_layer) {
        static int vsync = -1;
        if (vsync < 0) vsync = getenv("RECOMP_VSYNC") ? atoi(getenv("RECOMP_VSYNC")) : 1;
        [s_layer release];
        s_layer = [layer retain];
        s_layer.device = s_dev;
        s_layer.pixelFormat = PIX_BGRA;
        s_layer.framebufferOnly = NO;           /* kept and captured images copy it */
        s_layer.displaySyncEnabled = vsync ? YES : NO;
        s_layer.maximumDrawableCount = 3;
        s_swap_w = s_swap_h = 0;
    }
    if (w != s_swap_w || h != s_swap_h) {
        s_layer.drawableSize = CGSizeMake(w, h);
        s_swap_w = w; s_swap_h = h;
        fprintf(stderr, "[METAL] drawable %ux%u\n", w, h);
    }
    return 1;
}

/* RECOMP_PRESENT_CAPTURE=<prefix>; create <prefix>.flag to capture the next
 * presented images (as many as the flag file's number, default 1). */
static void write_bmp(id<MTLTexture> tex, const char *path)
{
    NSUInteger w = [tex width], h = [tex height];
    id<MTLBuffer> buf = [s_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    FILE *f;
    if (!buf) return;
    [blit_encoder_for(BRK_OTHER) copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0
             destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    submit(1);
    {
        uint32_t row = ((uint32_t)w * 3 + 3) & ~3u, img = row * (uint32_t)h, tot = 54 + img, y, x;
        uint32_t ww = (uint32_t)w, hh = (uint32_t)h;
        uint8_t hdr[54], *line = (uint8_t *)calloc(1, row);
        const uint8_t *px = (const uint8_t *)[buf contents];
        f = fopen(path, "wb");
        if (f && line) {
            memset(hdr, 0, sizeof hdr);
            hdr[0] = 'B'; hdr[1] = 'M';
            memcpy(hdr + 2, &tot, 4);
            hdr[10] = 54; hdr[14] = 40;
            memcpy(hdr + 18, &ww, 4);
            memcpy(hdr + 22, &hh, 4);
            hdr[26] = 1; hdr[28] = 24;
            memcpy(hdr + 34, &img, 4);
            fwrite(hdr, 1, 54, f);
            for (y = 0; y < hh; y++) {
                const uint8_t *src = px + (size_t)(hh - 1 - y) * w * 4;
                for (x = 0; x < ww; x++) {
                    line[x * 3] = src[x * 4];
                    line[x * 3 + 1] = src[x * 4 + 1];
                    line[x * 3 + 2] = src[x * 4 + 2];
                }
                fwrite(line, 1, row, f);
            }
            fprintf(stderr, "[METAL] captured %s\n", path);
        }
        if (f) fclose(f);
        free(line);
    }
    [buf release];
}

static void capture_backbuffer(id<MTLTexture> bb)
{
    static const char *prefix = (const char *)-1;
    static unsigned remaining, frame;
    char path[1024];
    FILE *f;
    if (prefix == (const char *)-1) prefix = getenv("RECOMP_PRESENT_CAPTURE");
    if (!prefix) return;
    if (!remaining) {
        int count = 0;
        snprintf(path, sizeof path, "%s.flag", prefix);
        f = fopen(path, "rb");
        if (!f) return;
        if (fscanf(f, "%d", &count) != 1 || count < 1) count = 1;
        fclose(f);
        remove(path);
        remaining = (unsigned)count;
    }
    snprintf(path, sizeof path, "%s-%03u.bmp", prefix, frame++);
    write_bmp(bb, path);
    remaining--;
}

/* Above 0 while a load keeps the last frame up: the spinner's phase. */
static float s_loading;

/* Draw surface `s` (with the overlay described in *pc) into a w x h target,
 * letterboxed to the display aspect when asked. */
static void composite(id<MTLTexture> target, UINT w, UINT h, Surface *s,
                      PresentConsts *pc, int letterbox)
{
    float target_w = (float)w, target_h = (float)h, x0 = 0, y0 = 0;
    static const float black[4] = { 0, 0, 0, 1 };
    MTLRenderPassDescriptor *d;
    id<MTLRenderCommandEncoder> e;
    id<MTLRenderPipelineState> pso;
    if (letterbox) {
        target_h = target_w / nv2a_d3d_display_aspect();
        if (target_h > (float)h) {
            target_h = (float)h;
            target_w = target_h * nv2a_d3d_display_aspect();
        }
        x0 = ((float)w - target_w) * 0.5f;
        y0 = ((float)h - target_h) * 0.5f;
    }
    if (letterbox) {
        pthread_rwlock_wrlock(&s_mr_lock);
        s_present_rect[0] = x0 / w; s_present_rect[1] = y0 / h;
        s_present_rect[2] = target_w / w; s_present_rect[3] = target_h / h;
        pthread_rwlock_unlock(&s_mr_lock);
    }
    pc->dst_rect[0] = x0 / w * 2 - 1;
    pc->dst_rect[1] = 1 - y0 / h * 2;
    pc->dst_rect[2] = (x0 + target_w) / w * 2 - 1;
    pc->dst_rect[3] = 1 - (y0 + target_h) / h * 2;
    pc->src_uv[0] = pc->src_uv[1] = 0;
    pc->src_uv[2] = 1; pc->src_uv[3] = 1;
    pc->src_size[0] = (float)s->w; pc->src_size[1] = (float)s->h;
    pc->src_size[2] = (float)s->iw; pc->src_size[3] = (float)s->ih;
    pc->force_alpha[0] = 1.0f;
    pc->force_alpha[1] = letterbox ? s_loading : 0.0f;   /* the window only */
    pc->force_alpha[2] = (float)w;
    pc->force_alpha[3] = (float)h;
    if (pc->ovl_flags[0] && s->sx > s->sy * 1.001f) {
        pc->ovl_in[2] = s->sx / s->sy;
        pc->ovl_in[3] = (float)s->w * 0.5f;
    }
    surface_resolve(s);
    pso = pipeline(s_fn_present_vs, s_fn_present_ps, [target pixelFormat], MTLPixelFormatInvalid,
                   1, 0, WRITE_ALL, 0, 0, 0);
    if (!pso) return;
    unbind_targets();
    d = pass_descriptor(target, nil, nil);
    d.visibilityResultBuffer = nil;
    d.colorAttachments[0].loadAction = MTLLoadActionClear;
    d.colorAttachments[0].clearColor = MTLClearColorMake(black[0], black[1], black[2], black[3]);
    e = [cmd() renderCommandEncoderWithDescriptor:d];
    [e setRenderPipelineState:pso];
    [e setViewport:(MTLViewport){ 0, 0, (double)w, (double)h, 0, 1 }];
    [e setVertexBytes:pc length:sizeof *pc atIndex:0];
    [e setFragmentBytes:pc length:sizeof *pc atIndex:0];
    [e setFragmentTexture:s->tex atIndex:0];
    [e setFragmentTexture:pc->ovl_flags[0] && s_ovl_tex ? s_ovl_tex : s_null_2d atIndex:1];
    [e setFragmentSamplerState:s_linear_clamp atIndex:0];
    [e setFragmentSamplerState:s_point_clamp atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
}

/* The overlay, uploaded when a new frame arrived, as present constants. */
static void prepare_overlay(PresentConsts *pc)
{
    XboxOverlay ovl;
    if (!xbox_FramebufferOverlay(&ovl))
        return;
    if (ovl.serial != s_ovl_serial || !s_ovl_tex) {
        uint32_t *px = scratch_pixels((size_t)ovl.in_w * ovl.in_h), x, y;
        if (px) {
            for (y = 0; y < ovl.in_h; y++)
                for (x = 0; x + 1 < ovl.in_w; x += 2)
                    yuv_pair(ovl.yuy2 + (size_t)y * ovl.pitch + x * 2, 0,
                             px + (size_t)y * ovl.in_w + x);
            if (!s_ovl_tex || s_ovl_w != ovl.in_w || s_ovl_h != ovl.in_h) {
                [s_ovl_tex release];
                s_ovl_tex = make_texture(ovl.in_w, ovl.in_h, 1, 1, PIX_BGRA, MTLTextureUsageShaderRead, 0);
                s_ovl_w = ovl.in_w; s_ovl_h = ovl.in_h;
            }
            if (s_ovl_tex)
                upload_region(s_ovl_tex, 0, 0, 0, 0, ovl.in_w, ovl.in_h, px, (NSUInteger)ovl.in_w * 4, ovl.in_h);
        }
        s_ovl_serial = ovl.serial;
    }
    if (!s_ovl_tex)
        return;
    pc->ovl_flags[0] = 1;
    pc->ovl_flags[1] = ovl.color_key_enabled;
    pc->ovl_flags[2] = ovl.color_key;
    pc->ovl_out[0] = (float)ovl.out_x; pc->ovl_out[1] = (float)ovl.out_y;
    pc->ovl_out[2] = (float)ovl.out_w; pc->ovl_out[3] = (float)ovl.out_h;
    pc->ovl_walk[0] = ovl.start_s / 1048576.0f;
    pc->ovl_walk[1] = ovl.start_t / 1048576.0f;
    pc->ovl_walk[2] = ovl.ds_dx / 1048576.0f;
    pc->ovl_walk[3] = ovl.dt_dy / 1048576.0f;
    pc->ovl_in[0] = (float)ovl.in_w; pc->ovl_in[1] = (float)ovl.in_h;
    pc->ovl_in[2] = 1.0f;
}

/* RECOMP_CAPTURE_SURFACE: the composited guest image at internal resolution
 * (no window scaling or letterbox), for pixel comparisons. */
static id<MTLTexture> s_cap_tex;

/* A copy of the last image presented, for nv2a_d3d_repeat_frame: the guest
 * may already be drawing the next frame into the surface it came from. */
static id<MTLTexture> s_kept;

static void keep_image(id<MTLTexture> bb)
{
    if (s_kept && ([s_kept width] != [bb width] || [s_kept height] != [bb height])) {
        [s_kept release];
        s_kept = nil;
    }
    if (!s_kept)
        s_kept = make_texture((UINT)[bb width], (UINT)[bb height], 1, 1, [bb pixelFormat],
                              MTLTextureUsageShaderRead, 0);
    if (s_kept)
        [blit_encoder_for(BRK_PRESENT) copyFromTexture:bb toTexture:s_kept];
}

/* One wait per guest flip; tick/movie presentation passes no pacing state. */
typedef struct FlipPacing {
    int done;
    int64_t ticks;
} FlipPacing;

static void pace_vblank(void);

static int pace_after_present(void)
{
    static int after = -1;
    if (after < 0) {
        const char *e = getenv("RECOMP_PACE_AFTER_PRESENT");
        after = e && atoi(e) != 0;
    }
    return after;
}

static void pace_flip(FlipPacing *pacing)
{
    int64_t begin;
    if (!pacing || pacing->done) return;
    pacing->done = 1;
    begin = qpc();
    pace_vblank();
    pacing->ticks = qpc() - begin;
    if (s_prof_on > 0) s_prof[PROF_PACE] += pacing->ticks;
}

/* The kept image presented again; 0 if there is none to show. */
static int present_kept(void)
{
    id<CAMetalDrawable> dr;
    if (!s_kept || !ensure_swapchain()) return 0;
    if ([s_kept width] != s_swap_w || [s_kept height] != s_swap_h) return 0;  /* resized since */
    dr = [s_layer nextDrawable];
    if (!dr) return 0;
    [blit_encoder_for(BRK_PRESENT) copyFromTexture:s_kept toTexture:[dr texture]];
    capture_backbuffer([dr texture]);
    [cmd() presentDrawable:dr];
    submit(0);
    s_last_present = GetTickCount();
    return 1;
}

/* The last HIST_FRAMES game images (the guest surface each flip showed, at
 * half the internal resolution: 48 frames, 0.8 s at 60 Hz, covers the time
 * it takes to notice a flash and press the key), so a glitch too brief to
 * describe can be looked at:
 * nv2a_metal_save_recent_frames (Graphics > Save Recent Frames) writes them
 * as BMPs, oldest first, to ~/Library/Logs/Midtown Madness 3 Frames/<time>/. */
#define HIST_FRAMES 48
static id<MTLTexture> s_hist[HIST_FRAMES];
static uint32_t s_hist_frame[HIST_FRAMES];
static int s_hist_next;
static _Atomic int s_hist_save;

void nv2a_metal_save_recent_frames(void)
{
    atomic_store(&s_hist_save, 1);
}

static void history_keep(Surface *s)
{
    id<MTLTexture> t = s_hist[s_hist_next];
    UINT w = (s->iw + 1) / 2, h = (s->ih + 1) / 2;
    if (!t || [t width] != w || [t height] != h) {
        [t release];
        t = s_hist[s_hist_next] = make_texture(w, h, 1, 1, PIX_BGRA, USAGE_RT, 0);
        if (!t) return;
    }
    blit_span(s->tex, nil, t, nil, w, h, -1.0f, 0, 1, 0, 1);
    s_hist_frame[s_hist_next] = s_frame;
    s_hist_next = (s_hist_next + 1) % HIST_FRAMES;
}

static void history_save(void)
{
    char dir[1024], path[1200];
    const char *home = getenv("HOME");
    time_t now = time(NULL);
    struct tm tm;
    int i, n = 0;
    if (!atomic_exchange(&s_hist_save, 0) || !home) return;
    localtime_r(&now, &tm);
    snprintf(dir, sizeof dir, "%s/Library/Logs/Midtown Madness 3 Frames", home);
    mkdir(dir, 0755);
    snprintf(dir + strlen(dir), sizeof dir - strlen(dir), "/%04d%02d%02d-%02d%02d%02d-f%u",
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec,
             s_frame);
    mkdir(dir, 0755);
    submit(1);
    for (i = 0; i < HIST_FRAMES; i++) {
        int k = (s_hist_next + i) % HIST_FRAMES;
        if (!s_hist[k]) continue;
        snprintf(path, sizeof path, "%s/%02d-frame%u.bmp", dir, n++, s_hist_frame[k]);
        write_bmp(s_hist[k], path);
    }
    fprintf(stderr, "[METAL] saved %d recent frames to %s\n", n, dir);
    fflush(stderr);
}

static void present_surface(Surface *s, FlipPacing *pacing)
{
    PresentConsts pc;
    s_last_present = GetTickCount();
    if (!s)
        return;
    RECOMP_PROFILE_BEGIN("Metal present");
    memset(&pc, 0, sizeof pc);
    prepare_overlay(&pc);
    if (getenv("RECOMP_CAPTURE_SURFACE")) {
        if (!s_cap_tex || [s_cap_tex width] != s->iw || [s_cap_tex height] != s->ih) {
            [s_cap_tex release];
            s_cap_tex = make_texture(s->iw, s->ih, 1, 1, PIX_BGRA, USAGE_RT, 0);
        }
        if (s_cap_tex) {
            composite(s_cap_tex, s->iw, s->ih, s, &pc, 0);
            capture_backbuffer(s_cap_tex);
        }
    }
    if (ensure_swapchain()) {
        id<CAMetalDrawable> dr = [s_layer nextDrawable];
        if (dr) {
            composite([dr texture], s_swap_w, s_swap_h, s, &pc, 1);
            history_keep(s);
            keep_image([dr texture]);           /* game image only */
            if (!getenv("RECOMP_CAPTURE_SURFACE"))
                capture_backbuffer([dr texture]);
            /* Composite and capture are complete; align the actual host
             * submission, without pacing tick/movie-only presentations. */
            if (pacing && !pace_after_present()) pace_flip(pacing);
            [cmd() presentDrawable:dr];
            submit(0);
            s->cpu_present_pending = 0;
            s->shown_drawn = s->drawn;
            history_save();
        }
    } else {
        submit(0);
    }
    RECOMP_PROFILE_END();
}

/* The flip completes at the display's next vertical blank, as it does on the
 * NV2A: FLIP_STALL holds the GPU until then, and the title, waiting on the
 * GPU, is paced by it. RECOMP_FPS_LIMIT=N sets the rate (default 60,
 * 0 = unpaced). The wait sleeps to within a millisecond, then spins. */
static int nv_pacing_deadline(int64_t *next, int64_t now, int64_t frequency, int limit)
{
    int64_t period;
    if (limit <= 0 || frequency <= 0) return 0;
    period = frequency / limit;
    if (period <= 0 || now < 0 || *next < 0 || *next > INT64_MAX - period) {
        *next = now;
        return 0;
    }
    *next += period;
    if (!*next || *next <= now) {
        *next = now;
        return 0;
    }
    return 1;
}

static void nv_pacing_wait(int64_t deadline)
{
    int64_t now = qpc();
    if (deadline - now > 1500000) {
        int64_t sleep_ns = deadline - now - 1000000;
        struct timespec ts = { (time_t)(sleep_ns / 1000000000LL), (long)(sleep_ns % 1000000000LL) };
        nanosleep(&ts, NULL);
    }
    while (qpc() < deadline)
        ;
}

static void pace_vblank(void)
{
    static int limit = -1;
    static int64_t next;
    int64_t now;
    extern int xbox_FramebufferPaused(void);
    while (xbox_FramebufferPaused()) {   /* in the background: hold the vblank */
        usleep(50000);
        next = 0;                        /* and start a new cadence after */
    }
    if (limit < 0) {
        const char *e = getenv("RECOMP_FPS_LIMIT");
        limit = e ? atoi(e) : 60;
    }
    if (limit <= 0)
        return;
    now = qpc();
    /* A frame that ran late is shown at once and starts a new cadence;
     * waiting for the next boundary would turn every slow frame into two. */
    if (!nv_pacing_deadline(&next, now, QPC_FREQ, limit))
        return;
    RECOMP_PROFILE_BEGIN("Metal pace");
    nv_pacing_wait(next);
    RECOMP_PROFILE_END();
}

/* Internal resolution and aspect follow the window: RECOMP_RENDER_SCALE=N
 * and RECOMP_ASPECT pin them, else the window's drawable area -- the guest's
 * 480 lines become as many as the window has, at its aspect. A resize
 * applies once it has settled for RESIZE_SETTLE_MS, by dropping every host
 * surface; they are rebuilt at the new size from guest memory. A title whose
 * projection is built once per scene can ask that an aspect change wait
 * (NvOverlayHooks.hold_aspect) rather than stretch the view. */
#define RESIZE_SETTLE_MS 300

/* The resolution chosen in the host's menu (app_macos.m): N lines, or 0 to
 * follow the window. Taken by the render thread at its next frame; until
 * the first choice RECOMP_RENDER_SCALE (or the window) decides. */
static _Atomic int s_req_lines = -1;
static int s_lines_choice = -1;

void nv2a_metal_request_render_lines(int lines)
{
    atomic_store(&s_req_lines, lines < 0 ? 0 : lines);
}

/* Anti-aliasing samples and anisotropy chosen in the host's menu, applied
 * at the next frame the same way: new sample counts rebuild every host
 * surface from guest memory, a new anisotropy drops the cached samplers. */
static _Atomic int s_req_msaa = -1, s_req_aniso = -1;

void nv2a_metal_request_msaa(int samples) { atomic_store(&s_req_msaa, samples < 1 ? 1 : samples); }
void nv2a_metal_request_aniso(int n) { atomic_store(&s_req_aniso, n < 1 ? 1 : n); }

static int take_quality_requests(void)
{
    int rebuild = 0, m = atomic_exchange(&s_req_msaa, -1), a = atomic_exchange(&s_req_aniso, -1);
    if (m > 0) {
        NSUInteger n = (NSUInteger)(m > 8 ? 8 : m);
        for (; n > 1; n /= 2)
            if ([s_dev supportsTextureSampleCount:n]) break;
        if (n != s_msaa) {
            s_msaa = n;
            rebuild = 1;
            fprintf(stderr, "[METAL] anti-aliasing %lux\n", (unsigned long)s_msaa);
        }
    }
    if (a > 0 && (NSUInteger)(a > 16 ? 16 : a) != s_aniso) {
        int i;
        s_aniso = (NSUInteger)(a > 16 ? 16 : a);
        for (i = 0; i < STATE_SLOTS; i++) {
            [(id)s_samp_cache[i].obj release];
            s_samp_cache[i].obj = NULL;
        }
        fprintf(stderr, "[METAL] anisotropic filtering %lux\n", (unsigned long)s_aniso);
    }
    return rebuild;
}

static void display_config(int now)
{
    static UINT seen_w, seen_h, done_w, done_h;
    static DWORD seen_at;
    const char *e = getenv("RECOMP_RENDER_SCALE");
    float scale, aspect = env_aspect();
    UINT w, h;
    int i, deferred, req = atomic_exchange(&s_req_lines, -1), forced = 0, rebuild = 0;
    if (req >= 0 && req != s_lines_choice) { s_lines_choice = req; forced = 1; }
    if (!now && take_quality_requests()) forced = rebuild = 1;
    if (s_lines_choice >= 0) e = NULL;
    if (!client_size(&w, &h)) {
        if (!now) return;
        w = (UINT)(GUEST_H * nv2a_d3d_display_aspect()); h = GUEST_H;
    }
    if (!now && !forced) {
        if (w != seen_w || h != seen_h) { seen_w = w; seen_h = h; seen_at = GetTickCount(); return; }
        if ((w == done_w && h == done_h) || GetTickCount() - seen_at < RESIZE_SETTLE_MS) return;
    }
    if (!aspect) aspect = clamp_aspect((float)w / (float)h);
    deferred = !now && s_aspect && fabsf(aspect - s_aspect) > 1e-4f &&
               s_overlay.hold_aspect && s_overlay.hold_aspect();
    if (deferred) aspect = s_aspect;             /* retried every flip */
    if (s_lines_choice > 0) {
        scale = (float)s_lines_choice / (float)GUEST_H;
    } else if (e && atof(e) >= 0.5 && atof(e) <= 8.0) {
        scale = (float)atof(e);
    } else {
        /* RECOMP_SUPERSAMPLE=N (1..4) renders N x N host pixels per window
         * pixel; presentation's bilinear minification averages them back. A
         * Retina drawable already has twice the points' pixels, so the
         * default here is 1. */
        const char *ss = getenv("RECOMP_SUPERSAMPLE");
        int n = ss ? atoi(ss) : 1;
        float fit_h = (float)h < (float)w / aspect ? (float)h : (float)w / aspect;
        if (n < 1) n = 1;
        if (n > 4) n = 4;
        scale = fit_h / (float)GUEST_H * (float)n;
        if (scale < 1.0f) scale = 1.0f;
        if (scale > 8.0f) scale = 8.0f;
    }
    if (!deferred) { done_w = w; done_h = h; }
    if (!now && !rebuild && fabsf(scale - s_scale) < 1e-3f && fabsf(aspect - s_aspect) < 1e-4f)
        return;
    if (!now) {
        unbind_targets();
        for (i = 0; i < MAX_SURFACES; i++)
            if (s_surf[i].tex) surface_release(&s_surf[i]);
        for (i = 0; i < MAX_DEPTHS; i++)
            depth_release(&s_depth[i]);
        s_shown = NULL;
    }
    s_scale = scale;
    s_aspect = aspect;
    fprintf(stderr, "[METAL] rendering %ux%u (window %ux%u, aspect %.3f)\n",
            (uint32_t)(GUEST_W * s_scale * widen() + 0.5f), (uint32_t)(GUEST_H * s_scale + 0.5f),
            w, h, aspect);
    fflush(stderr);
}

/* A display buffer read from guest memory: the surface at that address,
 * brought up to date with whatever the CPU wrote there. */
static Surface *scan_surface(uint32_t va, uint32_t pitch)
{
    uint32_t bpp = pitch >= 640 * 4 ? 4 : 2;
    uint32_t w = pitch / bpp, h = 480;
    Surface *s = surface_find(phys(va));
    if (w > 640) w = 640;
    if (!s || s->pitch != pitch)
        s = surface_get(va, pitch, bpp == 4 ? 0x5 : 0x3, w, h, 0);
    if (s) surface_sync(s, 1);
    return s;
}

void nv2a_d3d_flip(uint32_t surface_addr, uint32_t pitch)
{
    Surface *s;
    FlipPacing pacing = { 0 };
    if (!nv2a_d3d_init())
        return;
    @autoreleasepool {
        if (s_overlay.frame) s_overlay.frame();
        if (s_mr_frame_n || s_mr_shown_n) {
            pthread_rwlock_wrlock(&s_mr_lock);
            memcpy(s_mr_shown, s_mr_frame, (size_t)s_mr_frame_n * sizeof *s_mr_frame);
            s_mr_shown_n = s_mr_frame_n;
            pthread_rwlock_unlock(&s_mr_lock);
            s_mr_frame_n = 0;
        }
        s_depth_hazed = 0;
        s = surface_find(phys(surface_addr));
        if (!s && pitch)
            s = scan_surface(surface_addr, pitch);
        s_shown = s;
        s_last_flip = GetTickCount();
        {
            int64_t t0 = s_prof_on > 0 ? qpc() : 0, t1;
            writeback_surfaces();
            t1 = s_prof_on > 0 ? qpc() : 0;
            present_surface(s, &pacing);
            if (s_prof_on > 0) {
                s_prof[PROF_WRITEBACK] += t1 - t0;
                s_prof[PROF_PRESENT] += qpc() - t1 - pacing.ticks;
            }
        }
        /* A missing surface or drawable still completes exactly one paced
         * guest flip. */
        pace_flip(&pacing);
        RECOMP_PROFILE_FRAME();
        prof_report();
        pass_log_frame();
        exp_poll();
        archive_save_maybe();
        if (!(s_frame % 600) && getenv("RECOMP_SPEC_DUMP")) spec_dump();
        display_config(0);
        texpack_apply_toggle();
        s_frame++;
    }
}

void nv2a_metal_pass_log_flush(void)
{
    submit(1);
    stamp_report();
}

/* The last flipped frame shown again, paced like a flip: for a title that
 * has nothing new to draw this frame (MM3's console-rate mod between world
 * updates). Asked from the title's thread, done on this one, which owns the
 * device; the asker waits for it as it would for a flip. */
static _Atomic int s_repeat;

void nv2a_d3d_repeat_frame(void)
{
    if (!s_shown)
        return;
    atomic_store(&s_repeat, 1);
    while (atomic_load(&s_repeat))
        sched_yield();
}

void nv2a_d3d_tick(void)
{
    DWORD now;
    uint32_t va, pitch;
    /* CPU scanout and PVIDEO can precede the first pushbuffer flip. */
    if (s_init_state <= 0 && !nv2a_d3d_init())
        return;
    @autoreleasepool {
        if (atomic_load(&s_repeat)) {
            if (!present_kept())
                present_surface(s_shown, NULL);
            pace_vblank();
            s_frame++;
            atomic_store(&s_repeat, 0);
            return;
        }
        now = GetTickCount();
        if (now - s_last_present < 16)
            return;
        /* A stop in flipping after the title has started, with no movie, is a
         * load: the frame gets a turning arc so it does not look hung. With
         * RECOMP_LOADING_SPINNER=0 it stays still, as on the console. */
        static int spinner = -1;
        XboxOverlay ovl;
        if (spinner < 0)
            spinner = !getenv("RECOMP_LOADING_SPINNER") || atoi(getenv("RECOMP_LOADING_SPINNER")) != 0;
        int movie = xbox_FramebufferOverlay(&ovl);
        s_loading = spinner && !movie && s_last_flip && now - s_last_flip > 700
                  ? 1.0f + (float)(now % 1000) / 1000.0f : 0.0f;
        if (xbox_FramebufferScanSource(&va, &pitch)) {
            Surface *s = scan_surface(va, pitch);
            present_surface(s, NULL);
            s_loading = 0.0f;
            s_frame++;
            return;
        }
        /* No flip for a while: say once what the display is left showing. */
        {
            static DWORD noted;
            if (s_last_flip && now - s_last_flip > 1000 && noted != s_last_flip) {
                noted = s_last_flip;
                uint32_t sva = 0, spitch = 0;
                xbox_FramebufferScanSource(&sva, &spitch);
                fprintf(stderr, "[METAL] no flip for 1 s: shown %08X drawn %u/%u scan %08X loading %.2f\n",
                        s_shown ? s_shown->va : 0, s_shown ? s_shown->drawn : 0,
                        s_shown ? s_shown->shown_drawn : 0, sva, s_loading);
                fflush(stderr);
            }
        }
        /* A title can keep drawing the displayed buffer with the CPU after its
         * last GPU flip, without another AvSetDisplayMode -- or with the GPU:
         * the CRTC scans the front buffer out, so what is drawn into it shows
         * (MM3 draws its briefing that way and waits for A without a flip). */
        if (s_shown && now - s_last_flip > 50) {
            uint32_t generation = s_shown->gen;
            /* Do not commit a new shadow while an older GPU readback is pending:
             * readback uses that shadow to identify and preserve later CPU writes. */
            if (!s_wb_pending)
                surface_sync(s_shown, 1);
            if (s_shown->gen != generation)
                s_shown->cpu_present_pending = 1;
            if (s_shown->drawn != s_shown->shown_drawn) {
                static int told;
                if (!told++) {
                    fprintf(stderr, "[METAL] showing GPU drawing into the displayed buffer (no flip)\n");
                    fflush(stderr);
                }
                s_shown->cpu_present_pending = 1;
            }
            if (s_shown->cpu_present_pending || movie ||
                (s_loading > 0.0f && now - s_last_present >= 33))
                present_surface(s_shown, NULL);
            else
                s_last_present = now;
        }
        s_loading = 0.0f;
    }
}
