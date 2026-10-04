/* Vector-family corpus implementation. Author: Timur Isaev */
#include "isa_corpus_common.h"
#include <math.h>

enum
{
    ADDPS,
    SUBPS,
    MULPS,
    DIVPS,
    SQRTPS,
    MINPS,
    MAXPS,
    AND,
    ANDN,
    OR,
    XOR,
    EQPS,
    LTPS,
    UNORDPS,
    SHUFPS,
    UNPCKLPS,
    UNPCKHPS,
    ADDSUBPS,
    HADDPS,
    HSUBPS,
    MOVSLDUP,
    MOVSHDUP,
    MOVDDUP,
    ADDPD,
    SUBPD,
    MULPD,
    DIVPD,
    MINPD,
    MAXPD,
    ADDSUBPD,
    HADDPD,
    HSUBPD,
    PSHUFB,
    PABSB,
    PABSW,
    PABSD,
    PSIGNB,
    PSIGNW,
    PSIGND,
    PHADDW,
    PHADDD,
    PHSUBW,
    PHSUBD,
    PHADDSW,
    PHSUBSW,
    PMADDUBSW,
    PMULHRSW,
    PALIGNR,
    PMULLD,
    PMULDQ,
    PMINSB,
    PMINSD,
    PMINUW,
    PMINUD,
    PMAXSB,
    PMAXSD,
    PMAXUW,
    PMAXUD,
    PCMPEQQ,
    PBLENDVB,
    BLENDPS,
    PTEST,
    PACKUSDW,
    ROUNDPS,
    DPPS,
    PCMPGTQ,
    CRC32B,
    CRC32W,
    CRC32D,
    CRC32Q,
    PCMPESTRM_ANY,
    PCMPESTRM_EACH,
    BLENDVPS,
    PERM2F128,
    PADDB,
    PADDW,
    PADDD,
    PADDQ,
    PSUBB,
    PSUBD,
    PSUBQ,
    PCMPEQB,
    PCMPEQD,
    PCMPGTD,
    PSLLVD,
    PSRLVD,
    PSRAVD,
    PERMD
};

/* Result 19's published histogram emphasizes ordinary data/compare/integer
 * forms, not measured SIMD execution frequencies. Spend four times the random
 * budget on integer arithmetic/comparisons as on floating-point arithmetic. */
#define I(name, code) {name, code, CORPUS_WIDTH, 0, 1024}
#define F(name, code) {name, code, CORPUS_WIDTH, 32, 256}
#define D(name, code) {name, code, CORPUS_WIDTH, 64, 256}
#define B(name, code) {name, code, CORPUS_WIDTH, 0, 512}
#if ALLOY_CORPUS_FAMILY >= 6
#define CORPUS_WIDTH 32
#else
#define CORPUS_WIDTH 16
#endif

#if ALLOY_CORPUS_FAMILY == 1
#define CORPUS_FAMILY "sse"
static const corpus_op operations[] = {
    F("addps", ADDPS),       F("subps", SUBPS),        F("mulps", MULPS),
    F("divps", DIVPS),       F("sqrtps", SQRTPS),      B("minps", MINPS),
    B("maxps", MAXPS),       B("andps", AND),          B("andnps", ANDN),
    B("orps", OR),           B("xorps", XOR),          B("cmpeqps", EQPS),
    B("cmpltps", LTPS),      B("cmpunordps", UNORDPS), B("shufps", SHUFPS),
    B("unpcklps", UNPCKLPS), B("unpckhps", UNPCKHPS)};
#elif ALLOY_CORPUS_FAMILY == 2
#define CORPUS_FAMILY "sse3"
static const corpus_op operations[] = {
    F("addsubps", ADDSUBPS), F("haddps", HADDPS),     F("hsubps", HSUBPS),
    B("movsldup", MOVSLDUP), B("movshdup", MOVSHDUP), B("movddup", MOVDDUP),
    D("addsubpd", ADDSUBPD), D("haddpd", HADDPD),     D("hsubpd", HSUBPD)};
#elif ALLOY_CORPUS_FAMILY == 3
#define CORPUS_FAMILY "ssse3"
static const corpus_op operations[] = {
    B("pshufb", PSHUFB),    I("pabsb", PABSB),         I("pabsw", PABSW),
    I("pabsd", PABSD),      I("psignb", PSIGNB),       I("psignw", PSIGNW),
    I("psignd", PSIGND),    I("phaddw", PHADDW),       I("phaddd", PHADDD),
    I("phsubw", PHSUBW),    I("phsubd", PHSUBD),       I("phaddsw", PHADDSW),
    I("phsubsw", PHSUBSW),  I("pmaddubsw", PMADDUBSW), I("pmulhrsw", PMULHRSW),
    B("palignr13", PALIGNR)};
#elif ALLOY_CORPUS_FAMILY == 4
#define CORPUS_FAMILY "sse41"
static const corpus_op operations[] = {
    I("pmulld", PMULLD),    I("pmuldq", PMULDQ), I("pminsb", PMINSB),     I("pminsd", PMINSD),
    I("pminuw", PMINUW),    I("pminud", PMINUD), I("pmaxsb", PMAXSB),     I("pmaxsd", PMAXSD),
    I("pmaxuw", PMAXUW),    I("pmaxud", PMAXUD), I("pcmpeqq", PCMPEQQ),   B("pblendvb", PBLENDVB),
    B("blendps5", BLENDPS), B("ptest", PTEST),   I("packusdw", PACKUSDW), F("roundps", ROUNDPS),
    F("dpps", DPPS)};
#elif ALLOY_CORPUS_FAMILY == 5
#define CORPUS_FAMILY "sse42"
static const corpus_op operations[] = {I("pcmpgtq", PCMPGTQ),
                                       I("crc32b", CRC32B),
                                       I("crc32w", CRC32W),
                                       I("crc32d", CRC32D),
                                       I("crc32q", CRC32Q),
                                       B("pcmpestrm-any", PCMPESTRM_ANY),
                                       B("pcmpestrm-each", PCMPESTRM_EACH)};
#elif ALLOY_CORPUS_FAMILY == 6
#define CORPUS_FAMILY "avx"
static const corpus_op operations[] = {
    F("vaddps", ADDPS),       F("vsubps", SUBPS),         F("vmulps", MULPS),
    F("vdivps", DIVPS),       F("vsqrtps", SQRTPS),       B("vminps", MINPS),
    B("vmaxps", MAXPS),       B("vandps", AND),           B("vandnps", ANDN),
    B("vorps", OR),           B("vxorps", XOR),           B("vcmpeqps", EQPS),
    B("vcmpltps", LTPS),      B("vcmpunordps", UNORDPS),  B("vshufps", SHUFPS),
    B("vunpcklps", UNPCKLPS), B("vunpckhps", UNPCKHPS),   F("vhaddps", HADDPS),
    B("vblendvps", BLENDVPS), B("vperm2f128", PERM2F128), D("vaddpd", ADDPD),
    D("vsubpd", SUBPD),       D("vmulpd", MULPD),         D("vdivpd", DIVPD),
    B("vminpd", MINPD),       B("vmaxpd", MAXPD)};
#elif ALLOY_CORPUS_FAMILY == 7
#define CORPUS_FAMILY "avx2"
static const corpus_op operations[] = {
    I("vpaddd", PADDD),      I("vpaddb", PADDB),         I("vpaddw", PADDW),
    I("vpaddq", PADDQ),      I("vpsubb", PSUBB),         I("vpsubd", PSUBD),
    I("vpsubq", PSUBQ),      I("vpcmpeqb", PCMPEQB),     I("vpcmpeqd", PCMPEQD),
    I("vpcmpeqq", PCMPEQQ),  I("vpcmpgtd", PCMPGTD),     I("vpcmpgtq", PCMPGTQ),
    I("vpmulld", PMULLD),    I("vpmuldq", PMULDQ),       B("vpshufb", PSHUFB),
    I("vpsllvd", PSLLVD),    I("vpsrlvd", PSRLVD),       I("vpsravd", PSRAVD),
    B("vpermd", PERMD),      I("vpmaddubsw", PMADDUBSW), I("vpabsd", PABSD),
    B("vpblendvb", PBLENDVB)};
#else
#error Unknown ALLOY_CORPUS_FAMILY
#endif
#undef I
#undef F
#undef D
#undef B

static CORPUS_REFERENCE void reference(const corpus_op *op, const corpus_vec *a,
                                       const corpus_vec *b, corpus_vec *r)
{
    unsigned n = op->width, code = op->code;
    memset(r, 0, sizeof *r);
    switch (code)
    {
    case ADDPS:
    case SUBPS:
    case MULPS:
    case DIVPS:
    case SQRTPS:
    case ROUNDPS:
        for (unsigned i = 0; i < n / 4; ++i)
        {
            volatile float x = a->f[i], y = b->f[i], z;
            if (code == ADDPS)
                z = x + y;
            else if (code == SUBPS)
                z = x - y;
            else if (code == MULPS)
                z = x * y;
            else if (code == DIVPS)
                z = x / y;
            else if (code == SQRTPS)
                z = sqrtf(x);
            else
                z = nearbyintf(x);
            r->f[i] = z;
        }
        break;
    case MINPS:
    case MAXPS:
    case EQPS:
    case LTPS:
    case UNORDPS:
        for (unsigned i = 0; i < n / 4; ++i)
        {
            int unordered = corpus_nan32(a->d[i]) || corpus_nan32(b->d[i]);
            if (code == MINPS || code == MAXPS)
                r->d[i] = !unordered && (code == MINPS ? a->f[i] < b->f[i] : a->f[i] > b->f[i])
                              ? a->d[i]
                              : b->d[i];
            else
                r->d[i] = (code == UNORDPS ? unordered
                                           : !unordered && (code == EQPS ? a->f[i] == b->f[i]
                                                                         : a->f[i] < b->f[i]))
                              ? UINT32_MAX
                              : 0;
        }
        break;
    case ADDPD:
    case SUBPD:
    case MULPD:
    case DIVPD:
    case MINPD:
    case MAXPD:
        for (unsigned i = 0; i < n / 8; ++i)
        {
            volatile double x = a->g[i], y = b->g[i], z;
            if (code == MINPD || code == MAXPD)
                r->q[i] = !corpus_nan64(a->q[i]) && !corpus_nan64(b->q[i]) &&
                                  (code == MINPD ? x < y : x > y)
                              ? a->q[i]
                              : b->q[i];
            else
            {
                if (code == ADDPD)
                    z = x + y;
                else if (code == SUBPD)
                    z = x - y;
                else if (code == MULPD)
                    z = x * y;
                else
                    z = x / y;
                r->g[i] = z;
            }
        }
        break;
    case AND:
    case ANDN:
    case OR:
    case XOR:
        for (unsigned i = 0; i < n; ++i)
            r->b[i] = code == AND    ? a->b[i] & b->b[i]
                      : code == ANDN ? (~a->b[i]) & b->b[i]
                      : code == OR   ? a->b[i] | b->b[i]
                                     : a->b[i] ^ b->b[i];
        break;
    case ADDSUBPS:
        for (unsigned i = 0; i < n / 4; ++i)
            r->f[i] = i & 1 ? a->f[i] + b->f[i] : a->f[i] - b->f[i];
        break;
    case HADDPS:
    case HSUBPS:
        for (unsigned base = 0; base < n / 4; base += 4)
            for (unsigned i = 0; i < 4; ++i)
            {
                const corpus_vec *v = i < 2 ? a : b;
                unsigned j = base + 2 * (i % 2);
                r->f[base + i] = code == HADDPS ? v->f[j] + v->f[j + 1] : v->f[j] - v->f[j + 1];
            }
        break;
    case ADDSUBPD:
    case HADDPD:
    case HSUBPD:
        if (code == ADDSUBPD)
        {
            r->g[0] = a->g[0] - b->g[0];
            r->g[1] = a->g[1] + b->g[1];
        }
        else
        {
            r->g[0] = code == HADDPD ? a->g[0] + a->g[1] : a->g[0] - a->g[1];
            r->g[1] = code == HADDPD ? b->g[0] + b->g[1] : b->g[0] - b->g[1];
        }
        break;
    case SHUFPS:
    case UNPCKLPS:
    case UNPCKHPS:
        for (unsigned base = 0; base < n / 4; base += 4)
            for (unsigned i = 0; i < 4; ++i)
                if (code == SHUFPS)
                    r->d[base + i] = i < 2 ? a->d[base + 3 - i] : b->d[base + 3 - i];
                else
                    r->d[base + i] = (i & 1 ? b : a)->d[base + (code == UNPCKHPS ? 2 : 0) + i / 2];
        break;
    case MOVSLDUP:
    case MOVSHDUP:
        for (unsigned i = 0; i < 4; ++i)
            r->d[i] = a->d[(i & ~1u) + (code == MOVSHDUP)];
        break;
    case MOVDDUP:
        r->q[0] = r->q[1] = a->q[0];
        break;
    case PSHUFB:
        for (unsigned i = 0; i < n; ++i)
            r->b[i] = b->b[i] & 0x80 ? 0 : a->b[(i & ~15u) + (b->b[i] & 15)];
        break;
    case PABSB:
    case PSIGNB:
        for (unsigned i = 0; i < n; ++i)
            r->b[i] = code == PABSB    ? (a->b[i] & 0x80 ? 0u - a->b[i] : a->b[i])
                      : b->b[i] == 0   ? 0
                      : b->b[i] & 0x80 ? 0u - a->b[i]
                                       : a->b[i];
        break;
    case PABSW:
    case PSIGNW:
        for (unsigned i = 0; i < n / 2; ++i)
            r->w[i] = code == PABSW      ? (a->w[i] & 0x8000 ? 0u - a->w[i] : a->w[i])
                      : b->w[i] == 0     ? 0
                      : b->w[i] & 0x8000 ? 0u - a->w[i]
                                         : a->w[i];
        break;
    case PABSD:
    case PSIGND:
        for (unsigned i = 0; i < n / 4; ++i)
            r->d[i] = code == PABSD          ? (a->d[i] & 0x80000000 ? 0u - a->d[i] : a->d[i])
                      : b->d[i] == 0         ? 0
                      : b->d[i] & 0x80000000 ? 0u - a->d[i]
                                             : a->d[i];
        break;
    case PHADDW:
    case PHSUBW:
    case PHADDSW:
    case PHSUBSW:
        for (unsigned i = 0; i < 8; ++i)
        {
            const corpus_vec *v = i < 4 ? a : b;
            unsigned j = (i % 4) * 2;
            int32_t x = (int32_t)corpus_signed(v->w[j], 16),
                    y = (int32_t)corpus_signed(v->w[j + 1], 16);
            int32_t z = code == PHADDW || code == PHADDSW ? x + y : x - y;
            r->w[i] = (uint16_t)(code == PHADDSW || code == PHSUBSW ? corpus_saturate16(z) : z);
        }
        break;
    case PHADDD:
    case PHSUBD:
        for (unsigned i = 0; i < 4; ++i)
        {
            const corpus_vec *v = i < 2 ? a : b;
            unsigned j = (i % 2) * 2;
            r->d[i] = code == PHADDD ? v->d[j] + v->d[j + 1] : v->d[j] - v->d[j + 1];
        }
        break;
    case PMADDUBSW:
        for (unsigned i = 0; i < n / 2; ++i)
            r->w[i] = (uint16_t)corpus_saturate16(
                a->b[2 * i] * (int32_t)corpus_signed(b->b[2 * i], 8) +
                a->b[2 * i + 1] * (int32_t)corpus_signed(b->b[2 * i + 1], 8));
        break;
    case PMULHRSW:
        for (unsigned i = 0; i < n / 2; ++i)
        {
            int32_t product = (int32_t)(corpus_signed(a->w[i], 16) * corpus_signed(b->w[i], 16));
            r->w[i] = (uint16_t)corpus_asr32((uint32_t)(product + 16384), 15);
        }
        break;
    case PALIGNR:
        for (unsigned i = 0; i < 16; ++i)
            r->b[i] = i + 13 < 16 ? b->b[i + 13] : a->b[i - 3];
        break;
    case PMULLD:
        for (unsigned i = 0; i < n / 4; ++i)
            r->d[i] = a->d[i] * b->d[i];
        break;
    case PMULDQ:
        for (unsigned i = 0; i < n / 8; ++i)
            r->q[i] = (uint64_t)(corpus_signed(a->d[2 * i], 32) * corpus_signed(b->d[2 * i], 32));
        break;
    case PMINSB:
    case PMAXSB:
        for (unsigned i = 0; i < n; ++i)
        {
            int less = corpus_signed(a->b[i], 8) < corpus_signed(b->b[i], 8);
            r->b[i] = (code == PMINSB ? less : !less) ? a->b[i] : b->b[i];
        }
        break;
    case PMINUW:
    case PMAXUW:
        for (unsigned i = 0; i < n / 2; ++i)
            r->w[i] = (code == PMINUW ? a->w[i] < b->w[i] : a->w[i] > b->w[i]) ? a->w[i] : b->w[i];
        break;
    case PMINSD:
    case PMAXSD:
    case PMINUD:
    case PMAXUD:
        for (unsigned i = 0; i < n / 4; ++i)
        {
            int less = code == PMINSD || code == PMAXSD
                           ? corpus_signed(a->d[i], 32) < corpus_signed(b->d[i], 32)
                           : a->d[i] < b->d[i];
            r->d[i] = (code == PMINSD || code == PMINUD ? less : !less) ? a->d[i] : b->d[i];
        }
        break;
    case PCMPEQQ:
    case PCMPGTQ:
        for (unsigned i = 0; i < n / 8; ++i)
            r->q[i] = (code == PCMPEQQ ? a->q[i] == b->q[i]
                                       : corpus_signed(a->q[i], 64) > corpus_signed(b->q[i], 64))
                          ? UINT64_MAX
                          : 0;
        break;
    case PBLENDVB:
        /* A third operand is derived, not constant: mask = a XOR b. */
        for (unsigned i = 0; i < n; ++i)
            r->b[i] = (a->b[i] ^ b->b[i]) & 0x80 ? b->b[i] : a->b[i];
        break;
    case BLENDPS:
    case BLENDVPS:
        for (unsigned i = 0; i < n / 4; ++i)
            r->d[i] =
                (code == BLENDPS ? (5u >> i) & 1 : (a->d[i] ^ b->d[i]) >> 31) ? b->d[i] : a->d[i];
        break;
    case PTEST:
    {
        uint8_t both = 0, not_a = 0;
        for (unsigned i = 0; i < n; ++i)
        {
            both |= a->b[i] & b->b[i];
            not_a |= (~a->b[i]) & b->b[i];
        }
        r->d[0] = (both == 0) | ((not_a == 0) << 1);
        break;
    }
    case PACKUSDW:
        for (unsigned i = 0; i < 8; ++i)
        {
            int64_t v = corpus_signed((i < 4 ? a : b)->d[i % 4], 32);
            r->w[i] = (uint16_t)(v < 0 ? 0 : v > 65535 ? 65535 : v);
        }
        break;
    case DPPS:
    {
        volatile float p[4];
        for (unsigned i = 0; i < 4; ++i)
            p[i] = a->f[i] * b->f[i];
        volatile float left = p[0] + p[1], right = p[2] + p[3], result = left + right;
        for (unsigned i = 0; i < 4; ++i)
            r->f[i] = result;
        break;
    }
    case CRC32B:
    case CRC32W:
    case CRC32D:
    case CRC32Q:
    {
        unsigned bytes = 1u << (code - CRC32B);
        uint32_t crc = a->d[0];
        for (unsigned i = 0; i < bytes; ++i)
        {
            crc ^= b->b[i];
            for (unsigned bit = 0; bit < 8; ++bit)
                crc = (crc >> 1) ^ (crc & 1 ? UINT32_C(0x82f63b78) : 0);
        }
        r->d[0] = crc;
        break;
    }
    case PCMPESTRM_ANY:
    case PCMPESTRM_EACH:
        for (unsigned i = 0; i < 16; ++i)
        {
            int match = a->b[i] == b->b[i];
            if (code == PCMPESTRM_ANY)
            {
                match = 0;
                for (unsigned j = 0; j < 16; ++j)
                    match |= a->b[j] == b->b[i];
            }
            r->w[0] |= (uint16_t)(match << i);
        }
        break;
    case PERM2F128:
        memcpy(r->b, a->b + 16, 16);
        memcpy(r->b + 16, b->b, 16);
        break;
    case PADDB:
    case PSUBB:
    case PCMPEQB:
        for (unsigned i = 0; i < n; ++i)
            r->b[i] = (uint8_t)(code == PADDB        ? a->b[i] + b->b[i]
                                : code == PSUBB      ? a->b[i] - b->b[i]
                                : a->b[i] == b->b[i] ? 255
                                                     : 0);
        break;
    case PADDW:
        for (unsigned i = 0; i < n / 2; ++i)
            r->w[i] = (uint16_t)(a->w[i] + b->w[i]);
        break;
    case PADDD:
    case PSUBD:
    case PCMPEQD:
    case PCMPGTD:
        for (unsigned i = 0; i < n / 4; ++i)
            r->d[i] = code == PADDD   ? a->d[i] + b->d[i]
                      : code == PSUBD ? a->d[i] - b->d[i]
                      : (code == PCMPEQD ? a->d[i] == b->d[i]
                                         : corpus_signed(a->d[i], 32) > corpus_signed(b->d[i], 32))
                          ? UINT32_MAX
                          : 0;
        break;
    case PADDQ:
    case PSUBQ:
        for (unsigned i = 0; i < n / 8; ++i)
            r->q[i] = code == PADDQ ? a->q[i] + b->q[i] : a->q[i] - b->q[i];
        break;
    case PSLLVD:
    case PSRLVD:
    case PSRAVD:
        for (unsigned i = 0; i < n / 4; ++i)
            r->d[i] = code == PSRAVD   ? corpus_asr32(a->d[i], b->d[i])
                      : b->d[i] >= 32  ? 0
                      : code == PSLLVD ? a->d[i] << b->d[i]
                                       : a->d[i] >> b->d[i];
        break;
    case PERMD:
        for (unsigned i = 0; i < 8; ++i)
            r->d[i] = a->d[b->d[i] & 7];
        break;
    default:
        fputs("FAIL unknown reference operation\n", stderr);
        exit(2);
    }
#ifdef ALLOY_CORPUS_MUTATE
    if (code == operations[0].code)
        r->b[0] ^= 1;
#endif
}

#if CORPUS_X86
static CORPUS_INSTRUCTION void instruction(const corpus_op *op, const corpus_vec *a,
                                           const corpus_vec *b, corpus_vec *r)
{
    memset(r, 0, sizeof *r);
#if ALLOY_CORPUS_FAMILY <= 5
    __m128i x = _mm_loadu_si128((const __m128i *)a), y = _mm_loadu_si128((const __m128i *)b);
    __m128 xf = _mm_castsi128_ps(x), yf = _mm_castsi128_ps(y);
    __m128d xd = _mm_castsi128_pd(x), yd = _mm_castsi128_pd(y);
    (void)xf;
    (void)yf;
    (void)xd;
    (void)yd;
#define RI(code, expr)                                                                             \
    case code:                                                                                     \
        _mm_storeu_si128((__m128i *)r, (expr));                                                    \
        break
#define RF(code, expr)                                                                             \
    case code:                                                                                     \
        _mm_storeu_ps(r->f, (expr));                                                               \
        break
#define RD(code, expr)                                                                             \
    case code:                                                                                     \
        _mm_storeu_pd(r->g, (expr));                                                               \
        break
#else
    __m256i x = _mm256_loadu_si256((const __m256i *)a), y = _mm256_loadu_si256((const __m256i *)b);
    __m256 xf = _mm256_castsi256_ps(x), yf = _mm256_castsi256_ps(y);
    __m256d xd = _mm256_castsi256_pd(x), yd = _mm256_castsi256_pd(y);
    (void)xf;
    (void)yf;
    (void)xd;
    (void)yd;
#define RI(code, expr)                                                                             \
    case code:                                                                                     \
        _mm256_storeu_si256((__m256i *)r, (expr));                                                 \
        break
#define RF(code, expr)                                                                             \
    case code:                                                                                     \
        _mm256_storeu_ps(r->f, (expr));                                                            \
        break
#define RD(code, expr)                                                                             \
    case code:                                                                                     \
        _mm256_storeu_pd(r->g, (expr));                                                            \
        break
#endif
    switch (op->code)
    {
#if ALLOY_CORPUS_FAMILY == 1
        RF(ADDPS, _mm_add_ps(xf, yf));
        RF(SUBPS, _mm_sub_ps(xf, yf));
        RF(MULPS, _mm_mul_ps(xf, yf));
        RF(DIVPS, _mm_div_ps(xf, yf));
        RF(SQRTPS, _mm_sqrt_ps(xf));
        RF(MINPS, _mm_min_ps(xf, yf));
        RF(MAXPS, _mm_max_ps(xf, yf));
        RF(AND, _mm_and_ps(xf, yf));
        RF(ANDN, _mm_andnot_ps(xf, yf));
        RF(OR, _mm_or_ps(xf, yf));
        RF(XOR, _mm_xor_ps(xf, yf));
        RF(EQPS, _mm_cmpeq_ps(xf, yf));
        RF(LTPS, _mm_cmplt_ps(xf, yf));
        RF(UNORDPS, _mm_cmpunord_ps(xf, yf));
        RF(SHUFPS, _mm_shuffle_ps(xf, yf, 0x1b));
        RF(UNPCKLPS, _mm_unpacklo_ps(xf, yf));
        RF(UNPCKHPS, _mm_unpackhi_ps(xf, yf));
#elif ALLOY_CORPUS_FAMILY == 2
        RF(ADDSUBPS, _mm_addsub_ps(xf, yf));
        RF(HADDPS, _mm_hadd_ps(xf, yf));
        RF(HSUBPS, _mm_hsub_ps(xf, yf));
        RF(MOVSLDUP, _mm_moveldup_ps(xf));
        RF(MOVSHDUP, _mm_movehdup_ps(xf));
        RD(MOVDDUP, _mm_movedup_pd(xd));
        RD(ADDSUBPD, _mm_addsub_pd(xd, yd));
        RD(HADDPD, _mm_hadd_pd(xd, yd));
        RD(HSUBPD, _mm_hsub_pd(xd, yd));
#elif ALLOY_CORPUS_FAMILY == 3
        RI(PSHUFB, _mm_shuffle_epi8(x, y));
        RI(PABSB, _mm_abs_epi8(x));
        RI(PABSW, _mm_abs_epi16(x));
        RI(PABSD, _mm_abs_epi32(x));
        RI(PSIGNB, _mm_sign_epi8(x, y));
        RI(PSIGNW, _mm_sign_epi16(x, y));
        RI(PSIGND, _mm_sign_epi32(x, y));
        RI(PHADDW, _mm_hadd_epi16(x, y));
        RI(PHADDD, _mm_hadd_epi32(x, y));
        RI(PHSUBW, _mm_hsub_epi16(x, y));
        RI(PHSUBD, _mm_hsub_epi32(x, y));
        RI(PHADDSW, _mm_hadds_epi16(x, y));
        RI(PHSUBSW, _mm_hsubs_epi16(x, y));
        RI(PMADDUBSW, _mm_maddubs_epi16(x, y));
        RI(PMULHRSW, _mm_mulhrs_epi16(x, y));
        RI(PALIGNR, _mm_alignr_epi8(x, y, 13));
#elif ALLOY_CORPUS_FAMILY == 4
        RI(PMULLD, _mm_mullo_epi32(x, y));
        RI(PMULDQ, _mm_mul_epi32(x, y));
        RI(PMINSB, _mm_min_epi8(x, y));
        RI(PMINSD, _mm_min_epi32(x, y));
        RI(PMINUW, _mm_min_epu16(x, y));
        RI(PMINUD, _mm_min_epu32(x, y));
        RI(PMAXSB, _mm_max_epi8(x, y));
        RI(PMAXSD, _mm_max_epi32(x, y));
        RI(PMAXUW, _mm_max_epu16(x, y));
        RI(PMAXUD, _mm_max_epu32(x, y));
        RI(PCMPEQQ, _mm_cmpeq_epi64(x, y));
        RI(PBLENDVB, _mm_blendv_epi8(x, y, _mm_xor_si128(x, y)));
    case BLENDPS:
    {
        /* The intrinsic was lowered to PBLENDW by LLVM. This corpus must
         * exercise BLENDPS itself, not just an equivalent bit selection. */
        __m128 result = xf;
        __asm__ volatile("blendps $5, %1, %0" : "+x"(result) : "x"(yf));
        _mm_storeu_ps(r->f, result);
        break;
    }
    case PTEST:
        r->d[0] = _mm_testz_si128(x, y) | (_mm_testc_si128(x, y) << 1);
        break;
        RI(PACKUSDW, _mm_packus_epi32(x, y));
        RF(ROUNDPS, _mm_round_ps(xf, _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC));
        RF(DPPS, _mm_dp_ps(xf, yf, 0xff));
#elif ALLOY_CORPUS_FAMILY == 5
        RI(PCMPGTQ, _mm_cmpgt_epi64(x, y));
    case CRC32B:
        r->d[0] = _mm_crc32_u8(a->d[0], b->b[0]);
        break;
    case CRC32W:
        r->d[0] = _mm_crc32_u16(a->d[0], b->w[0]);
        break;
    case CRC32D:
        r->d[0] = _mm_crc32_u32(a->d[0], b->d[0]);
        break;
    case CRC32Q:
        r->d[0] = (uint32_t)_mm_crc32_u64(a->d[0], b->q[0]);
        break;
        RI(PCMPESTRM_ANY,
           _mm_cmpestrm(x, 16, y, 16, _SIDD_UBYTE_OPS | _SIDD_CMP_EQUAL_ANY | _SIDD_BIT_MASK));
        RI(PCMPESTRM_EACH,
           _mm_cmpestrm(x, 16, y, 16, _SIDD_UBYTE_OPS | _SIDD_CMP_EQUAL_EACH | _SIDD_BIT_MASK));
#elif ALLOY_CORPUS_FAMILY == 6
        RF(ADDPS, _mm256_add_ps(xf, yf));
        RF(SUBPS, _mm256_sub_ps(xf, yf));
        RF(MULPS, _mm256_mul_ps(xf, yf));
        RF(DIVPS, _mm256_div_ps(xf, yf));
        RF(SQRTPS, _mm256_sqrt_ps(xf));
        RF(MINPS, _mm256_min_ps(xf, yf));
        RF(MAXPS, _mm256_max_ps(xf, yf));
        RF(AND, _mm256_and_ps(xf, yf));
        RF(ANDN, _mm256_andnot_ps(xf, yf));
        RF(OR, _mm256_or_ps(xf, yf));
        RF(XOR, _mm256_xor_ps(xf, yf));
        RF(EQPS, _mm256_cmp_ps(xf, yf, _CMP_EQ_OQ));
        RF(LTPS, _mm256_cmp_ps(xf, yf, _CMP_LT_OQ));
        RF(UNORDPS, _mm256_cmp_ps(xf, yf, _CMP_UNORD_Q));
        RF(SHUFPS, _mm256_shuffle_ps(xf, yf, 0x1b));
        RF(UNPCKLPS, _mm256_unpacklo_ps(xf, yf));
        RF(UNPCKHPS, _mm256_unpackhi_ps(xf, yf));
        RF(HADDPS, _mm256_hadd_ps(xf, yf));
        RF(BLENDVPS, _mm256_blendv_ps(xf, yf, _mm256_xor_ps(xf, yf)));
        RF(PERM2F128, _mm256_permute2f128_ps(xf, yf, 0x21));
        RD(ADDPD, _mm256_add_pd(xd, yd));
        RD(SUBPD, _mm256_sub_pd(xd, yd));
        RD(MULPD, _mm256_mul_pd(xd, yd));
        RD(DIVPD, _mm256_div_pd(xd, yd));
        RD(MINPD, _mm256_min_pd(xd, yd));
        RD(MAXPD, _mm256_max_pd(xd, yd));
#elif ALLOY_CORPUS_FAMILY == 7
        RI(PADDD, _mm256_add_epi32(x, y));
        RI(PADDB, _mm256_add_epi8(x, y));
        RI(PADDW, _mm256_add_epi16(x, y));
        RI(PADDQ, _mm256_add_epi64(x, y));
        RI(PSUBB, _mm256_sub_epi8(x, y));
        RI(PSUBD, _mm256_sub_epi32(x, y));
        RI(PSUBQ, _mm256_sub_epi64(x, y));
        RI(PCMPEQB, _mm256_cmpeq_epi8(x, y));
        RI(PCMPEQD, _mm256_cmpeq_epi32(x, y));
        RI(PCMPEQQ, _mm256_cmpeq_epi64(x, y));
        RI(PCMPGTD, _mm256_cmpgt_epi32(x, y));
        RI(PCMPGTQ, _mm256_cmpgt_epi64(x, y));
        RI(PMULLD, _mm256_mullo_epi32(x, y));
        RI(PMULDQ, _mm256_mul_epi32(x, y));
        RI(PSHUFB, _mm256_shuffle_epi8(x, y));
        RI(PSLLVD, _mm256_sllv_epi32(x, y));
        RI(PSRLVD, _mm256_srlv_epi32(x, y));
        RI(PSRAVD, _mm256_srav_epi32(x, y));
        RI(PERMD, _mm256_permutevar8x32_epi32(x, y));
        RI(PMADDUBSW, _mm256_maddubs_epi16(x, y));
        RI(PABSD, _mm256_abs_epi32(x));
        RI(PBLENDVB, _mm256_blendv_epi8(x, y, _mm256_xor_si256(x, y)));
#endif
    default:
        fputs("FAIL unknown instruction operation\n", stderr);
        exit(2);
    }
#undef RI
#undef RF
#undef RD
}
#endif

static unsigned failures;
static void compare(const corpus_op *op, const corpus_vec *a, const corpus_vec *b,
                    const corpus_vec *expected, const corpus_vec *actual, const char *where)
{
    if (memcmp(expected, actual, op->width) == 0)
        return;
    /* Count every failure. Bound only the diagnostic text, not the counter. */
    if (failures < 12)
    {
        printf("FAIL %s %s a=", op->name, where);
        corpus_hex(a, op->width);
        fputs(" b=", stdout);
        corpus_hex(b, op->width);
        fputs(" expected=", stdout);
        corpus_hex(expected, op->width);
        fputs(" actual=", stdout);
        corpus_hex(actual, op->width);
        putchar('\n');
    }
    ++failures;
}

static void run_hand_vector(void)
{
    corpus_vec a = {0}, b = {0}, expected = {0}, actual;
    /* Literal answers are independent of reference(). Every family's first
     * operation has a control that the native build can detect on its own. */
#if ALLOY_CORPUS_FAMILY == 1 || ALLOY_CORPUS_FAMILY == 2 || ALLOY_CORPUS_FAMILY == 6
    for (unsigned i = 0; i < CORPUS_WIDTH / 4; ++i)
    {
        a.f[i] = 1.0f;
        b.f[i] = 2.0f;
        expected.f[i] = ALLOY_CORPUS_FAMILY == 2 && !(i & 1) ? -1.0f : 3.0f;
    }
#elif ALLOY_CORPUS_FAMILY == 3
    for (unsigned i = 0; i < 16; ++i)
    {
        a.b[i] = (uint8_t)i;
        b.b[i] = (uint8_t)(15 - i);
        expected.b[i] = (uint8_t)(15 - i);
    }
    b.b[3] = 0x83;
    expected.b[3] = 0;
#elif ALLOY_CORPUS_FAMILY == 4
    for (unsigned i = 0; i < 4; ++i)
    {
        a.d[i] = 3;
        b.d[i] = 7;
        expected.d[i] = 21;
    }
#elif ALLOY_CORPUS_FAMILY == 5
    a.q[0] = UINT64_MAX;
    b.q[0] = 0;
    expected.q[0] = 0;
    a.q[1] = 0;
    b.q[1] = UINT64_C(0x8000000000000000);
    expected.q[1] = UINT64_MAX;
#elif ALLOY_CORPUS_FAMILY == 7
    for (unsigned i = 0; i < 8; ++i)
    {
        a.d[i] = UINT32_MAX;
        b.d[i] = i + 1;
        expected.d[i] = i;
    }
#endif
    reference(&operations[0], &a, &b, &actual);
    compare(&operations[0], &a, &b, &expected, &actual, "hand-vector");
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (fesetenv(FE_DFL_ENV) != 0 || fesetround(FE_TONEAREST) != 0)
    {
        fputs("FAIL floating-point environment\n", stderr);
        return 2;
    }
#if CORPUS_X86
    /* All exceptions masked; round-to-nearest, DAZ and FTZ disabled. Status
     * bits are not part of this vector-result corpus's claim. */
    _mm_setcsr(0x1f80);
#endif
    const size_t count = sizeof operations / sizeof operations[0];
    if (argc == 2 && strcmp(argv[1], "--list") == 0)
    {
        for (size_t i = 0; i < count; ++i)
            puts(operations[i].name);
        return 0;
    }
    if (argc == 5 && strcmp(argv[1], "--case") == 0)
    {
        for (size_t i = 0; i < count; ++i)
            if (strcmp(argv[2], operations[i].name) == 0)
            {
                corpus_vec a, b, r;
                if (!corpus_parse_hex(argv[3], &a, CORPUS_WIDTH) ||
                    !corpus_parse_hex(argv[4], &b, CORPUS_WIDTH))
                    return 64;
                reference(&operations[i], &a, &b, &r);
                corpus_normalize(&r, &operations[i]);
#if CORPUS_X86
                corpus_vec real;
                instruction(&operations[i], &a, &b, &real);
                corpus_normalize(&real, &operations[i]);
                compare(&operations[i], &a, &b, &r, &real, "literal");
#endif
                corpus_hex(&r, CORPUS_WIDTH);
                putchar('\n');
                return failures ? 1 : 0;
            }
        return 64;
    }
    if (argc != 1)
    {
        fputs("usage: corpus [--list | --case op a-hex b-hex]\n", stderr);
        return 64;
    }
#ifdef ALLOY_CORPUS_MUTATE
    const char *mutation = operations[0].name;
#else
    const char *mutation = "none";
#endif
    printf("cpu-001 isa-corpus %s mode=%s seed=%016llx mutate=%s\n", CORPUS_FAMILY,
           CORPUS_X86 ? "instruction-parity" : "reference-only", (unsigned long long)CORPUS_SEED,
           mutation);
    run_hand_vector();
    uint64_t family_hash = CORPUS_FNV_OFFSET, cases = 0;
    for (size_t o = 0; o < count; ++o)
    {
        const corpus_op *op = &operations[o];
        uint64_t state = CORPUS_SEED, hash = CORPUS_FNV_OFFSET;
        unsigned total = CORPUS_EDGE_COUNT * CORPUS_EDGE_COUNT + op->random_cases;
        for (unsigned i = 0; i < total; ++i)
        {
            corpus_vec a, b, r;
            if (i < CORPUS_EDGE_COUNT * CORPUS_EDGE_COUNT)
            {
                corpus_edge(i / CORPUS_EDGE_COUNT, &a);
                corpus_edge(i % CORPUS_EDGE_COUNT, &b);
            }
            else
                for (unsigned lane = 0; lane < 4; ++lane)
                {
                    a.q[lane] = corpus_random(&state);
                    b.q[lane] = corpus_random(&state);
                }
            reference(op, &a, &b, &r);
            corpus_normalize(&r, op);
#if CORPUS_X86
            corpus_vec real;
            instruction(op, &a, &b, &real);
            corpus_normalize(&real, op);
            compare(op, &a, &b, &r, &real, "parity");
#endif
            corpus_fold(&hash, &r, op->width);
            corpus_fold(&family_hash, &r, op->width);
        }
        printf("op=%s cases=%u checksum=%016llx\n", op->name, total, (unsigned long long)hash);
        cases += total;
    }
    printf("cpu-001 isa-corpus %s: cases=%llu failures=%u checksum=%016llx mutate=%s\n",
           CORPUS_FAMILY, (unsigned long long)cases, failures, (unsigned long long)family_hash,
           mutation);
    return failures ? 1 : 0;
}
