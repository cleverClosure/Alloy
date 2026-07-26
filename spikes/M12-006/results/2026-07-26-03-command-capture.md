# M12-006 result 03 — command capture is self-contained, deterministic, and pixel-neutral

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Green
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

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

| Measurement | Capture A | Capture B |
| --- | ---: | ---: |
| Setup | 27.209 ms | 30.512 ms |
| First frame | 7.670 ms | 3.253 ms |
| Warm mean | 0.429 ms | 0.434 ms |
| Warm p50 | 0.283 ms | 0.290 ms |
| Warm p95 | 1.125 ms | 1.297 ms |
| Image digest | `44709706809f28e9` | `44709706809f28e9` |
| Nonuniform pixels | 230,397 / 230,400 | 230,397 / 230,400 |

The capture-disabled live run, capture A, and capture B produced byte-identical
BMP files:

```text
SHA-256 80cbde4aa12a7f8faf6087654d32abd08d7daacbeb636b97257a25cc303b1cca
```

The two 27,716-byte traces are themselves byte-identical:

```text
SHA-256 4106394cea5fbb044e8c8582865067d168f7f0ab711f27f8175afc6c5f7e7f11
```

Capture therefore changes CPU timing but not pixels or command semantics.

## Claim boundary

The trace captures every call and caller-provided byte in the current public
subset. A private render target has no invented initial snapshot: its clear,
draw, copy, and present records define its contents.

The embedded metallib makes the file self-contained for replay on the measured
compatibility epoch. It does not promise metallib portability across arbitrary
Apple GPUs, OS releases, or compiler generations.
