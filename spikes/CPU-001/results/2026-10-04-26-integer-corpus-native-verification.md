# CPU-001 result 26 — integer, atomic and x87 corpus prepared; FEX pending

**Author:** Timur Isaev  
**Date:** 4 October 2026  
**Host:** Apple Silicon, macOS 27.0 (26A428)  
**Issue:** #104 milestone 4 preparation; runtime dependency #111

## Observed outcomes

Five family binaries add 85 operation forms/invariants and 216,984 seeded cases.
BMI1, BMI2 and integer flags agree between native arm64 references and separate
Rosetta instruction builds. Atomics execute real operations on both hosts and
agree with a serial reference. x87 executes exact guest-side self-checks on
Rosetta and has **no arm64 floating-point comparison**. Every clean run passed;
every family's deliberately corrupted build failed by name with exit 1.
These are local oracle and harness proofs. **No FEX outcome is claimed.**

| Family | Forms/invariants | Cases | Clean checksum | Corrupted-reference checksum |
| --- | ---: | ---: | --- | --- |
| bmi1 | 12 | 33,324 | `5a36ed60bc454d14` | `20eadcbd0e12aa65` |
| bmi2 | 16 | 44,432 | `0fa7cb1768b0cd21` | `c3df897b1512a714` |
| flags | 34 | 99,620 | `dabc6bdd3b7d41af` | `93c7f7c6028d282b` |
| atomics | 15 | 35,512 | `faad3e1498581db0` | `2476aea558e8f030` |
| x87 | 8 | 4,096 | `cc376fd87725cdb0` | `95eec97d57d7a340` |

All use seed `a1c0ffee5eed0003`. The integer manifest pins case inventories,
mutation names, exact failure counts and expected checksums. The standing
cross-compile command now builds 34 CPU-001 binaries successfully. No existing
binary was removed or substituted.

## Reproduce the available proofs

From the repository root:

```sh
python3 spikes/CPU-001/testcases/verify-isa-vectors.py   spikes/CPU-001/work/integer-proof --rosetta   --families bmi1,bmi2,flags,atomics,x87
```

Omit `--families` to recheck all twelve new families from results 25 and 26.
That complete command also passed after the common helper changes. SSE2's
previous native proof remains `testcases/build-isa-corpus-native.sh`.

For each arm64-capable family, clean and corrupted output was byte-identical
across O0/O1/O2/O3 and three separate O2 invocations. Each x86 Mach-O build
checked real instructions against the reference and matched the native
checksums. x87's x86 self-checks were separately repeated across all four
optimization levels and three O2 invocations. It is never compiled as an
arm64 FP test; the source rejects that build explicitly.

Clean and corrupted PE builds succeeded with warnings as errors. Disassembly
checks require every specified opcode in the instruction routine. The corpus
reader's four positive and sixteen negative controls still pass. A nonzero
exit, incomplete inventory, missing mismatch, extra mismatch or changed
checksum cannot count as a successful mutation control.

## Family scope

### BMI1 and BMI2

All listed operations cover both 32-bit and 64-bit operands. BMI1 includes
ANDN, BLSI, BLSR, BLSMSK, BEXTR and TZCNT. BMI2 includes PDEP, PEXT, BZHI,
MULX, SHLX, SHRX, SARX and RORX with an explicit rotate immediate.
The reference uses bounded bit loops; MULX uses a two-limb shift/add product,
not a compiler 128-bit multiply. Both product halves are compared.

Edges exercise zero counts, zero inputs, signed boundaries, width-crossing
shift/extract counts, all-zero/all-one masks, sparse/dense masks and the
low-eight-bit index behavior of BZHI. The generator is first-party and seeded;
no external instruction corpus or PRNG was imported.

### Integer condition flags

ADD, SUB, ADC, SBB, CMP, TEST, AND, OR, XOR, INC, DEC, NEG, SHL, SHR, SAR, ROL
and ROR each cover 32 and 64 bits, including both incoming carry states.
Results and all architecturally defined CF/PF/AF/ZF/SF/OF bits are compared.
Undefined AF for logic/shifts and undefined OF for multi-bit shifts/rotates
are masked explicitly. A zero shift retains the deliberately initialized flags.

The assembly sets known initial flags with SAHF and reads them with LAHF plus
SETO; it does not push flags into Darwin's stack red zone. Literal overflow,
wraparound and all-clear vectors demonstrate positive and negative flag
outcomes. A separate temporary build removed OF from the comparison mask:
the literal overflow vector reported FAIL. That defective source was never
committed. The ordinary mutation flips the expected carry for ADD32 and is
caught by all three hand vectors and the instruction comparisons.

### Atomics

The serial corpus checks successful and failed strong compare-exchange,
fetch-add, exchange, fetch-or, fetch-and and fetch-xor at both widths, including
returned old values, expected-value writeback, success state and final memory.
The native side executes actual arm64 atomics against the serial reference.
The x86 side executes the compiler's actual locked instructions/CAS loops.
This is C11 operation coverage, not a claim that each API is a single opcode.

Four contending threads also claim 4,096 tickets. The final counter, sum, full
per-ticket bitmap and duplicate detector must all agree. Checksums fold the
canonical final state, so thread scheduling cannot change a correct result.
A second corruption maps tickets into half the range; both native and Rosetta
runs rejected it with the exact known duplicate/missing-ticket invariant.
Its checksum is `cf73f23dd9bcc99f`, distinct from the clean state.

These checks cover naturally aligned 32/64-bit operations and contention.
They do not access CAS-tear telemetry or alter issue #78, which remains separate.

### x87: guest-side self-checks, never arm64 parity

Apple Silicon's C `long double` is binary64 and cannot provide an independent
80-bit arithmetic result. x87 instead consumes explicit ten-byte values and
compares its stored result against exact integer constructions of the required
80-bit encoding. No conversion through native `double` or `long double` is
used. This is the intended guest-side self-check boundary for this family.

Tests retain the `2^-63` increment at 1.0, subtract that increment, scale across
normal and subnormal exponent boundaries, take exact integer square roots,
round signed half-integers to even, and check ordered/unordered comparison
flags. The x87 control word selects extended precision and nearest rounding
with exceptions masked, then is restored. Every operation gets 512 seeded
cases. The corruption changes the first family's exact expected significand.

Rosetta runs sanity-check the guest and its failure control; they are not a
native-arm64 oracle and do not satisfy the required FEX run. The authoritative
FEX-side result remains pending. A future FEX precision mismatch must be
reported as a translator finding, not removed by weakening these expectations.

The explicit FSUBP/FDIVP bytes use Intel operand order. LLVM's AT&T disassembly
spells those forms `fsubrp`/`fdivrp`; that alias is recorded in the inventory.
Primary semantic references are the
[Intel SDM](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
and LLVM's
[BMI1](https://clang.llvm.org/doxygen/bmiintrin_8h.html) and
[BMI2](https://clang.llvm.org/doxygen/bmi2intrin_8h.html) declarations.

## Remaining acceptance work

Milestone 4 remains pending until these clean and corrupted Windows guests
actually execute through the restored FEX runtime with the required recorded
identities and unchanged before/after runtime inventory. Milestone 5 still
needs its end-to-end FEX aggregate. No Wine guest, shared source edit, shared
runtime build, GitHub Actions job, or issue #78 change occurred in this work.
