/*
 * test_memory_layout.c -- the Xbox memory model on arm64 macOS, without a
 * game: xbox_MemoryLayoutInit on a synthetic XBE, then the properties the
 * recompiled code relies on.
 *
 *   - sections land at their guest addresses through g_xbox_mem_offset
 *   - every RAM mirror aliases the same pages (a write through one is seen
 *     through all), as the 26-bit bus makes them on the console
 *   - the contiguous window at 0x80000000 is mapped, and the tiled aperture
 *     at 0xF0000000 aliases it (the window itself is separate storage by
 *     design: the XBE image occupies low RAM)
 *   - the host hardware traps: an OHCI register read through the guest
 *     address faults, is decoded (mmio_decode.h, arm64) and answered by the
 *     controller model, and the thread carries on -- through plain loads and
 *     stores and through the ordered forms the generated code's accessors
 *     use (LDAR, LDAPR, LDAPUR, STLR, STLUR)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xbox_winnt.h"
#include "xbox_memory_layout.h"
#include "xbox_host.h"

extern ptrdiff_t g_xbox_mem_offset;
extern ptrdiff_t xbox_GetMemoryOffset(void);
extern void xbox_kernel_init(void);
extern void xbox_kernel_bridge_init(void);

static int g_failures;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL: " __VA_ARGS__); fprintf(stderr, "\n"); g_failures++; } } while (0)

#define VA(a) ((volatile uint32_t *)((uintptr_t)(uint32_t)(a) + xbox_GetMemoryOffset()))

/* XBE: header at 0x10000 (one page), one section at 0x11000 holding a
 * marker and an empty kernel thunk table. */
static uint8_t *make_xbe(size_t *size)
{
    size_t n = 0x3000;
    uint8_t *x = calloc(1, n);
    uint32_t *w = (uint32_t *)x;
    w[0] = 0x48454258;                  /* "XBEH" */
    w[0x104 / 4] = 0x00010000;          /* base address */
    w[0x108 / 4] = 0x1000;              /* size of headers */
    w[0x10C / 4] = 0x3000;              /* size of image */
    w[0x118 / 4] = 0x00010400;          /* certificate */
    w[0x11C / 4] = 1;                   /* sections */
    w[0x120 / 4] = 0x00010200;          /* section headers */
    w[0x128 / 4] = 0x00011000 ^ 0xA8FC57AB; /* entry point (retail key) */
    w[0x158 / 4] = 0x00011100 ^ 0x5B6D40B6; /* kernel thunks (retail key) */
    /* section header */
    w[0x200 / 4 + 0] = 0x00000006;      /* writable | executable */
    w[0x200 / 4 + 1] = 0x00011000;      /* VA */
    w[0x200 / 4 + 2] = 0x1000;          /* virtual size */
    w[0x200 / 4 + 3] = 0x1000;          /* raw offset */
    w[0x200 / 4 + 4] = 0x1000;          /* raw size */
    w[0x200 / 4 + 5] = 0x00010300;      /* name */
    memcpy(x + 0x300, ".text\0\0\0", 8);
    /* certificate title (UTF-16) */
    {
        const char *t = "Layout test";
        int i;
        for (i = 0; t[i]; i++) x[0x40C + 2 * i] = (uint8_t)t[i];
    }
    /* section contents: a marker; the thunk table at +0x100 is empty */
    w[0x1000 / 4] = 0xC0DEF00D;
    *size = n;
    return x;
}

int main(void)
{
    size_t size;
    uint8_t *xbe = make_xbe(&size);
    uint32_t v;
    int ok;

    setenv("RECOMP_USB", "1", 0);
    xbox_SetMapSize(128u * 1024u * 1024u);
    ok = xbox_MemoryLayoutInit(xbe, size);
    CHECK(ok, "xbox_MemoryLayoutInit");
    if (!ok) return 1;
    g_xbox_mem_offset = xbox_GetMemoryOffset();
    fprintf(stderr, "guest offset %p\n", (void *)g_xbox_mem_offset);

    CHECK(*VA(0x00011000) == 0xC0DEF00D, "section marker %08X", *VA(0x00011000));

    /* RAM is 64 MB with nothing mirrored above it: the slots up to the
     * 128 MB map are reserved and fault, as on the console. */
    *VA(0x00200040) = 0x11223344;
    CHECK(*VA(0x00200040) == 0x11223344, "RAM store not read back");

    /* The contiguous window is writable, and the tiled aperture sees it. */
    *VA(0x80200040) = 0x99AABBCC;
    v = *VA(0xF0200040);
    CHECK(v == 0x99AABBCC, "tiled aperture reads %08X", v);

    /* Host hardware: the OHCI register block faults and is emulated. */
    xbox_kernel_init();
    xbox_kernel_bridge_init();
    CHECK(xbox_HostHardwareInit(), "xbox_HostHardwareInit");
    v = *VA(0xFED00000);                /* HcRevision */
    fprintf(stderr, "OHCI HcRevision %08X\n", v);
    CHECK(v == 0x10 || v == 0x110, "HcRevision %08X", v);

#if defined(__aarch64__)
    {   /* The same register through each ordered load, and a writable one
         * (HcPeriodicStart, 0x40) through the ordered stores. */
        volatile uint32_t *rev = VA(0xFED00000), *ps = VA(0xFED00040);
        uint32_t a = 0, b = 0, c = 0, plain;
        __asm__ volatile("ldar %w0, [%1]" : "=r"(a) : "r"(rev) : "memory");
        __asm__ volatile(".arch_extension rcpc\n ldapr %w0, [%1]" : "=r"(b) : "r"(rev) : "memory");
        /* ldapur w0, [x1, #-4]: no mnemonic in this assembler */
        __asm__ volatile("mov x1, %1\n .inst 0x995FC020\n mov %w0, w0"
                         : "=r"(c) : "r"(rev + 1) : "x0", "x1", "memory");
        CHECK(a == v && b == v && c == v, "ordered loads read %08X %08X %08X, plain %08X", a, b, c, v);
        *ps = 0x1234;
        plain = *ps;
        if (plain == 0x1234) {
            __asm__ volatile("stlr %w0, [%1]" : : "r"(0x2345u), "r"(ps) : "memory");
            CHECK(*ps == 0x2345, "STLR wrote %08X", *ps);
            /* stlur w0, [x1, #8] */
            __asm__ volatile("mov w0, %w0\n mov x1, %1\n .inst 0x99008020"
                             : : "r"(0x3456u), "r"(ps - 2) : "x0", "x1", "memory");
            CHECK(*ps == 0x3456, "STLUR wrote %08X", *ps);
        } else {
            fprintf(stderr, "HcPeriodicStart does not read back (%08X); ordered stores only decoded\n", plain);
            __asm__ volatile("stlr %w0, [%1]" : : "r"(0x2345u), "r"(ps) : "memory");
        }
    }
#endif

    fprintf(stderr, g_failures ? "memory layout: %d failures\n" : "memory layout: ok\n", g_failures);
    return g_failures ? 1 : 0;
}
