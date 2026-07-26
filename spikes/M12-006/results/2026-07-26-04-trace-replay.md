# M12-006 result 04 — scene-free replay is digest-stable across ten fresh runtimes

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Green
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

- The 27,716-byte Trace 1.0 artifact from result 03, SHA-256
  `4106394cea5fbb044e8c8582865067d168f7f0ab711f27f8175afc6c5f7e7f11`.
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

```text
replay: runs=10 stable=10 digest=44709706809f28e9
changed pixels=230397/230400
status: PASS
```

The mean across all ten fresh runtimes, with full preflight, trace parsing,
temporary metallib materialization, and object reconstruction included in each
setup sample, was:

| Measurement | Live | Replay 10-run mean |
| --- | ---: | ---: |
| Setup | 30.378 ms | 5.175 ms |
| First frame | 5.460 ms | 4.580 ms |
| Warm mean | 1.062 ms | 0.586 ms |
| Warm p50 | 0.644 ms | 0.307 ms |
| Warm p95 | 4.024 ms | 2.009 ms |

The tenth run measured 1.223 ms setup, 4.993 ms first frame, and
0.794 / 0.315 / 3.010 ms warm mean / p50 / p95. Reporting both the aggregate
and last sample avoids selecting one favorable fresh-runtime run.

The replay BMP is byte-identical to the live BMP:

```text
SHA-256 80cbde4aa12a7f8faf6087654d32abd08d7daacbeb636b97257a25cc303b1cca
```

## Validation behavior

`AM12ValidateTrace` applies the same complete preflight without creating Metal
objects. The reference gate accepted the unmodified capture and rejected all
16 targeted mutations:

Before capture/replay, a separate public-command matrix also rejected all five
successful-call divergences it targets: zero-byte writes, a texture-only
resource entering a buffer state, non-finite clear values, presenting undefined
contents, and ending an incomplete frame. `AM12FinishCapture` runs the complete
preflight again before the atomic rename, so an invalid stream is not
published even if a future command-validation mismatch is introduced. Two
destruction regressions also verify cleanup of missing-output and active-frame
captures. Buffer creation deterministically zero-initializes every byte, and
each v1 Draw record is bounded to one three-vertex instance.

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
trace validation mutations: 16/16 rejected
```

The preflight also enforces the Trace 1.0 aggregate limits and canonical
device/metallib/resource/pipeline/frame/output ordering documented in
`Specs/TRACE_FORMAT_V1.md`.

## Claim boundary

Ten-run equality proves deterministic replay of this trace on this host
compatibility epoch. It is not a claim of cross-epoch metallib portability,
general engine-trace coverage, or a Windows D3D12 entry point.
