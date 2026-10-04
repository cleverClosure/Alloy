# M12-006 result 04 — scene-free replay is digest-stable across ten fresh runtimes

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Green
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

- The original result-03 run used the 27,716-byte Trace 1.0 artifact, SHA-256
  `4106394cea5fbb044e8c8582865067d168f7f0ab711f27f8175afc6c5f7e7f11`.
- The earlier Gate-1 convergence rerun used a 27,800-byte Trace 1.0
  artifact, SHA-256
  `e8f09c18700890b90ad75cb2a74389382af6f7e9e086bc61a2b503e97c2cfb65`.
  Two independent captures produced that same byte sequence.
- The reconciliation batch used two byte-identical 27,736-byte Trace 1.0
  artifacts, SHA-256
  `52f10f9321a54f418f829a601bf52f1087b371075322d270dfad2114627d2855`.
  It was captured at commit
  `94afcc2fee0742b0887f46cd356e1c54a4bb191d`, from runtime tree
  `77d5f21cfbdacf8472156f9586942eb6c020a251`, under reference-run
  manifest SHA-256
  `6f866b3cda69ae220fc72673e3c4329d51b0670ae5f726dd2b5c80102fc3db0c`.
- The enclosing unsigned staging generation has `SHA256SUMS` digest
  `5cdc5848e8c133ab3582c5f41e70555e64c0c9f038e6b65e89d22540add72079`
  and classification `STAGING_ONLY`; it is checksum-closed but
  unauthenticated. The snapshot covers tested commit `94afcc2`; this later
  documentation reconciliation is outside it.
- `libAlloyMetal12.a`.
- `Tools/metal12_replay.m`, linked only against the library and system
  frameworks. It contains no HLSL, scene constants, fixture image, or
  reference-scene source.
- Command:
  `runtime/metal12/build/metal12_replay reference-a.am12 replay.bmp 10`.

## Outcome

The library first completes a side-effect-free structural and semantic
preflight. Only then does each run extract the embedded metallib to private
temporary storage, create a fresh Metal runtime, recreate logical resources
and descriptors, and invoke the same public commands used by a live client.
The original, convergence, and reconciliation runs reported the same digest
and changed-pixel count; the reconciliation log is:

```text
replay: runs=10 stable=10 digest=44709706809f28e9
metric: changed_pixels=230397
status: PASS
```

The original result and Gate-1 convergence series (generation A) measured:

| Measurement | Original live | Original replay mean | Convergence live | Convergence replay mean |
| --- | ---: | ---: | ---: | ---: |
| Setup | 30.378 ms | 5.175 ms | 24.424 ms | 4.397 ms |
| First frame | 5.460 ms | 4.580 ms | 4.814 ms | 2.892 ms |
| Warm mean | 1.062 ms | 0.586 ms | 0.468 ms | 0.341 ms |
| Warm p50 | 0.644 ms | 0.307 ms | 0.331 ms | 0.274 ms |
| Warm p95 | 4.024 ms | 2.009 ms | 1.019 ms | 0.648 ms |

The original tenth run measured 1.223 ms setup, 4.993 ms first frame, and
0.794 / 0.315 / 3.010 ms warm mean / p50 / p95. The convergence tenth run
measured 1.622 ms setup, 2.492 ms first frame, and
0.266 / 0.240 / 0.339 ms for the same warm measurements.

The manifest-bound final-acceptance reproduction (generation B) measured:

| Measurement | Reconciled live | Reconciled replay mean |
| --- | ---: | ---: |
| Setup | 25.748 ms | 3.694 ms |
| First frame | 13.375 ms | 3.321 ms |
| Warm mean | 0.534 ms | 0.363 ms |
| Warm p50 | 0.350 ms | 0.287 ms |
| Warm p95 | 1.001 ms | 0.787 ms |

Generation B's tenth replay measured 1.285 ms setup, 3.423 ms first frame,
and 0.310 / 0.264 / 0.544 ms warm mean / p50 / p95. Reporting aggregates and
last samples avoids selecting one favorable fresh-runtime run, while naming
the evidence generations keeps their timing series distinct.

The replay BMP is byte-identical to the live BMP:

```text
SHA-256 80cbde4aa12a7f8faf6087654d32abd08d7daacbeb636b97257a25cc303b1cca
```

## Validation behavior

`AM12ValidateTrace` applies the same complete preflight without creating Metal
objects. The original result rejected 16 targeted mutations. The
reconciliation build accepted the unmodified capture and rejected all 17,
including the later `barrier_access_overflow` mutation that exceeds the
runtime tracker's per-frame access capacity.

Before capture/replay, the public-command matrix now rejects all six
successful-call divergences it targets: zero-byte writes, a texture-only
resource entering a buffer state, a stale descriptor generation, non-finite
clear values, presenting undefined contents, and ending an incomplete frame.
The stale-descriptor case is the sixth rejection added since the original
five-case result. `AM12FinishCapture` runs the complete preflight again before
the atomic rename, so an invalid stream is not published even if a future
command-validation mismatch is introduced. The two destruction regressions
still verify cleanup of missing-output and active-frame captures. Buffer
creation deterministically zero-initializes every byte, and each v1 Draw
record is bounded to one three-vertex instance.

```text
public command validation: 6/6 rejected
capture cleanup validation: 2/2 cleaned
```

```text
bad magic                         rejected
bad header version                rejected
truncated tail                    rejected
unknown opcode                    rejected
nonzero record flags              rejected
missing metallib                  rejected
missing output                    rejected
duplicate device                  rejected
oversized dimension               rejected
oversized frame count             rejected
oversized buffer                  rejected
bad write range                   rejected
transition before-state mismatch  rejected
descriptor generation mismatch    rejected
frame index mismatch              rejected
oversized draw                     rejected
barrier access overflow            rejected
trace validation mutations: 17/17 rejected
```

The preflight also enforces the Trace 1.0 aggregate limits and canonical
device/metallib/resource/pipeline/frame/output ordering documented in
`Specs/TRACE_FORMAT_V1.md`.

## Claim boundary

Ten-run equality proves deterministic replay of this trace on this host
compatibility epoch. It is not a claim of cross-epoch metallib portability,
general engine-trace coverage, or a Windows D3D12 entry point.
