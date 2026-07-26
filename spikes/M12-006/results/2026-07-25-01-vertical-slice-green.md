# M12-006 result 01 — the four prototypes compose: the reference scene renders on Metal, 99.38% byte-identical to the GPTK baseline

**Author:** Timur Isaev
**Date:** 25 July 2026
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB · **OS:** macOS 26.5.2 (`25F84`)
**Provenance:** ADR-0012 discipline model, inputs in [PROVENANCE.md](../PROVENANCE.md) — no excluded source consulted.

## Verdict

```text
metric: changed_pixels=230397/230400
metric: image_fnv1a64=44709706809f28e9
model: residency budget_mb=12124 placed_kb=976 placements=1
model: vheap materializations=120 stale_rejects=0
model: barriers transitions=122 edges_required=1 satisfied_by_encoder_order=1 explicit_needed=0
status: PASS

identical pixels: 228971/230400 (99.380%)
max-channel-delta histogram:
  delta   0:  228971 pixels (99.380%)
  delta   1:    1429 pixels (0.620%)
worst pixel at (35, 0): per-channel delta [1, 0, 0]
```

The D4 hypothesis holds at vertical-slice scope. The M12-001..004 prototypes,
each of which had only ever run against its own synthetic model, compose into
one path that renders the M12-005 reference scene. Against Apple's evaluation
environment as the answer key, **99.380% of pixels are byte-identical and no
pixel anywhere in the image differs by more than 1/255 on one channel.**

![Metal12 vertical slice](2026-07-25-metal12-slice.png)

## The digest does not match, and that is the interesting part

| | Value |
| --- | --- |
| GPTK baseline (recorded by M12-005, reproduced here) | `825861ee12085256` |
| Metal12 slice, three consecutive runs | `44709706809f28e9` |
| Nonuniform pixels, both | 230,397 / 230,400 |

A digest mismatch on its own says nothing, so the comparison reports the
distribution instead. Of 230,400 pixels, 228,971 are exactly equal; the other
1,429 differ by **exactly one** in a single channel. The maximum error over the
whole image is one least-significant bit.

Two things make that number trustworthy rather than reassuring:

- The comparison tool **reproduces the baseline's recorded digest**,
  `825861ee12085256`, from the committed PNG. If it could not, the slice's
  digest would be uninterpretable. Getting there required matching
  `d3d12_reference.c`'s digest constants rather than FNV-1a's: the scene seeds
  with `1469598103934665603`, which is not the standard 64-bit offset basis,
  and the textbook value produces a number comparable with nothing.
- The nonuniform-pixel count is *identical*, not merely similar — the same
  three pixels match the first pixel in both images. A structural difference
  would not land on the same three.

**Attribution.** The two paths do not use the same shader compiler. The
baseline compiles `vs_5_1`/`ps_5_1` to DXBC through `D3DCompile`; this path
compiles the same 1,333 bytes of HLSL to `vs_6_0`/`ps_6_0` DXIL with `dxc`,
because DXIL is what the M12-003 pipeline ingests. The scene's pixel shader is
transcendental-heavy — `cos` twice, `atan` reconstructed into `atan2` with
quadrant fixups, `sqrt`, `frac`, `floor` — and a 1-ULP disagreement in any of
those lands exactly here.

Rebuilding the MSL with `-fno-fast-math` was the falsification attempt: it
moves the digest to `4e24d9c0d91308de` and leaves the delta at 1 LSB over
0.621% of pixels — 228,970 identical instead of 228,971. Fast math is
therefore not the explanation, which points at the compiler pair rather than
at one build flag.

## What each prototype actually contributed

| Spike | In this slice | Exercised how far |
| --- | --- | --- |
| M12-001 descriptor virtualization | The root-constant CBV is a heap record with a generation; every frame materializes it through the heap, and a generation mismatch returns nil rather than a stale resource | 120 materializations, 0 stale rejects. **The argument-buffer page encoding is not exercised** — see deviations |
| M12-002 barrier tracker | Every state change is declared to the tracker, which derives the ordering edges the frame requires; the run then checks each against the encoder order emitted and fails on any not covered | 122 transitions, 1 edge required, 1 satisfied by encoder order, 0 needing an explicit Metal barrier |
| M12-003 shader path | Both shaders are MSL lowered from the scene's DXIL by the extended lowering | Vertex and fragment stages, 15 and 99 ops |
| M12-004 residency | The render target is a placement allocation from a reserved private heap behind a model that reports a D3D12-shaped budget | Budget 12,124 MB, 976 KB placed, 1 placement |

## Timings: offscreen attribution and measured presented comparison

The original three offscreen runs all produced the same image:

| Measurement | Run 1 | Run 2 | Run 3 | GPTK cache-warm anchor |
| --- | ---: | ---: | ---: | ---: |
| Setup | 26.229 ms | 43.811 ms | 24.242 ms | 187.617 ms |
| First submitted frame | 3.066 ms | 6.730 ms | 3.380 ms | 26.788 ms |
| Warm mean (119 frames) | 0.314 ms | 0.287 ms | 0.382 ms | 6.165 ms |
| Warm p50 | 0.259 ms | 0.272 ms | 0.280 ms | 3.711 ms |
| Warm p95 | 0.627 ms | 0.369 ms | 1.006 ms | 15.894 ms |

Those rows remain useful only to attribute the runtime's offscreen cost. Phase
1 now supplies the missing presented boundary: a recorded three-run series
through a visible 640 × 360 `CAMetalLayer`, with the final drawable as pixel
authority. Invocation 3 is compared with GPTK's third-run cache-warm anchor:

| Measurement | Metal12 CAMetalLayer | GPTK run 3 cache-warm anchor | Metal12 minus GPTK |
| --- | ---: | ---: | ---: |
| Setup | 75.481 ms | 187.617 ms | -112.136 ms |
| First submitted frame | 4.922 ms | 26.788 ms | -21.866 ms |
| Warm mean | 8.243 ms | 6.165 ms | +2.078 ms |
| Warm p50 | 8.370 ms | 3.711 ms | +4.659 ms |
| Warm p95 | 11.207 ms | 15.894 ms | -4.687 ms |

The presented path has the same digest, `44709706809f28e9`, and a
byte-identical BMP. Presentation changed pacing, not pixels. On this measured
boundary Metal12's warm mean is **1.34× the GPTK frame time**, not twenty times
faster. Metal12 still renders offscreen and blits into its drawable while GPTK
renders directly into its backbuffer, so these single-host figures remain
engineering evidence rather than a general product-performance claim. Exact
method, all three historical runs, the separate final-acceptance reproduction
that measured a 1.33× warm-mean ratio, and the claim boundary are recorded in
[result 06](2026-07-26-06-cametallayer-presentation.md).

## Deviations, stated rather than buried

1. **The original run had no swap chain or present.** Its offscreen target and
   single capture explain the historical warm-frame attribution above. Phase 1
   closes that measurement gap with the separately recorded `CAMetalLayer`
   path; it does not rewrite what this original invocation executed.
2. **The CBV is bound directly, not through an argument-buffer page.** The
   virtual heap holds the record and gates the binding on its generation, which
   is the model's correctness core, but the lowering emits
   `constant float4 *cb0 [[buffer(0)]]`, so the page encode/recycle path
   M12-001 measured at 24.5 ns/descriptor is not on this critical path. Putting
   it there requires the lowering to emit an indexed page read.
3. **The barrier tracker is applied, not re-proven.** This frame needs exactly
   one ordering edge. M12-002's 90%-elimination result came from 10,000
   randomized two-queue streams; a one-edge frame cannot re-test it. What is
   tested here is that the tracker's plan is *checked* against what was emitted
   rather than assumed.
4. **Only the render target is a placement allocation.** The readback and
   constant buffers need CPU access and are shared-storage allocations outside
   the private heap, so `placements=1`.
5. **Shader model differs from the baseline**, as above.

## Implications for pending decision 3 — Metal12 GA feature subset

**Phase-1 update:** presentation is now measured rather than inferred. The
presented mean does not support the original apparent speedup, and it leaves
the feature decision dependent on breadth rather than this tiny scene's
pacing. The promoted runtime now measures explicit-LOD point/bilinear textures,
three wave patterns, capture/replay, and a real presentation boundary; control
flow, broader resources and descriptors, real-title traces, and the blocked
high-memory residency execution remain outside the evidenced subset. The
current decision statement is recorded in
[result 07](2026-07-26-07-phase1-decision-feed.md).

At the time of result 01, the original slice's shader path covered the
following, with everything outside it failing on a named diagnostic rather
than degrading silently:

- **Stages**: compute, vertex, fragment.
- **Arithmetic**: `fmul`/`fadd`/`fsub`/`fdiv`, integer `mul`/`add`/`sub`,
  `fmin`/`fmax`, `fcmp` in `ogt`/`olt`/`oge`/`ole`/`oeq`, `select`, i1
  `and`/`or`.
- **Intrinsics**: `FAbs`, `Saturate`, `Cos`, `Sin`, `Atan`, `Frc`, `Sqrt`,
  `Round_ne`, `Round_ni`, `Round_pi`, `Round_z`.
- **Binding**: raw buffer load/store, constant-buffer loads via
  `cbufferLoadLegacy`, signature-driven stage inputs and outputs, constant
  arrays hoisted by dxc.

What the original result left unanswered, in rough order of how much of a real
title each item gated:

1. **Control flow.** Neither stage in this scene branches, so the normalized IR
   was straight-line by construction. Loops and branches were the single
   largest shape-changing gap.
2. **Textures and samplers.** Nothing in the original slice sampled anything.
   A sampling scene was needed to exercise that shader class.
3. **Structured/typed UAVs and atomics** beyond the raw-buffer form.
4. **Wave intrinsics**, then rejected by name — `wave_cs` was the historical
   corpus's rejected case.
5. **Geometry, hull, domain, mesh and amplification stages**, none of which are
   touched by this scene.

The evidence this original result added to the decision was narrow but real:
for a straight-line shader over constants and raw buffers, the translation
is faithful to within 1 LSB, and the descriptor, barrier and residency models
survived contact with each other. Result 01 alone said nothing about control
flow or texturing; [result 05](2026-07-26-05-shader-subset.md) later added
explicit-LOD texture and wave evidence while leaving control flow open.

## Reproduce

```sh
spikes/M12-006/prototype/run-slice.sh
```

Compiles the scene HLSL to DXIL with the pinned `dxc` under Alloy's own
Wine/FEX stack, lowers both stages to MSL, links a metallib, builds and runs
the slice, and compares the result against the committed baseline image. At
the time of this result, the historical M12-003 compute corpus passed 5/1/0
with byte-identical MSL hashes. The canonical runtime corpus now records
10 GPU-exact passes, one named rejection, and zero failures in
[result 05](2026-07-26-05-shader-subset.md).
