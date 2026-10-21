/* Win32 host calls the runtime expects that the macOS build answers itself. */
#include <stddef.h>

/* The runtime's legacy PGRAPH translator (nv2a_pgraph_d3d11.c) draws through
 * a D3D8 HLE device when a title has one. MM3 renders through the pushbuffer
 * executor and the Metal backend, so there is none; the translator checks. */
struct IDirect3DDevice8;
struct IDirect3DDevice8 *xbox_GetD3DDevice(void)
{
    return NULL;
}
