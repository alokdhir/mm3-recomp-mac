/* Implementations for mac/include/mac_win32_extras.h. */
#include <mach/mach.h>
#include <mach/mach_vm.h>

#include "mac_win32_extras.h"

extern ptrdiff_t g_xbox_mem_offset;
extern size_t xbox_GetMappedSize(void);

int ReadProcessMemory(void *process, const void *address, void *buffer,
                      size_t size, size_t *read)
{
    mach_vm_size_t copied = 0;
    kern_return_t kr;
    uintptr_t a = (uintptr_t)address, ram = (uintptr_t)g_xbox_mem_offset;

    (void)process;
    /* Guest RAM stays mapped for the whole run (a guest free returns heap
     * blocks or zeroes them; it never unmaps), so a read wholly inside it
     * cannot fault and needs no trip through the kernel. MM3's object
     * passes probe it this way every frame. Hardware apertures and anything
     * else take the fault-free path. */
    if (ram && a >= ram && size <= xbox_GetMappedSize() && a - ram <= xbox_GetMappedSize() - size) {
        memcpy(buffer, address, size);
        if (read) *read = size;
        return 1;
    }
    kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(uintptr_t)address,
                                size, (mach_vm_address_t)(uintptr_t)buffer, &copied);
    if (read)
        *read = kr == KERN_SUCCESS ? (size_t)copied : 0;
    return kr == KERN_SUCCESS;
}

/* The runtime's legacy PGRAPH translator (nv2a_pgraph_d3d11.c) draws through
 * a D3D8 HLE device when a title has one. MM3 renders through the pushbuffer
 * executor and the Metal backend, so there is none; the translator checks. */
struct IDirect3DDevice8;
struct IDirect3DDevice8 *xbox_GetD3DDevice(void)
{
    return NULL;
}
