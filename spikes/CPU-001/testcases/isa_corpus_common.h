/* Seeded ISA corpus support. Author: Timur Isaev */
#ifndef ALLOY_ISA_CORPUS_COMMON_H
#define ALLOY_ISA_CORPUS_COMMON_H

#include <fenv.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) || defined(_M_X64)
#define CORPUS_X86 1
#include <immintrin.h>
#else
#define CORPUS_X86 0
#endif

/* Do not let the compiler replace the scalar oracle with the vector operation
 * it is supposed to check. Native arm64 also supplies a separate checksum. */
#define CORPUS_REFERENCE __attribute__((noinline, optnone))
#define CORPUS_INSTRUCTION __attribute__((noinline))
#define CORPUS_SEED UINT64_C(0xa1c0ffee5eed0003)
#define CORPUS_FNV_OFFSET UINT64_C(0xcbf29ce484222325)

typedef union
{
    uint8_t b[32];
    uint16_t w[16];
    uint32_t d[8];
    uint64_t q[4];
    float f[8];
    double g[4];
} corpus_vec;

typedef struct
{
    const char *name;
    unsigned code;
    unsigned width;
    /* 0: exact bytes; 32/64: arithmetic NaNs compare by class, all other
     * values (including signed zero and subnormals) compare bit-for-bit. */
    unsigned nan_width;
    unsigned random_cases;
} corpus_op;

static uint64_t corpus_random(uint64_t *state)
{
    uint64_t x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x * UINT64_C(0x2545f4914f6cdd1d);
    return *state;
}

static void corpus_fold(uint64_t *hash, const void *data, size_t size)
{
    const uint8_t *bytes = data;
    for (size_t i = 0; i < size; ++i)
    {
        *hash ^= bytes[i];
        *hash *= UINT64_C(0x100000001b3);
    }
}

static void corpus_hex(const corpus_vec *v, unsigned width)
{
    for (unsigned i = 0; i < width; ++i)
        printf("%02x", v->b[i]);
}

static int corpus_parse_hex(const char *text, corpus_vec *v, unsigned width)
{
    if (strlen(text) != width * 2)
        return 0;
    memset(v, 0, sizeof *v);
    for (unsigned i = 0; i < width; ++i)
    {
        unsigned byte = 0;
        for (unsigned j = 0; j < 2; ++j)
        {
            unsigned char c = (unsigned char)text[2 * i + j];
            if (c >= '0' && c <= '9')
                byte = 16 * byte + c - '0';
            else if (c >= 'a' && c <= 'f')
                byte = 16 * byte + c - 'a' + 10;
            else
                return 0;
        }
        v->b[i] = (uint8_t)byte;
    }
    return 1;
}

static int64_t corpus_signed(uint64_t v, unsigned bits)
{
    uint64_t sign = UINT64_C(1) << (bits - 1);
    uint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;
    v &= mask;
    if (!(v & sign))
        return (int64_t)v;
    /* -(INT64_MIN) is not representable. Complement before conversion. */
    return -1 - (int64_t)((~v) & mask);
}

static uint32_t corpus_asr32(uint32_t value, uint32_t count)
{
    if (count >= 32)
        return value & UINT32_C(0x80000000) ? UINT32_MAX : 0;
    if (count == 0)
        return value;
    uint32_t out = value >> count;
    if (value & UINT32_C(0x80000000))
        out |= UINT32_MAX << (32 - count);
    return out;
}

static int32_t corpus_saturate16(int32_t value)
{
    return value < -32768 ? -32768 : value > 32767 ? 32767 : value;
}

static int corpus_nan32(uint32_t bits)
{
    return (bits & UINT32_C(0x7fffffff)) > UINT32_C(0x7f800000);
}

static int corpus_nan64(uint64_t bits)
{
    return (bits & UINT64_C(0x7fffffffffffffff)) > UINT64_C(0x7ff0000000000000);
}

static void corpus_normalize(corpus_vec *v, const corpus_op *op)
{
    if (op->nan_width == 32)
        for (unsigned i = 0; i < op->width / 4; ++i)
            if (corpus_nan32(v->d[i]))
                v->d[i] = UINT32_C(0x7fc00000);
    if (op->nan_width == 64)
        for (unsigned i = 0; i < op->width / 8; ++i)
            if (corpus_nan64(v->q[i]))
                v->q[i] = UINT64_C(0x7ff8000000000000);
}

/* Distinct upper lanes catch accidental 128-bit-only implementations. The
 * Cartesian edge product also exercises both operand orders. */
#define CORPUS_EDGE_COUNT 24
static void corpus_edge(unsigned index, corpus_vec *v)
{
    static const uint32_t edges[CORPUS_EDGE_COUNT] = {
        0,          0xffffffff, 1,          0x7fffffff, 0x80000000, 0x55555555,
        0xaaaaaaaa, 0x0000001f, 0x00000020, 0x00000021, 0x007fffff, 0x00800000,
        0x3f800000, 0xbf800000, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
        0x7fc00001, 0x7f800001, 0x00010000, 0x7fff8000, 0x01020304, 0x80ff007f};
    for (unsigned i = 0; i < 8; ++i)
        v->d[i] = edges[(index + (i < 4 ? 0 : i)) % CORPUS_EDGE_COUNT];
    /* Four additional 64-bit floating-point edges share slots with 32-bit
     * edges but still enter both operand positions across the full product. */
    if (index >= 20)
    {
        static const uint64_t doubles[4][4] = {
            {0, UINT64_C(0x8000000000000000), 1, UINT64_C(0x000fffffffffffff)},
            {UINT64_C(0x0010000000000000), UINT64_C(0x3ff0000000000000),
             UINT64_C(0xbff0000000000000), UINT64_C(0x7fefffffffffffff)},
            {UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000),
             UINT64_C(0x7ff8000000000001), UINT64_C(0x7ff0000000000001)},
            {UINT64_C(0xffffffffffffffff), UINT64_C(0x7fffffffffffffff),
             UINT64_C(0xaaaaaaaa55555555), UINT64_C(0x800000007fffffff)}};
        memcpy(v->q, doubles[index - 20], sizeof v->q);
    }
}

#endif
