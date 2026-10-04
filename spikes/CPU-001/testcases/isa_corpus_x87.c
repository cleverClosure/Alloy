/* x87 extended precision: guest-side self-checks only. Author: Timur Isaev
 * No arm64 floating-point oracle: its long double is binary64, not x87's
 * explicit-integer-bit 80-bit format. Expected values below are exact integer
 * constructions in that format, never a cast through double. */
#include "isa_corpus_common.h"
#if !CORPUS_X86
#error The x87 corpus is an x86 guest self-check, not a native arm64 comparison
#endif

typedef struct __attribute__((packed))
{
    uint64_t significand;
    uint16_t exponent;
} fp80;
_Static_assert(sizeof(fp80) == 10, "x87 memory operands contain exactly 80 bits");
enum
{
    ADD_PRECISION,
    SUB_PRECISION,
    MUL_SCALE,
    DIV_SCALE,
    SQRT_SQUARE,
    ROUND_EVEN,
    ORDER,
    UNORDERED
};
static const char *const names[] = {"fadd-precision", "fsub-precision",  "fmul-scale",
                                    "fdiv-scale",     "fsqrt-square",    "frndint-even",
                                    "fucomi-order",   "fucomi-unordered"};

static fp80 integer80(uint64_t value)
{
    fp80 r = {0, 0};
    if (value == 0)
        return r;
    unsigned high = 0;
    for (unsigned i = 1; i < 64; ++i)
        if (value >> i)
            high = i;
    r.significand = value << (63 - high);
    r.exponent = (uint16_t)(16383 + high);
    return r;
}

static CORPUS_INSTRUCTION fp80 instruction(unsigned op, fp80 a, fp80 b)
{
    fp80 out = {0, 0};
    switch (op)
    {
    case ADD_PRECISION:
        __asm__ volatile("fldt %1; fldt %2; faddp; fstpt %0" : "=m"(out) : "m"(a), "m"(b) : "st");
        break;
    case SUB_PRECISION:
        /* Explicit Intel opcode DE E9 = FSUBP ST(1),ST(0), avoiding the
         * historical reversed spelling of GAS's no-operand FSUBP forms. */
        __asm__ volatile("fldt %1; fldt %2; .byte 0xde,0xe9; fstpt %0"
                         : "=m"(out)
                         : "m"(a), "m"(b)
                         : "st");
        break;
    case MUL_SCALE:
        __asm__ volatile("fldt %1; fldt %2; fmulp; fstpt %0" : "=m"(out) : "m"(a), "m"(b) : "st");
        break;
    case DIV_SCALE:
        /* DE F9 = FDIVP ST(1),ST(0). */
        __asm__ volatile("fldt %1; fldt %2; .byte 0xde,0xf9; fstpt %0"
                         : "=m"(out)
                         : "m"(a), "m"(b)
                         : "st");
        break;
    case SQRT_SQUARE:
        __asm__ volatile("fldt %1; fsqrt; fstpt %0" : "=m"(out) : "m"(a) : "st");
        break;
    case ROUND_EVEN:
        __asm__ volatile("fldt %1; frndint; fstpt %0" : "=m"(out) : "m"(a) : "st");
        break;
    case ORDER:
    case UNORDERED:
    {
        unsigned char cf, zf, pf;
        __asm__ volatile("fldt %[b]; fldt %[a]; fucomip %%st(1), %%st; fstp %%st(0); "
                         "setb %[cf]; sete %[zf]; setp %[pf]"
                         : [cf] "=qm"(cf), [zf] "=qm"(zf), [pf] "=qm"(pf)
                         : [a] "m"(a), [b] "m"(b)
                         : "st", "cc");
        out.significand = cf | (pf << 2) | (zf << 6);
        break;
    }
    default:
        fputs("FAIL unknown x87 instruction\n", stderr);
        exit(2);
    }
    return out;
}

static unsigned failures;
static void check(unsigned op, fp80 a, fp80 b, fp80 expected, fp80 actual, const char *where)
{
    if (expected.significand == actual.significand && expected.exponent == actual.exponent)
        return;
    if (failures < 12)
        printf(
            "FAIL %s %s a=%04x:%016llx b=%04x:%016llx expected=%04x:%016llx actual=%04x:%016llx\n",
            names[op], where, a.exponent, (unsigned long long)a.significand, b.exponent,
            (unsigned long long)b.significand, expected.exponent,
            (unsigned long long)expected.significand, actual.exponent,
            (unsigned long long)actual.significand);
    ++failures;
}

static fp80 expected_value(unsigned op, unsigned index, uint64_t *state, fp80 *a, fp80 *b)
{
    uint64_t random = corpus_random(state);
    fp80 expected = {0, 0};
    uint16_t sign = (uint16_t)(random >> 48) & 0x8000;
    *a = (fp80){UINT64_C(0x8000000000000002) | (random & UINT64_C(0x3ffffffffffffffc)),
                (uint16_t)(16383 | sign)};
    *b = (fp80){UINT64_C(0x8000000000000000), (uint16_t)((16383 - 63) | sign)};
    switch (op)
    {
    case ADD_PRECISION:
        expected = *a;
        ++expected.significand;
        break;
    case SUB_PRECISION:
        expected = *a;
        --expected.significand;
        break;
    case MUL_SCALE:
    case DIV_SCALE:
    {
        static const uint16_t exponents[] = {1, 2, 64, 16319, 16383, 16384, 32765};
        a->exponent = (uint16_t)(exponents[index % 7] | sign);
        *b = (fp80){UINT64_C(0x8000000000000000), 16384};
        expected = *a;
        if (op == MUL_SCALE)
            ++expected.exponent;
        else if ((a->exponent & 0x7fff) == 1)
        {
            expected.significand >>= 1;
            expected.exponent = sign;
        }
        else
            --expected.exponent;
        break;
    }
    case SQRT_SQUARE:
    {
        uint64_t n = (random & 1023) + 1;
        *a = integer80(n * n);
        *b = (fp80){0, 0};
        expected = integer80(n);
        break;
    }
    case ROUND_EVEN:
    {
        uint64_t n = random & 1023;
        *a = integer80(2 * n + 1);
        --a->exponent;
        a->exponent |= sign;
        *b = (fp80){0, 0};
        expected = integer80(n + (n & 1));
        expected.exponent |= sign;
        break;
    }
    case ORDER:
    {
        uint64_t n = (random & 1023) + 1, m = n + index % 3 - 1;
        *a = integer80(n);
        *b = integer80(m);
        expected.significand = n < m ? 1 : n == m ? 64 : 0;
        break;
    }
    case UNORDERED:
        *a = (fp80){UINT64_C(0xc000000000000001) | random, 0x7fff};
        *b = integer80(1);
        expected.significand = 0x45;
        break;
    }
#ifdef ALLOY_CORPUS_MUTATE
    if (op == ADD_PRECISION)
        expected.significand ^= 1;
#endif
    return expected;
}

int main(void)
{
    const unsigned count = sizeof names / sizeof names[0], cases_per_op = 512;
    uint16_t saved_control, control = 0x037f;
    __asm__ volatile("fnstcw %0; fnclex; fldcw %1" : "=m"(saved_control) : "m"(control));
#ifdef ALLOY_CORPUS_MUTATE
    const char *mutation = names[0];
#else
    const char *mutation = "none";
#endif
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("cpu-001 isa-corpus x87 mode=x87-self-check seed=%016llx mutate=%s\n",
           (unsigned long long)CORPUS_SEED, mutation);
    fp80 one = {UINT64_C(0x8000000000000000), 16383};
    fp80 step = {UINT64_C(0x8000000000000000), 16320};
    fp80 literal = {UINT64_C(0x8000000000000001), 16383}, hand_expected = literal;
#ifdef ALLOY_CORPUS_MUTATE
    hand_expected.significand ^= 1;
#endif
    check(ADD_PRECISION, one, step, literal, hand_expected, "hand-vector");
    check(ADD_PRECISION, one, step, literal, instruction(ADD_PRECISION, one, step),
          "precision-boundary");
    uint64_t family_hash = CORPUS_FNV_OFFSET;
    for (unsigned op = 0; op < count; ++op)
    {
        uint64_t state = CORPUS_SEED, hash = CORPUS_FNV_OFFSET;
        for (unsigned i = 0; i < cases_per_op; ++i)
        {
            fp80 a, b, expected = expected_value(op, i, &state, &a, &b);
            check(op, a, b, expected, instruction(op, a, b), "parity");
            corpus_fold(&hash, &expected, 10);
            corpus_fold(&family_hash, &expected, 10);
        }
        printf("op=%s cases=%u checksum=%016llx\n", names[op], cases_per_op,
               (unsigned long long)hash);
    }
    printf("cpu-001 isa-corpus x87: cases=%u failures=%u checksum=%016llx mutate=%s\n",
           count * cases_per_op, failures, (unsigned long long)family_hash, mutation);
    __asm__ volatile("fnclex; fldcw %0" : : "m"(saved_control));
    return failures ? 1 : 0;
}
