/*
 * Known-answer calibration guest for the execution census (issue #12).
 * Author: Tim Isaev
 *
 * The census claims to count *decodes* - once per block compilation - rather
 * than executions. That claim is what makes it cheap enough not to distort
 * what it measures, and it is falsifiable: run one distinctive instruction a
 * million times inside a single loop body and the census must report a count
 * near 1, not near 1000000.
 *
 * Each mode isolates one distinctive instruction form so it can be found in
 * the census output by name without depending on FEX's instruction selection:
 *
 *   loop      crc32 executed ITERATIONS times from one compiled block
 *   unrolled  crc32 executed ITERATIONS times from many distinct sites
 *   quiet     no distinctive instruction at all (negative control)
 *
 * "loop" and "unrolled" execute the same number of crc32 instructions. If the
 * census counted executions the two would agree; because it counts decodes,
 * "unrolled" must report many times more than "loop". Two modes that must
 * disagree are a stronger check than one mode that must hit a number.
 */

#include <windows.h>

#include <nmmintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ITERATIONS 1000000u
#define UNROLL 64u

/* Volatile so the compiler cannot hoist, fold or vectorise the loop body away;
 * the census is counting what the decoder sees, so the instruction has to
 * survive to the binary. */
static volatile uint32_t sink;

static uint32_t run_loop(void)
{
    uint32_t crc = 0;
    unsigned int i;

    for (i = 0; i < ITERATIONS; i++)
        crc = _mm_crc32_u32(crc, i);
    sink = crc;
    return crc;
}

#define CRC8(c, i)                                                                                 \
    (c) = _mm_crc32_u32((c), (i));                                                                 \
    (c) = _mm_crc32_u32((c), (i));                                                                 \
    (c) = _mm_crc32_u32((c), (i));                                                                 \
    (c) = _mm_crc32_u32((c), (i));                                                                 \
    (c) = _mm_crc32_u32((c), (i));                                                                 \
    (c) = _mm_crc32_u32((c), (i));                                                                 \
    (c) = _mm_crc32_u32((c), (i));                                                                 \
    (c) = _mm_crc32_u32((c), (i))

#define CRC64(c, i)                                                                                \
    CRC8(c, i);                                                                                    \
    CRC8(c, i);                                                                                    \
    CRC8(c, i);                                                                                    \
    CRC8(c, i);                                                                                    \
    CRC8(c, i);                                                                                    \
    CRC8(c, i);                                                                                    \
    CRC8(c, i);                                                                                    \
    CRC8(c, i)

static uint32_t run_unrolled(void)
{
    uint32_t crc = 0;
    unsigned int i;

    for (i = 0; i < ITERATIONS / UNROLL; i++)
    {
        CRC64(crc, i);
    }
    sink = crc;
    return crc;
}

static uint32_t run_quiet(void)
{
    uint32_t acc = 0;
    unsigned int i;

    for (i = 0; i < ITERATIONS; i++)
        acc += i ^ (acc >> 3);
    sink = acc;
    return acc;
}

int main(int argc, char **argv)
{
    const char *mode;
    uint32_t result;

    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (argc != 2)
    {
        fprintf(stderr, "usage: census_probe.exe loop|unrolled|quiet\n");
        return 64;
    }
    mode = argv[1];

    if (!strcmp(mode, "loop"))
        result = run_loop();
    else if (!strcmp(mode, "unrolled"))
        result = run_unrolled();
    else if (!strcmp(mode, "quiet"))
        result = run_quiet();
    else
    {
        fprintf(stderr, "unknown mode: %s\n", mode);
        return 65;
    }

    /* The checksum is printed so a census run can be shown to have executed
     * the same work as a non-census run, byte for byte. */
    printf("census_probe %s iterations=%u checksum=%08x\n", mode, ITERATIONS, result);
    return 0;
}
