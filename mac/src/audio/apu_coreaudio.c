/*
 * apu_coreaudio.c -- the APU's audio output on macOS (the xa2_* interface of
 * xboxrecomp's apu/apu_xaudio2.h, there backed by XAudio2).
 *
 * The APU thread submits each mixed frame (256 stereo samples at 48 kHz,
 * 5.33 ms); an output AudioUnit pulls from a lock-free single-producer ring.
 * The semantics are XAudio2's as the APU relies on them: a submission is
 * refused (0) while 64 frames' worth (341 ms) is queued, which is what paces
 * the APU when it runs ahead; after running dry a cushion of silence is
 * queued in front, so one gap absorbs the next few scheduler hitches instead
 * of each one clicking; and output is silent while the game is paused in the
 * background.
 *
 * The device never holds up the game. Opening it can block for seconds when
 * it is unavailable (a display's speakers while the display sleeps take
 * about six to fail), so every open, retry and restart runs on a private
 * serial queue. Until a unit is running -- and whenever a running one stops
 * pulling, as when its device goes away mid-game -- the APU thread drains the
 * ring at the real-time rate itself, so the title is paced as if it were
 * heard, and the queue retries every two seconds. Either consumer advances
 * the tail by compare-and-swap, so the handover between them is safe.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "apu_xaudio2.h"

#define CA_SAMPLE_RATE   48000
#define CA_CHANNELS      2
#define CA_BUF_SAMPLES   1024             /* largest single submission */
#define CA_QUEUE_LIMIT   (64 * 256)       /* frames: 341 ms, XAudio2's 64 buffers */
#define CA_CUSHION       8                /* submissions of silence after running dry */
#define CA_RING_FRAMES   32768            /* power of two, above the limit */
#define CA_RETRY_NS      2000000000ull    /* between attempts to open the device */
#define CA_STALL_NS      750000000ull     /* a running unit silent this long has lost its device */

static int16_t s_ring[CA_RING_FRAMES][CA_CHANNELS];
static _Atomic uint32_t s_head;           /* written by the APU thread */
static _Atomic uint32_t s_tail;           /* advanced by whichever consumer runs */
static _Atomic int s_running;             /* a unit is started and pulling */
static _Atomic uint64_t s_last_pull_ns;   /* the render callback's last call */
static _Atomic int s_muted;
static _Atomic uint32_t s_underruns;
static int s_initialized;
static int s_frames_written;
static FILE *s_pcm_dump;
static uint64_t s_clock_ns;               /* APU thread: the drain clock */

/* Owned by s_queue. */
static dispatch_queue_t s_queue;
static AudioComponentInstance s_unit;
static int s_opening;                     /* an attempt is scheduled or running */
static int s_reported;                    /* the failure was logged */

static uint64_t now_ns(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

/* Take up to `want` frames from the tail; how many were taken. */
static uint32_t consume(uint32_t want, int16_t *out)
{
    uint32_t tail = atomic_load_explicit(&s_tail, memory_order_acquire), head, n, i;
    for (;;) {
        head = atomic_load_explicit(&s_head, memory_order_acquire);
        n = want < head - tail ? want : head - tail;
        if (out)
            for (i = 0; i < n; i++) {
                const int16_t *f = s_ring[(tail + i) & (CA_RING_FRAMES - 1)];
                out[2 * i] = f[0];
                out[2 * i + 1] = f[1];
            }
        if (atomic_compare_exchange_weak_explicit(&s_tail, &tail, tail + n,
                                                  memory_order_acq_rel, memory_order_acquire))
            return n;
    }
}

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                       UInt32 bus, UInt32 frames, AudioBufferList *io)
{
    int16_t *out = (int16_t *)io->mBuffers[0].mData;
    uint32_t queued = atomic_load_explicit(&s_head, memory_order_acquire) -
                      atomic_load_explicit(&s_tail, memory_order_relaxed);
    uint32_t n = consume(frames, out);
    (void)ref; (void)flags; (void)ts; (void)bus;
    atomic_store_explicit(&s_last_pull_ns, now_ns(), memory_order_relaxed);
    if (n < frames) {
        memset(out + 2 * n, 0, (size_t)(frames - n) * CA_CHANNELS * sizeof(int16_t));
        if (queued) atomic_fetch_add(&s_underruns, 1);
    }
    if (atomic_load_explicit(&s_muted, memory_order_relaxed))
        memset(out, 0, (size_t)frames * CA_CHANNELS * sizeof(int16_t));
    return noErr;
}

static void close_output(void)
{
    if (!s_unit) return;
    AudioOutputUnitStop(s_unit);
    AudioUnitUninitialize(s_unit);
    AudioComponentInstanceDispose(s_unit);
    s_unit = NULL;
}

/* The default output unit, started; 0 when it cannot be. On s_queue. */
static int open_output(void)
{
    AudioComponentDescription desc = { kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
                                       kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp;
    AudioStreamBasicDescription fmt;
    AURenderCallbackStruct cb = { render, NULL };
    OSStatus st;

    if (!(comp = AudioComponentFindNext(NULL, &desc)) ||
        AudioComponentInstanceNew(comp, &s_unit) != noErr) {
        s_unit = NULL;
        if (!s_reported++) fprintf(stderr, "[AUDIO] no default output unit; running silent\n");
        return 0;
    }
    memset(&fmt, 0, sizeof fmt);
    fmt.mSampleRate = CA_SAMPLE_RATE;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = CA_CHANNELS;
    fmt.mBitsPerChannel = 16;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = CA_CHANNELS * 2;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;
    st = AudioUnitSetProperty(s_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                              0, &fmt, sizeof fmt);
    if (st == noErr)
        st = AudioUnitSetProperty(s_unit, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (st == noErr) st = AudioUnitInitialize(s_unit);
    if (st == noErr) {
        atomic_store(&s_last_pull_ns, now_ns());
        st = AudioOutputUnitStart(s_unit);
    }
    if (st != noErr) {
        if (!s_reported++)
            fprintf(stderr, "[AUDIO] output device unavailable (%d); running silent, will retry\n",
                    (int)st);
        AudioUnitUninitialize(s_unit);
        AudioComponentInstanceDispose(s_unit);
        s_unit = NULL;
        return 0;
    }
    return 1;
}

/* One attempt; on failure the next is scheduled. On s_queue. */
static void attempt(void *unused)
{
    (void)unused;
    if (!s_initialized) { s_opening = 0; return; }
    close_output();
    if (open_output()) {
        atomic_store(&s_last_pull_ns, now_ns());
        atomic_store(&s_running, 1);
        if (s_reported) fprintf(stderr, "[AUDIO] output device available; sound on\n");
        s_reported = 0;
        s_opening = 0;
    } else {
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)CA_RETRY_NS), s_queue,
                         NULL, attempt);
    }
}

static void request_open(void *unused)
{
    (void)unused;
    if (s_opening) return;
    s_opening = 1;
    attempt(NULL);
}

int xa2_init(void)
{
    if (s_initialized) return 1;
    if (!s_queue) s_queue = dispatch_queue_create("mm3.audio-device", DISPATCH_QUEUE_SERIAL);
    atomic_store(&s_head, 0);
    atomic_store(&s_tail, 0);
    atomic_store(&s_running, 0);
    s_frames_written = 0;
    s_clock_ns = now_ns();
    s_initialized = 1;
    {
        const char *path = getenv("RECOMP_XA2_PCM_DUMP");
        if (path && *path) {
            s_pcm_dump = fopen(path, "wb");
            fprintf(stderr, "[AUDIO] PCM capture %s: %s (s16le stereo 48000 Hz)\n",
                    s_pcm_dump ? "opened" : "failed", path);
        }
    }
    dispatch_async_f(s_queue, NULL, request_open);
    fprintf(stderr, "[AUDIO] Core Audio output (%d Hz stereo 16-bit, %d ms queue)\n",
            CA_SAMPLE_RATE, CA_QUEUE_LIMIT * 1000 / CA_SAMPLE_RATE);
    return 1;
}

static void shutdown_output(void *unused)
{
    (void)unused;
    close_output();
}

void xa2_shutdown(void)
{
    if (s_pcm_dump) {
        fclose(s_pcm_dump);
        s_pcm_dump = NULL;
    }
    if (s_initialized) {
        s_initialized = 0;
        atomic_store(&s_running, 0);
        dispatch_sync_f(s_queue, NULL, shutdown_output);
        fprintf(stderr, "[AUDIO] Shut down (%d frames written, %u underruns)\n",
                s_frames_written, atomic_load(&s_underruns));
    }
}

int xa2_is_active(void)
{
    return s_initialized;
}

/* No unit pulling: consume what real-time playback would have. A device
 * that ran dry plays silence and owes nothing, and neither does the clock
 * (else a stall's debt would empty the next second of audio). */
static void drain_tick(void)
{
    uint64_t now = now_ns();
    uint64_t frames = (now - s_clock_ns) * CA_SAMPLE_RATE / 1000000000ull;
    if (!frames) return;
    {
        uint32_t want = frames > CA_RING_FRAMES ? CA_RING_FRAMES : (uint32_t)frames;
        uint32_t n = consume(want, NULL);
        s_clock_ns = n < frames ? now : s_clock_ns + frames * 1000000000ull / CA_SAMPLE_RATE;
    }
}

static void push(const int16_t *samples, uint32_t n)
{
    uint32_t head = atomic_load_explicit(&s_head, memory_order_relaxed), i;
    for (i = 0; i < n; i++) {
        int16_t *f = s_ring[(head + i) & (CA_RING_FRAMES - 1)];
        if (samples) { f[0] = samples[2 * i]; f[1] = samples[2 * i + 1]; }
        else f[0] = f[1] = 0;
    }
    atomic_store_explicit(&s_head, head + n, memory_order_release);
}

/* 1 = accepted, 0 = queue full (retry), -1 = failure. */
int xa2_submit_samples(const int16_t *samples, int num_samples)
{
    uint32_t queued;
    int running;
    if (!samples || num_samples <= 0 || num_samples > CA_BUF_SAMPLES) return -1;
    if (!s_initialized) return -1;
    {   /* Paused in the background: quiet, not a held note. */
        extern int xbox_FramebufferPaused(void);
        atomic_store_explicit(&s_muted, xbox_FramebufferPaused(), memory_order_relaxed);
    }
    running = atomic_load_explicit(&s_running, memory_order_acquire);
    if (running && now_ns() - atomic_load_explicit(&s_last_pull_ns, memory_order_relaxed) > CA_STALL_NS) {
        /* The unit stopped pulling: its device went away. Drain from here
         * and reopen in the background (the default output may now be
         * another device, or this one once it wakes). */
        atomic_store(&s_running, 0);
        running = 0;
        s_clock_ns = now_ns();
        fprintf(stderr, "[AUDIO] output stalled; running silent, reopening\n");
        dispatch_async_f(s_queue, NULL, request_open);
    }
    if (!running) drain_tick();
    queued = atomic_load_explicit(&s_head, memory_order_relaxed) -
             atomic_load_explicit(&s_tail, memory_order_acquire);
    if (queued + (uint32_t)num_samples > CA_QUEUE_LIMIT) return 0;
    if (queued == 0 && running) {
        if (s_frames_written)
            fprintf(stderr, "[AUDIO] underrun after %d buffers\n", s_frames_written);
        push(NULL, (uint32_t)num_samples * CA_CUSHION);
    }
    push(samples, (uint32_t)num_samples);
    if (s_pcm_dump) {
        fwrite(samples, 1, (size_t)num_samples * CA_CHANNELS * sizeof(int16_t), s_pcm_dump);
        fflush(s_pcm_dump);
    }
    s_frames_written++;
    return 1;
}

int xa2_get_buffer_size(void)
{
    return CA_BUF_SAMPLES;
}
