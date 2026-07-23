# ADR-0011: Support a Modern Baseline Only

**Status:** Accepted
**Date:** 23 July 2026
**Author:** Tim Isaev
**Decision owners:** CEO/CTO (founder), Product
**Related requirements:** RUN-004, RUN-005, RUN-006, RUN-007, CMP-010, INS-008

## Context

The v1.0 documentation carried a substantial legacy surface: 32-bit games as a deferred "later tier" (R-033), D3D8/9/DirectDraw/OpenGL layered providers in the contract surface (`d3d9on11-dxmt`, `wined3d`, `native-opengl`), a macOS 14.4 working floor with "one or more prior majors," an 8 GB memory class in the graphics-memory spike, WMV/VC-1-era media bridging, DirectInput-era input certification, and standalone wizard-installer support. Each legacy dimension is not one more code path but one more conformance suite, certification-matrix row, lab dimension, and support playbook — forever (see R-026). The team is a solo founder who will not compromise on depth of quality; scope must therefore be cut along the axis that preserves the product thesis (certified reliability for premium titles) while shrinking permanent surface.

## Decision

MGCR supports a **modern baseline only**:

1. **Guest executables:** x64 only. 32-bit x86 **game** executables are permanently out of certification scope — not a deferred tier. A narrow translated-WoW64 allowance exists solely for auxiliary helper processes (launcher, installer, DRM helper) that a supported x64 title requires; helpers receive conservative per-process policy and are never part of gameplay certification evidence.
2. **Guest graphics APIs:** Direct3D 10/11 (DXMT), Direct3D 12 (Metal12), and Vulkan (MoltenVK). Direct3D 9 and earlier, DirectDraw, and OpenGL are out of product scope; no provider ships and the profile schema does not admit them.
3. **Guest OS era:** catalog titles must officially support Windows 10 x64 or later.
4. **Host window:** Apple silicon only (ADR-0003) with a rolling macOS support window of the **current major plus the previous major** at each stable release. The exact first-release minimum is set after Phase 0 within this policy. macOS 14.4 remains an architecture-discussion reference only.
5. **Certified memory floor:** 16 GB unified memory. Hosts below the floor may run Experimental/Custom states but cannot carry Certified status. The GPU-family floor (M1 vs M2) is decided from Phase-0 catalog evidence through capability metadata (NFR-EVO-004), not model names.
6. **Installation:** storefront-managed installs only. Standalone wizard-style installers are out of scope (consistent with the no-UI-automation rule in the architecture).
7. **Media:** modern codec set only — system decode via VideoToolbox/AudioToolbox (H.264/AAC) plus game-bundled codecs (e.g., Bink). No WMV/VC-1/legacy Media Foundation pipeline.
8. **Input/audio certification scope:** XInput/GameInput-class controllers and XAudio2 2.8+/WASAPI. DirectInput/DirectSound-era APIs remain whatever upstream Wine provides, permanently uncertified.

## Rationale

- **Quality concentration:** every removed dimension converts breadth into depth on the wedge the strategy already chose — premium modern single-player/co-op titles.
- **Cost model:** certification and support cost scale with matrix size (R-013, R-026). The modern baseline removes three graphics translation paths, one CPU mode, one memory class, a codec pipeline, and an installer population from the permanent matrix.
- **CPU surface:** pure x64→ARM64EC is FEX's strongest path; dropping 32-bit game codegen shrinks the hardest technical bet (R-001).
- **Legal surface:** removes the VC-1/WMV patent-pool question and most legacy Microsoft redistributables (see `docs/research/SPIKE-LEGAL-001-preliminary-findings.md`).
- **Positioning:** legacy back-catalog is where general-purpose suites and community wrappers are already strong. "Modern games, done better than anyone" is a sharper claim than a broader-but-shallower catalog.

## Consequences

### Positive

- Smaller permanent conformance, lab, and support matrices.
- Sharper marketing and honest scope ("built for modern games on modern Macs").
- Reduced FEX, media, input, and installer engineering surface.
- Fewer third-party redistribution and patent touchpoints.

### Negative / cost

- The beloved 32-bit/D3D9 back-catalog is excluded; this must be stated plainly in the PRD and marketing (feeds R-024 perception risk).
- Some modern titles ship 32-bit helpers; catalog selection must screen for them and the helper allowance adds bounded WoW64 scope.
- The 16 GB floor excludes 8 GB Apple-silicon Macs from Certified status — a real share of the installed base.
- Rolling macOS window requires disciplined annual intake of new majors.

## Alternatives considered

1. **Legacy tiers on demand (v1.0 posture):** rejected — "later tier" framing is a scope-creep magnet and books permanent matrix cost against the weakest revenue.
2. **32-bit games via WoW64 as a certified tier:** rejected — doubles CPU-provider correctness surface for titles with the lowest willingness-to-pay and the highest per-title support burden.
3. **Cutting Vulkan too:** rejected — MoltenVK is Apache-2.0, maintained, and some modern catalog candidates are Vulkan-native; the marginal surface is small.
4. **8 GB support with reduced settings:** rejected for Certified status — unified-memory pressure at 8 GB produces exactly the stutter/termination behavior the certification promise forbids (R-006).

## Validation and implementation notes

- SPIKE-CATALOG-001 gains hard filters: x64-only executable, D3D10/11/12-or-Vulkan renderer, storefront-managed install, no required 32-bit-only middleware beyond an approved launcher helper, Windows 10+ support.
- SPIKE-STORE-001 gains a criterion: 32-bit helper burden of the storefront client itself.
- Schema change: remove `d3d9on11-dxmt`, `native-opengl`, `wined3d` from graphics-provider enums (breaking change, schema v1 → v1.1 while pre-release).
- SPIKE-MEDIA-001 rescoped to VideoToolbox H.264/AAC + game-bundled codecs; SPIKE-M12-004 memory classes become 16/24/32/64 GB.
- Verify at catalog selection that no shortlisted title's gameplay depends on excluded paths.

## Revisit triggers

Revisit only with decisive commercial evidence that a specific legacy segment is worth its permanent matrix cost (quantified per R-026), or a team-scale change that makes an additional tier affordable without diluting the modern catalog. A single high-value title with one excluded dependency is handled as a catalog exclusion, not a baseline change.
