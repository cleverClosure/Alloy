# SPIKE-M12-005 — GPTK D3D12 reference scene

**Author:** Timur Isaev
**Status:** Active (started 24 July 2026)
**Board task:** [#9](https://github.com/cleverClosure/Alloy/issues/9)
**Provenance:** [ADR-0012 discipline model](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md) · log in [PROVENANCE.md](PROVENANCE.md)

## Hypothesis

Apple's lab-only D3DMetal evaluation environment can render a small,
self-verifying D3D12 workload on the target Mac and provide a repeatable visual
and timing baseline for Metal12.

## Method

`scene/d3d12_reference.c` is an original x64 Windows program built with the
pinned llvm-mingw toolchain. It exercises:

- D3D12 device, direct queue, flip-model swap chain, command allocator/list,
  root signature, graphics pipeline, and render-target descriptors;
- runtime HLSL compilation and root constants;
- resource-state transitions, draw submission, presentation, fencing, and GPU
  readback;
- deterministic bitmap capture with a pixel-diversity check and FNV-1a digest;
- setup, first-frame, and warm-frame timing.

`scene/run-reference.sh` creates an isolated CrossOver bottle inside ignored
`work/`, explicitly selects D3DMetal, proves the selected backend from Wine's
process trace, runs the scene, and records the provider identity. No Apple or
CrossOver binary is copied into the repository.

## Legal boundary

This spike is internal evaluation only. GPTK/D3DMetal is never bundled,
redistributed, or used as Alloy's shipping D3D12 provider. The only committed
artifacts are first-party source, hashes/identity metadata, measurements, and a
captured image produced by the first-party scene.

## Results log

Dated notes live in `results/`. Hardware baseline: MacBook Pro M2 Pro, 16 GB,
macOS 26.5.
