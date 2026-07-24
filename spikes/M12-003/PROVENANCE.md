# M12-003 provenance log (append-only)

**Author:** Tim Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)
(discipline-model clean room). Excluded sources — vkd3d, vkd3d-proton, DXMT `src/d3d12/`,
any copyleft D3D12 implementation — were not read, searched, or pasted into any
AI-assistant context for this spike. Entries are dated and never rewritten.

## Entries

- **2026-07-24 — spike start.** Log created before design work. Inputs for the
  DXIL-to-Metal shader-path prototype:
  - **DXC binary release** `v1.9.2602.24` (microsoft/DirectXShaderCompiler, NCSA —
    ADR-0012 approved input), used as a *tool* to produce DXIL from HLSL. Run as the
    unmodified x64 `dxc.exe` under Alloy's own Wine/FEX stack. No DXC source read for
    design; its documentation and the CC-BY-4.0 DirectX-Specs DXIL documentation are
    the format references.
  - DXIL container layout (FourCC part container) and DXIL-as-LLVM-3.7-bitcode facts:
    Microsoft public documentation/DirectX-Specs.
  - LLVM bitcode backward-compatibility guarantee (readable by modern `llvm-dis`):
    LLVM public documentation; Homebrew `llvm@15` used as the disassembly tool.
  - Apple Metal Shading Language specification (public) for the MSL lowering target.
  - The container parser, normalized-IR subset, MSL lowering, determinism/diagnostic
    harness, and CPU-reference comparison are original experimentation for this spike.
