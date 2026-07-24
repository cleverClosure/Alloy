# M12-004 provenance log (append-only)

**Author:** Tim Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)
(discipline-model clean room). Excluded sources — vkd3d, vkd3d-proton, DXMT `src/d3d12/`,
any copyleft D3D12 implementation — were not read, searched, or pasted into any
AI-assistant context for this spike. Entries are dated and never rewritten.

## Entries

- **2026-07-24 — spike start.** Log created before design work. Inputs for the
  unified-memory residency prototype:
  - D3D12 public memory-model semantics (committed vs placed resources, heap
    aliasing lifetime rules, `QueryVideoMemoryInfo`-style budget reporting) from
    Microsoft public documentation / CC-BY-4.0 DirectX-Specs, consulted from general
    knowledge of the public API surface; no reference implementation consulted.
  - Apple Metal public API: `MTLHeap` placement heaps (`newBufferWithLength:
    options:offset:`), `recommendedMaxWorkingSetSize`, `currentAllocatedSize`,
    shared-storage commit-on-touch behavior — Apple developer documentation.
  - `host_statistics64` free/inactive pages as the graceful-degradation bail-out —
    Apple public documentation (`os_proc_available_memory` is iOS-only).
  - The chunk-cache eviction design, checksummed rematerialization, aliasing
    stale-read guard, and long-session churn harness are original experimentation.
