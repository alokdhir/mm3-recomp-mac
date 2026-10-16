/*
 * fb_window_macos.m -- the framebuffer window on macOS. See fb_window_macos.h.
 *
 * Mirrors the Win32 window in xboxrecomp's fb_present.c: opened when the
 * title first shows a picture and RECOMP_FB_WINDOW is set, keys remembered
 * as virtual-key codes, the pointer as a fraction of the client area, the
 * title bar showing FPS, fullscreen on F11, Cmd+F or Cmd+Return, and
 * RECOMP_PAUSE_UNFOCUSED holding the game while another app is in front.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Carbon/Carbon.h>       /* kVK_* key codes */
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#include "fb_window_macos.h"

extern float nv2a_d3d_display_aspect(void);

static void (*s_close_handler)(void);
static _Atomic int s_started;
static CAMetalLayer *_Atomic s_layer;
static _Atomic unsigned s_pix_w, s_pix_h;
static _Atomic int s_inactive;
static NSWindow *s_window;

/* Written by the main thread, read by the USB/input threads a byte at a
 * time; a press seen a frame late is indistinguishable from a later one. */
static volatile unsigned char s_key_down[256];
static volatile float s_mouse_x, s_mouse_y;
static _Atomic int s_mouse_moves;

static uint16_t s_title[48] = { 'M', 'i', 'd', 't', 'o', 'w', 'n', ' ', 'M', 'a', 'd', 'n', 'e', 's', 's', ' ', '3' };
static _Atomic long s_flips;
static _Atomic long s_frame_draws;

void xbox_FramebufferSetCloseHandler(void (*handler)(void))
{
    s_close_handler = handler;
}

/* Quit from the menu or Cmd+Q: the same as closing the window. */
void xbox_FramebufferRequestClose(void)
{
    if (s_close_handler)
        s_close_handler();
    else
        exit(0);
}

int xbox_FramebufferHostInputCaptured(void)
{
    return 0;
}

void *xbox_FramebufferMetalLayer(void)
{
    return (void *)atomic_load(&s_layer);
}

int xbox_FramebufferClientPixels(unsigned *w, unsigned *h)
{
    *w = atomic_load(&s_pix_w);
    *h = atomic_load(&s_pix_h);
    return *w && *h;
}

int xbox_FramebufferScreenSize(unsigned *w, unsigned *h)
{
    __block CGFloat sw = 0, sh = 0;
    void (^query)(void) = ^{
        NSScreen *screen = [NSScreen mainScreen];
        if (screen) {
            NSRect f = [screen frame];
            sw = f.size.width * [screen backingScaleFactor];
            sh = f.size.height * [screen backingScaleFactor];
        }
    };
    if ([NSThread isMainThread]) query();
    else dispatch_sync(dispatch_get_main_queue(), query);
    *w = (unsigned)sw;
    *h = (unsigned)sh;
    return *w && *h;
}

int xbox_FramebufferKeyDown(int vk)
{
    if ((unsigned)vk > 255)
        return 0;
    return s_key_down[vk] != 0;
}

int xbox_FramebufferMouse(float *x, float *y)
{
    *x = s_mouse_x;
    *y = s_mouse_y;
    return atomic_load(&s_mouse_moves);
}

int xbox_FramebufferPaused(void)
{
    static int on = -1;
    if (on < 0)
        on = getenv("RECOMP_PAUSE_UNFOCUSED") && atoi(getenv("RECOMP_PAUSE_UNFOCUSED")) != 0;
    return on && atomic_load(&s_inactive);
}

void xbox_FramebufferWindowSetTitle(const uint16_t *name, int max_chars)
{
    int i;
    for (i = 0; i < max_chars && i < 47 && name[i]; i++)
        s_title[i] = name[i];
    s_title[i] = 0;
}

void xbox_FramebufferNoteFlip(uint32_t draws)
{
    atomic_fetch_add(&s_flips, 1);
    atomic_store(&s_frame_draws, (long)draws);
}

void xbox_FramebufferWindowFrameStats(uint32_t draws)
{
    xbox_FramebufferNoteFlip(draws);
}

/* A macOS virtual key code as the Win32 virtual-key code for the same key;
 * 0 if it has none. */
static int vk_from_keycode(unsigned short k)
{
    switch (k) {
    case kVK_ANSI_A: return 'A'; case kVK_ANSI_B: return 'B'; case kVK_ANSI_C: return 'C';
    case kVK_ANSI_D: return 'D'; case kVK_ANSI_E: return 'E'; case kVK_ANSI_F: return 'F';
    case kVK_ANSI_G: return 'G'; case kVK_ANSI_H: return 'H'; case kVK_ANSI_I: return 'I';
    case kVK_ANSI_J: return 'J'; case kVK_ANSI_K: return 'K'; case kVK_ANSI_L: return 'L';
    case kVK_ANSI_M: return 'M'; case kVK_ANSI_N: return 'N'; case kVK_ANSI_O: return 'O';
    case kVK_ANSI_P: return 'P'; case kVK_ANSI_Q: return 'Q'; case kVK_ANSI_R: return 'R';
    case kVK_ANSI_S: return 'S'; case kVK_ANSI_T: return 'T'; case kVK_ANSI_U: return 'U';
    case kVK_ANSI_V: return 'V'; case kVK_ANSI_W: return 'W'; case kVK_ANSI_X: return 'X';
    case kVK_ANSI_Y: return 'Y'; case kVK_ANSI_Z: return 'Z';
    case kVK_ANSI_0: return '0'; case kVK_ANSI_1: return '1'; case kVK_ANSI_2: return '2';
    case kVK_ANSI_3: return '3'; case kVK_ANSI_4: return '4'; case kVK_ANSI_5: return '5';
    case kVK_ANSI_6: return '6'; case kVK_ANSI_7: return '7'; case kVK_ANSI_8: return '8';
    case kVK_ANSI_9: return '9';
    case kVK_Return: case kVK_ANSI_KeypadEnter: return 0x0D;
    case kVK_Escape: return 0x1B;
    case kVK_Space: return 0x20;
    case kVK_Tab: return 0x09;
    case kVK_Delete: return 0x08;            /* backspace */
    case kVK_ForwardDelete: return 0x2E;
    case kVK_Help: return 0x2D;              /* insert */
    case kVK_Home: return 0x24; case kVK_End: return 0x23;
    case kVK_PageUp: return 0x21; case kVK_PageDown: return 0x22;
    case kVK_LeftArrow: return 0x25; case kVK_UpArrow: return 0x26;
    case kVK_RightArrow: return 0x27; case kVK_DownArrow: return 0x28;
    case kVK_Shift: return 0xA0; case kVK_RightShift: return 0xA1;
    case kVK_Control: return 0xA2; case kVK_RightControl: return 0xA3;
    case kVK_Option: return 0xA4; case kVK_RightOption: return 0xA5;
    case kVK_Command: return 0x5B; case kVK_RightCommand: return 0x5C;
    case kVK_F1: return 0x70; case kVK_F2: return 0x71; case kVK_F3: return 0x72;
    case kVK_F4: return 0x73; case kVK_F5: return 0x74; case kVK_F6: return 0x75;
    case kVK_F7: return 0x76; case kVK_F8: return 0x77; case kVK_F9: return 0x78;
    case kVK_F10: return 0x79; case kVK_F11: return 0x7A; case kVK_F12: return 0x7B;
    case kVK_ANSI_Keypad0: return 0x60; case kVK_ANSI_Keypad1: return 0x61;
    case kVK_ANSI_Keypad2: return 0x62; case kVK_ANSI_Keypad3: return 0x63;
    case kVK_ANSI_Keypad4: return 0x64; case kVK_ANSI_Keypad5: return 0x65;
    case kVK_ANSI_Keypad6: return 0x66; case kVK_ANSI_Keypad7: return 0x67;
    case kVK_ANSI_Keypad8: return 0x68; case kVK_ANSI_Keypad9: return 0x69;
    case kVK_ANSI_KeypadMultiply: return 0x6A; case kVK_ANSI_KeypadPlus: return 0x6B;
    case kVK_ANSI_KeypadMinus: return 0x6D; case kVK_ANSI_KeypadDecimal: return 0x6E;
    case kVK_ANSI_KeypadDivide: return 0x6F;
    case kVK_ANSI_Semicolon: return 0xBA; case kVK_ANSI_Equal: return 0xBB;
    case kVK_ANSI_Comma: return 0xBC; case kVK_ANSI_Minus: return 0xBD;
    case kVK_ANSI_Period: return 0xBE; case kVK_ANSI_Slash: return 0xBF;
    case kVK_ANSI_Grave: return 0xC0; case kVK_ANSI_LeftBracket: return 0xDB;
    case kVK_ANSI_Backslash: return 0xDC; case kVK_ANSI_RightBracket: return 0xDD;
    case kVK_ANSI_Quote: return 0xDE;
    default: return 0;
    }
}

/* Side-specific modifiers also set the generic VK_SHIFT/CONTROL/MENU. */
static void set_key(int vk, int down)
{
    if (vk <= 0 || vk > 255) return;
    s_key_down[vk] = (unsigned char)(down != 0);
    if (vk == 0xA0 || vk == 0xA1) s_key_down[0x10] = s_key_down[0xA0] | s_key_down[0xA1];
    if (vk == 0xA2 || vk == 0xA3) s_key_down[0x11] = s_key_down[0xA2] | s_key_down[0xA3];
    if (vk == 0xA4 || vk == 0xA5) s_key_down[0x12] = s_key_down[0xA4] | s_key_down[0xA5];
    if (getenv("RECOMP_KEY_TRACE") && down) {
        static unsigned n;
        if (n++ < 40) fprintf(stderr, "  [KEY] down vk=0x%02X\n", (unsigned)vk);
    }
}

static void clear_keys(void)
{
    memset((void *)s_key_down, 0, sizeof s_key_down);
}

/* The keyboard as it physically is, from the window server: after a menu
 * chord the view missed the key-ups and key-downs that went to the menus,
 * and a key still held (the throttle) sends no new key-down. Without access
 * to that state every key reads up, which is the old clear. */
static void resync_keys(void)
{
    int kc;
    clear_keys();
    for (kc = 0; kc < 128; kc++) {
        int vk = vk_from_keycode((unsigned short)kc);
        if (vk > 0 && vk < 256 &&
            CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, (CGKeyCode)kc))
            set_key(vk, 1);
    }
}

/* For the host's menus: a menu action took the keyboard for a moment. */
void xbox_FramebufferReleaseKeys(void)
{
    resync_keys();
}

@interface MM3View : NSView
@end

/* The game takes no mouse input, so over the picture the pointer is
 * invisible. A cursor rect: AppKit applies it only while the window is key
 * and the pointer is inside the view, so the title bar, the menu bar (in
 * full screen too) and other apps keep the normal pointer. */
static NSCursor *blank_cursor(void)
{
    static NSCursor *c;
    if (!c) {
        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
        c = [[NSCursor alloc] initWithImage:img hotSpot:NSZeroPoint];
        [img release];
    }
    return c;
}

@implementation MM3View

- (BOOL)acceptsFirstResponder { return YES; }

- (void)resetCursorRects
{
    [self addCursorRect:[self bounds] cursor:blank_cursor()];
}
- (BOOL)wantsUpdateLayer { return YES; }

- (CALayer *)makeBackingLayer
{
    return [CAMetalLayer layer];
}

- (void)publishSize
{
    NSRect b = [self convertRectToBacking:[self bounds]];
    CAMetalLayer *layer = (CAMetalLayer *)[self layer];
    layer.contentsScale = [[self window] backingScaleFactor];
    atomic_store(&s_pix_w, (unsigned)b.size.width);
    atomic_store(&s_pix_h, (unsigned)b.size.height);
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self publishSize];
    [[self window] invalidateCursorRectsForView:self];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self publishSize];
}

- (void)keyDown:(NSEvent *)e
{
    NSEventModifierFlags m = [e modifierFlags];
    if (([e keyCode] == kVK_F11 || ([e keyCode] == kVK_Return && (m & NSEventModifierFlagCommand)) ||
         ([e keyCode] == kVK_ANSI_F && (m & NSEventModifierFlagCommand))) && ![e isARepeat]) {
        [[self window] toggleFullScreen:nil];
        return;
    }
    if (m & NSEventModifierFlagCommand) {
        /* Cmd+Q and friends belong to the menu. */
        [super keyDown:e];
        return;
    }
    set_key(vk_from_keycode([e keyCode]), 1);
}

- (void)keyUp:(NSEvent *)e
{
    set_key(vk_from_keycode([e keyCode]), 0);
}

- (void)flagsChanged:(NSEvent *)e
{
    NSEventModifierFlags m = [e modifierFlags];
    int vk = vk_from_keycode([e keyCode]), down = 0;
    switch ([e keyCode]) {
    case kVK_Shift: case kVK_RightShift: down = (m & NSEventModifierFlagShift) != 0; break;
    case kVK_Control: case kVK_RightControl: down = (m & NSEventModifierFlagControl) != 0; break;
    case kVK_Option: case kVK_RightOption: down = (m & NSEventModifierFlagOption) != 0; break;
    case kVK_Command: case kVK_RightCommand: down = (m & NSEventModifierFlagCommand) != 0; break;
    default: return;
    }
    /* Both sides held, one let go: the flag stays set; trust the key code. */
    if (down && s_key_down[vk]) down = 0;
    /* Command goes to the menus. Keys pressed or released while it is held
     * reach the menu, not this view (a ⌘⇧S save took the arrows' key-ups
     * with it and left steering dead), so start every chord from nothing. */
    if ([e keyCode] == kVK_Command || [e keyCode] == kVK_RightCommand) {
        if (down) clear_keys();
        else { resync_keys(); return; }
    }
    set_key(vk, down);
}

- (void)notePointer:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSRect b = [self bounds];
    if (b.size.width > 0 && b.size.height > 0) {
        s_mouse_x = (float)(p.x / b.size.width);
        s_mouse_y = (float)(1.0 - p.y / b.size.height);   /* top-left origin, as Win32 */
        atomic_fetch_add(&s_mouse_moves, 1);
    }
}

- (void)mouseMoved:(NSEvent *)e { [self notePointer:e]; }
- (void)mouseDragged:(NSEvent *)e { [self notePointer:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self notePointer:e]; }
- (void)mouseDown:(NSEvent *)e { s_key_down[0x01] = 1; }
- (void)mouseUp:(NSEvent *)e { s_key_down[0x01] = 0; }
- (void)rightMouseDown:(NSEvent *)e { s_key_down[0x02] = 1; }
- (void)rightMouseUp:(NSEvent *)e { s_key_down[0x02] = 0; }
- (void)otherMouseDown:(NSEvent *)e { s_key_down[0x04] = 1; }
- (void)otherMouseUp:(NSEvent *)e { s_key_down[0x04] = 0; }

@end

@interface MM3WindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation MM3WindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)w
{
    if (s_close_handler)
        s_close_handler();
    return NO;          /* the handler ends the process */
}

/* While the game has focus the display stays awake: driving with a
 * controller is not activity macOS counts, so it would otherwise dim and
 * sleep mid-race. Released when the player switches away. */
static id<NSObject> s_awake;

- (void)windowDidBecomeKey:(NSNotification *)n
{
    if (!s_awake)
        s_awake = [[[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityIdleDisplaySleepDisabled
                              reason:@"Playing Midtown Madness 3"] retain];
}

- (void)windowDidResignKey:(NSNotification *)n
{
    /* Switching away with a key held would leave it held for ever. */
    clear_keys();
    if (s_awake) {
        [[NSProcessInfo processInfo] endActivity:s_awake];
        [s_awake release];
        s_awake = nil;
    }
}

@end

/* The initial client size, in points: RECOMP_WINDOW_SIZE=WxH, else the
 * display aspect at about two thirds of the visible screen's height. */
static NSSize initial_size(void)
{
    const char *e = getenv("RECOMP_WINDOW_SIZE");
    NSRect vis = [[NSScreen mainScreen] visibleFrame];
    int w, h;
    float aspect = nv2a_d3d_display_aspect();
    if (e && sscanf(e, "%dx%d", &w, &h) == 2 && w >= 64 && h >= 48)
        return NSMakeSize(w, h);
    h = (int)(vis.size.height * 2 / 3);
    w = (int)(h * aspect + 0.5f);
    if (w > vis.size.width) {
        w = (int)vis.size.width;
        h = (int)(w / aspect + 0.5f);
    }
    return NSMakeSize(w, h);
}

static void update_title(void)
{
    static long f0;
    static CFAbsoluteTime t0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    long f = atomic_load(&s_flips);
    int n = 0;
    NSString *name, *title;
    while (n < 47 && s_title[n]) n++;
    name = [NSString stringWithCharacters:(const unichar *)s_title length:(NSUInteger)n];
    title = [NSString stringWithFormat:@"%@ | FPS: %.1f | draws: %ld", name,
             t0 ? (f - f0) / (now - t0) : 0.0, atomic_load(&s_frame_draws)];
    [s_window setTitle:title];
    t0 = now;
    f0 = f;
}

static void open_window(void)
{
    MM3WindowDelegate *delegate = [[MM3WindowDelegate alloc] init];
    NSSize size = initial_size();
    MM3View *view;
    s_window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                             backing:NSBackingStoreBuffered defer:NO];
    [s_window setDelegate:delegate];
    [s_window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [s_window setAcceptsMouseMovedEvents:YES];
    [s_window setContentMinSize:NSMakeSize(320, 240)];
    view = [[MM3View alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    [view setWantsLayer:YES];
    [s_window setContentView:view];
    [view publishSize];
    atomic_store(&s_layer, (CAMetalLayer *)[view layer]);
    [s_window center];
    [s_window makeKeyAndOrderFront:nil];
    [s_window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
    if (getenv("RECOMP_FULLSCREEN"))
        [s_window toggleFullScreen:nil];
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { update_title(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidResignActiveNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { atomic_store(&s_inactive, 1); clear_keys(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { atomic_store(&s_inactive, 0); }];
    fprintf(stderr, "  [FBWIN] framebuffer window open (%.0fx%.0f points)\n", size.width, size.height);
}

void xbox_FramebufferWindowStart(void)
{
    int expected = 0;
    if (!getenv("RECOMP_FB_WINDOW"))
        return;
    if (!atomic_compare_exchange_strong(&s_started, &expected, 1))
        return;
    if ([NSThread isMainThread]) open_window();
    else dispatch_async(dispatch_get_main_queue(), ^{ open_window(); });
}
