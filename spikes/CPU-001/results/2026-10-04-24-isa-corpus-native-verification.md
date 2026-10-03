<!-- Author: Timur Isaev -->

# CPU-001 result 24 — SSE2 corpus native milestone reverified

**Date:** 4 October 2026  
**Host:** M2 Pro, macOS 27.0 (26A428)

Issue #104 milestone 1 provides a deterministic, dependency-free generator
for 53 SSE2 integer operations, with 12,736 cases. This milestone runs the
portable reference side on arm64 and cross-compiles the Windows guest. It
does not certify instruction translation through FEX.

## Reproduce

From the repository root, with the existing llvm-mingw toolchain on PATH:

```sh
mkdir -p spikes/CPU-001/work/isa-native-proof/guests
bash spikes/CPU-001/testcases/build-isa-corpus-native.sh \
  spikes/CPU-001/work/isa-native-proof/native
bash spikes/CPU-001/testcases/build-isa-corpus-native.sh \
  spikes/CPU-001/work/isa-native-proof/native -DALLOY_CORPUS_MUTATE_PADDB
bash spikes/CPU-001/testcases/build-corpus.sh \
  spikes/CPU-001/work/isa-native-proof/guests
```

The native script deliberately uses `/usr/bin/clang` so a cross compiler
ahead of it on PATH cannot select the wrong compiler. It builds and checks
O0, O1, O2 and O3, then compares three separate O2 invocations.

## Observed results

| Variant | Native program exit | Reference checksum | Proof-script exit |
| --- | --- | --- | --- |
| Clean | 0 at all four optimization levels | `21ba41417def5d07` | 0 |
| Corrupted `paddb` reference | 1 at all four levels; named hand-vector failure | `eb480915973927bd` | 0 |

The proof script succeeds for the corrupted build only when the program
actually rejects its mutation by name. A nonzero exit without the named
failure is insufficient. Complete output is byte-identical across all four
optimization levels and across three repeated O2 runs for each variant.
All 22 Windows corpus executables cross-compile successfully.

The interrupted review's five additional corruptions were re-created in
scratch copies: omitted rounding in `pavgb`/`pavgw`, inverted `pcmpgtb`, a
15-bit high-half shift in `pmulhw`, and reversed `psubq` operands. Each
proof run fails on its matching hand vector. Removing the hand-vector
failure-counter increments is also rejected: a log containing `FAIL` cannot
pass merely because the exit code and counter claim success.

## Limits

There are ten table-operation hand vectors and one shuffle hand vector:
11 of 53 operations have hand-computed expected answers. The other 42
references still need stronger independent coverage; matching optimization
levels and repeated output alone do not prove instruction semantics.

As an additional local check, x86-64 Mach-O builds at O0 and O2 execute all
reference-versus-intrinsic comparisons under Rosetta and produce the same
clean checksum. This checks against another translator; it is neither a
physical x86 oracle nor a FEX result.

The Wine/FEX path is blocked by the independently reproduced runtime
regression in [#111](https://github.com/cleverClosure/Alloy/issues/111).
Milestone 2's actual clean/mutated guest outcomes, later instruction-family
milestones, and issue #78 remain separate and unfinished. No CI job was
added for this corpus.
