/*
 * fb_window_macos.h -- the game window on macOS (fb_window_macos.m).
 *
 * The window half of xboxrecomp's fb_present.c: an AppKit window whose view
 * is backed by a CAMetalLayer the renderer presents into, and the keys and
 * pointer it receives, reported as Win32 virtual-key codes because that is
 * what the input layer (xinput_device.c, usb_gamepad.c) asks for. AppKit
 * runs on the main thread (mac/src/app_macos.m); everything here that other
 * threads call is safe from any thread.
 */
#ifndef FB_WINDOW_MACOS_H
#define FB_WINDOW_MACOS_H

/* The window's CAMetalLayer, or NULL until it exists. */
void *xbox_FramebufferMetalLayer(void);
/* The drawable size in pixels; 0 while there is no window or it is hidden. */
int xbox_FramebufferClientPixels(unsigned *w, unsigned *h);
/* The main screen's size in pixels; 0 if unknown. */
int xbox_FramebufferScreenSize(unsigned *w, unsigned *h);

#endif
