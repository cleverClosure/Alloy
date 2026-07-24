# SPIKE-GFX-001 — D3D11 product-quality baseline

**Author:** Tim Isaev
**Status:** Active (started 24 July 2026)
**Canonical definition:** [doc 16 §GFX-001](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md) · provider decision context in [ADR-0006](../../docs/adr/ADR-0006-owned-d3d12-metal-and-reused-d3d11.md)

**Hypothesis:** a Metal-native D3D11 provider (DXMT fork) can deliver stable frame pacing
and correctness for the MVP catalog, integrated with Alloy's EC Wine and FEX CPU path.

**Provenance guard (binding):** the DXMT checkout is fetched with `src/d3d12/` deleted at
clone time (MANIFEST.toml, ADR-0012) — that subtree is a Metal12 clean-room excluded
source. It must never be restored, read, or pasted into any AI context. `enable_d3d12`
stays off.

## Method (incremental gates)

1. **Build survey** — configure/build DXMT (pin `e520fea`, LGPL, CodeWeavers) for this
   stack: ARM64EC PE side via the pinned llvm-mingw (upstream ships `build-arm64ec.txt`),
   unix winemetal side against WINE-001's build-2, airconv shader translator against a
   native LLVM (upstream pins LLVM 15 for AIR compatibility). Failure catalogue is the
   deliverable.
2. **First light** — a minimal D3D11 guest (device + swapchain + clear + readback) renders
   under FEX through DXMT/winemetal in the graphical prefix (CPU-001 result 07 stack).
3. **Triangle-and-texture correctness** — shaders through airconv, vertex/index buffers,
   texture sampling; pixel-exact readback checks.
4. **Scene measurement** — doc 16 scope: candidate games across engines, cold/warm scenes,
   frame percentiles, memory; launcher/game process split via WINE-001 policy routing.

## Pass evidence (from doc 16)

At least two titles reach the proposed Certified gate; remaining defects scoped and
fixable; long-session memory bounded; provider integration and licensing acceptable
(LGPL §2 compliance model per docs/docs/18).

## Results log

Dated notes in `results/`, newest last. Builds and prefixes live in `work/` (gitignored).
Hardware baseline: MacBook Pro M2 Pro, 16 GB, macOS 26.5.
