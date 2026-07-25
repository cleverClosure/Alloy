# SPIKE-M12-006 — first Metal12 vertical slice

**Author:** Tim Isaev
**Status:** Active (started 25 July 2026)
**Board task:** [#45](https://github.com/cleverClosure/Alloy/issues/45)
**Provenance:** [ADR-0012 discipline model](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md) · log in [PROVENANCE.md](PROVENANCE.md)

**Hypothesis:** the four M12-001..004 prototypes, which each proved one
subproblem in isolation, compose into a single Metal path that renders the
M12-005 reference scene and stands comparison against the GPTK baseline.

## What "renders the reference scene" means here

The baseline ([M12-005 result 02](../M12-005/results/2026-07-25-02-gptk4-reference-green.md))
is an x64 D3D12 PE executed by Apple's evaluation environment. This spike does
**not** re-implement `d3d12.dll` and does not execute that PE. It performs the
same D3D12-shaped sequence natively on Metal — same shaders, same 120 animated
frames at the same resolution, same readback — so the two paths can be compared
digest-for-digest and millisecond-for-millisecond.

That distinction is the whole claim boundary. A digest match proves the
translation of *this scene's* shader and binding model is faithful; it proves
nothing about API coverage, and nothing renders through a D3D12 entry point.

## Method

1. **Shader path.** Extend the M12-003 DXIL→MSL lowering from its compute
   subset to the vertex and fragment stages the scene needs, using the same
   rules: a defined subset, a named diagnostic for anything outside it, and
   byte-identical output across two runs.
2. **Binding.** Bind the scene's one root-constant buffer through the M12-001
   virtual-heap/argument-buffer model rather than a direct Metal binding, so
   the slice exercises the descriptor path.
3. **Barriers.** Drive render-target and readback transitions through the
   M12-002 tracker so the emitted Metal synchronization is the tracker's plan,
   not hand-placed.
4. **Residency.** Allocate the render target, readback buffer and constant
   buffer through the M12-004 residency model.
5. **Compare.** Capture the final frame, compute the same nonuniform-pixel
   count and FNV-1a digest the baseline reports, and record setup, first-frame
   and warm-frame timings beside it.

## Shader inputs the scene actually needs

Taken from the DXIL that `dxc` produces for the extracted scene HLSL, so the
subset is bounded by measurement rather than by guess:

| Form | Count | Status before this spike |
| --- | ---: | --- |
| `dx.op.unary.f32` (6 FAbs, 7 Saturate, 12 Cos, 17 Atan, 22 Frc, 24 Sqrt, 27 Round_ni) | 14 | not supported |
| `dx.op.storeOutput.f32` | 12 | not supported |
| `dx.op.loadInput.f32` / `.i32` | 5 | not supported |
| `dx.op.cbufferLoadLegacy.f32` | 2 | not supported |
| `dx.op.createHandle` | 2 | supported |
| `fmul` / `fadd` / `fsub` / `fdiv` | 66 | supported |
| `fcmp` (`oeq`, `oge`, `olt`) | 5 | `oeq` not supported |
| `select` | 5 | supported |
| `and` (i1) | 4 | not supported |
| `getelementptr` + `load` on a constant `[3 x float]` global | 4 | not supported |

There is no control flow in either stage — no branches, no loops, no phi
nodes — so the existing straight-line normalized-IR shape still holds.

## Deviation from the baseline's shader model

The baseline compiles `vs_5_1`/`ps_5_1` through `D3DCompile`, which produces
DXBC. This path compiles the same HLSL to `vs_6_0`/`ps_6_0` DXIL with `dxc`,
because DXIL is what M12-003's pipeline ingests. Two different compilers can
round differently, so an image delta is possible and would be a property of the
shader compiler rather than of the Metal translation. Any delta is reported
per-channel rather than waved through.

## Falsification

- A digest match that survives only because the comparison is loose. The
  nonuniform-pixel count and the full-image FNV-1a are both reported, and the
  image is committed.
- A lowering that happens to work for this one scene. Anything outside the
  subset must fail with a named diagnostic rather than silently degrade, and
  the M12-003 compute corpus must keep passing unchanged.
