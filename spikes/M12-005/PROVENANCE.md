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

- **2026-07-25 — founder-installed GPTK 4 baseline.**
  - The founder downloaded Apple's `Evaluation environment for Windows games
    4.0 beta 1` under their Apple ID, personally ran the interactive installer,
    reviewed the bundled license, and accepted it for this internal,
    non-commercial evaluation.
  - Source disk-image SHA-256:
    `4272f3bf08a62138dc6c8c4d421b8b165f8e08d52f64f45cb87cdd9acec6c4ba`.
  - The task-local, ignored provider identifies itself as
    `PROGRAM:D3DMetal PROJECT:D3DMetal-4.0b1`. D3DMetal SHA-256:
    `0fb4a9dfd10fc6d90b41b1e6aaa03e19a373af9368a2fd3152dc4cf5cc3bd443`;
    `libd3dshared.dylib` SHA-256:
    `66005073540dc91001ea11685160a71e302bfd79c2ee7b9fe5be560ae17621e2`;
    D3D12 DLL SHA-256:
    `562719036d18851bc433dc06c43f8f6fa2f540426d073c856f2edf583b24a39a`.
  - The signed CrossOver 26.3 installation remained unchanged. The runner
    selected the task-local provider through process environment and recorded
    `set_graphics_backend using d3dmetal as the graphics backend`.
  - Three successful runs produced the same pixel digest and PNG SHA-256:
    `6300cd9f0717bb89d8d4a3fffc9a290edbe0834a2f4c64a29ad1888e9fd62974`.
  - No excluded D3D12 translation implementation was consulted during the
    install, execution, measurement, or documentation work.
