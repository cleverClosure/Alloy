/* Integer results and architecturally defined condition flags. Author: Timur Isaev */
#include "isa_corpus_common.h"

enum
{
    ADD,
    SUB,
    ADC,
    SBB,
    CMP,
    TEST,
    AND,
    OR,
    XOR,
    INC,
    DEC,
    NEG,
    SHL,
    SHR,
    SAR,
    ROL,
    ROR
};
enum
{
    CF = 1,
    PF = 4,
    AF = 16,
    ZF = 64,
    SF = 128,
    OF = 2048,
    ALL_FLAGS = 2261
};
typedef struct
{
    const char *name;
    unsigned code, bits;
} flag_op;
typedef struct
{
    uint64_t value;
    unsigned flags, mask;
} flag_result;
#define BOTH(name, code) {name "32", code, 32}, {name "64", code, 64}
static const flag_op ops[] = {
    BOTH("add", ADD),   BOTH("sub", SUB), BOTH("adc", ADC), BOTH("sbb", SBB), BOTH("cmp", CMP),
    BOTH("test", TEST), BOTH("and", AND), BOTH("or", OR),   BOTH("xor", XOR), BOTH("inc", INC),
    BOTH("dec", DEC),   BOTH("neg", NEG), BOTH("shl", SHL), BOTH("shr", SHR), BOTH("sar", SAR),
    BOTH("rol", ROL),   BOTH("ror", ROR)};
#undef BOTH

static unsigned parity(uint64_t value)
{
    unsigned ones = 0;
    for (unsigned i = 0; i < 8; ++i)
        ones += (unsigned)((value >> i) & 1);
    return !(ones & 1);
}

static CORPUS_REFERENCE flag_result reference(const flag_op *op, uint64_t a, uint64_t b,
                                              unsigned carry)
{
    unsigned bits = op->bits, code = op->code;
    uint64_t mask = bits == 64 ? UINT64_MAX : UINT32_MAX;
    uint64_t sign = UINT64_C(1) << (bits - 1);
    a &= mask;
    b &= mask;
    flag_result r = {a, PF | ZF | carry, ALL_FLAGS};
    uint64_t left = a, right = b, value;
    unsigned cf = 0, of = 0, af = 0;
    if (code >= SHL)
    {
        unsigned count = (unsigned)b & (bits - 1);
        if (count == 0)
            return r; /* Flags are the explicitly seeded flags. */
        r.mask &= ~AF;
        if (count != 1)
            r.mask &= ~OF;
        if (code == ROL || code == ROR)
        {
            r.mask |= AF; /* Rotates preserve all non-CF/OF flags. */
            r.value = (code == ROL ? (a << count) | (a >> (bits - count))
                                   : (a >> count) | (a << (bits - count))) &
                      mask;
            cf = code == ROL ? (unsigned)(r.value & 1) : (unsigned)(r.value >> (bits - 1));
            of = code == ROL ? ((r.value & sign) != 0) ^ cf
                             : (unsigned)((r.value >> (bits - 1)) ^ (r.value >> (bits - 2))) & 1;
            r.flags = (PF | ZF | cf | (of << 11)) & r.mask;
            return r;
        }
        if (code == SHL)
        {
            value = (a << count) & mask;
            cf = (unsigned)((a >> (bits - count)) & 1);
            of = ((value & sign) != 0) ^ cf;
        }
        else
        {
            value = a >> count;
            cf = (unsigned)((a >> (count - 1)) & 1);
            if (code == SAR && (a & sign))
                value |= mask << (bits - count);
            value &= mask;
            of = code == SHR && (a & sign) != 0;
        }
    }
    else if (code == AND || code == TEST || code == OR || code == XOR)
    {
        value = code == AND || code == TEST ? a & b : code == OR ? a | b : a ^ b;
        r.mask &= ~AF; /* AF is architecturally undefined for logic ops. */
    }
    else
    {
        if (code == INC || code == DEC)
            right = 1;
        if (code == NEG)
        {
            left = 0;
            right = a;
        }
        unsigned cin = code == ADC || code == SBB ? carry : 0;
        int subtract = code == SUB || code == SBB || code == CMP || code == DEC || code == NEG;
        if (subtract)
        {
            value = (left - right - cin) & mask;
            cf = left < right || (cin && left == right);
            of = ((left ^ right) & (left ^ value) & sign) != 0;
        }
        else
        {
            uint64_t first = (left + right) & mask;
            value = (first + cin) & mask;
            cf = first < left || value < first;
            of = ((~(left ^ right)) & (left ^ value) & sign) != 0;
        }
        af = ((left ^ right ^ value) & 16) != 0;
        if (code == INC || code == DEC)
            cf = carry;
    }
    r.value = code == CMP || code == TEST ? a : value;
    r.flags = (cf | (parity(value) << 2) | (af << 4) | ((value == 0) << 6) |
               (((value & sign) != 0) << 7) | (of << 11)) &
              r.mask;
#ifdef ALLOY_CORPUS_MUTATE
    if (op == &ops[0])
        r.flags ^= CF;
#endif
    return r;
}

#if CORPUS_X86
static CORPUS_INSTRUCTION flag_result instruction(const flag_op *op, uint64_t a, uint64_t b,
                                                  unsigned carry, unsigned mask)
{
    uint64_t value = a, flags = UINT64_C(0x4600) | ((uint64_t)carry << 8);
    unsigned char overflow;
    /* TEST clears OF, then SAHF establishes PF=ZF=1, SF=AF=0 and the chosen
     * carry. LAHF + SETO avoid push/pop writes into Darwin's red zone. */
#define EXEC(body)                                                                                 \
    __asm__ volatile("testl %%eax, %%eax; sahf; " body "; lahf; seto %[overflow]"                  \
                     : [value] "+r"(value), [flags] "+&a"(flags), [overflow] "=qm"(overflow)       \
                     : [right] "r"(b), [count] "c"(b)                                              \
                     : "cc")
#define BINARY(code, name)                                                                         \
    case code:                                                                                     \
        if (op->bits == 32)                                                                        \
        {                                                                                          \
            EXEC(name "l %k[right], %k[value]");                                                   \
        }                                                                                          \
        else                                                                                       \
        {                                                                                          \
            EXEC(name "q %[right], %[value]");                                                     \
        }                                                                                          \
        break
#define UNARY(code, name)                                                                          \
    case code:                                                                                     \
        if (op->bits == 32)                                                                        \
        {                                                                                          \
            EXEC(name "l %k[value]");                                                              \
        }                                                                                          \
        else                                                                                       \
        {                                                                                          \
            EXEC(name "q %[value]");                                                               \
        }                                                                                          \
        break
#define SHIFT(code, name)                                                                          \
    case code:                                                                                     \
        if (op->bits == 32)                                                                        \
        {                                                                                          \
            EXEC(name "l %%cl, %k[value]");                                                        \
        }                                                                                          \
        else                                                                                       \
        {                                                                                          \
            EXEC(name "q %%cl, %[value]");                                                         \
        }                                                                                          \
        break
    switch (op->code)
    {
        BINARY(ADD, "add");
        BINARY(SUB, "sub");
        BINARY(ADC, "adc");
        BINARY(SBB, "sbb");
        BINARY(CMP, "cmp");
        BINARY(TEST, "test");
        BINARY(AND, "and");
        BINARY(OR, "or");
        BINARY(XOR, "xor");
        UNARY(INC, "inc");
        UNARY(DEC, "dec");
        UNARY(NEG, "neg");
        SHIFT(SHL, "shl");
        SHIFT(SHR, "shr");
        SHIFT(SAR, "sar");
        SHIFT(ROL, "rol");
        SHIFT(ROR, "ror");
    default:
        fputs("FAIL unknown flags instruction\n", stderr);
        exit(2);
    }
#undef EXEC
#undef BINARY
#undef UNARY
#undef SHIFT
    flag_result result = {op->bits == 32 ? (uint32_t)value : value,
                          (unsigned)((flags >> 8) | ((uint64_t)overflow << 11)) & mask, mask};
    return result;
}
#endif

static unsigned failures;
static void check(const flag_op *op, uint64_t a, uint64_t b, unsigned carry, flag_result expected,
                  flag_result actual, const char *where)
{
    if (expected.value == actual.value && expected.flags == actual.flags)
        return;
    if (failures < 12)
        printf("FAIL %s %s a=%016llx b=%016llx carry=%u mask=%03x expected=%016llx/%03x "
               "actual=%016llx/%03x\n",
               op->name, where, (unsigned long long)a, (unsigned long long)b, carry, expected.mask,
               (unsigned long long)expected.value, expected.flags, (unsigned long long)actual.value,
               actual.flags);
    ++failures;
}

int main(void)
{
    static const uint64_t edge[] = {0,
                                    1,
                                    2,
                                    3,
                                    7,
                                    8,
                                    15,
                                    16,
                                    31,
                                    32,
                                    33,
                                    63,
                                    64,
                                    65,
                                    UINT32_MAX,
                                    UINT64_MAX,
                                    UINT64_C(0x7fffffff),
                                    UINT64_C(0x80000000),
                                    UINT64_C(0x7fffffffffffffff),
                                    UINT64_C(0x8000000000000000),
                                    UINT64_C(0xaaaaaaaa55555555)};
    const unsigned edges = sizeof edge / sizeof edge[0], total = 2 * edges * edges + 2048;
#ifdef ALLOY_CORPUS_MUTATE
    const char *mutation = ops[0].name;
#else
    const char *mutation = "none";
#endif
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("cpu-001 isa-corpus flags mode=%s seed=%016llx mutate=%s\n",
           CORPUS_X86 ? "instruction-parity" : "reference-only", (unsigned long long)CORPUS_SEED,
           mutation);
    flag_result literal = {0, CF | PF | AF | ZF, ALL_FLAGS};
    check(&ops[0], UINT32_MAX, 1, 0, literal, reference(&ops[0], UINT32_MAX, 1, 0), "hand-vector");
    /* A distinct positive OF case and an all-clear case prove the individual
     * condition bits, rather than trusting a zero because nothing fired. */
    literal = (flag_result){UINT32_C(0x80000000), OF | SF | AF | PF, ALL_FLAGS};
    check(&ops[0], UINT32_C(0x7fffffff), 1, 0, literal,
          reference(&ops[0], UINT32_C(0x7fffffff), 1, 0), "hand-vector");
    literal = (flag_result){2, 0, ALL_FLAGS};
    check(&ops[0], 1, 1, 0, literal, reference(&ops[0], 1, 1, 0), "hand-vector");
    uint64_t family_hash = CORPUS_FNV_OFFSET;
    for (unsigned o = 0; o < sizeof ops / sizeof ops[0]; ++o)
    {
        uint64_t state = CORPUS_SEED, hash = CORPUS_FNV_OFFSET;
        for (unsigned i = 0; i < total; ++i)
        {
            uint64_t a = i < 2 * edges * edges ? edge[(i / 2) / edges] : corpus_random(&state);
            uint64_t b = i < 2 * edges * edges ? edge[(i / 2) % edges] : corpus_random(&state);
            unsigned carry = i & 1;
            flag_result expected = reference(&ops[o], a, b, carry);
#if CORPUS_X86
            check(&ops[o], a, b, carry, expected, instruction(&ops[o], a, b, carry, expected.mask),
                  "parity");
#endif
            corpus_fold(&hash, &expected.value, 8);
            corpus_fold(&hash, &expected.flags, 4);
            corpus_fold(&hash, &expected.mask, 4);
            corpus_fold(&family_hash, &expected.value, 8);
            corpus_fold(&family_hash, &expected.flags, 4);
            corpus_fold(&family_hash, &expected.mask, 4);
        }
        printf("op=%s cases=%u checksum=%016llx\n", ops[o].name, total, (unsigned long long)hash);
    }
    printf("cpu-001 isa-corpus flags: cases=%u failures=%u checksum=%016llx mutate=%s\n",
           total * (unsigned)(sizeof ops / sizeof ops[0]), failures,
           (unsigned long long)family_hash, mutation);
    return failures ? 1 : 0;
}
