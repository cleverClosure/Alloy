# SPIKE-M12-005 — GPTK D3D12 reference scene

**Author:** Timur Isaev
**Status:** Complete (24–25 July 2026)
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

`scene/install-gptk-lab.sh` is an interactive founder-only installer. It mounts
Apple's disk image read-only, displays the bundled license, requires the
founder to type `I ACCEPT`, and copies the evaluation libraries only into
ignored `work/`. `scene/run-reference.sh` overlays that task-local provider
onto the signed CrossOver runtime, creates a dedicated bottle inside ignored
`work/`, explicitly selects D3DMetal, proves the selected backend from Wine's
process trace, runs the scene, and records the provider identity. Neither the
installed CrossOver app nor any existing bottle is modified.

## Legal boundary

This spike is internal, non-commercial evaluation only, consistent with
[SPIKE-LEGAL-001](../../docs/research/SPIKE-LEGAL-001-preliminary-findings.md)
and decision
[D-021](../../docs/docs/14_DECISION_LOG.md). GPTK/D3DMetal is never bundled,
redistributed, or used as Alloy's shipping D3D12 provider. The only committed
artifacts are first-party source, hashes/identity metadata, measurements, and a
captured image produced by the first-party scene.

## Results log

Dated notes:

- [Result 01](results/2026-07-24-01-d3dmetal-reference-green.md) — predecessor
  baseline using CrossOver's bundled D3DMetal 3.0.
- [Result 02](results/2026-07-25-02-gptk4-reference-green.md) — founder-installed
  GPTK 4.0 beta 1 baseline; task #9 done criteria met.

Hardware baseline: MacBook Pro M2 Pro, 16 GB, macOS 26.5.2.
