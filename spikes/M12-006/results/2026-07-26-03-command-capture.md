# M12-006 result 03 — command capture is self-contained, deterministic, and pixel-neutral

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Green
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

- Tested execution commit
  `94afcc2fee0742b0887f46cd356e1c54a4bb191d`, runtime tree
  `77d5f21cfbdacf8472156f9586942eb6c020a251`, and reference-run manifest
  SHA-256
  `6f866b3cda69ae220fc72673e3c4329d51b0670ae5f726dd2b5c80102fc3db0c`.
- The enclosing unsigned staging generation has `SHA256SUMS` digest
  `5cdc5848e8c133ab3582c5f41e70555e64c0c9f038e6b65e89d22540add72079`.
  It is `STAGING_ONLY`; checksum closure does not provide authenticity or
  durable preservation. The snapshot covers tested commit `94afcc2`; this
  later documentation reconciliation is outside it.
- `runtime/metal12/Specs/TRACE_FORMAT_V1.md`.
- The M12-006 reference scene lowered to a two-function metallib from the
  pinned DXC and Xcode Metal toolchains.
- The public command sequence in
  `runtime/metal12/Tests/vertical_slice.m`.
- Proof command:
  `runtime/metal12/run-reference-trace.sh`.

## Outcome

The optional recorder sits on the public D3D12-shaped command interface. It
records device dimensions, complete metallib bytes, logical resource
declarations, every CPU resource write, pipeline entry names, descriptor
writes/binds, transitions, clears, draws, copies, frame boundaries, presents,
and the output declaration.

Trace 1.0 is a little-endian TLV stream. It contains no timestamp, source path,
host pointer, Objective-C identity, or random identifier.

Capture writes to an exclusive temporary sibling, then
`AM12FinishCapture` flushes, synchronizes, closes, and atomically renames it
onto the requested path. A failed or partial capture is never published as the
final artifact. Two cleanup regressions prove that destruction with either a
missing output declaration or an active frame removes the temporary capture
without replacing a pre-existing destination.

## Capture measurements

### Recorded Gate-2 series A

| Measurement | Capture A | Capture B |
| --- | ---: | ---: |
| Setup | 21.742 ms | 24.234 ms |
| First frame | 3.243 ms | 3.333 ms |
| Warm mean | 0.396 ms | 0.472 ms |
| Warm p50 | 0.289 ms | 0.314 ms |
| Warm p95 | 1.049 ms | 1.349 ms |
| Image digest | `44709706809f28e9` | `44709706809f28e9` |
| Nonuniform pixels | 230,397 / 230,400 | 230,397 / 230,400 |

The capture-disabled live run, capture A, and capture B produced byte-identical
BMP files:

```text
SHA-256 80cbde4aa12a7f8faf6087654d32abd08d7daacbeb636b97257a25cc303b1cca
```

The two 27,800-byte traces in generation A were themselves byte-identical:

```text
SHA-256 e8f09c18700890b90ad75cb2a74389382af6f7e9e086bc61a2b503e97c2cfb65
```

### Final-acceptance reproduction B

| Measurement | Capture A | Capture B |
| --- | ---: | ---: |
| Setup | 23.515 ms | 24.494 ms |
| First frame | 3.382 ms | 10.969 ms |
| Warm mean | 0.373 ms | 0.497 ms |
| Warm p50 | 0.308 ms | 0.339 ms |
| Warm p95 | 0.999 ms | 1.089 ms |
| Image digest | `44709706809f28e9` | `44709706809f28e9` |
| Nonuniform pixels | 230,397 / 230,400 | 230,397 / 230,400 |

Generation B produced two byte-identical 27,736-byte traces:

```text
SHA-256 52f10f9321a54f418f829a601bf52f1087b371075322d270dfad2114627d2855
```

Its capture-disabled live run, both captures, replay, and presentation also
produced the same BMP SHA-256 recorded above. Both generations therefore show
that capture changes CPU timing but not pixels or command semantics.
Generation A remains an unmanifested historical summary. Generation B alone
is bound by the cited manifest, which prevents its timing series and trace
hash from being mistaken for generation A.

## Claim boundary

The trace captures every call and caller-provided byte in the current public
subset. A private render target has no invented initial snapshot: its clear,
draw, copy, and present records define its contents.

The embedded metallib makes the file self-contained for replay on the measured
compatibility epoch. It does not promise metallib portability across arbitrary
Apple GPUs, OS releases, or compiler generations.
