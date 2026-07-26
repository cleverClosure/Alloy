# M12-006 result 02 — one Metal12 library runs the promoted proofs and reference client

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Partially green; full-model command-path convergence and a
public-header DXIL-to-MSL entry point remain open, while the M12-004 pressure
execution is blocked on explicit host-risk approval
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

- Branch `task/84-metal12-phase1` at base `21136e4`.
- Historical first-party implementations from M12-001 through M12-004,
  promoted without editing the spike copies.
- The M12-006 reference HLSL and the M12-005 GPTK answer-key image.
- Xcode 26.3 host Objective-C and Metal toolchains.
- [`runtime/metal12/build.sh`](../../../runtime/metal12/build.sh), which
  produces `libAlloyMetal12.a` and separately linked proof executables.

## Library promotion

`runtime/metal12/` now contains one Objective-C static archive behind
`include/AlloyMetal12.h`. The archive contains the trace-driven command runtime
and the canonical promoted proof implementations as separate objects. The
public command surface owns logical resources, placement-backed render targets,
shared buffers, descriptor generations, state transitions, draw/copy/present
commands, command-buffer submission, capture/replay, and image measurement.

`Tests/vertical_slice.m` contains scene data and assertions only. Its resource,
descriptor, barrier, render, copy, submit, present, and readback operations all
go through the public header.

The three full native model harnesses are canonical library-owned proof
functions with tiny independently linked test clients. The shader runner links
`libAlloyMetal12.a` and calls its public
`AM12ValidateShaderProofConfiguration` API before each dispatch; the canonical
Python lowerer remains a production-local build tool, not a Python dependency
hidden behind a C function. This proves archive ownership, symbol consumption,
and linkage. It does not satisfy Gate 1's literal requirement that DXIL-to-MSL
sit behind the one public header, and it does not prove that the first command
path already calls the full proof-model implementations.

## Architecture claim boundary

The first vertical path deliberately exercises smaller model subsets:

- **Descriptors:** one constant-buffer view with generation validation and 120
  materializations, bound directly to the generated shader. It does not execute
  the proof's 65,536-slot heap, descriptor-copy workload, argument-buffer page
  cache/ring, poisoning, or completion-handler retirement.
- **Barriers:** 122 declared transitions and one required render-to-copy edge,
  checked against actual encoder order. It does not run the proof's randomized
  per-subresource/alias planner inside command submission.
- **Residency:** budget reporting and one 976 KB private-heap placement. It
  does not run alias retirement, checksummed eviction/rematerialization,
  long-session churn, or pressure recovery inside resource creation.

The exact convergence work is to extract private
`AM12DescriptorHeap`, `AM12BarrierTracker`, and `AM12ResidencyManager`
implementations under `Sources/Models/`, then route both their proof harnesses
and the corresponding public command operations through those same objects.
Gate 1 cannot claim that convergence until the original thresholds rerun
through the shared implementations.

Gate 1 also requires a native public-header lowering contract. The current
`run-shader-corpus.sh` invokes the canonical production-local Python lowerer
directly and then gives the library compiled metallib artifacts. That is a
deliberate build/runtime boundary, but it differs from the issue's required
boundary and is therefore recorded as an unmet criterion rather than treated
as equivalent.

## Measurements

### M12-001 promoted descriptor proof

```text
descriptor update: 0.7 ns/descriptor (1M heap writes)
sensitivity: deliberate early recycle -> 64/64 poison reads
randomized model: 1342296 probes verified, 0 mismatches
page encode: 36.9 ns/descriptor (271164 descriptors)
table cache: 485 hits / 1915 misses (20.2%)
page pool: 64 pages, high-water 16, stalls 0
resident memory: 29.6 MB
```

The correctness counts and pool threshold reproduce result 01. Timing is
reported anew rather than copied; page encoding measured 36.9 ns here versus
24.5 ns in the original run.

### M12-002 promoted barrier proof

```text
10000 streams x 200 ops
6180618 hazard pairs, 0 uncovered
conservative 1934 edges/stream, optimized 193.3
90.0% eliminated
dropped-edge sensitivity 100/100
GPU fence chain 0 errors; cross-queue chain 0 errors
hardware interval overlap 11.3 ms
```

### M12-003 original regression subset

The five original supported compute shaders remain GPU-exact in the promoted
10-shader corpus. Graphics regression lowering remains 15 vertex operations
and 99 fragment operations, and both generated MSL files compile.

### Reference client through the library

```text
setup 30.378 ms
first frame 5.460 ms
warm mean / p50 / p95 1.062 / 0.644 / 4.024 ms
digest 44709706809f28e9
changed pixels 230397/230400
descriptor materializations 120, stale rejects 0
barrier transitions 122, required edges 1, uncovered 0
residency placement 976 KB, placements 1
```

The output remains the established M12-006 image: 228,971 of 230,400 pixels
are byte-identical to GPTK and every other pixel differs by one channel value
of one.

## M12-004 execution blocker

The promoted residency source and linked `residency_test` build successfully
and preserve the original alias, eviction/rematerialization, 20,000-operation
churn, oversubscription, bailout, and post-release assertions. Its full
execution intentionally allocates through the Metal advisory budget and up to
one GiB beyond it.

The host safety reviewer rejected that process before launch because the run
could destabilize the machine and the initial task request did not explicitly
authorize that disruptive allocation. No pressure allocation occurred. The
test was not weakened or routed around the safeguard.

This result therefore does **not** claim a new M12-004 runtime-linked
measurement. The pressure portion becomes green only after the user explicitly
authorizes the command and the original zero-mismatch, bounded-churn, and
post-release thresholds pass. Full Gate 1 additionally requires both the
command-path model convergence and public-header lowering contract described
above. Until then, this document is the precise partial/blocker record
permitted by task #84.

## Claim boundary

The completed evidence proves canonical library ownership and linkage for the
full proof implementations, plus new executions of M12-001, M12-002, the
shader path, and the integrated scene. The integrated scene proves only the
smaller command-path subsets listed above; it does not prove that the public
commands share the full proof internals or that the build-time Python lowerer
is behind the public native header. It also does not turn the native command
surface into `d3d12.dll` or replace the missing M12-004 pressure execution
with historical numbers.
