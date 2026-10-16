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
 * new speed starts a short effect at that intensity, renewed while the
 * motor stays on. Each pad's state is sampled on its own handler
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
    int failed[2];
    /* Requested by XInputSetState (any thread), under s_lock: */
    float want[2];
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

/* ---- rumble (all on the main queue) */

static void motor_stop(Pad *p, int m)
{
    if (p->player[m]) {
        [p->player[m] stopAtTime:CHHapticTimeImmediate error:nil];
        [p->player[m] release];
        p->player[m] = nil;
    }
    if (p->engine[m]) {
        [p->engine[m] stopWithCompletionHandler:nil];
        [p->engine[m] release];
        p->engine[m] = nil;
    }
    p->playing[m] = 0;
}

#define RUMBLE_SPAN 1.0              /* seconds each effect lasts */
#define RUMBLE_RENEW_NS 800000000ull  /* restarted before it runs out */

static int motor_engine(Pad *p, int m)
{
    GCDeviceHaptics *h = p->controller.haptics;
    GCHapticsLocality loc = m ? GCHapticsLocalityRightHandle : GCHapticsLocalityLeftHandle;
    NSError *err = nil;
    if (p->engine[m]) return 1;
    if (!h || p->failed[m]) return 0;
    if (![h.supportedLocalities containsObject:loc]) loc = GCHapticsLocalityDefault;
    p->engine[m] = [[h createEngineWithLocality:loc] retain];
    if (p->engine[m] && [p->engine[m] startAndReturnError:&err]) return 1;
    fprintf(stderr, "[PAD] rumble unavailable on this controller (%s)\n",
            err ? [[err localizedDescription] UTF8String] : "no haptics");
    p->failed[m] = 1;
    [p->engine[m] release];
    p->engine[m] = nil;
    return 0;
}

/* Motor m at intensity v (0..1) for the next RUMBLE_SPAN. */
static void motor_play(Pad *p, int m, float v)
{
    CHHapticEventParameter *sharp, *level;
    CHHapticEvent *ev;
    CHHapticPattern *pat;
    id<CHHapticPatternPlayer> pl;
    NSError *err = nil;
    if (!motor_engine(p, m)) return;
    level = [[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                           value:v] autorelease];
    /* Low-frequency motor soft, high-frequency one sharp. */
    sharp = [[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                           value:m ? 0.9f : 0.15f] autorelease];
    ev = [[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                        parameters:@[ level, sharp ] relativeTime:0
                                          duration:RUMBLE_SPAN] autorelease];
    pat = [[[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&err] autorelease];
    pl = pat ? [p->engine[m] createPlayerWithPattern:pat error:&err] : nil;
    if (!pl || ![pl startAtTime:CHHapticTimeImmediate error:&err]) return;
    if (p->player[m]) {
        [p->player[m] stopAtTime:CHHapticTimeImmediate error:nil];
        [p->player[m] release];
    }
    p->player[m] = [pl retain];
    p->playing[m] = v;
}

static void motor_set(Pad *p, int m, float v)
{
    if (v <= 0.0f) {
        if (p->player[m]) {
            [p->player[m] stopAtTime:CHHapticTimeImmediate error:nil];
            [p->player[m] release];
            p->player[m] = nil;
        }
        p->playing[m] = 0;
        return;
    }
    if (p->player[m] && fabsf(v - p->playing[m]) < 0.01f) return;
    motor_play(p, m, v);
}

/* While any motor runs, its effect is restarted before it ends. One timer
 * at a time (main queue). */
static int s_renewing;

static void rumble_renew(void *unused)
{
    int i, m, again = 0;
    (void)unused;
    s_renewing = 0;
    @autoreleasepool {
        for (i = 0; i < MAX_PADS; i++)
            for (m = 0; m < 2; m++)
                if (s_pads[i].controller && s_pads[i].player[m]) {
                    motor_play(&s_pads[i], m, s_pads[i].playing[m]);
                    again = 1;
                }
    }
    if (again && !s_renewing) {
        s_renewing = 1;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)RUMBLE_RENEW_NS),
                         dispatch_get_main_queue(), NULL, rumble_renew);
    }
}

static void rumble_apply(int slot)
{
    Pad *p = &s_pads[slot];
    float want[2];
    os_unfair_lock_lock(&s_lock);
    want[0] = p->want[0];
    want[1] = p->want[1];
    p->scheduled = 0;
    os_unfair_lock_unlock(&s_lock);
    if (!p->controller) return;
    {
        static int told;
        if (!told && (want[0] > 0 || want[1] > 0)) {
            told = 1;
            fprintf(stderr, "[PAD] first rumble on port %d: low %.2f high %.2f\n", slot, want[0], want[1]);
        }
    }
    @autoreleasepool {
        int was = p->player[0] || p->player[1];
        motor_set(p, 0, want[0]);
        motor_set(p, 1, want[1]);
        if (!was && (p->player[0] || p->player[1]) && !s_renewing) {
            s_renewing = 1;
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)RUMBLE_RENEW_NS),
                             dispatch_get_main_queue(), NULL, rumble_renew);
        }
    }
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
