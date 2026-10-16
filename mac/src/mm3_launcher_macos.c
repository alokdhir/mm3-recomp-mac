/*
 * mm3_launcher_macos.c -- the settings launcher entry for macOS.
 *
 * The Windows launcher (mm3_launcher.cpp) is an RmlUi window on Win32/D3D11
 * that saves the chosen settings and exports them, with the defaults
 * scripts\\play.ps1 also sets, as environment variables before play. Until the
 * macOS one exists, play starts directly with those defaults; anything
 * already in the environment wins.
 */
#include <stdlib.h>

static void preset(const char *name, const char *value)
{
    if (!getenv(name))
        setenv(name, value, 0);
}

int mm3_launcher(void)
{
    /* What play.ps1 and the launcher's export set: the window, the
     * pushbuffer executor, pads and audio. */
    preset("RECOMP_PB_EXEC", "1");
    preset("RECOMP_FB_WINDOW", "1");
    preset("RECOMP_USB", "1");
    preset("RECOMP_APU_DSP_ACK", "0x80458810");
    preset("RECOMP_KEYBOARD_LAYOUT", "mm3");
    preset("RECOMP_KEYBOARD", "1");
    return 1;   /* 1 = play, 0 = the user quit */
}

/* The Dear ImGui debug overlay (mods/debug_overlay.cpp) is Win32/D3D11. */
void mm3_debug_overlay_init(void)
{
}
