/*
 * CPU-001 compute-throughput benchmark.
 * Author: Tim Isaev
 *
 * Measures FEX's x86->arm64 translation tax by running a spread of
 * game-representative kernels (integer mix, scalar FP, memory stream,
 * data-dependent branch) and reporting ns per operation. The SAME source
 * builds two ways: as an x86_64 PE run under FEX, and as a native arm64
 * Mach-O run directly. The ratio FEX/native is the translation overhead
 * relative to the host's native ceiling - the right viability metric for
 * "is FEX fast enough on this hardware".
 *
 * Each kernel accumulates a checksum that is printed, so the optimiser
 * cannot elide the work. A warm-up pass precedes every timed run. Exit 0
 * iff every kernel completed and produced a non-zero checksum.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static uint64_t now_ns(void)
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (uint64_t)c.QuadPart * 1000000000ull / (uint64_t)f.QuadPart;
}
static const char *host_tag = "x86_64-PE-under-FEX";
#else
#include <time.h>
static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static const char *host_tag = "native";
#endif

#define MEM_WORDS (1u << 18) /* 2 MiB of uint64 */
static uint64_t membuf[MEM_WORDS];

/* integer ALU: xorshift-style mixing, heavy on shifts/xor/mul */
static uint64_t kernel_int(uint64_t n, uint64_t seed)
{
    uint64_t x = seed | 1;
    for (uint64_t i = 0; i < n; i++)
    {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x *= 0x2545F4914F6CDD1Dull;
    }
    return x;
}

/* scalar FP: multiply-accumulate chains, the shape of transforms/physics.
 * A symplectic rotation (s += t*a; t -= s*a) traces a bounded orbit for small
 * a, so 300M iterations stay finite instead of overflowing to NaN. */
static uint64_t kernel_fp(uint64_t n, uint64_t seed)
{
    double a = 1e-4 + (double)(seed & 0xFFF) * 1e-16;
    double s = 1.0, t = 0.0;
    for (uint64_t i = 0; i < n; i++)
    {
        s = s + t * a;
        t = t - s * a;
    }
    uint64_t bits;
    double r = s + t;
    memcpy(&bits, &r, sizeof bits);
    return bits;
}

/* memory: strided read-modify-write across a 2 MiB buffer */
static uint64_t kernel_mem(uint64_t n, uint64_t seed)
{
    uint64_t acc = seed;
    uint64_t idx = seed;
    for (uint64_t i = 0; i < n; i++)
    {
        idx = (idx * 6364136223846793005ull + 1442695040888963407ull);
        uint32_t p = (uint32_t)(idx >> 40) & (MEM_WORDS - 1);
        acc += membuf[p];
        membuf[p] = acc ^ i;
    }
    return acc;
}

/* branch: data-dependent, hard-to-predict control flow */
static uint64_t kernel_branch(uint64_t n, uint64_t seed)
{
    uint64_t x = seed | 1, count = 0;
    for (uint64_t i = 0; i < n; i++)
    {
        x = x * 2862933555777941757ull + 3037000493ull;
        if (x & 0x8000000000000000ull)
            count += x >> 60;
        else if ((x & 0xF) > 9)
            count ^= x >> 12;
        else
            count -= (x & 0xFF);
    }
    return count;
}

struct kernel
{
    const char *name;
    uint64_t (*fn)(uint64_t, uint64_t);
    uint64_t iters;
};

int main(void)
{
    const struct kernel kernels[] = {
        {"int_mix", kernel_int, 300000000ull},
        {"fp_mac", kernel_fp, 300000000ull},
        {"mem_stream", kernel_mem, 120000000ull},
        {"branch_dep", kernel_branch, 200000000ull},
    };
    const int k = (int)(sizeof kernels / sizeof kernels[0]);
    uint64_t guard = 0;
    int i;

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 0; i < (int)MEM_WORDS; i++)
        membuf[i] = (uint64_t)i * 2654435761ull;

    printf("cpu-001 throughput [%s]\n", host_tag);
    for (i = 0; i < k; i++)
    {
        uint64_t warm = kernels[i].fn(kernels[i].iters / 100 + 1, 0x1234 + i);
        uint64_t t0 = now_ns();
        uint64_t sum = kernels[i].fn(kernels[i].iters, 0x9E3779B97F4A7C15ull + i);
        uint64_t t1 = now_ns();
        guard += sum ^ warm;
        double ns_per = (double)(t1 - t0) / (double)kernels[i].iters;
        printf("%-11s %11llu iters  %8.3f ns/op  %8.2f Mops/s  chk=%016llx\n", kernels[i].name,
               (unsigned long long)kernels[i].iters, ns_per, 1000.0 / ns_per,
               (unsigned long long)sum);
        if (sum == 0)
            return 2 + i;
    }
    printf("guard=%016llx\n", (unsigned long long)guard);
    return guard ? 0 : 1;
}
