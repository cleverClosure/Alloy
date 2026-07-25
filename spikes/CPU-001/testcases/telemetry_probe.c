/*
 * Known-answer calibration guest for FEX's anomaly telemetry (issue #12).
 * Author: Tim Isaev
 *
 * FEX tracks split locks, split 16-byte atomics and CAS tears, but nothing on
 * the ARM64EC path ever emitted them, so those counters had never once been
 * observed to fire. A counter that has never fired reports zero for "no
 * anomalies" and for "the counter is dead" with equal confidence, so no census
 * may quote them until they have been made to fire deliberately.
 *
 * All of them are set from FEXCore::ArchHelpers::Arm64::HandleUnalignedAccess,
 * reached on ARM64EC when the guest takes EXCEPTION_DATATYPE_MISALIGNMENT from
 * a locked operation on an unaligned address (ARM64EC Module.cpp). So each
 * mode below performs a locked RMW straddling a boundary:
 *
 *   splitlock  lock add on a dword straddling a 64-byte cache line
 *   castear32  lock cmpxchg on a dword straddling a 64-byte cache line
 *   castear64  lock cmpxchg on a qword straddling a 64-byte cache line
 *   split16    lock cmpxchg16b on a 16-byte value that is not 16-byte aligned
 *   clean      the same operations, all naturally aligned (negative control)
 *
 * "clean" is the control that matters: if the telemetry is set even there, it
 * is not reporting what its name claims. Note the values are flags, not
 * frequencies - FEX assigns 1 rather than incrementing - so these modes prove
 * the counters can fire, not how often anything happened.
 */

#include <windows.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ITERATIONS 2000u

static unsigned char *arena;

/* Locked read-modify-write on an arbitrary (possibly unaligned) address.
 * Written as inline asm because the compiler is entitled to refuse to emit a
 * locked access it can prove is unaligned, and the point here is the encoding
 * that reaches FEX, not what C would normally produce. */
static inline void locked_add32(void *p, uint32_t v)
{
    __asm__ volatile("lock addl %1, (%0)" ::"r"(p), "r"(v) : "memory", "cc");
}

static inline uint32_t locked_cmpxchg32(void *p, uint32_t expected, uint32_t desired)
{
    uint32_t out;
    __asm__ volatile("lock cmpxchgl %2, (%1)"
                     : "=a"(out)
                     : "r"(p), "r"(desired), "0"(expected)
                     : "memory", "cc");
    return out;
}

static inline uint64_t locked_cmpxchg64(void *p, uint64_t expected, uint64_t desired)
{
    uint64_t out;
    __asm__ volatile("lock cmpxchgq %2, (%1)"
                     : "=a"(out)
                     : "r"(p), "r"(desired), "0"(expected)
                     : "memory", "cc");
    return out;
}

/* cmpxchg16b compares rdx:rax with the memory operand and stores rcx:rbx on
 * success. Unaligned, this is the 16-byte split the TYPE_16BYTE_SPLIT and
 * TYPE_CAS_128BIT_TEAR counters describe. */
static inline int locked_cmpxchg16b(void *p, uint64_t explo, uint64_t exphi, uint64_t deslo,
                                    uint64_t deshi)
{
    unsigned char ok;
    __asm__ volatile("lock cmpxchg16b (%%rsi)\n\tsetz %0"
                     : "=q"(ok), "+a"(explo), "+d"(exphi)
                     : "S"(p), "b"(deslo), "c"(deshi)
                     : "memory", "cc");
    return ok;
}

/* A pointer whose access of `size` bytes straddles the next 64-byte boundary. */
static void *straddling(size_t size)
{
    uintptr_t base = (uintptr_t)arena;
    uintptr_t line = (base + 128) & ~(uintptr_t)63;
    return (void *)(line - (size / 2));
}

static void *aligned(size_t size)
{
    uintptr_t base = (uintptr_t)arena;
    uintptr_t line = (base + 128) & ~(uintptr_t)63;
    (void)size;
    return (void *)line;
}

static int run_splitlock(void *p)
{
    unsigned int i;

    for (i = 0; i < ITERATIONS; i++)
        locked_add32(p, 1);
    return 0;
}

static int run_castear32(void *p)
{
    unsigned int i;

    for (i = 0; i < ITERATIONS; i++)
        locked_cmpxchg32(p, i, i + 1);
    return 0;
}

static int run_castear64(void *p)
{
    unsigned int i;

    for (i = 0; i < ITERATIONS; i++)
        locked_cmpxchg64(p, i, i + 1);
    return 0;
}

static int run_split16(void *p)
{
    unsigned int i;

    for (i = 0; i < ITERATIONS; i++)
        locked_cmpxchg16b(p, i, 0, i + 1, 0);
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode;
    int misaligned = 1;

    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (argc != 2)
    {
        fprintf(stderr, "usage: telemetry_probe.exe splitlock|castear32|castear64|split16|clean\n");
        return 64;
    }
    mode = argv[1];

    arena = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!arena)
    {
        fprintf(stderr, "VirtualAlloc failed: %lu\n", GetLastError());
        return 2;
    }
    memset(arena, 0, 4096);

    if (!strcmp(mode, "clean"))
        misaligned = 0;

#define TARGET(sz) (misaligned ? straddling(sz) : aligned(sz))

    if (!strcmp(mode, "splitlock"))
        run_splitlock(TARGET(4));
    else if (!strcmp(mode, "castear32"))
        run_castear32(TARGET(4));
    else if (!strcmp(mode, "castear64"))
        run_castear64(TARGET(8));
    else if (!strcmp(mode, "split16"))
        run_split16(TARGET(16));
    else if (!strcmp(mode, "clean"))
    {
        run_splitlock(TARGET(4));
        run_castear32(TARGET(4));
        run_castear64(TARGET(8));
        run_split16(TARGET(16));
    }
    else
    {
        fprintf(stderr, "unknown mode: %s\n", mode);
        return 65;
    }

    printf("telemetry_probe %s iterations=%u misaligned=%d ok\n", mode, ITERATIONS, misaligned);
    return 0;
}
