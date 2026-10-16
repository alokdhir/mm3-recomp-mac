/*
 * xinput.h for the macOS build: the XInput types and calls xboxrecomp's
 * input layer (input/xinput_device.c) is written against, implemented over
 * Apple's GameController framework (mac/src/input/gc_xinput.m).
 */
#ifndef MM3_MAC_XINPUT_H
#define MM3_MAC_XINPUT_H

#include "platform/xbox_winnt.h"

/* XINPUT_GAMEPAD, XINPUT_STATE, XInputGetState and the button bits come
 * from the runtime's win32_compat.h. */

#define XINPUT_DEVTYPE_GAMEPAD          0x01
#define XINPUT_DEVSUBTYPE_GAMEPAD       0x01
#define XINPUT_FLAG_GAMEPAD             0x00000001

typedef struct _XINPUT_VIBRATION {
    WORD wLeftMotorSpeed;
    WORD wRightMotorSpeed;
} XINPUT_VIBRATION, *PXINPUT_VIBRATION;

typedef struct _XINPUT_CAPABILITIES {
    BYTE Type;
    BYTE SubType;
    WORD Flags;
    XINPUT_GAMEPAD Gamepad;
    XINPUT_VIBRATION Vibration;
} XINPUT_CAPABILITIES, *PXINPUT_CAPABILITIES;

DWORD XInputSetState(DWORD user, XINPUT_VIBRATION *vibration);
DWORD XInputGetCapabilities(DWORD user, DWORD flags, XINPUT_CAPABILITIES *caps);

#endif
