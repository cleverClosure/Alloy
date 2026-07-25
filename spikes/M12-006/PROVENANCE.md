# M12-006 provenance log (append-only)

**Author:** Tim Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)
(discipline-model clean room). Excluded sources — vkd3d, vkd3d-proton, DXMT `src/d3d12/`,
any copyleft D3D12 implementation — were not read, searched, or pasted into any
AI-assistant context for this spike. Entries are dated and never rewritten.

## Entries

- **2026-07-25 — spike start.** Log created before design work on the vertical
  slice. Inputs:
  - **The four prior M12 prototypes and their results** (M12-001 descriptor
    virtualization, M12-002 barrier tracker, M12-003 DXIL→MSL shader path,
    M12-004 residency model) — Alloy's own prior work.
  - **The M12-005 reference scene** (`d3d12_reference.c`) and its GPTK baseline
    result — Alloy's own prior work. The scene's HLSL is extracted verbatim from
    the C string literal in that file, mechanically rather than by
    transcription, so the two paths compile the same 1,333 bytes.
  - **DXC binary release** `v1.9.2602.24` (microsoft/DirectXShaderCompiler,
    NCSA — ADR-0012 approved input), used as a *tool* to produce DXIL from
    HLSL, run as the unmodified x64 `dxc.exe` under Alloy's own Wine/FEX stack.
    Now pinned in `third_party/MANIFEST.toml` and `deps.lock`. No DXC source
    read for design.
  - **DXIL operation semantics**: Microsoft public DirectX-Specs documentation
    (CC-BY-4.0) for the `dx.op` opcode numbering and signature-table meanings.
  - **Apple Metal Shading Language specification** (public) for the lowering
    target, and **Apple Metal framework documentation** (public) for the host
    API.
  - GPTK/D3DMetal remain an **answer key only** — a rendered image and a timing
    table to compare against. No excluded D3D12 translation implementation was
    read, searched, or consulted, and none is an input to any design decision
    here.
  - The stage detection, signature-table parsing, graphics-stage lowering, the
    integrated Metal path, and the comparison harness are original
    experimentation for this spike.

- **2026-07-25 — slice complete.** Additional inputs used during the work, none
  of them excluded sources:
  - `xcrun metal` / `metallib` from the installed Xcode command line tools, as
    the MSL compiler and linker.
  - Python's `zlib` for the first-party PNG reader in `compare_reference.py`;
    the decoder, the BMP reader and the comparison are original.
  - `sips` (macOS) to convert the slice's BMP output to the committed PNG. The
    conversion was verified pixel-exact by comparing the PNG back against the
    BMP through the same tool: 230,400/230,400 identical.
  - The GPTK baseline image and digest from M12-005 were read **as an answer
    key only** — a rendered result to compare against. No excluded D3D12
    translation implementation was read, searched, or consulted, and none
    informed any design decision here.
