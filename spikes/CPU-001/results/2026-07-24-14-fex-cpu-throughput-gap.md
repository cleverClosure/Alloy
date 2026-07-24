# CPU-001 result 14 — the FEX CPU translation tax measured: native-parity on integer, ~1.6x on FP/memory, ~2.7x worst-case on branchy code, and bit-exact correct

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `36a24a1` · **FEX:** `alloy/spike-fex-001`
darwin-teb build @ `93cae98` · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Why this exists

The corpus proved FEX runs x64 code *correctly*; `PHASE-0-STATUS` line 33 also
asks for "acceptable initial performance" and a "measured CPU gap", which had
never been taken. This is the CPU analogue of the graphics gate-4 synthetic
scene (233-329 fps): a first, synthetic, prototype-scope measurement of FEX's
x86->arm64 translation overhead, plus a bit-exact correctness cross-check.

## Method

`testcases/cpu_throughput.c` runs four game-representative kernels — integer mix
(xorshift + multiply), scalar FP multiply-accumulate (a bounded symplectic
rotation), 2 MiB strided memory read-modify-write, and a data-dependent
multi-way branch. Each accumulates a printed checksum (so the optimiser cannot
elide the work) and is preceded by a warm-up pass. The **same source** builds
two ways and runs on the same M2 Pro:

- **native** — Apple `clang -O2 -arch arm64`, run directly (the host ceiling);
- **FEX** — `x86_64-w64-mingw32-clang -O2`, run as an x64 PE under FEX+wine.

Both are built `-ffp-contract=off` so neither side contracts the FP kernel into
an FMA — an apples-to-apples comparison of the *same* operations, and (per
result 12) the difference that would otherwise make the FP checksums diverge.
The ratio FEX/native is the translation tax relative to the native ceiling —
the right "is FEX viable on this hardware" metric. Medians of three runs each
(<3% run-to-run spread):

| kernel | native ns/op | FEX ns/op | FEX / native | checksum vs native |
| --- | --- | --- | --- | --- |
| int_mix | 3.345 | 3.288 | **0.98x** (parity) | exact match |
| fp_mac | 5.178 | 8.160 | **1.58x** | exact match |
| mem_stream | 1.177 | 1.932 | **1.64x** | exact match |
| branch_dep | 1.861 | 5.005 | **2.69x** | exact match |

## Reading the result

- **Integer ALU runs at native speed.** Xorshift/multiply maps almost 1:1 to
  arm64; the JIT-compiled loop is indistinguishable from native (0.98x is within
  noise). Binary translation adds no measurable tax on this class.
- **FP and memory carry ~1.6x.** Scalar FP and strided load/store cost about
  60% more than native — the steady-state cost of translating SSE scalar math
  and x86 addressing to arm64. This is well inside the typical DBT band.
- **Data-dependent branches are the worst case at ~2.7x.** Unpredictable
  multi-way control flow is the classic dynamic-binary-translation tax (branch
  target resolution, block linking). Still under 3x.
- **Every kernel is bit-for-bit correct.** With the FMA confound removed, all
  four checksums and the global guard match native exactly — FEX's translation
  is not just fast but numerically identical to native for these workloads. The
  only divergence seen before `-ffp-contract=off` was native-arm64 using a fused
  FMA where the x86 build used separate mul+add (result 12's finding again), not
  a FEX error.

For a dynamic binary translator these are strong numbers: native parity on
integer, ~1.6x on the common FP/memory mix, ~2.7x only on the hardest branchy
code. FEX's CPU path is viable at prototype scope; the branch-heavy worst case
is the area to watch as real titles arrive.

## Honest caveats

- **Ceiling, not a PC.** This measures FEX against *native arm64* — the best
  this hardware can do — not against native x86 on a gaming PC. It quantifies
  FEX's efficiency on this Mac, which is the viability question that matters
  here; it is not a cross-platform fps prediction.
- **Synthetic, steady-state, single-thread.** Kernels run long enough to
  amortise JIT compilation, so this is warm-JIT throughput, not cold-start cost
  (measured separately) and not a real game's instruction blend. Like gate-4,
  it is a first synthetic anchor, not a title benchmark — those need the E3
  founder titles.
- **`-ffp-contract=off` for parity.** Real x86 game binaries (MSVC) often do
  emit FMA; an FMA-heavy FP path would shift the FP number (result 12 proved
  FEX's `vfmadd` lowering is itself bit-exact and single-rounded).

## Status

Fills `PHASE-0-STATUS` line 33's "measured CPU gap" at synthetic/prototype
scope. `cpu_throughput` is added to `build-corpus.sh` (15 tests) and exits 0
only when every kernel completes with a matching-shape non-zero checksum, so it
doubles as a permanent correctness regression alongside the timing.
