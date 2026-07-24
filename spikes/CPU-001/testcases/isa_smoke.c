/*
 * CPU-001 x64 ISA smoke test.
 * Author: Timur Isaev
 */

#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void cpuid(uint32_t leaf, uint32_t subleaf, uint32_t regs[4])
{
    __asm__ volatile("cpuid"
                     : "=a"(regs[0]), "=b"(regs[1]), "=c"(regs[2]), "=d"(regs[3])
                     : "a"(leaf), "c"(subleaf));
}

static uint64_t xgetbv(uint32_t index)
{
    uint32_t low, high;

    __asm__ volatile(".byte 0x0f, 0x01, 0xd0" : "=a"(low), "=d"(high) : "c"(index));
    return ((uint64_t)high << 32) | low;
}

__attribute__((noinline, optnone)) static uint32_t crc32c_reference(uint32_t crc, uint64_t value)
{
    unsigned int byte, bit;

    for (byte = 0; byte < 8; byte++)
    {
        crc ^= (uint8_t)value;
        value >>= 8;
        for (bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0x82f63b78u & -(int32_t)(crc & 1));
    }
    return crc;
}

__attribute__((noinline, optnone)) static uint64_t pdep_reference(uint64_t value, uint64_t mask)
{
    uint64_t result = 0;
    uint64_t source_bit = 1;

    while (mask)
    {
        uint64_t target_bit = mask & -mask;

        if (value & source_bit)
            result |= target_bit;
        mask &= mask - 1;
        source_bit <<= 1;
    }
    return result;
}

__attribute__((noinline, optnone)) static uint64_t pext_reference(uint64_t value, uint64_t mask)
{
    uint64_t result = 0;
    uint64_t result_bit = 1;

    while (mask)
    {
        uint64_t source_bit = mask & -mask;

        if (value & source_bit)
            result |= result_bit;
        mask &= mask - 1;
        result_bit <<= 1;
    }
    return result;
}

int main(int argc, char **argv)
{
    uint32_t leaf1[4], leaf7[4];
    volatile uint64_t crc_input = 0x0123456789abcdefull;
    volatile uint64_t bmi_value = 0x123456789abcdef0ull;
    volatile uint64_t bmi_mask = 0x0f0f33335555aaaauLL;
    uint64_t xcr0, deposited, extracted;
    __m256i lanes, addend, sum, product;
    int32_t sum_values[8], product_values[8];
    int advertised_failure = 0;
    int instructions_only;
    unsigned int i;

    instructions_only = argc == 2 && !strcmp(argv[1], "--instructions-only");
    if (argc != 1 && !instructions_only)
    {
        fprintf(stderr, "usage: %s [--instructions-only]\n", argv[0]);
        return 64;
    }

    cpuid(1, 0, leaf1);
    cpuid(7, 0, leaf7);
    printf("cpuid.1: eax=%08x ebx=%08x ecx=%08x edx=%08x; "
           "cpuid.7.0: eax=%08x ebx=%08x ecx=%08x edx=%08x\n",
           leaf1[0], leaf1[1], leaf1[2], leaf1[3], leaf7[0], leaf7[1], leaf7[2], leaf7[3]);

    if (!(leaf1[2] & (1u << 20)))
        advertised_failure = 1; /* SSE4.2 */
    else if (!(leaf1[2] & (1u << 27)))
        advertised_failure = 2; /* OSXSAVE */
    else if (!(leaf1[2] & (1u << 28)))
        advertised_failure = 3; /* AVX */
    else if (!(leaf7[1] & (1u << 3)))
        advertised_failure = 4; /* BMI1 */
    else if (!(leaf7[1] & (1u << 5)))
        advertised_failure = 5; /* AVX2 */
    else if (!(leaf7[1] & (1u << 8)))
        advertised_failure = 6; /* BMI2 */

    if (advertised_failure && !instructions_only)
        return advertised_failure;
    if (advertised_failure)
        printf("warning: bypassing CPUID advertisement failure %d\n", advertised_failure);

    xcr0 = xgetbv(0);
    if ((xcr0 & 0x6) != 0x6)
        return 7;

    if (_mm_crc32_u64(0, crc_input) != crc32c_reference(0, crc_input))
        return 10;
    if (_andn_u64(bmi_value, bmi_mask) != ((~bmi_value) & bmi_mask))
        return 11;
    if (_blsi_u64(bmi_value) != (bmi_value & -bmi_value))
        return 12;

    deposited = _pdep_u64(bmi_value, bmi_mask);
    extracted = _pext_u64(bmi_value, bmi_mask);
    if (deposited != pdep_reference(bmi_value, bmi_mask))
        return 13;
    if (extracted != pext_reference(bmi_value, bmi_mask))
        return 14;

    lanes = _mm256_set_epi32(8, 7, 6, 5, 4, 3, 2, 1);
    addend = _mm256_set1_epi32(10);
    sum = _mm256_add_epi32(lanes, addend);
    product = _mm256_mullo_epi32(lanes, _mm256_set1_epi32(3));
    _mm256_storeu_si256((__m256i *)sum_values, sum);
    _mm256_storeu_si256((__m256i *)product_values, product);

    for (i = 0; i < 8; i++)
    {
        if (sum_values[i] != (int32_t)i + 11)
            return 20 + i;
        if (product_values[i] != ((int32_t)i + 1) * 3)
            return 30 + i;
    }

    puts("cpu-001 isa semantics ok: SSE4.2 AVX2 BMI1 BMI2");
    if (advertised_failure)
        return 100 + advertised_failure;
    puts("cpu-001 isa advertisement ok");
    return 0;
}
