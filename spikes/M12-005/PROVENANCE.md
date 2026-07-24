# M12-005 provenance log (append-only)

**Author:** Timur Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)

Excluded sources — vkd3d, vkd3d-proton, DXMT `src/d3d12/`, and any copyleft
D3D12 implementation — were not read, searched, or pasted into an
AI-assistant context for this spike. Entries are dated and never rewritten.

## Entries

- **2026-07-24 — spike start.** Inputs used to build the reference workload:
  - Microsoft public D3D12/DXGI API contracts and the pinned MIT-licensed
    DirectX headers shipped by llvm-mingw;
  - Apple's public Game Porting Toolkit page and the D3DMetal framework
    shipped in the locally installed CrossOver 26.3;
  - Alloy's own D3D11 measured-scene conventions for structured timing and
    self-verifying readback.
  - `scene/d3d12_reference.c` and its runner are original test-harness code.
    No D3D12 translation implementation was consulted.
