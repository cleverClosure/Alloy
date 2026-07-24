# CPU-001 result 15 — FEX compute scales linearly across cores: 8.01x on 8 threads at 100% efficiency, bit-exact, no per-process serialization

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `36a24a1` · **FEX:** `alloy/spike-fex-001`
darwin-teb build @ `93cae98` · **Hardware:** M2 Pro (8 P-cores + 4 E-cores), 16 GB, macOS 26.5

## Why this exists

Result 14 measured single-thread throughput. Real game engines run
worker-thread pools, so the next question is whether FEX's translation *scales*
across cores or serializes on hidden per-process state — a shared code-cache
lock, JIT serialization, a global emulator mutex. A translator can be fast
single-threaded and still bottleneck the moment several guest threads run hot
at once. This measures that directly.

## Method

`testcases/cpu_scaling.c` runs a contention-free pure-ALU kernel (the
result-14 xorshift mix — no shared memory, so ideal scaling is perfectly
linear) across 1, 2, 4, and 8 threads, each doing a fixed 200M iterations, and
reports wall-clock, aggregate throughput, and parallel efficiency. The same
source builds as an x64 PE under FEX and as native arm64; comparing the two
scaling curves isolates any FEX-specific serialization. Eight threads fit the
host's 8 performance cores.

| threads | native ms | native scale | FEX ms | FEX scale | FEX eff | checksum |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 674.6 | 1.00x | 659.3 | 1.00x | 100.0% | match |
| 2 | 668.4 | 2.02x | 653.3 | 2.02x | 100.9% | match |
| 4 | 664.5 | 4.06x | 657.1 | 4.01x | 100.3% | match |
| 8 | 666.5 | 8.10x | 658.5 | 8.01x | 100.1% | match |

## Reading the result

- **FEX scales linearly to 8 cores.** Wall-clock stays flat (~658 ms) as thread
  count rises 1->8; aggregate throughput rises 8.01x at 8 threads, 100.1%
  parallel efficiency. FEX's per-thread JIT-compiled code runs fully in
  parallel — there is **no shared-JIT-lock or per-process serialization** in the
  steady-state execution path. A game's worker-thread pool gets full core
  utilisation under FEX, not a serialized fraction.
- **The native and FEX curves are indistinguishable.** FEX matches native
  scaling shape exactly (both linear to 8), consistent with result 14's
  native-parity on this integer kernel. FEX wall-clock is even marginally lower
  here, within noise.
- **Bit-exact under concurrency.** Every thread-count checksum and the global
  guard match native exactly — FEX is deterministic and free of cross-thread
  corruption when many translated threads run hot simultaneously.

## Honest caveats

- **Steady-state execution, not concurrent compilation.** The kernel compiles
  once early and then runs 200M iterations, so this measures warm-JIT execution
  scaling. Whether FEX's *compiler* scales when many threads hit cold code at
  the same instant (a launch / level-load stutter concern) is a separate axis,
  not measured here.
- **Pure ALU, no shared memory.** The kernel is deliberately contention-free to
  isolate translator serialization. Real workloads add cache-coherency and
  memory-bandwidth contention that bound both FEX and native equally; this is
  the translator-scaling ceiling, not a shared-data-structure benchmark.
- **Not the exception path.** Multi-thread *exception dispatch* is item #24 and
  is unrelated to this compute-scaling result.

## Status

Together with result 14 this closes the synthetic/prototype-scope CPU
performance picture for `PHASE-0-STATUS` line 33: single-thread tax measured
(native-parity to ~2.7x by workload) and multi-thread scaling measured (linear
to 8 cores, bit-exact). `cpu_scaling` joins `build-corpus.sh` (16 tests) and
exits 0 only when every batch completes with a non-zero checksum, so it doubles
as a permanent concurrency-correctness regression. The remaining line-33 item —
a deterministic real-title scene — awaits the founder E3 titles.
