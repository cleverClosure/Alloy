# M12-006 result 02 — one Metal12 library runs the promoted proofs and reference client

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Shared-model and public-lowering convergence green; the linked
M12-004 high-memory execution remains blocked on explicit host-risk approval
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

`runtime/metal12/` contains one Objective-C static archive behind
`include/AlloyMetal12.h`. The public surface owns logical resources,
placement-backed render targets, shared buffers, descriptor tables, state
transitions, draw/copy/present commands, submission, capture/replay, image
measurement, shader-proof validation, and DXIL-to-MSL lowering.

`Tests/vertical_slice.m` contains scene data and assertions only. Its resource,
descriptor, barrier, render, copy, submit, present, and readback operations all
go through the public header.

The native model harnesses are library-owned proof functions with tiny linked
clients. Their descriptor, barrier, and residency logic is factored into
`Sources/Models/`; the proofs and matching public commands call the same
components with different capacities.

The linked `AM12LowerDXILToMSL` contract takes only DXIL, hash-matched DXC
disassembly, and output-directory paths. The interpreter is build-pinned, and
the canonical script payload plus SHA-256 are embedded in the archive. The
boundary stages inputs privately, rejects inconsistent embedded hash values
before launch, validates fresh MSL/provenance/fixture hashes after launch, and
only then publishes. Same-shader writers are serialized and ordinary
failures trigger rollback; interrupted transactions are recovered before the
next publication. Positive, poisoned-`PATH`, stale-artifact, mismatched-pair,
oversized-part-table, resource-index, operation-count,
unsupported-graphics-CBV, and legacy `/usr/bin/true` bypass tests pass. The
child inherits only available standard descriptors and has a 30-second
kill-and-reap deadline.

## Architecture claim boundary

The reference path uses narrower configurations of the shared models:

- **Descriptors:** a 256-slot `AM12DescriptorHeap` validates the CBV
  generation, materializes and completion-retains a one-entry GPU-address
  page, and binds only that page. Generated fragment MSL dereferences page
  index 0, and the encoder declares the indirect resource with `useResource`;
  page consumption therefore governs the image.
- **Barriers:** `AM12BarrierTracker` is the only resource-state authority.
  Actual encoder accesses append atomically, the optimized plan compiles before
  encoding, every producer owns a distinct `MTLFence`, and consumers wait
  using plan-derived producer masks. Frame-end verification checks every exact
  plan edge against the emitted wait.
- **Residency:** `AM12ResidencyManager` creates committed shared buffers,
  reports the Metal budget, and owns the 64 MiB placement heap plus the
  reference render target's 976 KiB placement lease. The same manager carries
  the proof's alias, LRU, churn, and pressure paths.

This satisfies Gate 1's shared-implementation and one-public-header
boundaries. The remaining exception is execution evidence for the
intentionally high-memory residency paths.

## Measurements

### M12-001 shared descriptor proof

```text
descriptor update: 64.9 ns/descriptor (1M heap writes)
sensitivity: deliberate early recycle -> 64/64 poison reads
randomized model: 1342296 probes verified, 0 mismatches
page encode: 59.1 ns/descriptor (271164 descriptors)
table cache: 485 hits / 1915 misses (20.2%)
page pool: 64 pages, high-water 17, stalls 0
resident memory: 29.6 MB
```

The fixed seed, correctness counts, cache split, poison sensitivity, and
zero-stall threshold reproduce the promoted proof through the shared
descriptor component. Timing is reported anew rather than copied.

### M12-002 shared barrier proof

```text
10000 streams x 200 ops
6180618 hazard pairs, 0 uncovered
conservative 1934 edges/stream, optimized 193.3
90.0% eliminated
dropped-edge sensitivity 100/100
GPU fence chain 0 errors; cross-queue chain 0 errors
two queues 27.9 ms vs fence-serialized 46.6 ms (1.67x)
```

### M12-003 regression subset

The ten supported compute shaders are GPU-exact and the unsupported
`waveReadLaneAt` case retains its named rejection. Graphics lowering remains
15 vertex operations and 99 fragment operations. Both generated MSL files
compile, and the fragment static gate proves the descriptor-page ABI replaced
the old direct CBV parameter.

### Reference client through the shared library

```text
setup 24.424 ms
first frame 4.814 ms
warm mean / p50 / p95 0.468 / 0.331 / 1.019 ms
digest 44709706809f28e9
changed pixels 230397/230400
descriptor materializations 120, stale rejects 0
barrier transitions 123, required/emitted/unmet edges 1/1/0
residency placement 976 KB, placements 1
```

The output remains the established M12-006 image: 228,971 of 230,400 pixels
are byte-identical to GPTK and every other pixel differs by one channel value
of one. The BMP SHA-256 is
`80cbde4aa12a7f8faf6087654d32abd08d7daacbeb636b97257a25cc303b1cca`.

## M12-004 execution blocker

The linked residency implementation preserves placement aliasing, checksummed
eviction/rematerialization, 20,000-operation churn, oversubscription, bailout,
and post-release assertions. Its separated safe path can still peak around
820 MiB; the full path intentionally allocates through the Metal advisory
budget and up to one GiB beyond it.

Those executions could destabilize the machine and were not authorized by the
task request. Neither path was launched, and no historical number is presented
as a current run.

The residency evidence becomes green only after the user explicitly authorizes
the relevant command and the original zero-mismatch, bounded-churn, pressure,
and post-release thresholds pass. This is the precise blocker record permitted
by task #84.

## Claim boundary

The completed evidence proves shared implementation—not only archive
ownership—for descriptor, barrier, and residency operations; public,
fail-closed entry into the canonical lowerer; new M12-001/M12-002 executions;
and an integrated image whose descriptor page and fence plan are load-bearing.
It does not turn the native command surface into `d3d12.dll`, broaden the
single-CBV graphics slice, authenticate the caller-provided disassembly body
against adversarial rewriting, or replace the missing M12-004 high-memory
execution with historical numbers.
