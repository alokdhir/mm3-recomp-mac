/*
 * test_mmio_arm64.c -- the arm64 trapped-MMIO path end to end.
 *
 * An inaccessible page stands in for a device aperture. A vectored handler
 * (posix_veh.c) routes its faults to mmio_emulate (mmio_decode.h) against a
 * register file in plain memory, and every A64 load/store form the decoder
 * claims is executed against it from inline assembly, so the instruction
 * under test is exactly the one written.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "xbox_winnt.h"
#include "mmio_decode.h"

static uint8_t *g_page;
static uint8_t g_regs[4096];
static int g_reads, g_writes, g_failures;

static uint64_t dev_read(void *dev, uint32_t off, int size)
{
    uint64_t v = 0;
    (void)dev;
    memcpy(&v, g_regs + off, (size_t)size);
    g_reads++;
    return v;
}

static void dev_write(void *dev, uint32_t off, uint64_t val, int size)
{
    (void)dev;
    memcpy(g_regs + off, &val, (size_t)size);
    g_writes++;
}

static LONG handler(PEXCEPTION_POINTERS ep)
{
    uintptr_t fault = ep->ExceptionRecord->ExceptionInformation[1];

    if (fault < (uintptr_t)g_page || fault >= (uintptr_t)g_page + 4096)
        return EXCEPTION_CONTINUE_SEARCH;
    if (!mmio_emulate(ep->ContextRecord, (uint32_t)(fault - (uintptr_t)g_page),
                      NULL, dev_read, dev_write)) {
        fprintf(stderr, "decode failed: %08X\n", mmio_fault_insn(ep->ContextRecord));
        return EXCEPTION_CONTINUE_SEARCH;
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

#define CHECK(cond) do { if (!(cond)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    g_failures++; } } while (0)

static void seed(void)
{
    for (int i = 0; i < 4096; i++)
        g_regs[i] = (uint8_t)(0x80 + i * 7);
}

static uint64_t le(int off, int n)
{
    uint64_t v = 0;
    memcpy(&v, g_regs + off, (size_t)n);
    return v;
}

int main(void)
{
    uint8_t *p;
    uint64_t x, y;
    int write_seen;

    g_page = mmap(NULL, 4096, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (g_page == MAP_FAILED) { perror("mmap"); return 1; }
    if (!AddVectoredExceptionHandler(1, handler)) { puts("no VEH"); return 1; }
    p = g_page;
    seed();

    /* Unsigned-offset loads of every width and signedness. */
    __asm__ volatile("ldrb w0, [%1, #3]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == le(3, 1));
    __asm__ volatile("ldrh w0, [%1, #8]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == le(8, 2));
    __asm__ volatile("ldr w0, [%1, #16]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == le(16, 4));
    __asm__ volatile("ldr x0, [%1, #24]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == le(24, 8));
    __asm__ volatile("ldrsb x0, [%1, #3]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == (uint64_t)(int64_t)(int8_t)le(3, 1));
    __asm__ volatile("ldrsb w0, [%1, #3]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == (uint32_t)(int32_t)(int8_t)le(3, 1));
    __asm__ volatile("ldrsh x0, [%1, #8]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == (uint64_t)(int64_t)(int16_t)le(8, 2));
    __asm__ volatile("ldrsw x0, [%1, #16]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == (uint64_t)(int64_t)(int32_t)le(16, 4));
    /* A W load clears the upper half. */
    __asm__ volatile("mov x0, #-1\n ldr w0, [%1, #16]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == le(16, 4));

    /* Stores, including the zero register. */
    __asm__ volatile("mov w0, #0xAB\n strb w0, [%0, #40]" : : "r"(p) : "x0", "memory");
    CHECK(g_regs[40] == 0xAB);
    __asm__ volatile("mov w0, #0x1234\n strh w0, [%0, #42]" : : "r"(p) : "x0", "memory");
    CHECK(le(42, 2) == 0x1234);
    __asm__ volatile("str %w1, [%0, #44]" : : "r"(p), "r"(0xDEADBEEFu) : "memory");
    CHECK(le(44, 4) == 0xDEADBEEFu);
    __asm__ volatile("str %1, [%0, #48]" : : "r"(p), "r"(0x0123456789ABCDEFull) : "memory");
    CHECK(le(48, 8) == 0x0123456789ABCDEFull);
    __asm__ volatile("str wzr, [%0, #44]" : : "r"(p) : "memory");
    CHECK(le(44, 4) == 0);

    /* Unscaled, register-offset, pre- and post-index. */
    __asm__ volatile("ldur w0, [%1, #5]\n mov %0, x0" : "=r"(x) : "r"(p) : "x0", "memory");
    CHECK(x == le(5, 4));
    __asm__ volatile("ldr w0, [%1, %2]\n mov %0, x0" : "=r"(x) : "r"(p), "r"((uint64_t)100) : "x0", "memory");
    CHECK(x == le(100, 4));
    __asm__ volatile("ldr w0, [%1, %2, lsl #2]\n mov %0, x0" : "=r"(x) : "r"(p), "r"((uint64_t)30) : "x0", "memory");
    CHECK(x == le(120, 4));
    {
        uint8_t *b = p + 200;
        __asm__ volatile("ldr w0, [%1], #8\n mov %0, x0" : "=r"(x), "+r"(b) : : "x0", "memory");
        CHECK(x == le(200, 4) && b == p + 208);
        __asm__ volatile("ldr w0, [%1, #-4]!\n mov %0, x0" : "=r"(x), "+r"(b) : : "x0", "memory");
        CHECK(x == le(204, 4) && b == p + 204);
        __asm__ volatile("str %w1, [%0, #4]!" : "+r"(b) : "r"(0x55AA55AAu) : "memory");
        CHECK(le(208, 4) == 0x55AA55AAu && b == p + 208);
    }

    /* Pairs. */
    __asm__ volatile("ldp w0, w1, [%2, #64]\n mov %0, x0\n mov %1, x1"
                     : "=r"(x), "=r"(y) : "r"(p) : "x0", "x1", "memory");
    CHECK(x == le(64, 4) && y == le(68, 4));
    __asm__ volatile("ldp x0, x1, [%2, #80]\n mov %0, x0\n mov %1, x1"
                     : "=r"(x), "=r"(y) : "r"(p) : "x0", "x1", "memory");
    CHECK(x == le(80, 8) && y == le(88, 8));
    __asm__ volatile("ldpsw x0, x1, [%2, #64]\n mov %0, x0\n mov %1, x1"
                     : "=r"(x), "=r"(y) : "r"(p) : "x0", "x1", "memory");
    CHECK(x == (uint64_t)(int64_t)(int32_t)le(64, 4) && y == (uint64_t)(int64_t)(int32_t)le(68, 4));
    __asm__ volatile("stp %w1, %w2, [%0, #200]" : : "r"(p), "r"(0x11111111u), "r"(0x22222222u) : "memory");
    CHECK(le(200, 4) == 0x11111111u && le(204, 4) == 0x22222222u);
    {
        uint8_t *b = p + 400;
        __asm__ volatile("stp %1, %2, [%0, #-16]!" : "+r"(b) : "r"(1ull), "r"(2ull) : "memory");
        CHECK(le(384, 8) == 1 && le(392, 8) == 2 && b == p + 384);
    }

    /* Scalar FP/SIMD. */
    {
        float f;
        double d;
        uint32_t fb = 0x3F800000u;   /* 1.0f */
        uint64_t db = 0x4000000000000000ull;  /* 2.0 */
        memcpy(g_regs + 500, &fb, 4);
        memcpy(g_regs + 504, &db, 8);
        __asm__ volatile("ldr s0, [%1, #500]\n fmov %w0, s0" : "=r"(x) : "r"(p) : "v0", "memory");
        CHECK(x == fb);
        __asm__ volatile("ldr d0, [%1, #504]\n fmov %0, d0" : "=r"(x) : "r"(p) : "v0", "memory");
        CHECK(x == db);
        f = 3.0f;
        __asm__ volatile("str %s1, [%0, #512]" : : "r"(p), "w"(f) : "memory");
        CHECK(le(512, 4) == 0x40400000u);
        d = 4.0;
        __asm__ volatile("str %d1, [%0, #520]" : : "r"(p), "w"(d) : "memory");
        CHECK(le(520, 8) == 0x4010000000000000ull);
        __asm__ volatile("ldr q0, [%1, #528]\n str q0, [%1, #544]\n mov %0, #0"
                         : "=r"(x) : "r"(p) : "v0", "memory");
        CHECK(memcmp(g_regs + 528, g_regs + 544, 16) == 0);
    }

    /* Compiler-generated accesses through a volatile pointer, as MEM32 makes. */
    {
        volatile uint32_t *r = (volatile uint32_t *)(p + 600);
        r[0] = 0xCAFEF00Du;
        r[1] = r[0] | 1u;
        CHECK(le(600, 4) == 0xCAFEF00Du && le(604, 4) == 0xCAFEF00Du);
    }

    write_seen = g_writes;
    printf("mmio arm64: %d reads, %d writes, %d failures\n", g_reads, write_seen, g_failures);
    return g_failures ? 1 : 0;
}
