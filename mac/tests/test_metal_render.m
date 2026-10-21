/*
 * test_metal_render.m -- the Metal NV2A renderer end to end, without a game.
 *
 * Opens the window, clears a 640x480 guest surface, draws one pre-transformed
 * triangle through nv2a_d3d_draw_ub (the ubershader path) and one through a
 * register-combiner configuration (the specialised path, given time to
 * build), flips, and captures the presented image as a BMP. Then checks
 * pixels: the clear colour in a corner, the triangle's colour at its centre,
 * and the guest framebuffer written back.
 */
#import <Cocoa/Cocoa.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "nv2a_d3d11.h"
#include "fb_window_macos.h"
#include "fb_present.h"

/* What the renderer takes from the rest of the runtime. */
static uint8_t *s_guest;
ptrdiff_t xbox_GetMemoryOffset(void) { return (ptrdiff_t)s_guest; }
int xbox_FramebufferOverlay(XboxOverlay *o) { (void)o; return 0; }
int xbox_FramebufferScanSource(uint32_t *va, uint32_t *pitch) { (void)va; (void)pitch; return 0; }
const uint32_t (*nv2a_vsh_program(uint32_t *start, uint32_t *version))[4] { (void)start; (void)version; return NULL; }
const float (*nv2a_vsh_constants(uint32_t *version))[4] { (void)version; return NULL; }
/* fb_present.c's window state (fb_window.h). */
volatile unsigned char fbw_key_down[256];
volatile float fbw_mouse_x, fbw_mouse_y;
volatile int32_t fbw_mouse_moves, fbw_inactive;
void (*fbw_close_handler)(void);
int fbw_title_due(uint16_t *out, size_t count) { (void)out; (void)count; return 0; }
int xbox_FramebufferPaused(void) { return 0; }
void xbox_FramebufferWindowStart(void);

static const char *s_cap;
static int s_failures;

#define FB_VA 0x00100000u

static uint32_t bmp_pixel(const char *path, int x, int y_from_top, int *w_out, int *h_out)
{
    FILE *f = fopen(path, "rb");
    uint8_t hdr[54], px[3];
    int32_t w, h;
    uint32_t row;
    if (!f) return 0xDEADBEEF;
    fread(hdr, 1, 54, f);
    memcpy(&w, hdr + 18, 4);
    memcpy(&h, hdr + 22, 4);
    *w_out = w; *h_out = h;
    row = ((uint32_t)w * 3 + 3) & ~3u;
    fseek(f, 54 + (long)(h - 1 - y_from_top) * row + x * 3, SEEK_SET);
    fread(px, 1, 3, f);
    fclose(f);
    return (uint32_t)px[2] << 16 | (uint32_t)px[1] << 8 | px[0];
}

static int near(uint32_t a, uint32_t b)
{
    int i;
    for (i = 0; i < 24; i += 8) {
        int d = (int)((a >> i) & 255) - (int)((b >> i) & 255);
        if (d < -6 || d > 6) return 0;
    }
    return 1;
}

#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL: " __VA_ARGS__); fprintf(stderr, "\n"); s_failures++; } } while (0)

static void draw_triangle(NvD3DState *st, uint32_t color, float x0, float y0)
{
    static float pos[3][4];
    static uint32_t col[3];
    NvD3DAttrib attr[16];
    float def[16][4];
    uint32_t idx[3] = { 0, 1, 2 };
    int i;
    float v[3][2] = { { x0, y0 }, { x0 + 200, y0 }, { x0 + 100, y0 + 200 } };
    memset(attr, 0, sizeof attr);
    memset(def, 0, sizeof def);
    for (i = 0; i < 3; i++) {
        pos[i][0] = v[i][0]; pos[i][1] = v[i][1]; pos[i][2] = 0.5f; pos[i][3] = 1.0f;
        col[i] = color;
    }
    attr[0].enabled = 1; attr[0].type = 2; attr[0].size = 4; attr[0].stride = 16;
    attr[0].data = (const uint8_t *)pos;
    attr[3].enabled = 1; attr[3].type = 0; attr[3].size = 4; attr[3].stride = 4;
    attr[3].data = (const uint8_t *)col;
    nv2a_d3d_draw_ub(st, NV_D3D_TRIANGLES, attr, (const float (*)[4])def, 0, idx, 3, 0, 2, NULL);
}

static void *render_thread(void *unused)
{
    NvD3DState st;
    char path[1024];
    int w, h, tries;
    uint32_t c, g;
    (void)unused;
    if (!nv2a_d3d_init()) { fprintf(stderr, "FAIL: init\n"); exit(1); }
    xbox_FramebufferWindowStart();
    for (tries = 0; tries < 200 && !xbox_FramebufferMetalLayer(); tries++) usleep(10000);
    CHECK(xbox_FramebufferMetalLayer(), "no window layer");

    memset(&st, 0, sizeof st);
    st.color_addr = FB_VA;
    st.color_pitch = 640 * 4;
    st.surface_format = 0x8 | (1u << 8);    /* A8R8G8B8, linear */
    st.clip_w = 640; st.clip_h = 480;
    st.color_mask = 0x01010101u;
    st.front_face = 0x901;

    /* Frame 1: clear, the ubershader's triangle. */
    nv2a_d3d_clear(&st, 0xF0, 0xFF203040u, 0, 0, 0, 639, 479);
    draw_triangle(&st, 0xFFFF0000u, 50, 50);
    /* The same through register combiners: final combiner D = diffuse,
     * every other input zero: out = diffuse. */
    st.rc_seen = 1;
    st.rc.control = 1;                       /* one stage, and it does nothing */
    st.rc.final0 = 0x04;                     /* D = R4 (diffuse) */
    st.rc.final1 = 0x1400;                   /* G = diffuse alpha */
    draw_triangle(&st, 0xFF00FF00u, 350, 50);
    snprintf(path, sizeof path, "%s.flag", s_cap);
    { FILE *f = fopen(path, "w"); fprintf(f, "1\n"); fclose(f); }
    nv2a_d3d_flip(FB_VA, 640 * 4);
    while (nv2a_d3d_writeback_busy()) usleep(1000);

    snprintf(path, sizeof path, "%s-000.bmp", s_cap);
    c = bmp_pixel(path, 5, 5, &w, &h);
    fprintf(stderr, "capture %dx%d corner %06X\n", w, h, c);
    CHECK(w > 0 && h > 0, "no capture");
    /* The surface sits letterboxed in the drawable; sample within it. */
    {
        float aspect = nv2a_d3d_display_aspect(), tw = (float)w, th = tw / aspect, x0 = 0, y0;
        if (th > h) { th = (float)h; tw = th * aspect; x0 = (w - tw) / 2; }
        y0 = (h - th) / 2;
        /* Guest (150, 120): inside the first triangle; (450, 120) the second;
         * (320, 400) background. 4:3 guest content is centred on a widened
         * surface. */
        {
            float narrow = (4.0f / 3.0f) / aspect, gx0 = x0 + tw * (1 - narrow) / 2, gw = tw * narrow;
            uint32_t p1 = bmp_pixel(path, (int)(gx0 + gw * 150 / 640), (int)(y0 + th * 120 / 480), &w, &h);
            uint32_t p2 = bmp_pixel(path, (int)(gx0 + gw * 450 / 640), (int)(y0 + th * 120 / 480), &w, &h);
            uint32_t p3 = bmp_pixel(path, (int)(gx0 + gw * 320 / 640), (int)(y0 + th * 400 / 480), &w, &h);
            fprintf(stderr, "uber %06X  combiner %06X  clear %06X\n", p1, p2, p3);
            CHECK(near(p1, 0xFF0000), "ubershader triangle %06X", p1);
            CHECK(near(p2, 0x00FF00), "combiner triangle %06X", p2);
            CHECK(near(p3, 0x203040), "clear colour %06X", p3);
        }
    }
    /* Write-back: guest memory holds what the GPU drew. */
    g = *(const uint32_t *)(s_guest + FB_VA + (120 * 640 + 150) * 4) & 0xFFFFFF;
    fprintf(stderr, "guest framebuffer at (150,120) %06X\n", g);
    CHECK(near(g, 0xFF0000), "write-back %06X", g);

    fprintf(stderr, s_failures ? "metal render: %d failures\n" : "metal render: ok\n", s_failures);
    exit(s_failures ? 1 : 0);
    return NULL;
}

int main(int argc, char **argv)
{
    pthread_t t;
    s_cap = argc > 1 ? argv[1] : "/tmp/metal_render";
    setenv("RECOMP_FB_WINDOW", "1", 1);
    setenv("RECOMP_PRESENT_CAPTURE", s_cap, 1);
    setenv("RECOMP_ASPECT", "16:9", 0);
    setenv("RECOMP_FPS_LIMIT", "0", 1);
    s_guest = mmap(NULL, 0x08000000u, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        pthread_create(&t, NULL, render_thread, NULL);
        [NSApp run];
    }
    return 0;
}
