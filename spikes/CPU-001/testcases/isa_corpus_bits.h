/* BMI reference parity, both operand widths. Author: Timur Isaev */
#include "isa_corpus_common.h"

enum
{
    ANDN,
    BLSI,
    BLSR,
    BLSMSK,
    BEXTR,
    TZCNT,
    PDEP,
    PEXT,
    BZHI,
    MULX,
    SHLX,
    SHRX,
    SARX,
    RORX
};
typedef struct
{
    const char *name;
    unsigned code, bits;
} bit_op;
#define BOTH(name, code) {name "32", code, 32}, {name "64", code, 64}
#if ALLOY_CORPUS_BMI == 1
#define BIT_FAMILY "bmi1"
static const bit_op ops[] = {BOTH("andn", ANDN),     BOTH("blsi", BLSI),   BOTH("blsr", BLSR),
                             BOTH("blsmsk", BLSMSK), BOTH("bextr", BEXTR), BOTH("tzcnt", TZCNT)};
#else
#define BIT_FAMILY "bmi2"
static const bit_op ops[] = {BOTH("pdep", PDEP), BOTH("pext", PEXT), BOTH("bzhi", BZHI),
                             BOTH("mulx", MULX), BOTH("shlx", SHLX), BOTH("shrx", SHRX),
                             BOTH("sarx", SARX), BOTH("rorx", RORX)};
#endif
#undef BOTH

/* The high half is independently observable for MULX; all other operations
 * leave it zero. Explicit fields avoid native padding in the checksum. */
typedef struct
{
    uint64_t lo, hi;
} bit_result;

static CORPUS_REFERENCE bit_result bit_reference(const bit_op *op, uint64_t a, uint64_t b)
{
    uint64_t mask = op->bits == 64 ? UINT64_MAX : UINT32_MAX;
    unsigned bits = op->bits;
    a &= mask;
    b &= mask;
    bit_result r = {0, 0};
    switch (op->code)
    {
    case ANDN:
        r.lo = ~a & b;
        break;
    case BLSI:
        r.lo = a & (0 - a);
        break;
    case BLSR:
        r.lo = a & (a - 1);
        break;
    case BLSMSK:
        r.lo = a ^ (a - 1);
        break;
    case TZCNT:
        r.lo = bits;
        for (unsigned i = 0; i < bits; ++i)
            if ((a >> i) & 1)
            {
                r.lo = i;
                break;
            }
        break;
    case BEXTR:
    {
        unsigned start = (unsigned)(b & 255), length = (unsigned)((b >> 8) & 255);
        for (unsigned i = 0; i < length && start + i < bits; ++i)
            if ((a >> (start + i)) & 1)
                r.lo |= UINT64_C(1) << i;
        break;
    }
    case PDEP:
    case PEXT:
    {
        unsigned packed = 0;
        for (unsigned i = 0; i < bits; ++i)
            if ((b >> i) & 1)
            {
                unsigned source = op->code == PDEP ? packed : i;
                unsigned target = op->code == PDEP ? i : packed;
                if ((a >> source) & 1)
                    r.lo |= UINT64_C(1) << target;
                ++packed;
            }
        break;
    }
    case BZHI:
    {
        unsigned index = (unsigned)(b & 255);
        r.lo = index >= bits ? a : index == 0 ? 0 : a & ((UINT64_C(1) << index) - 1);
        break;
    }
    case MULX:
    {
        /* Shift/add in two limbs, independent of compiler 128-bit multiply. */
        for (unsigned i = 0; i < bits; ++i)
            if ((b >> i) & 1)
            {
                uint64_t lo = (a << i) & mask;
                uint64_t hi = i == 0 ? 0 : a >> (bits - i);
                uint64_t previous = r.lo;
                r.lo = (r.lo + lo) & mask;
                r.hi = (r.hi + hi + (r.lo < previous)) & mask;
            }
        break;
    }
    case SHLX:
        r.lo = a << (b & (bits - 1));
        break;
    case SHRX:
        r.lo = a >> (b & (bits - 1));
        break;
    case SARX:
    {
        unsigned shift = (unsigned)(b & (bits - 1));
        r.lo = a >> shift;
        if (shift && (a >> (bits - 1)))
            r.lo |= mask << (bits - shift);
        break;
    }
    case RORX:
        r.lo = (a >> 13) | (a << (bits - 13));
        break;
    default:
        fputs("FAIL unknown bit operation\n", stderr);
        exit(2);
    }
    r.lo &= mask;
#ifdef ALLOY_CORPUS_MUTATE
    if (op == &ops[0])
        r.lo ^= 1;
#endif
    return r;
}

#if CORPUS_X86
static CORPUS_INSTRUCTION bit_result instruction(const bit_op *op, uint64_t a, uint64_t b)
{
    bit_result r = {0, 0};
    if (op->bits == 32)
    {
        uint32_t x = (uint32_t)a, y = (uint32_t)b, lo = 0, hi = 0;
        switch (op->code)
        {
#if ALLOY_CORPUS_BMI == 1
        case ANDN:
            lo = _andn_u32(x, y);
            break;
        case BLSI:
            lo = _blsi_u32(x);
            break;
        case BLSR:
            lo = _blsr_u32(x);
            break;
        case BLSMSK:
            lo = _blsmsk_u32(x);
            break;
        case BEXTR:
            lo = _bextr_u32(x, y & 255, (y >> 8) & 255);
            break;
        case TZCNT:
            lo = _tzcnt_u32(x);
            break;
#else
        case PDEP:
            lo = _pdep_u32(x, y);
            break;
        case PEXT:
            lo = _pext_u32(x, y);
            break;
        case BZHI:
            lo = _bzhi_u32(x, y);
            break;
        case MULX:
            __asm__ volatile("mulxl %3, %0, %1" : "=r"(lo), "=r"(hi) : "d"(x), "r"(y));
            break;
        case SHLX:
            __asm__ volatile("shlxl %2, %1, %0" : "=r"(lo) : "r"(x), "r"(y));
            break;
        case SHRX:
            __asm__ volatile("shrxl %2, %1, %0" : "=r"(lo) : "r"(x), "r"(y));
            break;
        case SARX:
            __asm__ volatile("sarxl %2, %1, %0" : "=r"(lo) : "r"(x), "r"(y));
            break;
        case RORX:
            __asm__ volatile("rorxl $13, %1, %0" : "=r"(lo) : "r"(x));
            break;
#endif
        default:
            fputs("FAIL unknown instruction\n", stderr);
            exit(2);
        }
        r.lo = lo;
        r.hi = hi;
    }
    else
        switch (op->code)
        {
#if ALLOY_CORPUS_BMI == 1
        case ANDN:
            r.lo = _andn_u64(a, b);
            break;
        case BLSI:
            r.lo = _blsi_u64(a);
            break;
        case BLSR:
            r.lo = _blsr_u64(a);
            break;
        case BLSMSK:
            r.lo = _blsmsk_u64(a);
            break;
        case BEXTR:
            r.lo = _bextr_u64(a, b & 255, (b >> 8) & 255);
            break;
        case TZCNT:
            r.lo = _tzcnt_u64(a);
            break;
#else
        case PDEP:
            r.lo = _pdep_u64(a, b);
            break;
        case PEXT:
            r.lo = _pext_u64(a, b);
            break;
        case BZHI:
            r.lo = _bzhi_u64(a, (unsigned)b);
            break;
        case MULX:
            __asm__ volatile("mulxq %3, %0, %1" : "=r"(r.lo), "=r"(r.hi) : "d"(a), "r"(b));
            break;
        case SHLX:
            __asm__ volatile("shlxq %2, %1, %0" : "=r"(r.lo) : "r"(a), "r"(b));
            break;
        case SHRX:
            __asm__ volatile("shrxq %2, %1, %0" : "=r"(r.lo) : "r"(a), "r"(b));
            break;
        case SARX:
            __asm__ volatile("sarxq %2, %1, %0" : "=r"(r.lo) : "r"(a), "r"(b));
            break;
        case RORX:
            __asm__ volatile("rorxq $13, %1, %0" : "=r"(r.lo) : "r"(a));
            break;
#endif
        default:
            fputs("FAIL unknown instruction\n", stderr);
            exit(2);
        }
    return r;
}
#endif

static unsigned failures;
static void check(const bit_op *op, uint64_t a, uint64_t b, bit_result expected, bit_result actual,
                  const char *where)
{
    if (expected.lo == actual.lo && expected.hi == actual.hi)
        return;
    if (failures < 12)
        printf("FAIL %s %s a=%016llx b=%016llx expected=%016llx:%016llx actual=%016llx:%016llx\n",
               op->name, where, (unsigned long long)a, (unsigned long long)b,
               (unsigned long long)expected.hi, (unsigned long long)expected.lo,
               (unsigned long long)actual.hi, (unsigned long long)actual.lo);
    ++failures;
}

int main(void)
{
    static const uint64_t edge[] = {0,
                                    1,
                                    2,
                                    3,
                                    15,
                                    16,
                                    31,
                                    32,
                                    33,
                                    63,
                                    64,
                                    65,
                                    255,
                                    256,
                                    257,
                                    UINT64_MAX,
                                    UINT32_MAX,
                                    UINT64_C(0x8000000000000000),
                                    UINT64_C(0x7fffffffffffffff),
                                    UINT64_C(0x80000000),
                                    UINT64_C(0x7fffffff),
                                    UINT64_C(0xaaaaaaaa55555555),
                                    UINT64_C(0x0100),
                                    UINT64_C(0x203f),
                                    UINT64_C(0x4020),
                                    UINT64_C(0x4040),
                                    UINT64_C(0xffff)};
    const unsigned edge_count = sizeof edge / sizeof edge[0];
    const unsigned total = edge_count * edge_count + 2048;
    const unsigned op_count = sizeof ops / sizeof ops[0];
#ifdef ALLOY_CORPUS_MUTATE
    const char *mutation = ops[0].name;
#else
    const char *mutation = "none";
#endif
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("cpu-001 isa-corpus %s mode=%s seed=%016llx mutate=%s\n", BIT_FAMILY,
           CORPUS_X86 ? "instruction-parity" : "reference-only", (unsigned long long)CORPUS_SEED,
           mutation);
#if ALLOY_CORPUS_BMI == 1
    bit_result literal = {0x50, 0};
    check(&ops[0], 0xaa, 0xf0, literal, bit_reference(&ops[0], 0xaa, 0xf0), "hand-vector");
#else
    /* 0b1101 deposited in 0b10101010 -> 0b10100010. */
    bit_result literal = {0xa2, 0};
    check(&ops[0], 0xd, 0xaa, literal, bit_reference(&ops[0], 0xd, 0xaa), "hand-vector");
#endif
    uint64_t family_hash = CORPUS_FNV_OFFSET;
    for (unsigned o = 0; o < op_count; ++o)
    {
        uint64_t state = CORPUS_SEED, hash = CORPUS_FNV_OFFSET;
        for (unsigned i = 0; i < total; ++i)
        {
            uint64_t a = i < edge_count * edge_count ? edge[i / edge_count] : corpus_random(&state);
            uint64_t b = i < edge_count * edge_count ? edge[i % edge_count] : corpus_random(&state);
            bit_result expected = bit_reference(&ops[o], a, b);
#if CORPUS_X86
            check(&ops[o], a, b, expected, instruction(&ops[o], a, b), "parity");
#endif
            corpus_fold(&hash, &expected.lo, 8);
            corpus_fold(&hash, &expected.hi, 8);
            corpus_fold(&family_hash, &expected.lo, 8);
            corpus_fold(&family_hash, &expected.hi, 8);
        }
        printf("op=%s cases=%u checksum=%016llx\n", ops[o].name, total, (unsigned long long)hash);
    }
    printf("cpu-001 isa-corpus %s: cases=%u failures=%u checksum=%016llx mutate=%s\n", BIT_FAMILY,
           total * op_count, failures, (unsigned long long)family_hash, mutation);
    return failures ? 1 : 0;
}
