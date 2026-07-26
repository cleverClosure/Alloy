# M12-006 result 06 — 120 CAMetalLayer frames preserve pixels and expose real pacing

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Green
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

- The same 640 × 360 reference metallib and public command sequence as the
  offscreen live/capture runs.
- A visible `NSWindow` with an RGBA8Unorm `CAMetalLayer`, two drawables,
  `framebufferOnly = NO`, and display sync disabled to match the GPTK
  `Present(0, 0)` intent.
- Exactly 120 acquire, encode, commit, present, and completion-wait cycles.
- Three complete presentation invocations; the table uses invocation 3 to
  match the GPTK result's third-run cache-warm anchor.
- On the final frame, the public copy command defers its readback until the
  offscreen source has been blitted into the drawable. The test then copies the
  drawable into the readback buffer before scheduling presentation and waits
  for the final drawable's presented callback. The drawable is therefore the
  presented run's image authority.

## Pixel result

```text
presented frames: 120
drawable readbacks: 1
changed pixels: 230397/230400
image digest: 44709706809f28e9
status: PASS
```

The presented-run BMP and the offscreen live BMP are byte-identical:

```text
SHA-256 80cbde4aa12a7f8faf6087654d32abd08d7daacbeb636b97257a25cc303b1cca
```

Presentation changed pacing, not pixels.

## Like-for-like timing statement

The Metal12 setup timer starts before `NSApplication`, window, and layer
creation and stops after the Metal device, two-drawable layer, heap, resources,
descriptors, and pipeline are ready. The frame timer starts before drawable
acquisition and includes the per-frame constant update and root-table bind,
encoding, presentation scheduling, and GPU completion; the final sample also
waits for the presented callback. GPTK likewise starts setup before window
creation and stops after its swapchain/resources/pipeline/fence are ready, then
times per-frame constants, encoding, `Present(0, 0)`, and its GPU fence.

The workloads still have an implementation difference that the table does not
erase: Metal12 renders to one private offscreen texture and blits it into the
drawable, whereas GPTK renders directly into its current backbuffer. The
comparison is a measured presented-workload boundary, not proof of identical
internal work.

The explicit Metal12 cache-warm series was:

| Invocation | Setup | First | Warm mean | Warm p50 | Warm p95 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 126.032 ms | 6.729 ms | 15.046 ms | 16.527 ms | 24.080 ms |
| 2 | 96.889 ms | 4.049 ms | 11.344 ms | 12.265 ms | 19.326 ms |
| 3 | 103.987 ms | 3.929 ms | 12.919 ms | 14.485 ms | 19.110 ms |

| Measurement | Metal12 CAMetalLayer | GPTK run 3 cache-warm anchor | Metal12 minus GPTK |
| --- | ---: | ---: | ---: |
| Setup | 103.987 ms | 187.617 ms | -83.630 ms |
| First submitted frame | 3.929 ms | 26.788 ms | -22.859 ms |
| Warm mean | 12.919 ms | 6.165 ms | +6.754 ms |
| Warm p50 | 14.485 ms | 3.711 ms | +10.774 ms |
| Warm p95 | 19.110 ms | 15.894 ms | +3.216 ms |

This replaces result 01's warning about reading an offscreen warm row as a
speedup. On the measured presented boundary, Metal12's warm mean is **2.10×
the GPTK frame time**, not twenty times faster. Metal12 setup and first frame
are shorter for this tiny native slice, but these single-host samples are
engineering evidence, not product performance claims.

## Claim boundary

The test proves a visible CAMetalLayer swapchain and deterministic presentation
for this scene. It does not isolate compositor latency, establish behavior
under occlusion or resize, cover HDR/high-DPI formats, or predict real-title
frame pacing.
