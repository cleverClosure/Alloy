# CPU-001 result 25 — vector corpus verified through FEX

**Author:** Timur Isaev  
**Date:** 4 October 2026  
**Host:** Apple Silicon, macOS 27.0 (26A428)  
**Issue:** #104, milestone 3; isolated runtime repair #111

## What was verified

Seven new family binaries add 114 operation forms and 143,744 seeded cases:
SSE floating point, SSE3, SSSE3, SSE4.1, SSE4.2, AVX and AVX2. SSE2's existing
53-operation integer corpus is unchanged. Every new clean native reference
and independent Rosetta instruction build passed. Every family's deliberately
corrupted reference exited 1 and reported its named mutation, both natively
and under Rosetta. Those independent oracle checks are now supplemented by
actual FEX execution: all seven clean guests exit 0 with zero failures and
all seven corrupted guests exit 1 with their exact named mismatch counts.
Their checksums match every pin in the table below.

| Family | Operation forms | Cases | Clean checksum | Mutation / corrupted checksum |
| --- | ---: | ---: | --- | --- |
| sse | 17 | 17,216 | `1243a236db34df2f` | `addps` / `55cf1a60181340ae` |
| sse3 | 9 | 8,256 | `a0918c8c7fafcfd9` | `addsubps` / `5305bc4225f49774` |
| ssse3 | 16 | 24,576 | `ce9645ed60d9d174` | `pshufb` / `89914f4da68752d8` |
| sse41 | 17 | 24,128 | `6cfd121cde334cde` | `pmulld` / `6011bfd1cf108682` |
| sse42 | 7 | 10,176 | `49c8cba45643ca58` | `pcmpgtq` / `393ef08fb8605058` |
| avx | 26 | 25,728 | `732fe5b38fa3c408` | `vaddps` / `64943f963264b421` |
| avx2 | 22 | 33,664 | `589ca5662342c316` | `vpaddd` / `5a9e8298190dc946` |

The seed is `a1c0ffee5eed0003`. Checksums use FNV-1a over ordered reference
result bytes and are regression pins, not cryptographic authenticity proofs.
The exact operation inventory and case budgets are committed in
`testcases/isa-corpus-vectors.json`. Per-operation checksums, build hashes,
compiler identity and each run's complete output are emitted in the chosen
output directory. A matching checksum alone never establishes a pass.

## Reproduce without Wine

From the repository root:

```sh
python3 spikes/CPU-001/testcases/verify-isa-vectors.py   spikes/CPU-001/work/vector-proof --rosetta
```

This command does not invoke Wine, edit a runtime, or run a PE executable. It:

1. Proves its log reader with four positive and sixteen deliberately invalid
   synthetic records, including timeout, crash, wrong checksum, silent failure
   counter, duplicate summary, lost operation and missing mutation evidence.
2. Compiles each clean and corrupted arm64 reference at O0/O1/O2/O3 and checks
   complete byte-identical output across optimization levels.
3. Runs each O2 native binary three more times as separate invocations and
   checks complete byte-identical output again.
4. Cross-compiles clean and corrupted Windows PE binaries with warnings as
   errors. Disassembles the instruction function and checks **every** listed
   operation's opcode is present. The sole aliases are documented disassembler
   spelling differences and explicitly named immediate variants.
5. With `--rosetta`, executes separate x86-64 Mach-O binaries through Rosetta.
   Every real instruction result must equal the scalar reference. Their clean
   and corrupted checksums also equal the arm64 pins; their corruption controls
   must report an actual instruction/reference mismatch as well as a failing
   literal hand vector. Rosetta is an independent translator, not physical
   Intel hardware and not FEX.

All seven families completed all of these checks on this host. The reader's
own control was additionally checked by replacing its validator with an
always-accept function: its first timeout control rejected that defect.

The complete standing cross-compile target also builds all seven binaries:

```sh
mkdir -p spikes/CPU-001/work/corpus
PATH="/Users/cleverclosure/Developer/Alloy/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin:$PATH"   bash spikes/CPU-001/testcases/build-corpus.sh spikes/CPU-001/work/corpus
```

## Coverage and oracle boundaries

A hand-authored xorshift generator supplies deterministic operands. Each
operation first sees the Cartesian product of 24 edge vectors, then its
seeded random cases. Edges include zero, all ones, sign boundaries, 31/32/33
shift counts, both signed zeros, smallest/largest subnormals, smallest normal,
finite limits, infinities, quiet/signaling NaNs, and distinct upper 128-bit
lanes. Random integer arithmetic/comparisons get 1,024 cases per operation;
bit movement and selection get 512; floating arithmetic gets 256.

This prioritization follows the ordinary data/integer/compare emphasis of
[result 19](2026-07-25-19-real-title-execution-census.md). That report counts
**decodes, not executions**, and publishes no per-SIMD-family frequency table.
The budgets are a transparent coverage choice, not invented execution weights.

Reference functions are scalar, noinline and optnone. Native and instruction
builds disable fast math and contraction. Arithmetic uses round-to-nearest with
flush-to-zero and denormals-are-zero disabled. Arithmetic NaNs compare by class
(canonical quiet NaN); finite values, signed zeros and denormals compare by
exact bits. Movement, bit operations, min/max selection and masks preserve all
bits, including NaN payloads. MXCSR sticky flags and alternate rounding modes
are not claimed by this vector-result corpus. x87 extended precision is a
separate milestone, with no attempted arm64 equivalence.

Every family has an internal literal hand vector independent of its reference
function. The seeded reference outputs then receive an independent translated
instruction check under Rosetta. This does not claim that every operation has
a separate hand-computed fixture, that every opcode variant is covered, or
that a second translator replaces the required FEX run.

Opcode inspection caught LLVM lowering the `blendps` intrinsic into `pblendw`.
The test now uses an explicit `blendps` instruction. The inventory gate rejects
the earlier PE binary specifically for its absent `blendps` opcode. This stops
an equivalent calculation from masquerading as coverage of the named opcode.

Instruction semantics were checked against the
[Intel SDM](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
and the primary LLVM intrinsic declarations for
[SSE3](https://clang.llvm.org/doxygen/pmmintrin_8h.html) and
[SSSE3](https://clang.llvm.org/doxygen/tmmintrin_8h.html).
No third-party corpus, PRNG, or reference implementation was imported.

## FEX acceptance evidence

All fourteen required guest outcomes passed through the existing builtin FEX
DLL in #111's isolated, repaired Wine build. Each log contains an actual builtin
FEX load event. The complete run's `aggregate.json` is under
`/private/tmp/alloy-104-m5/spikes/CPU-001/work/isa-corpus-runs/run-i5v8lx3u/`.
This milestone's seven family source files, vector/common headers, seeded
manifest entries and checksums match that run's inputs exactly. The shared
scalar helper declarations use the same inline form as the aggregate build.

Wine source is clean at `f0937d595166631dd00eaab31fef4fb5a6f37031`;
FEX source is unchanged at `ad942313dca79d32133cceaaf617016821e3b952`.
The actual FEX DLL SHA-256 is
`ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6`.
The full selected runtime inventory is identical before and after:
`8f0fa54a52cdd63ac7eb8fb722f210a375649e96fbd0cfadaf727423c7fa763a`
across 21,652 entries. Per-invocation metadata records source revisions,
binary hashes and idle-runtime checks. See
[result 28](2026-10-04-28-macos27-jit-signal-resume.md) for the runtime identities,
shared-tree preservation and isolated repair instructions.

The corpus does not rebuild or install the runtime. The shared build-2 remains
unchanged; tests select the repaired copy explicitly. Milestone 3 is complete.
BMI1/BMI2, atomics/flags, x87 and the standing aggregate command are delivered in
the following milestones. No GitHub Actions job was added. Issue #78 remains
separate, open and unmodified.
