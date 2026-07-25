/*
 * Known-answer calibration guest for FEX's anomaly telemetry (issues #12 and
 * #37). Author: Timur Isaev
 *
 * The ARM64EC path originally sampled these flags only at decode-census
 * intervals. A short calibration guest can finish decoding before its atomic
 * loop executes, making "not sampled after the event" look exactly like "the
 * flag stayed zero." Issue #37 adds a post-helper checkpoint and uses this
 * guest to distinguish those cases.
 *
 * The split flags are set from
 * FEXCore::ArchHelpers::Arm64::HandleUnalignedAccess, reached when an
 * unaligned locked operation raises EXCEPTION_DATATYPE_MISALIGNMENT. The CAS
 * tear flags mean something narrower: one half of a two-step emulated CAS
 * committed and the other half lost a race. Merely crossing a boundary cannot
 * make that race happen deterministically.
 *
 *   splitlock  lock add on a dword straddling a 64-byte cache line
 *   splitcas32 lock cmpxchg on a dword straddling a 64-byte cache line
 *   splitcas64 lock cmpxchg on a qword straddling a 64-byte cache line
 *   split16    current unsupported unaligned cmpxchg16b path (failure guard)
 *   clean      the same operations, all naturally aligned (negative control)
 *
 * "clean" must leave every flag at zero. splitlock/splitcas32/splitcas64 must
 * raise the split-lock and split-16-byte flags, whose values are
 * happened-at-least-once flags rather than frequencies. split16 currently
 * exits through FEX's unhandled CASPAL path; it is retained so support cannot
 * appear accidentally without a positive calibration being added.
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
 * success. The current ARM64EC 64-bit-pair CASPAL handler rejects this when
 * unaligned, before it can serve as telemetry calibration. */
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

static int run_splitcas32(void *p)
{
    unsigned int i;

    for (i = 0; i < ITERATIONS; i++)
        locked_cmpxchg32(p, i, i + 1);
    return 0;
}

static int run_splitcas64(void *p)
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
        fprintf(stderr,
                "usage: telemetry_probe.exe splitlock|splitcas32|splitcas64|split16|clean\n");
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
    else if (!strcmp(mode, "splitcas32") || !strcmp(mode, "castear32"))
        run_splitcas32(TARGET(4));
    else if (!strcmp(mode, "splitcas64") || !strcmp(mode, "castear64"))
        run_splitcas64(TARGET(8));
    else if (!strcmp(mode, "split16"))
        run_split16(TARGET(16));
    else if (!strcmp(mode, "clean"))
    {
        run_splitlock(TARGET(4));
        run_splitcas32(TARGET(4));
        run_splitcas64(TARGET(8));
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
