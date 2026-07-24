# M12-001 provenance log (append-only)

**Author:** Tim Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)
(discipline-model clean room). Excluded sources — vkd3d, vkd3d-proton, DXMT `src/d3d12/`,
any copyleft D3D12 implementation — were not read, searched, or pasted into any
AI-assistant context for this spike. Entries are dated and never rewritten.

## Entries

- **2026-07-24 — spike start.** Log created before any Metal12 design work, per
  ADR-0012 validation note. Design inputs for the descriptor/binding prototype:
  - D3D12 public API semantics (descriptor heaps, CopyDescriptors, root descriptor
    tables, shader-visible heap model) as documented in Microsoft public documentation
    and the CC-BY-4.0 DirectX-Specs — consulted from general knowledge of the public
    API surface; no reference implementation consulted.
  - Apple Metal public API: Metal 3 argument buffers as GPU-address arrays
    (`MTLBuffer.gpuAddress`, pointer-cast access in MSL), `useResource:usage:`
    residency declarations, `addCompletedHandler:` completion tracking, and
    `MTLSharedEvent` — Apple developer documentation and WWDC material.
  - All virtualization mechanics in `prototype/` (virtual heap records, page ring,
    generation counters, recycle poisoning, CPU model vs GPU probe verification) are
    original experimentation for this spike.
