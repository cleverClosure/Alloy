/*
 * CPU-001 systematic ISA correctness corpus - SSE2 integer family (issue #104).
 * Author: Tim Isaev
 *
 * Oracle method: reference-implementation parity, the pattern isa_smoke.c
 * already uses for CRC32C/PDEP/PEXT. For every SSE2 integer op, each test case
 * computes the result two independent ways - the real x86 instruction
 * (intrinsic) and a portable C reference operating lane-by-lane on plain
 * integers - over a seeded xorshift64 operand stream (same step function as
 * cpu_throughput.c/cpu_scaling.c) plus a fixed cross-product of deliberately
 * awkward edge operands (all-zero, all-one, sign-boundary bytes/words, an
 * alternating bit pattern). A mismatch is a translator finding, not a test
 * failure, and is printed with the operands and both results.
 *
 * The SAME source builds two ways, exactly like cpu_throughput.c:
 *
 *   - x64 Windows PE guest (build-corpus.sh, the mingw cross toolchain): both
 *     sides run, real vs. reference is the oracle check, and this is the
 *     binary run-isa-corpus.sh executes under FEX/Wine.
 *   - native arm64 Mach-O (clang, this host): there is no real SSE2 on this
 *     CPU, so only the portable reference side runs. It walks the identical
 *     seeded operand sequence and folds the identical checksum, so a native
 *     run and a passing FEX run must print the same number even though
 *     neither one ever saw the other's instructions.
 *
 * The native build is the Milestone-1 proof that the oracle and the harness
 * are trustworthy *before* any translator is involved: build-isa-corpus-
 * native.sh builds it at -O0/-O2/-O3 and requires byte-identical output
 * across all three, and run_hand_vectors() below checks the reference
 * against a handful of values computed by hand in this comment block rather
 * than against anything the program itself computes - a corrupted reference
 * agreeing with its own corruption cannot pass a hand-checked vector.
 *
 * Mutation control: build with -DALLOY_CORPUS_MUTATE_PADDB to deliberately
 * break ref_paddb (drops the wraparound by adding one extra). That must turn
 * the corpus red - both the "0xff+0x01 wraps to 0x00" hand vector and, once
 * this binary runs under FEX, the real-vs-reference comparison for every
 * paddb case - and name paddb as the failing operation. A corpus that cannot
 * fail this way proves nothing (CLAUDE.md "Measurement").
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) || defined(_M_X64)
#define ALLOY_HAVE_X86_INTRINSICS 1
#include <emmintrin.h>
#else
#define ALLOY_HAVE_X86_INTRINSICS 0
#endif

#if defined(ALLOY_CORPUS_MUTATE_PADDB)
static const char *const mutate_tag = "paddb";
#else
static const char *const mutate_tag = "none";
#endif

/* One XMM register's worth of bits, viewed by lane width. Every reference
 * function fills one member completely (b[16], w[8], d[4] or q[2] all cover
 * the same 16 bytes), and every call site also zero-fills the struct before
 * calling in, so no comparison or checksum ever reads an indeterminate byte -
 * that matters here specifically because an uninitialized read could differ
 * between -O0 and -O2 and masquerade as a real optimisation-level disagreement. */
typedef union
{
    uint8_t b[16];
    uint16_t w[8];
    uint32_t d[4];
    uint64_t q[2];
} v128;

/* ---- deterministic PRNG and checksum ----------------------------------- */

/* Fixed so every run, on either architecture, walks the identical operand
 * sequence. Changing it invalidates every checksum this corpus has ever
 * printed - do that deliberately, never silently. */
#define RNG_SEED UINT64_C(0xA1C0FFEE5EED0001)

static uint64_t xorshift64(uint64_t *state)
{
    uint64_t x = *state;

    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    x *= 0x2545F4914F6CDD1Dull;
    *state = x;
    return x;
}

static void random_v128(uint64_t *state, v128 *out)
{
    out->q[0] = xorshift64(state);
    out->q[1] = xorshift64(state);
}

/* FNV-1a, folded one byte at a time. Not cryptographic - just a small,
 * well-defined, order-sensitive mix so two independent implementations that
 * produce the same byte stream produce the same number. Both hosts here are
 * little-endian (Apple Silicon always runs LE, same as x86-64), so folding a
 * v128's raw bytes means the same thing on both builds. */
#define FNV_OFFSET UINT64_C(0xcbf29ce484222325)
#define FNV_PRIME UINT64_C(0x100000001b3)

static void fold_bytes(uint64_t *state, const void *data, size_t n)
{
    const uint8_t *p = (const uint8_t *)data;
    size_t i;

    for (i = 0; i < n; i++)
    {
        *state ^= p[i];
        *state *= FNV_PRIME;
    }
}

static void fold_v128(uint64_t *state, const v128 *v)
{
    fold_bytes(state, v, sizeof *v);
}

/* ---- operand tables: edge patterns and shift-count edges --------------- */

static void make_all(v128 *v, uint8_t byte)
{
    memset(v, byte, sizeof *v);
}

static void make_alt(v128 *v, uint8_t even, uint8_t odd)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        v->b[i] = (i & 1) ? odd : even;
}

#define EDGE_BYTE_COUNT 5
#define EDGE_COUNT (EDGE_BYTE_COUNT + 1)
static v128 edge_patterns[EDGE_COUNT];

#define COUNT_VALUES_COUNT 11
static uint64_t count_values[COUNT_VALUES_COUNT];

static void build_tables(void)
{
    /* all-zero, all-one, byte-sign boundaries (INT8_MAX/MIN), then an
     * alternating pattern that stresses every lane width's sign bit
     * differently depending on how it's sliced. */
    static const uint8_t edge_bytes[EDGE_BYTE_COUNT] = {0x00, 0xFF, 0x01, 0x7F, 0x80};
    /* shift counts straddling the 16/32/64-bit width boundaries every SSE2
     * shift op cares about, from one side to the other. */
    static const uint64_t counts[COUNT_VALUES_COUNT] = {0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65};
    unsigned i;

    for (i = 0; i < EDGE_BYTE_COUNT; i++)
        make_all(&edge_patterns[i], edge_bytes[i]);
    make_alt(&edge_patterns[EDGE_BYTE_COUNT], 0x55, 0xAA);
    for (i = 0; i < COUNT_VALUES_COUNT; i++)
        count_values[i] = counts[i];
}

static const uint8_t shuffle_imms[] = {0x00, 0x1B, 0x4E, 0x6C, 0xB1, 0xE4, 0xFF};
#define SHUFFLE_IMMS_COUNT (sizeof shuffle_imms / sizeof shuffle_imms[0])

/* ---- scalar helpers shared by several reference functions --------------- */

static int32_t clamp_i8(int32_t v)
{
    if (v > 127)
        return 127;
    if (v < -128)
        return -128;
    return v;
}

static int32_t clamp_i16(int32_t v)
{
    if (v > 32767)
        return 32767;
    if (v < -32768)
        return -32768;
    return v;
}

static int32_t clamp_u8(int32_t v)
{
    if (v > 255)
        return 255;
    if (v < 0)
        return 0;
    return v;
}

static int32_t clamp_u16(int32_t v)
{
    if (v > 65535)
        return 65535;
    if (v < 0)
        return 0;
    return v;
}

/* Portable arithmetic right shift. C leaves >> of a negative signed value
 * implementation-defined; every mainstream compiler makes it arithmetic, but
 * an oracle has no business resting on "every mainstream compiler" when a
 * three-line, fully-defined version is this cheap. Correct for any c, and in
 * particular for c >= the operand's real width: a value already sign-extended
 * into v naturally collapses to 0 or -1 once c passes its significant bits,
 * which is exactly PSRAW/PSRAD's documented "count exceeds width" behaviour. */
static int64_t asr64(int64_t v, uint64_t c)
{
    uint64_t u;

    if (c == 0)
        return v;
    if (c >= 63)
        return (v < 0) ? -1 : 0;
    u = (uint64_t)v >> c;
    if (v < 0)
        u |= ~((uint64_t)-1 >> c);
    return (int64_t)u;
}

/* ---- reference implementations: wraparound add/sub ---------------------- */

static void ref_paddb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
#if defined(ALLOY_CORPUS_MUTATE_PADDB)
        out->b[i] = (uint8_t)(a->b[i] + b->b[i] + 1); /* deliberately wrong: off by one */
#else
        out->b[i] = (uint8_t)(a->b[i] + b->b[i]);
#endif
}

static void ref_paddw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)(a->w[i] + b->w[i]);
}

static void ref_paddd(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = a->d[i] + b->d[i];
}

static void ref_paddq(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 2; i++)
        out->q[i] = a->q[i] + b->q[i];
}

static void ref_psubb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (uint8_t)(a->b[i] - b->b[i]);
}

static void ref_psubw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)(a->w[i] - b->w[i]);
}

static void ref_psubd(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = a->d[i] - b->d[i];
}

static void ref_psubq(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 2; i++)
        out->q[i] = a->q[i] - b->q[i];
}

/* ---- reference implementations: saturating add/sub ---------------------- */

static void ref_paddsb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (uint8_t)clamp_i8((int32_t)(int8_t)a->b[i] + (int32_t)(int8_t)b->b[i]);
}

static void ref_paddsw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)clamp_i16((int32_t)(int16_t)a->w[i] + (int32_t)(int16_t)b->w[i]);
}

static void ref_paddusb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (uint8_t)clamp_u8((int32_t)a->b[i] + (int32_t)b->b[i]);
}

static void ref_paddusw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)clamp_u16((int32_t)a->w[i] + (int32_t)b->w[i]);
}

static void ref_psubsb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (uint8_t)clamp_i8((int32_t)(int8_t)a->b[i] - (int32_t)(int8_t)b->b[i]);
}

static void ref_psubsw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)clamp_i16((int32_t)(int16_t)a->w[i] - (int32_t)(int16_t)b->w[i]);
}

static void ref_psubusb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (uint8_t)clamp_u8((int32_t)a->b[i] - (int32_t)b->b[i]);
}

static void ref_psubusw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)clamp_u16((int32_t)a->w[i] - (int32_t)b->w[i]);
}

/* ---- reference implementations: compares --------------------------------- */

static void ref_pcmpeqb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (a->b[i] == b->b[i]) ? 0xFF : 0x00;
}

static void ref_pcmpeqw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (a->w[i] == b->w[i]) ? 0xFFFF : 0x0000;
}

static void ref_pcmpeqd(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = (a->d[i] == b->d[i]) ? 0xFFFFFFFFu : 0x00000000u;
}

static void ref_pcmpgtb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = ((int8_t)a->b[i] > (int8_t)b->b[i]) ? 0xFF : 0x00;
}

static void ref_pcmpgtw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = ((int16_t)a->w[i] > (int16_t)b->w[i]) ? 0xFFFF : 0x0000;
}

static void ref_pcmpgtd(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = ((int32_t)a->d[i] > (int32_t)b->d[i]) ? 0xFFFFFFFFu : 0x00000000u;
}

/* ---- reference implementations: shifts ----------------------------------- */
/* Count comes packed in b->q[0] (b->q[1] unused), matching the variable-count
 * intrinsics (_mm_sll_epi16 etc.) rather than the immediate-form ones, so a
 * shift count can be generated at runtime instead of needing a 256-way
 * compile-time dispatch the way the shuffle immediates below do. */

static void ref_psllw(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (c >= 16) ? 0 : (uint16_t)((uint32_t)a->w[i] << c);
}

static void ref_pslld(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = (c >= 32) ? 0 : (uint32_t)((uint64_t)a->d[i] << c);
}

static void ref_psllq(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 2; i++)
        out->q[i] = (c >= 64) ? 0 : (a->q[i] << c);
}

static void ref_psrlw(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (c >= 16) ? 0 : (uint16_t)(a->w[i] >> c);
}

static void ref_psrld(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = (c >= 32) ? 0 : (a->d[i] >> c);
}

static void ref_psrlq(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 2; i++)
        out->q[i] = (c >= 64) ? 0 : (a->q[i] >> c);
}

static void ref_psraw(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)(int16_t)asr64((int16_t)a->w[i], c);
}

static void ref_psrad(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t c = b->q[0];
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = (uint32_t)(int32_t)asr64((int32_t)a->d[i], c);
}

/* ---- reference implementations: multiplies ------------------------------- */

static void ref_pmullw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    /* low 16 bits of the product are identical whether the inputs are taken
     * as signed or unsigned, so one reference covers both PMULLW uses. */
    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)((uint32_t)a->w[i] * (uint32_t)b->w[i]);
}

static void ref_pmulhw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
    {
        int32_t p = (int32_t)(int16_t)a->w[i] * (int32_t)(int16_t)b->w[i];
        out->w[i] = (uint16_t)asr64(p, 16);
    }
}

static void ref_pmulhuw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
    {
        uint32_t p = (uint32_t)a->w[i] * (uint32_t)b->w[i];
        out->w[i] = (uint16_t)(p >> 16);
    }
}

/* ---- reference implementations: pack / unpack ---------------------------- */

static void ref_packsswb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->b[i] = (uint8_t)clamp_i8((int16_t)a->w[i]);
    for (i = 0; i < 8; i++)
        out->b[8 + i] = (uint8_t)clamp_i8((int16_t)b->w[i]);
}

static void ref_packssdw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->w[i] = (uint16_t)clamp_i16((int32_t)a->d[i]);
    for (i = 0; i < 4; i++)
        out->w[4 + i] = (uint16_t)clamp_i16((int32_t)b->d[i]);
}

static void ref_packuswb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->b[i] = (uint8_t)clamp_u8((int16_t)a->w[i]);
    for (i = 0; i < 8; i++)
        out->b[8 + i] = (uint8_t)clamp_u8((int16_t)b->w[i]);
}

static void ref_punpcklbw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
    {
        out->b[2 * i] = a->b[i];
        out->b[2 * i + 1] = b->b[i];
    }
}

static void ref_punpckhbw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
    {
        out->b[2 * i] = a->b[8 + i];
        out->b[2 * i + 1] = b->b[8 + i];
    }
}

static void ref_punpcklwd(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
    {
        out->w[2 * i] = a->w[i];
        out->w[2 * i + 1] = b->w[i];
    }
}

static void ref_punpckhwd(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
    {
        out->w[2 * i] = a->w[4 + i];
        out->w[2 * i + 1] = b->w[4 + i];
    }
}

static void ref_punpckldq(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 2; i++)
    {
        out->d[2 * i] = a->d[i];
        out->d[2 * i + 1] = b->d[i];
    }
}

static void ref_punpckhdq(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 2; i++)
    {
        out->d[2 * i] = a->d[2 + i];
        out->d[2 * i + 1] = b->d[2 + i];
    }
}

/* ---- reference implementations: min/max, average, SAD, movemask --------- */

static void ref_pminub(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (a->b[i] < b->b[i]) ? a->b[i] : b->b[i];
}

static void ref_pmaxub(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (a->b[i] > b->b[i]) ? a->b[i] : b->b[i];
}

static void ref_pminsw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = ((int16_t)a->w[i] < (int16_t)b->w[i]) ? a->w[i] : b->w[i];
}

static void ref_pmaxsw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = ((int16_t)a->w[i] > (int16_t)b->w[i]) ? a->w[i] : b->w[i];
}

static void ref_pavgb(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        out->b[i] = (uint8_t)(((uint32_t)a->b[i] + (uint32_t)b->b[i] + 1) >> 1);
}

static void ref_pavgw(const v128 *a, const v128 *b, v128 *out)
{
    unsigned i;

    for (i = 0; i < 8; i++)
        out->w[i] = (uint16_t)(((uint32_t)a->w[i] + (uint32_t)b->w[i] + 1) >> 1);
}

static void ref_psadbw(const v128 *a, const v128 *b, v128 *out)
{
    uint64_t s0 = 0, s1 = 0;
    unsigned i;

    for (i = 0; i < 8; i++)
        s0 += (a->b[i] > b->b[i]) ? (uint64_t)(a->b[i] - b->b[i]) : (uint64_t)(b->b[i] - a->b[i]);
    for (i = 8; i < 16; i++)
        s1 += (a->b[i] > b->b[i]) ? (uint64_t)(a->b[i] - b->b[i]) : (uint64_t)(b->b[i] - a->b[i]);
    out->q[0] = s0;
    out->q[1] = s1;
}

static void ref_pmovmskb(const v128 *a, const v128 *b, v128 *out)
{
    uint32_t mask = 0;
    unsigned i;

    (void)b;
    for (i = 0; i < 16; i++)
        if (a->b[i] & 0x80)
            mask |= (1u << i);
    out->q[0] = mask;
    out->q[1] = 0;
}

/* ---- reference implementations: shuffles --------------------------------- */
/* Immediate-controlled, so unlike every op above these are called directly
 * rather than through the op table - the table's uniform (a, b, out) shape has
 * no slot for a compile-time-shaped control byte, and a runtime-variable imm
 * is fine for the reference side but needs a dispatch table on the real-
 * instruction side (see real_shuffle_epi32 below), so it gets its own small
 * driver (run_shuffle_family) instead of forcing that asymmetry into run_case. */

static void shuffle_epi32_ref(const v128 *a, uint8_t imm, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->d[i] = a->d[(imm >> (2 * i)) & 3];
}

static void shufflelo_epi16_ref(const v128 *a, uint8_t imm, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->w[i] = a->w[(imm >> (2 * i)) & 3];
    for (i = 4; i < 8; i++)
        out->w[i] = a->w[i];
}

static void shufflehi_epi16_ref(const v128 *a, uint8_t imm, v128 *out)
{
    unsigned i;

    for (i = 0; i < 4; i++)
        out->w[i] = a->w[i];
    for (i = 0; i < 4; i++)
        out->w[4 + i] = a->w[4 + ((imm >> (2 * i)) & 3)];
}

/* ---- real x86 instructions (guest build only) ---------------------------- */

#if ALLOY_HAVE_X86_INTRINSICS

static __m128i load128(const v128 *v)
{
    __m128i r;

    memcpy(&r, v, sizeof r);
    return r;
}

static void store128(v128 *v, __m128i r)
{
    memcpy(v, &r, sizeof *v);
}

#define REAL_BINARY(name, intrinsic)                                                               \
    static void name(const v128 *a, const v128 *b, v128 *out)                                      \
    {                                                                                              \
        store128(out, intrinsic(load128(a), load128(b)));                                          \
    }

REAL_BINARY(real_paddb, _mm_add_epi8)
REAL_BINARY(real_paddw, _mm_add_epi16)
REAL_BINARY(real_paddd, _mm_add_epi32)
REAL_BINARY(real_paddq, _mm_add_epi64)
REAL_BINARY(real_psubb, _mm_sub_epi8)
REAL_BINARY(real_psubw, _mm_sub_epi16)
REAL_BINARY(real_psubd, _mm_sub_epi32)
REAL_BINARY(real_psubq, _mm_sub_epi64)
REAL_BINARY(real_paddsb, _mm_adds_epi8)
REAL_BINARY(real_paddsw, _mm_adds_epi16)
REAL_BINARY(real_paddusb, _mm_adds_epu8)
REAL_BINARY(real_paddusw, _mm_adds_epu16)
REAL_BINARY(real_psubsb, _mm_subs_epi8)
REAL_BINARY(real_psubsw, _mm_subs_epi16)
REAL_BINARY(real_psubusb, _mm_subs_epu8)
REAL_BINARY(real_psubusw, _mm_subs_epu16)
REAL_BINARY(real_pcmpeqb, _mm_cmpeq_epi8)
REAL_BINARY(real_pcmpeqw, _mm_cmpeq_epi16)
REAL_BINARY(real_pcmpeqd, _mm_cmpeq_epi32)
REAL_BINARY(real_pcmpgtb, _mm_cmpgt_epi8)
REAL_BINARY(real_pcmpgtw, _mm_cmpgt_epi16)
REAL_BINARY(real_pcmpgtd, _mm_cmpgt_epi32)
REAL_BINARY(real_psllw, _mm_sll_epi16)
REAL_BINARY(real_pslld, _mm_sll_epi32)
REAL_BINARY(real_psllq, _mm_sll_epi64)
REAL_BINARY(real_psrlw, _mm_srl_epi16)
REAL_BINARY(real_psrld, _mm_srl_epi32)
REAL_BINARY(real_psrlq, _mm_srl_epi64)
REAL_BINARY(real_psraw, _mm_sra_epi16)
REAL_BINARY(real_psrad, _mm_sra_epi32)
REAL_BINARY(real_pmullw, _mm_mullo_epi16)
REAL_BINARY(real_pmulhw, _mm_mulhi_epi16)
REAL_BINARY(real_pmulhuw, _mm_mulhi_epu16)
REAL_BINARY(real_packsswb, _mm_packs_epi16)
REAL_BINARY(real_packssdw, _mm_packs_epi32)
REAL_BINARY(real_packuswb, _mm_packus_epi16)
REAL_BINARY(real_punpcklbw, _mm_unpacklo_epi8)
REAL_BINARY(real_punpckhbw, _mm_unpackhi_epi8)
REAL_BINARY(real_punpcklwd, _mm_unpacklo_epi16)
REAL_BINARY(real_punpckhwd, _mm_unpackhi_epi16)
REAL_BINARY(real_punpckldq, _mm_unpacklo_epi32)
REAL_BINARY(real_punpckhdq, _mm_unpackhi_epi32)
REAL_BINARY(real_pminub, _mm_min_epu8)
REAL_BINARY(real_pmaxub, _mm_max_epu8)
REAL_BINARY(real_pminsw, _mm_min_epi16)
REAL_BINARY(real_pmaxsw, _mm_max_epi16)
REAL_BINARY(real_pavgb, _mm_avg_epu8)
REAL_BINARY(real_pavgw, _mm_avg_epu16)
REAL_BINARY(real_psadbw, _mm_sad_epu8)

static void real_pmovmskb(const v128 *a, const v128 *b, v128 *out)
{
    (void)b;
    out->q[0] = (uint32_t)(uint16_t)_mm_movemask_epi8(load128(a));
    out->q[1] = 0;
}

/* _mm_shuffle_epi32 and friends require a compile-time-constant control byte,
 * so a runtime-chosen immediate needs an explicit dispatch over the small set
 * this corpus actually exercises (shuffle_imms[] above). */
static void real_shuffle_epi32(const v128 *a, uint8_t imm, v128 *out)
{
    __m128i va = load128(a), r;

    switch (imm)
    {
    case 0x00:
        r = _mm_shuffle_epi32(va, 0x00);
        break;
    case 0x1B:
        r = _mm_shuffle_epi32(va, 0x1B);
        break;
    case 0x4E:
        r = _mm_shuffle_epi32(va, 0x4E);
        break;
    case 0x6C:
        r = _mm_shuffle_epi32(va, 0x6C);
        break;
    case 0xB1:
        r = _mm_shuffle_epi32(va, 0xB1);
        break;
    case 0xE4:
        r = _mm_shuffle_epi32(va, 0xE4);
        break;
    case 0xFF:
        r = _mm_shuffle_epi32(va, 0xFF);
        break;
    default:
        fprintf(stderr, "pshufd: unsupported immediate 0x%02x\n", imm);
        exit(70);
    }
    store128(out, r);
}

static void real_shufflelo_epi16(const v128 *a, uint8_t imm, v128 *out)
{
    __m128i va = load128(a), r;

    switch (imm)
    {
    case 0x00:
        r = _mm_shufflelo_epi16(va, 0x00);
        break;
    case 0x1B:
        r = _mm_shufflelo_epi16(va, 0x1B);
        break;
    case 0x4E:
        r = _mm_shufflelo_epi16(va, 0x4E);
        break;
    case 0x6C:
        r = _mm_shufflelo_epi16(va, 0x6C);
        break;
    case 0xB1:
        r = _mm_shufflelo_epi16(va, 0xB1);
        break;
    case 0xE4:
        r = _mm_shufflelo_epi16(va, 0xE4);
        break;
    case 0xFF:
        r = _mm_shufflelo_epi16(va, 0xFF);
        break;
    default:
        fprintf(stderr, "pshuflw: unsupported immediate 0x%02x\n", imm);
        exit(70);
    }
    store128(out, r);
}

static void real_shufflehi_epi16(const v128 *a, uint8_t imm, v128 *out)
{
    __m128i va = load128(a), r;

    switch (imm)
    {
    case 0x00:
        r = _mm_shufflehi_epi16(va, 0x00);
        break;
    case 0x1B:
        r = _mm_shufflehi_epi16(va, 0x1B);
        break;
    case 0x4E:
        r = _mm_shufflehi_epi16(va, 0x4E);
        break;
    case 0x6C:
        r = _mm_shufflehi_epi16(va, 0x6C);
        break;
    case 0xB1:
        r = _mm_shufflehi_epi16(va, 0xB1);
        break;
    case 0xE4:
        r = _mm_shufflehi_epi16(va, 0xE4);
        break;
    case 0xFF:
        r = _mm_shufflehi_epi16(va, 0xFF);
        break;
    default:
        fprintf(stderr, "pshufhi: unsupported immediate 0x%02x\n", imm);
        exit(70);
    }
    store128(out, r);
}

#endif /* ALLOY_HAVE_X86_INTRINSICS */

/* ---- op table ------------------------------------------------------------- */

enum op_kind
{
    OP_BINARY, /* a and b are both general v128 operands */
    OP_SHIFT,  /* a is a general operand, b carries a shift count in q[0] */
    OP_UNARY   /* only a is meaningful; b is an ignored placeholder */
};

typedef void (*v128_fn)(const v128 *, const v128 *, v128 *);

struct op_entry
{
    const char *name;
    enum op_kind kind;
    v128_fn reference;
    v128_fn real;
};

#if ALLOY_HAVE_X86_INTRINSICS
#define OP_REAL(fn) fn
#else
#define OP_REAL(fn) NULL
#endif

static const struct op_entry sse2_ops[] = {
    {"paddb", OP_BINARY, ref_paddb, OP_REAL(real_paddb)},
    {"paddw", OP_BINARY, ref_paddw, OP_REAL(real_paddw)},
    {"paddd", OP_BINARY, ref_paddd, OP_REAL(real_paddd)},
    {"paddq", OP_BINARY, ref_paddq, OP_REAL(real_paddq)},
    {"psubb", OP_BINARY, ref_psubb, OP_REAL(real_psubb)},
    {"psubw", OP_BINARY, ref_psubw, OP_REAL(real_psubw)},
    {"psubd", OP_BINARY, ref_psubd, OP_REAL(real_psubd)},
    {"psubq", OP_BINARY, ref_psubq, OP_REAL(real_psubq)},
    {"paddsb", OP_BINARY, ref_paddsb, OP_REAL(real_paddsb)},
    {"paddsw", OP_BINARY, ref_paddsw, OP_REAL(real_paddsw)},
    {"paddusb", OP_BINARY, ref_paddusb, OP_REAL(real_paddusb)},
    {"paddusw", OP_BINARY, ref_paddusw, OP_REAL(real_paddusw)},
    {"psubsb", OP_BINARY, ref_psubsb, OP_REAL(real_psubsb)},
    {"psubsw", OP_BINARY, ref_psubsw, OP_REAL(real_psubsw)},
    {"psubusb", OP_BINARY, ref_psubusb, OP_REAL(real_psubusb)},
    {"psubusw", OP_BINARY, ref_psubusw, OP_REAL(real_psubusw)},
    {"pcmpeqb", OP_BINARY, ref_pcmpeqb, OP_REAL(real_pcmpeqb)},
    {"pcmpeqw", OP_BINARY, ref_pcmpeqw, OP_REAL(real_pcmpeqw)},
    {"pcmpeqd", OP_BINARY, ref_pcmpeqd, OP_REAL(real_pcmpeqd)},
    {"pcmpgtb", OP_BINARY, ref_pcmpgtb, OP_REAL(real_pcmpgtb)},
    {"pcmpgtw", OP_BINARY, ref_pcmpgtw, OP_REAL(real_pcmpgtw)},
    {"pcmpgtd", OP_BINARY, ref_pcmpgtd, OP_REAL(real_pcmpgtd)},
    {"psllw", OP_SHIFT, ref_psllw, OP_REAL(real_psllw)},
    {"pslld", OP_SHIFT, ref_pslld, OP_REAL(real_pslld)},
    {"psllq", OP_SHIFT, ref_psllq, OP_REAL(real_psllq)},
    {"psrlw", OP_SHIFT, ref_psrlw, OP_REAL(real_psrlw)},
    {"psrld", OP_SHIFT, ref_psrld, OP_REAL(real_psrld)},
    {"psrlq", OP_SHIFT, ref_psrlq, OP_REAL(real_psrlq)},
    {"psraw", OP_SHIFT, ref_psraw, OP_REAL(real_psraw)},
    {"psrad", OP_SHIFT, ref_psrad, OP_REAL(real_psrad)},
    {"pmullw", OP_BINARY, ref_pmullw, OP_REAL(real_pmullw)},
    {"pmulhw", OP_BINARY, ref_pmulhw, OP_REAL(real_pmulhw)},
    {"pmulhuw", OP_BINARY, ref_pmulhuw, OP_REAL(real_pmulhuw)},
    {"packsswb", OP_BINARY, ref_packsswb, OP_REAL(real_packsswb)},
    {"packssdw", OP_BINARY, ref_packssdw, OP_REAL(real_packssdw)},
    {"packuswb", OP_BINARY, ref_packuswb, OP_REAL(real_packuswb)},
    {"punpcklbw", OP_BINARY, ref_punpcklbw, OP_REAL(real_punpcklbw)},
    {"punpckhbw", OP_BINARY, ref_punpckhbw, OP_REAL(real_punpckhbw)},
    {"punpcklwd", OP_BINARY, ref_punpcklwd, OP_REAL(real_punpcklwd)},
    {"punpckhwd", OP_BINARY, ref_punpckhwd, OP_REAL(real_punpckhwd)},
    {"punpckldq", OP_BINARY, ref_punpckldq, OP_REAL(real_punpckldq)},
    {"punpckhdq", OP_BINARY, ref_punpckhdq, OP_REAL(real_punpckhdq)},
    {"pminub", OP_BINARY, ref_pminub, OP_REAL(real_pminub)},
    {"pmaxub", OP_BINARY, ref_pmaxub, OP_REAL(real_pmaxub)},
    {"pminsw", OP_BINARY, ref_pminsw, OP_REAL(real_pminsw)},
    {"pmaxsw", OP_BINARY, ref_pmaxsw, OP_REAL(real_pmaxsw)},
    {"pavgb", OP_BINARY, ref_pavgb, OP_REAL(real_pavgb)},
    {"pavgw", OP_BINARY, ref_pavgw, OP_REAL(real_pavgw)},
    {"psadbw", OP_BINARY, ref_psadbw, OP_REAL(real_psadbw)},
    {"pmovmskb", OP_UNARY, ref_pmovmskb, OP_REAL(real_pmovmskb)},
};
#define SSE2_OP_COUNT (sizeof sse2_ops / sizeof sse2_ops[0])

static const struct op_entry *find_op(const char *name)
{
    size_t i;

    for (i = 0; i < SSE2_OP_COUNT; i++)
        if (!strcmp(sse2_ops[i].name, name))
            return &sse2_ops[i];
    return NULL;
}

/* ---- reporting and checksum bookkeeping ---------------------------------- */

static uint64_t g_rng = RNG_SEED;
static uint64_t g_op_checksum;
static uint64_t g_op_cases;
static uint64_t g_family_checksum = FNV_OFFSET;
static uint64_t g_family_cases;
static int g_fail_count;

#define RANDOM_CASES_PER_OP 200u

static void dump_v128(char *buf, size_t n, const v128 *v)
{
    unsigned i;

    for (i = 0; i < 16; i++)
        snprintf(buf + (size_t)i * 2, n - (size_t)i * 2, "%02x", v->b[i]);
}

#if ALLOY_HAVE_X86_INTRINSICS
static void report_mismatch(const char *op, const v128 *a, const v128 *b, const v128 *ref_out,
                            const v128 *real_out)
{
    char abuf[40], bbuf[40], refbuf[40], realbuf[40];

    dump_v128(abuf, sizeof abuf, a);
    dump_v128(bbuf, sizeof bbuf, b);
    dump_v128(refbuf, sizeof refbuf, ref_out);
    dump_v128(realbuf, sizeof realbuf, real_out);
    printf("FAIL %-10s a=%s b=%s reference=%s real=%s\n", op, abuf, bbuf, refbuf, realbuf);
}

static void report_shuffle_mismatch(const char *op, const v128 *a, uint8_t imm, const v128 *ref_out,
                                    const v128 *real_out)
{
    char abuf[40], refbuf[40], realbuf[40];

    dump_v128(abuf, sizeof abuf, a);
    dump_v128(refbuf, sizeof refbuf, ref_out);
    dump_v128(realbuf, sizeof realbuf, real_out);
    printf("FAIL %-10s a=%s imm=0x%02x reference=%s real=%s\n", op, abuf, imm, refbuf, realbuf);
}
#endif

/* ---- hand-computed vectors (Milestone 1's native-side mutation control) --
 * These are not generated by anything in this file - they are arithmetic
 * done by hand in this comment and checked against what ref_*() computes, so
 * a corrupted reference is caught even on a host with no real SSE2 to compare
 * against. Each note below is the arithmetic a reader can re-check by hand. */

struct hand_vector
{
    const char *op_name;
    v128 a, b, expected;
    const char *note;
};
#define HAND_VECTOR_COUNT 5
static struct hand_vector hand_vectors[HAND_VECTOR_COUNT];

static void build_hand_vectors(void)
{
    struct hand_vector *h;

    h = &hand_vectors[0];
    h->op_name = "paddb";
    make_all(&h->a, 0xFF);
    make_all(&h->b, 0x01);
    make_all(&h->expected, 0x00);
    h->note = "0xff + 0x01 wraps to 0x00 in every byte lane";

    h = &hand_vectors[1];
    h->op_name = "paddsb";
    make_all(&h->a, 0x7F);
    make_all(&h->b, 0x01);
    make_all(&h->expected, 0x7F);
    h->note = "127 + 1 saturates to 127 (0x7f); signed bytes never wrap to -128 here";

    h = &hand_vectors[2];
    h->op_name = "psubusb";
    make_all(&h->a, 0x01);
    make_all(&h->b, 0x02);
    make_all(&h->expected, 0x00);
    h->note = "1 - 2 saturates to 0; unsigned bytes never go negative";

    h = &hand_vectors[3];
    h->op_name = "psllw";
    memset(&h->a, 0, sizeof h->a);
    h->a.w[0] = 1;
    h->a.w[1] = 2;
    h->a.w[2] = 0x8000;
    h->a.w[3] = 0xFFFF;
    memset(&h->b, 0, sizeof h->b);
    h->b.q[0] = 1;
    memset(&h->expected, 0, sizeof h->expected);
    h->expected.w[0] = 2;
    h->expected.w[1] = 4;
    h->expected.w[2] = 0x0000; /* 0x8000 << 1 == 0x10000, truncated to 16 bits is 0 */
    h->expected.w[3] = 0xFFFE; /* 0xffff << 1 == 0x1fffe, truncated is 0xfffe */
    h->note = "left shift by 1 truncates to 16 bits per lane";

    h = &hand_vectors[4];
    h->op_name = "psadbw";
    memset(&h->a, 0, sizeof h->a);
    memset(&h->b, 0, sizeof h->b);
    memset(h->a.b, 5, 8); /* low half: a = {5,5,5,5,5,5,5,5} */
    h->b.b[0] = 1;
    h->b.b[1] = 2;
    h->b.b[2] = 3;
    h->b.b[3] = 4;
    h->b.b[4] = 5;
    h->b.b[5] = 6;
    h->b.b[6] = 7;
    h->b.b[7] = 8;
    memset(&h->expected, 0, sizeof h->expected);
    h->expected.q[0] = 16; /* |5-1|+|5-2|+|5-3|+|5-4|+0+|5-6|+|5-7|+|5-8| = 4+3+2+1+0+1+2+3 */
    h->expected.q[1] = 0;  /* both halves all-zero vs all-zero */
    h->note = "sum of |5-1..8| in the low lane = 16; the all-zero high half sums to 0";
}

struct shuffle_hand_vector
{
    const char *op_name;
    v128 a, expected;
    uint8_t imm;
    const char *note;
};
#define SHUFFLE_HAND_VECTOR_COUNT 1
static struct shuffle_hand_vector shuffle_hand_vectors[SHUFFLE_HAND_VECTOR_COUNT];

static void build_shuffle_hand_vectors(void)
{
    struct shuffle_hand_vector *h = &shuffle_hand_vectors[0];

    h->op_name = "pshufd";
    memset(&h->a, 0, sizeof h->a);
    h->a.d[0] = 1;
    h->a.d[1] = 2;
    h->a.d[2] = 3;
    h->a.d[3] = 4;
    h->imm = 0x1B;
    memset(&h->expected, 0, sizeof h->expected);
    h->expected.d[0] = 4;
    h->expected.d[1] = 3;
    h->expected.d[2] = 2;
    h->expected.d[3] = 1;
    h->note = "imm 0x1b selects fields (3,2,1,0): a full reversal of the four dwords";
}

static void run_hand_vectors(void)
{
    size_t i;

    build_hand_vectors();
    for (i = 0; i < HAND_VECTOR_COUNT; i++)
    {
        const struct hand_vector *h = &hand_vectors[i];
        const struct op_entry *op = find_op(h->op_name);
        v128 got;

        if (!op)
        {
            printf("FAIL hand-vector %s: op not found in table\n", h->op_name);
            g_fail_count++;
            continue;
        }
        memset(&got, 0, sizeof got);
        op->reference(&h->a, &h->b, &got);
        if (memcmp(&got, &h->expected, sizeof got) != 0)
        {
            char gotbuf[40], expbuf[40];

            dump_v128(gotbuf, sizeof gotbuf, &got);
            dump_v128(expbuf, sizeof expbuf, &h->expected);
            printf("FAIL hand-vector %-10s expected=%s got=%s (%s)\n", h->op_name, expbuf, gotbuf,
                   h->note);
            g_fail_count++;
        }
        else
            printf("  hand-vector %-10s ok (%s)\n", h->op_name, h->note);
    }

    build_shuffle_hand_vectors();
    for (i = 0; i < SHUFFLE_HAND_VECTOR_COUNT; i++)
    {
        const struct shuffle_hand_vector *h = &shuffle_hand_vectors[i];
        v128 got;

        memset(&got, 0, sizeof got);
        shuffle_epi32_ref(&h->a, h->imm, &got); /* this corpus's one shuffle hand vector */
        if (memcmp(&got, &h->expected, sizeof got) != 0)
        {
            char gotbuf[40], expbuf[40];

            dump_v128(gotbuf, sizeof gotbuf, &got);
            dump_v128(expbuf, sizeof expbuf, &h->expected);
            printf("FAIL hand-vector %-10s expected=%s got=%s (%s)\n", h->op_name, expbuf, gotbuf,
                   h->note);
            g_fail_count++;
        }
        else
            printf("  hand-vector %-10s ok (%s)\n", h->op_name, h->note);
    }
}

/* ---- per-op and per-family drivers ---------------------------------------- */

static void run_case(const struct op_entry *op, const v128 *a, const v128 *b)
{
    v128 ref_out;

    memset(&ref_out, 0, sizeof ref_out);
    op->reference(a, b, &ref_out);
#if ALLOY_HAVE_X86_INTRINSICS
    {
        v128 real_out;

        memset(&real_out, 0, sizeof real_out);
        op->real(a, b, &real_out);
        if (memcmp(&ref_out, &real_out, sizeof ref_out) != 0)
        {
            report_mismatch(op->name, a, b, &ref_out, &real_out);
            g_fail_count++;
        }
    }
#endif
    fold_v128(&g_op_checksum, &ref_out);
    fold_v128(&g_family_checksum, &ref_out);
    g_op_cases++;
    g_family_cases++;
}

static void run_op_family(const struct op_entry *op)
{
    unsigned i, j;

    g_op_checksum = FNV_OFFSET;
    g_op_cases = 0;

    switch (op->kind)
    {
    case OP_BINARY:
        for (i = 0; i < EDGE_COUNT; i++)
            for (j = 0; j < EDGE_COUNT; j++)
                run_case(op, &edge_patterns[i], &edge_patterns[j]);
        for (i = 0; i < RANDOM_CASES_PER_OP; i++)
        {
            v128 a, b;

            random_v128(&g_rng, &a);
            random_v128(&g_rng, &b);
            run_case(op, &a, &b);
        }
        break;

    case OP_SHIFT:
        for (i = 0; i < EDGE_COUNT; i++)
            for (j = 0; j < COUNT_VALUES_COUNT; j++)
            {
                v128 count;

                memset(&count, 0, sizeof count);
                count.q[0] = count_values[j];
                run_case(op, &edge_patterns[i], &count);
            }
        for (i = 0; i < RANDOM_CASES_PER_OP; i++)
        {
            v128 a, count;

            random_v128(&g_rng, &a);
            memset(&count, 0, sizeof count);
            count.q[0] = xorshift64(&g_rng) % 80;
            run_case(op, &a, &count);
        }
        break;

    case OP_UNARY:
        for (i = 0; i < EDGE_COUNT; i++)
        {
            v128 dummy;

            memset(&dummy, 0, sizeof dummy);
            run_case(op, &edge_patterns[i], &dummy);
        }
        for (i = 0; i < RANDOM_CASES_PER_OP; i++)
        {
            v128 a, dummy;

            random_v128(&g_rng, &a);
            memset(&dummy, 0, sizeof dummy);
            run_case(op, &a, &dummy);
        }
        break;
    }

    printf("  %-12s %5llu cases  checksum=%016llx\n", op->name, (unsigned long long)g_op_cases,
           (unsigned long long)g_op_checksum);
}

typedef void (*shuffle_ref_fn)(const v128 *, uint8_t, v128 *);
#if ALLOY_HAVE_X86_INTRINSICS
typedef void (*shuffle_real_fn)(const v128 *, uint8_t, v128 *);
#endif

static void run_shuffle_case(const char *name, const v128 *a, uint8_t imm, shuffle_ref_fn reference
#if ALLOY_HAVE_X86_INTRINSICS
                             ,
                             shuffle_real_fn real
#endif
)
{
    v128 ref_out;

    memset(&ref_out, 0, sizeof ref_out);
    reference(a, imm, &ref_out);
#if ALLOY_HAVE_X86_INTRINSICS
    {
        v128 real_out;

        memset(&real_out, 0, sizeof real_out);
        real(a, imm, &real_out);
        if (memcmp(&ref_out, &real_out, sizeof ref_out) != 0)
        {
            report_shuffle_mismatch(name, a, imm, &ref_out, &real_out);
            g_fail_count++;
        }
    }
#else
    (void)name;
#endif
    fold_v128(&g_op_checksum, &ref_out);
    fold_v128(&g_family_checksum, &ref_out);
    g_op_cases++;
    g_family_cases++;
}

static void run_shuffle_family(const char *name, const uint8_t *imms, size_t n_imms,
                               shuffle_ref_fn reference
#if ALLOY_HAVE_X86_INTRINSICS
                               ,
                               shuffle_real_fn real
#endif
)
{
    size_t i, k;

    g_op_checksum = FNV_OFFSET;
    g_op_cases = 0;

    for (i = 0; i < EDGE_COUNT; i++)
        for (k = 0; k < n_imms; k++)
            run_shuffle_case(name, &edge_patterns[i], imms[k], reference
#if ALLOY_HAVE_X86_INTRINSICS
                             ,
                             real
#endif
            );
    for (i = 0; i < RANDOM_CASES_PER_OP; i++)
    {
        v128 a;
        size_t k2;

        random_v128(&g_rng, &a);
        k2 = (size_t)(xorshift64(&g_rng) % n_imms);
        run_shuffle_case(name, &a, imms[k2], reference
#if ALLOY_HAVE_X86_INTRINSICS
                         ,
                         real
#endif
        );
    }

    printf("  %-12s %5llu cases  checksum=%016llx\n", name, (unsigned long long)g_op_cases,
           (unsigned long long)g_op_checksum);
}

int main(void)
{
    size_t i;

    setvbuf(stdout, NULL, _IONBF, 0);
    build_tables();

#if ALLOY_HAVE_X86_INTRINSICS
    printf("cpu-001 isa-corpus sse2 [x64 guest: real instruction vs reference, mutate=%s]\n",
           mutate_tag);
#else
    printf("cpu-001 isa-corpus sse2 [native oracle: reference only, mutate=%s]\n", mutate_tag);
#endif

    run_hand_vectors();

    for (i = 0; i < SSE2_OP_COUNT; i++)
        run_op_family(&sse2_ops[i]);

    run_shuffle_family("pshufd", shuffle_imms, SHUFFLE_IMMS_COUNT, shuffle_epi32_ref
#if ALLOY_HAVE_X86_INTRINSICS
                       ,
                       real_shuffle_epi32
#endif
    );
    run_shuffle_family("pshuflw", shuffle_imms, SHUFFLE_IMMS_COUNT, shufflelo_epi16_ref
#if ALLOY_HAVE_X86_INTRINSICS
                       ,
                       real_shufflelo_epi16
#endif
    );
    run_shuffle_family("pshufhi", shuffle_imms, SHUFFLE_IMMS_COUNT, shufflehi_epi16_ref
#if ALLOY_HAVE_X86_INTRINSICS
                       ,
                       real_shufflehi_epi16
#endif
    );

    printf("cpu-001 isa-corpus sse2: cases=%llu failures=%d checksum=%016llx mutate=%s\n",
           (unsigned long long)g_family_cases, g_fail_count, (unsigned long long)g_family_checksum,
           mutate_tag);
    return g_fail_count ? 1 : 0;
}
