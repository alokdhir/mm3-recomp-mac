/*
 * gc_xinput.m -- XInputGetState/SetState/GetCapabilities over Apple's
 * GameController framework, for xboxrecomp's input/xinput_device.c (see
 * mac/include/xinput.h).
 *
 * Controllers take the four ports in the order they connect and keep them
 * until they disconnect. Rumble (XInputSetState) drives the pad's two handle
 * motors through Core Haptics: the left, low-frequency motor as a soft
 * continuous effect on the left grip, the right, high-frequency one as a
 * sharp one on the right, at the title's motor speed. Controller haptics take
 * plain pattern players only (an advanced player -- looping, live intensity
 * -- fails with "Couldn't communicate with a helper application"), so each
 * motor runs one long plain effect whose intensity control follows the
 * motor speed (see the rumble section). Each pad's state is sampled on its own handler
 * queue whenever an element changes and kept as a snapshot under a lock, so
 * the USB thread polling XInputGetState never touches GameController
 * objects, which are not thread-safe.
 *
 * Not windows.h: its BOOL clashes with Objective-C's; the XInput structures
 * are mirrored here with fixed-width types.
 */
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <os/lock.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

typedef struct {
    uint16_t wButtons;
    uint8_t bLeftTrigger, bRightTrigger;
    int16_t sThumbLX, sThumbLY, sThumbRX, sThumbRY;
} XiGamepad;

typedef struct {
    uint32_t dwPacketNumber;
    XiGamepad Gamepad;
} XiState;

typedef struct { uint16_t wLeftMotorSpeed, wRightMotorSpeed; } XiVibration;

typedef struct {
    uint8_t Type, SubType;
    uint16_t Flags;
    XiGamepad Gamepad;
    XiVibration Vibration;
} XiCapabilities;

#define XI_SUCCESS 0u
#define XI_NOT_CONNECTED 1167u
#define MAX_PADS 4

typedef struct {
    GCController *controller;           /* retained; nil when free */
    XiState state;
    dispatch_queue_t queue;
    /* Rumble, touched on the main queue only (Core Haptics' connection to
     * the controller service fails from a background queue: "Couldn't
     * communicate with a helper application"): */
    CHHapticEngine *engine[2];          /* left, right handle */
    id<CHHapticPatternPlayer> player[2];
    float playing[2];                   /* intensity last sent */
    uint64_t started[2];                /* when the running effect began */
    uint64_t heard[2];                  /* last asked for above zero */
    uint64_t applied;                   /* last change applied */
    int failed[2];
    /* Requested by XInputSetState (any thread), under s_lock: */
    float want[2];
    float peak[2];                      /* strongest asked for since last applied */
    int scheduled;
} Pad;

static Pad s_pads[MAX_PADS];
static os_unfair_lock s_lock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t s_once;

static int16_t axis(float v)
{
    float s = v * 32767.0f;
    if (s > 32767.0f) s = 32767.0f;
    if (s < -32768.0f) s = -32768.0f;
    return (int16_t)s;
}

static uint8_t trigger(float v)
{
    float s = v * 255.0f + 0.5f;
    return (uint8_t)(s > 255.0f ? 255.0f : s < 0.0f ? 0.0f : s);
}

/* Sample every element of pad slot's controller (on its handler queue). */
static void sample(int slot, GCExtendedGamepad *g)
{
    XiGamepad p;
    memset(&p, 0, sizeof p);
    if (g.dpad.up.pressed) p.wButtons |= 0x0001;
    if (g.dpad.down.pressed) p.wButtons |= 0x0002;
    if (g.dpad.left.pressed) p.wButtons |= 0x0004;
    if (g.dpad.right.pressed) p.wButtons |= 0x0008;
    if (g.buttonMenu.pressed) p.wButtons |= 0x0010;
    if (g.buttonOptions.pressed) p.wButtons |= 0x0020;
    if (g.leftThumbstickButton.pressed) p.wButtons |= 0x0040;
    if (g.rightThumbstickButton.pressed) p.wButtons |= 0x0080;
    if (g.leftShoulder.pressed) p.wButtons |= 0x0100;
    if (g.rightShoulder.pressed) p.wButtons |= 0x0200;
    if (g.buttonA.pressed) p.wButtons |= 0x1000;
    if (g.buttonB.pressed) p.wButtons |= 0x2000;
    if (g.buttonX.pressed) p.wButtons |= 0x4000;
    if (g.buttonY.pressed) p.wButtons |= 0x8000;
    p.bLeftTrigger = trigger(g.leftTrigger.value);
    p.bRightTrigger = trigger(g.rightTrigger.value);
    p.sThumbLX = axis(g.leftThumbstick.xAxis.value);
    p.sThumbLY = axis(g.leftThumbstick.yAxis.value);
    p.sThumbRX = axis(g.rightThumbstick.xAxis.value);
    p.sThumbRY = axis(g.rightThumbstick.yAxis.value);
    os_unfair_lock_lock(&s_lock);
    if (memcmp(&s_pads[slot].state.Gamepad, &p, sizeof p)) {
        s_pads[slot].state.Gamepad = p;
        s_pads[slot].state.dwPacketNumber++;
    }
    os_unfair_lock_unlock(&s_lock);
}

static void attach(GCController *c)
{
    int slot, i;
    if (!c.extendedGamepad) return;
    os_unfair_lock_lock(&s_lock);
    for (i = 0; i < MAX_PADS; i++)
        if (s_pads[i].controller == c) { os_unfair_lock_unlock(&s_lock); return; }
    for (slot = 0; slot < MAX_PADS && s_pads[slot].controller; slot++)
        ;
    if (slot == MAX_PADS) { os_unfair_lock_unlock(&s_lock); return; }
    s_pads[slot].controller = [c retain];
    memset(&s_pads[slot].state, 0, sizeof s_pads[slot].state);
    if (!s_pads[slot].queue)
        s_pads[slot].queue = dispatch_queue_create("mm3.pad", DISPATCH_QUEUE_SERIAL);
    os_unfair_lock_unlock(&s_lock);
    c.playerIndex = (GCControllerPlayerIndex)slot;
    c.handlerQueue = s_pads[slot].queue;
    c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *e) {
        (void)e;
        sample(slot, g);
    };
    dispatch_async(s_pads[slot].queue, ^{ sample(slot, c.extendedGamepad); });
    fprintf(stderr, "[PAD] %s on port %d\n", [[c vendorName] UTF8String] ?: "controller", slot);
}

/* ---- rumble (all on the main queue)
 *
 * Each motor plays one long effect at full scale, and the title's speed
 * changes only its intensity control (a dynamic parameter). Starting a new
 * effect per speed change -- dozens a second in a crash -- jams an Xbox pad's
 * rumble over Bluetooth until it reconnects, though every call succeeds.
 * Changes are also applied at most RUMBLE_MIN_NS apart, and a stopped motor
 * keeps its effect (at zero) for RUMBLE_IDLE_NS before it is let go. */

#define RUMBLE_SPAN 30.0                   /* seconds each effect lasts (the most allowed) */
#define RUMBLE_RENEW_AGE_NS 28000000000ull /* restarted before it runs out */
#define RUMBLE_IDLE_NS 2000000000ull       /* silent this long: stopped */
#define RUMBLE_TICK_NS 500000000ull        /* renew/idle check while any runs */
#define RUMBLE_MIN_NS 50000000ull          /* between applied changes (20/s) */

static uint64_t now_ns(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void player_drop(Pad *p, int m)
{
    if (p->player[m]) {
        [p->player[m] stopAtTime:CHHapticTimeImmediate error:nil];
        [p->player[m] release];
        p->player[m] = nil;
    }
    p->playing[m] = 0;
}

static void motor_stop(Pad *p, int m)
{
    player_drop(p, m);
    if (p->engine[m]) {
        [p->engine[m] stopWithCompletionHandler:nil];
        [p->engine[m] release];
        p->engine[m] = nil;
    }
}

static void motor_set(Pad *p, int m, float v);
static void tick_soon(void);

/* Engine e of motor m stopped (why: CHHapticEngineStoppedReason, -1 reset). */
static void motor_lost(Pad *p, int m, CHHapticEngine *e, long why)
{
    float v;
    if (p->engine[m] != e) return;
    v = p->playing[m];
    fprintf(stderr, "[PAD] rumble engine %s (%ld), restarting it\n", why < 0 ? "reset" : "stopped", why);
    motor_stop(p, m);
    if (v > 0) @autoreleasepool { motor_set(p, m, v); }
}

static int motor_engine(Pad *p, int m)
{
    GCDeviceHaptics *h = p->controller.haptics;
    GCHapticsLocality loc = m ? GCHapticsLocalityRightHandle : GCHapticsLocalityLeftHandle;
    NSError *err = nil;
    if (p->engine[m]) return 1;
    if (!h || p->failed[m]) return 0;
    if (![h.supportedLocalities containsObject:loc]) loc = GCHapticsLocalityDefault;
    p->engine[m] = [[h createEngineWithLocality:loc] retain];
    if (p->engine[m] && [p->engine[m] startAndReturnError:&err]) {
        /* The haptics service can stop or reset the engine under us (app
         * deactivated, controller service restarted); drop it so the next
         * request makes a fresh one rather than playing into a dead one. */
        CHHapticEngine *e = p->engine[m];
        e.stoppedHandler = ^(CHHapticEngineStoppedReason why) {
            dispatch_async(dispatch_get_main_queue(), ^{ motor_lost(p, m, e, (long)why); });
        };
        e.resetHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{ motor_lost(p, m, e, -1); });
        };
        return 1;
    }
    fprintf(stderr, "[PAD] rumble unavailable on this controller (%s)\n",
            err ? [[err localizedDescription] UTF8String] : "no haptics");
    p->failed[m] = 1;
    [p->engine[m] release];
    p->engine[m] = nil;
    return 0;
}

/* Motor m's running effect to intensity v (0..1). */
static BOOL motor_level(Pad *p, int m, float v, NSError **err)
{
    CHHapticDynamicParameter *d =
        [[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                         value:v relativeTime:0] autorelease];
    if (![p->player[m] sendParameters:@[ d ] atTime:CHHapticTimeImmediate error:err]) return NO;
    p->playing[m] = v;
    return YES;
}

/* A new effect for motor m at intensity v, replacing any running one; one
 * retry on a fresh engine when it will not start. */
static void motor_start(Pad *p, int m, float v, int retry)
{
    CHHapticEventParameter *sharp, *level;
    CHHapticEvent *ev;
    CHHapticPattern *pat;
    id<CHHapticPatternPlayer> pl;
    NSError *err = nil;
    if (!motor_engine(p, m)) return;
    level = [[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                           value:1.0f] autorelease];
    /* Low-frequency motor soft, high-frequency one sharp. */
    sharp = [[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                           value:m ? 0.9f : 0.15f] autorelease];
    ev = [[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                        parameters:@[ level, sharp ] relativeTime:0
                                          duration:RUMBLE_SPAN] autorelease];
    pat = [[[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&err] autorelease];
    pl = pat ? [p->engine[m] createPlayerWithPattern:pat error:&err] : nil;
    if (!pl || ![pl startAtTime:CHHapticTimeImmediate error:&err]) {
        /* Engine gone bad without telling us: start over with a new one. */
        fprintf(stderr, "[PAD] rumble effect failed (%s), restarting the engine\n",
                err ? [[err localizedDescription] UTF8String] : "?");
        motor_stop(p, m);
        if (retry) motor_start(p, m, v, 0);
        return;
    }
    player_drop(p, m);
    p->player[m] = [pl retain];
    p->started[m] = now_ns();
    if (!motor_level(p, m, v, &err))
        fprintf(stderr, "[PAD] rumble intensity not taken (%s)\n",
                err ? [[err localizedDescription] UTF8String] : "?");
    p->playing[m] = v;
    tick_soon();
}

static void motor_set(Pad *p, int m, float v)
{
    if (v < 0.0f) v = 0.0f;
    if (v > 0.0f) p->heard[m] = now_ns();
    if (p->player[m]) {
        if (fabsf(v - p->playing[m]) < 0.01f) return;
        if (motor_level(p, m, v, NULL)) return;
    }
    if (v > 0.0f) motor_start(p, m, v, 1);
}

/* While any effect runs: renew it before it ends, let it go once silent for
 * RUMBLE_IDLE_NS. One timer at a time (main queue). */
static int s_ticking;

static void rumble_tick(void *unused)
{
    int i, m, again = 0;
    uint64_t t = now_ns();
    (void)unused;
    s_ticking = 0;
    @autoreleasepool {
        for (i = 0; i < MAX_PADS; i++)
            for (m = 0; m < 2; m++) {
                Pad *p = &s_pads[i];
                if (!p->controller || !p->player[m]) continue;
                if (p->playing[m] <= 0.0f && t - p->heard[m] > RUMBLE_IDLE_NS) {
                    player_drop(p, m);
                    continue;
                }
                if (t - p->started[m] > RUMBLE_RENEW_AGE_NS)
                    motor_start(p, m, p->playing[m], 1);
                again |= p->player[m] != nil;
            }
    }
    if (again) tick_soon();
}

static void tick_soon(void)
{
    if (s_ticking) return;
    s_ticking = 1;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)RUMBLE_TICK_NS),
                     dispatch_get_main_queue(), NULL, rumble_tick);
}

static void rumble_apply_f(void *slot);

static void rumble_apply(int slot)
{
    Pad *p = &s_pads[slot];
    float want[2];
    int settle;
    uint64_t t = now_ns();
    if (t - p->applied < RUMBLE_MIN_NS) {
        /* Too soon after the last change: once more when the gap is up, with
         * the strongest the title asks for by then (still scheduled). */
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(p->applied + RUMBLE_MIN_NS - t)),
                         dispatch_get_main_queue(), (void *)(intptr_t)slot, rumble_apply_f);
        return;
    }
    p->applied = t;
    /* The peak, so a jolt shorter than the gap (a crash) is still felt; if
     * the title has since dropped below it, the drop follows one gap later. */
    os_unfair_lock_lock(&s_lock);
    want[0] = p->peak[0];
    want[1] = p->peak[1];
    p->peak[0] = p->want[0];
    p->peak[1] = p->want[1];
    settle = want[0] != p->want[0] || want[1] != p->want[1];
    p->scheduled = settle;
    os_unfair_lock_unlock(&s_lock);
    if (settle)
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)RUMBLE_MIN_NS),
                         dispatch_get_main_queue(), (void *)(intptr_t)slot, rumble_apply_f);
    if (!p->controller) return;
    {
        static int told;
        if (!told && (want[0] > 0 || want[1] > 0)) {
            told = 1;
            fprintf(stderr, "[PAD] first rumble on port %d: low %.2f high %.2f\n", slot, want[0], want[1]);
        }
    }
    @autoreleasepool {
        motor_set(p, 0, want[0]);
        motor_set(p, 1, want[1]);
    }
}

static void rumble_apply_f(void *slot)
{
    rumble_apply((int)(intptr_t)slot);
}

static void detach(GCController *c)
{
    int i;
    for (i = 0; i < MAX_PADS; i++) {
        Pad *p = &s_pads[i];
        int mine;
        os_unfair_lock_lock(&s_lock);
        mine = p->controller == c;
        os_unfair_lock_unlock(&s_lock);
        if (!mine) continue;
        /* On the main queue already (the notification), where rumble runs. */
        motor_stop(p, 0);
        motor_stop(p, 1);
        p->failed[0] = p->failed[1] = 0;
        os_unfair_lock_lock(&s_lock);
        [p->controller release];
        p->controller = nil;
        memset(&p->state, 0, sizeof p->state);
        p->want[0] = p->want[1] = 0;
        p->peak[0] = p->peak[1] = 0;
        os_unfair_lock_unlock(&s_lock);
        fprintf(stderr, "[PAD] port %d disconnected\n", i);
    }
}

static void start(void)
{
    dispatch_once(&s_once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                        usingBlock:^(NSNotification *n) { attach((GCController *)n.object); }];
            [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
                        usingBlock:^(NSNotification *n) { detach((GCController *)n.object); }];
            for (GCController *c in [GCController controllers]) attach(c);
        });
    });
}

uint32_t XInputGetState(uint32_t user, XiState *state)
{
    uint32_t r = XI_NOT_CONNECTED;
    start();
    if (user >= MAX_PADS || !state) return XI_NOT_CONNECTED;
    os_unfair_lock_lock(&s_lock);
    if (s_pads[user].controller) {
        *state = s_pads[user].state;
        r = XI_SUCCESS;
    }
    os_unfair_lock_unlock(&s_lock);
    return r;
}

/* The motor speeds, applied on the pad's queue; requests that arrive while
 * one is pending only update what it will apply. */
uint32_t XInputSetState(uint32_t user, XiVibration *vibration)
{
    uint32_t r = XI_NOT_CONNECTED;
    int schedule = 0;
    if (user >= MAX_PADS) return r;
    os_unfair_lock_lock(&s_lock);
    if (s_pads[user].controller) {
        r = XI_SUCCESS;
        if (vibration) {
            Pad *p = &s_pads[user];
            float l = vibration->wLeftMotorSpeed / 65535.0f, rt = vibration->wRightMotorSpeed / 65535.0f;
            if (l != p->want[0] || rt != p->want[1]) {
                p->want[0] = l;
                p->want[1] = rt;
                if (l > p->peak[0]) p->peak[0] = l;
                if (rt > p->peak[1]) p->peak[1] = rt;
                if (!p->scheduled) { p->scheduled = 1; schedule = 1; }
            }
        }
    }
    os_unfair_lock_unlock(&s_lock);
    if (schedule) {
        int slot = (int)user;
        dispatch_async(dispatch_get_main_queue(), ^{ rumble_apply(slot); });
    }
    return r;
}

uint32_t XInputGetCapabilities(uint32_t user, uint32_t flags, XiCapabilities *caps)
{
    uint32_t r = XInputSetState(user, NULL);
    /* (a NULL vibration only asks whether the pad is there) */
    (void)flags;
    if (r != XI_SUCCESS || !caps) return r;
    memset(caps, 0, sizeof *caps);
    caps->Type = 0x01;          /* XINPUT_DEVTYPE_GAMEPAD */
    caps->SubType = 0x01;       /* XINPUT_DEVSUBTYPE_GAMEPAD */
    caps->Gamepad.wButtons = 0xF3FF;
    caps->Gamepad.bLeftTrigger = caps->Gamepad.bRightTrigger = 255;
    return XI_SUCCESS;
}
