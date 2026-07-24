# M12-002 provenance log (append-only)

**Author:** Tim Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)
(discipline-model clean room). Excluded sources — vkd3d, vkd3d-proton, DXMT `src/d3d12/`,
any copyleft D3D12 implementation — were not read, searched, or pasted into any
AI-assistant context for this spike. Entries are dated and never rewritten.

## Entries

- **2026-07-24 — spike start.** Log created before design work. Inputs for the
  barrier/state-tracker prototype:
  - D3D12 public resource-barrier semantics (transition/UAV/aliasing barriers,
    per-subresource states, cross-queue fences) from Microsoft public documentation
    and the CC-BY-4.0 DirectX-Specs, consulted from general knowledge of the public
    API surface; no reference implementation consulted.
  - Apple Metal public API: `MTLFence` (intra-queue, encoder-scoped update/wait),
    `MTLSharedEvent`/`MTLEvent` (cross-queue signal/wait), untracked-resource hazard
    rules — Apple developer documentation and WWDC material.
  - The tracker design (per-subresource last-access records, per-queue vector clocks
    for transitive-order elision, hazard-graph ground-truth verification, conservative
    vs optimized plan comparison) is original experimentation for this spike.
