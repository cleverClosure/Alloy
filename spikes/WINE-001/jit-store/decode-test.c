/*
 * Unit tests for the ARM64 translated-JIT store decoder.
 * Author: Tim Isaev
 *
 * The header under test is the one ntdll ships, included straight out of the
 * Wine tree by run-decode-test.sh - not a copy.  An earlier revision tested a
 * second, separately written copy of the decoder that lived beside this file.
 * The two had already drifted: the copy narrowed the scaled uimm12 offset to
 * int16_t, which silently wraps for any str Qt offset above 32767, and the
 * shipped decoder did not.  A test of a replica cannot catch that, so it is
 * worse than no test - it reports confidence it has not earned.
 *
 * This is also where rejection of unknown store forms is covered.  Doing it
 * from guest x64 instead would test which ARM64 instructions FEX selects, not
 * what this decoder accepts.
 */

#include "arm64_jit_store.h"

#include <stdio.h>
#include <stdlib.h>

static unsigned int failures;

#define CHECK(condition, ...)                                                                      \
    do                                                                                             \
    {                                                                                              \
        if (!(condition))                                                                          \
        {                                                                                          \
            fprintf(stderr, "FAIL: " __VA_ARGS__);                                                 \
            fputc('\n', stderr);                                                                   \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

static struct arm64_jit_store decode_supported(uint32_t instr, const char *name)
{
    struct arm64_jit_store store;

    CHECK(arm64_jit_store_decode(instr, &store), "%s was rejected (%08x)", name, instr);
    return store;
}

static void check_scalar_widths(void)
{
    struct arm64_jit_store store;
    unsigned int size;

    for (size = 0; size < 4; size++)
    {
        store = decode_supported(0x089ffc00 | (size << 30) | (7 << 5) | 9, "stlr");
        CHECK(store.kind == ARM64_JIT_STORE_STLR, "stlr kind %u", store.kind);
        CHECK(store.source == 9 && store.base == 7, "stlr registers %u/%u", store.source,
              store.base);
        CHECK(store.width == (1u << size), "stlr width %u", store.width);

        store = decode_supported(0x383f6800 | (size << 30) | (8 << 5) | 10, "str register-zero");
        CHECK(store.kind == ARM64_JIT_STORE_STR_REGZERO, "str register-zero kind %u", store.kind);
        CHECK(store.source == 10 && store.base == 8, "str register-zero registers %u/%u",
              store.source, store.base);
        CHECK(store.width == (1u << size), "str register-zero width %u", store.width);

        store = decode_supported(0x38000400 | (size << 30) | (0x1f8 << 12) | (11 << 5) | 12,
                                 "str post-index");
        CHECK(store.kind == ARM64_JIT_STORE_STR_POST, "str post-index kind %u", store.kind);
        CHECK(store.source == 12 && store.base == 11, "str post-index registers %u/%u",
              store.source, store.base);
        CHECK(store.width == (1u << size), "str post-index width %u", store.width);
        CHECK(store.writeback_offset == -8, "str post-index offset %d", store.writeback_offset);
        CHECK(store.address_offset == 0, "str post-index address offset %d", store.address_offset);

        store = decode_supported(0x38e08000 | (size << 30) | (13 << 16) | (14 << 5) | 15, "swpal");
        CHECK(store.kind == ARM64_JIT_STORE_SWPAL, "swpal kind %u", store.kind);
        CHECK(store.source == 13 && store.base == 14 && store.result == 15,
              "swpal registers %u/%u/%u", store.source, store.base, store.result);
        CHECK(store.width == (1u << size), "swpal width %u", store.width);
    }
}

static void check_vector_forms(void)
{
    struct arm64_jit_store store;

    store = decode_supported(0x3d800000 | (17 << 10) | (3 << 5) | 4, "str q unsigned");
    CHECK(store.kind == ARM64_JIT_STORE_STR_Q_UNSIGNED, "str q unsigned kind %u", store.kind);
    CHECK(store.source == 4 && store.base == 3 && store.width == 16,
          "str q unsigned fields %u/%u/%u", store.source, store.base, store.width);
    CHECK(store.address_offset == 272, "str q unsigned offset %d", store.address_offset);

    store =
        decode_supported(0xac800000 | (0x7f << 15) | (6 << 10) | (7 << 5) | 5, "stp q post-index");
    CHECK(store.kind == ARM64_JIT_STORE_STP_Q_POST, "stp q post-index kind %u", store.kind);
    CHECK(store.source == 5 && store.source2 == 6 && store.base == 7 && store.width == 32,
          "stp q post-index fields %u/%u/%u/%u", store.source, store.source2, store.base,
          store.width);
    CHECK(store.writeback_offset == -16, "stp q post-index offset %d", store.writeback_offset);

    store = decode_supported(0x3c800000 | (0x1f1 << 12) | (9 << 5) | 8, "stur q");
    CHECK(store.kind == ARM64_JIT_STORE_STUR_Q, "stur q kind %u", store.kind);
    CHECK(store.source == 8 && store.base == 9 && store.width == 16, "stur q fields %u/%u/%u",
          store.source, store.base, store.width);
    CHECK(store.address_offset == -15, "stur q offset %d", store.address_offset);
}

/* Regression: the scaled uimm12 offset of str Qt reaches 4095*16 = 65520,
 * which does not fit in the int16_t an earlier copy of this decoder used.
 * Every offset above 32767 wrapped negative and addressed the wrong page. */
static void check_offset_extremes(void)
{
    struct arm64_jit_store store;

    store = decode_supported(0x3d800000 | (0xfff << 10) | (3 << 5) | 4, "str q maximum offset");
    CHECK(store.address_offset == 65520, "str q maximum offset %d (expected 65520)",
          store.address_offset);

    store = decode_supported(0x3d800000 | (0x800 << 10) | (3 << 5) | 4, "str q offset above int16");
    CHECK(store.address_offset == 32768, "str q offset %d (expected 32768)", store.address_offset);

    store = decode_supported(0x3c800000 | (0x100 << 12) | (9 << 5) | 8, "stur q most negative");
    CHECK(store.address_offset == -256, "stur q offset %d (expected -256)", store.address_offset);

    store = decode_supported(0xac800000 | (0x40 << 15) | (6 << 10) | (7 << 5) | 5,
                             "stp q most negative");
    CHECK(store.writeback_offset == -1024, "stp q offset %d (expected -1024)",
          store.writeback_offset);

    store = decode_supported(0xac800000 | (0x3f << 15) | (6 << 10) | (7 << 5) | 5,
                             "stp q most positive");
    CHECK(store.writeback_offset == 1008, "stp q offset %d (expected 1008)",
          store.writeback_offset);
}

static void check_rejected_forms(void)
{
    static const struct
    {
        uint32_t instr;
        const char *name;
    } rejected[] = {{0xd503201f, "nop"},
                    {0xf9400020, "ldr x"},
                    {0x3dc00020, "ldr q unsigned"},
                    {0x3cc00020, "ldur q"},
                    {0xad000420, "stp q offset"},
                    {0xad800420, "stp q pre-index"},
                    {0x08dffc20, "ldar"},
                    {0x38000c20, "str scalar pre-index"},
                    {0xb9000020, "str scalar unsigned"},
                    {0x3ca06820, "str q register-offset"},
                    {0xac000420, "stnp q"},
                    {0x0c007020, "st1 vector"}};
    struct arm64_jit_store store;
    unsigned int i;

    for (i = 0; i < sizeof(rejected) / sizeof(rejected[0]); i++)
    {
        CHECK(!arm64_jit_store_decode(rejected[i].instr, &store),
              "%s was accepted (%08x) as kind %u", rejected[i].name, rejected[i].instr, store.kind);
        CHECK(store.kind == ARM64_JIT_STORE_NONE, "%s left kind %u", rejected[i].name, store.kind);
    }
}

int main(void)
{
    check_scalar_widths();
    check_vector_forms();
    check_offset_extremes();
    check_rejected_forms();

    if (failures)
    {
        fprintf(stderr, "FAIL: %u decoder assertion(s)\n", failures);
        return EXIT_FAILURE;
    }
    puts("PASS ARM64 translated-JIT store decoder");
    return EXIT_SUCCESS;
}
