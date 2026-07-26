# M12-006 result 02 — one Metal12 library runs the promoted proofs and reference client

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Shared-model, public-lowering, and authorized linked M12-004
pressure execution green
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

- Branch `task/84-metal12-phase1`, forked from accepted base `21136e4`.
- The reconciled measurement batch was captured at commit
  `94afcc2fee0742b0887f46cd356e1c54a4bb191d` from runtime tree
  `77d5f21cfbdacf8472156f9586942eb6c020a251`.
- Its build, model, and reference manifests have SHA-256
  `ac45aba8c7e170f29d1063edcc3eb8e24642899232fe261201d007c113d890c2`,
  `cbdbd40f9cac8e1d01de3bfe3386cd5f39ee70adc1d3e3f69fb70d92fd77b744`,
  and
  `6f866b3cda69ae220fc72673e3c4329d51b0670ae5f726dd2b5c80102fc3db0c`.
  The model manifest is intentionally
  `incomplete-pressure-not-run`; the reference manifest is
  `complete-presented`.
- That execution batch is packaged in the checksum-closed unsigned staging
  generation whose `SHA256SUMS` digest is
  `5cdc5848e8c133ab3582c5f41e70555e64c0c9f038e6b65e89d22540add72079`.
  Its classification is `STAGING_ONLY`: checksum closure is not signer
  authentication or durable preservation. The snapshot covers tested commit
  `94afcc2`; this later documentation reconciliation is outside it.
- The authorized pressure generation was executed at tested commit
  `5c463b76dd18f37c06a4ab22b11d5347514fab21`, runtime tree
  `c0b354313cc9d97f69c0b19d6a138e9ce7b44f39`, and build-manifest SHA-256
  `88aefac1d766dfd9c60faa3e37165bfd9cd2872a39dacd0fd4d12952b0faae11`.
  Its model-run manifest SHA-256 is
  `c9aebbf498fa22ec5e44b4eeb8f2fc00dbe4d90957e4eb481ffba61b84afe8d0`,
  with `status: complete-pressure-pass` and `residency_mode: pressure`.
- That execution is packaged in the checksum-closed local unsigned staging
  generation whose `SHA256SUMS` digest is
  `2b8ef5a50a20dc3a52c8833b206d1a01cb2bfaae9b0fa262bbfde9a6752a0d6d`.
  It remains `STAGING_ONLY`; the snapshot covers tested commit `5c463b7`,
  while this later result update is outside it.
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
boundaries. The authorized full residency execution now supplies the remaining
hardware-pressure evidence on this host.

## Recorded measurements

The following subsections retain the Gate-1 convergence series (generation A)
that originally established the result. The final-acceptance reproduction
(generation B) is reported separately so values from the two invocations are
not mixed.

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

### Final-acceptance reproduction B

The manifest-bound reproduction re-executed the same functional thresholds:

```text
descriptor update: 69.6 ns/descriptor (1M heap writes)
randomized model: 1342296 probes verified, 0 mismatches
page encode: 81.8 ns/descriptor (271164 descriptors)
page pool: 64 pages, high-water 17, stalls 0
resident memory: 29.7 MB

6180618 hazard pairs, 0 uncovered
90.0% eliminated; dropped-edge sensitivity 100/100
GPU fence chain 0 errors; cross-queue chain 0 errors
two queues 17.3 ms vs fence-serialized 32.0 ms (1.85x)

live setup / first frame 25.748 / 13.375 ms
live warm mean / p50 / p95 0.534 / 0.350 / 1.001 ms
digest 44709706809f28e9
changed pixels 230397/230400
```

Generation B reproduces the disposition; it does not erase generation A.
Its model status remains `incomplete-pressure-not-run`, with
`residency_mode: none`. A later HEAD-bound capture can produce different
timings without changing this batch's implementation identity: the immutable
runtime-tree identifier and machine manifests bind generation B without
requiring a tracked result document to predict its own future commit hash.

### Authorized pressure reproduction C

After explicit user authorization, the linked full proof passed:

```text
budget: recommended max 12124 MB, baseline usage 0.1 MB
aliasing: A@0 then B@0; A reads 0xBB
eviction cache: 137 evictions, 109 rematerializations, 0 mismatches
long session: 20000 ops in 0.2 s, peak 820 MB
post-churn usage: 0.1 MB -> 0.1 MB (delta 0.0 MB)
oversubscription: 13184 MB allocated against 12124 MB budget
allocation failures / evict-retry recoveries: 0 / 0
post-release Metal allocation: 0.1 MB
post-release process footprint: 3.8 MB
status: complete-pressure-pass
```

This generation supersedes the earlier blocker disposition without rewriting
the historical no-pressure runs. It proves placement aliasing, checksummed
eviction/rematerialization, bounded churn, intentional advisory-budget
oversubscription, and post-release drain through the shared library on the
measured 16 GB host.

## Claim boundary

The completed evidence proves shared implementation—not only archive
ownership—for descriptor, barrier, and residency operations; public,
fail-closed entry into the canonical lowerer; new M12-001/M12-002 executions;
the authorized M12-004 pressure execution; and an integrated image whose
descriptor page and fence plan are load-bearing.
It does not turn the native command surface into `d3d12.dll`, broaden the
single-CBV graphics slice, authenticate the caller-provided disassembly body
against adversarial rewriting, or extrapolate one 16 GB host run into the
unmeasured 24/32/64 GB residency matrix.
