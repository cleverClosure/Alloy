# STORE-001 result 02 — entitled build boots under the Alloy runtime

**Author:** Timur Isaev
**Date:** 25 July 2026

## Verdict

**GREEN:** the entitled *The Life and Suffering of Sir Brante* build reached its
interactive game layer under the Alloy runtime. The graphical run selected the
exact-image policy before imports, loaded native DXMT D3D11/DXGI, initialized Unity
2018.3 and Direct3D 11, reloaded Mono assemblies, initialized input, constructed the
game manager, and loaded game assets without a fault livelock.

This is Lane C of the [STORE-001 runbook](../RUNBOOK.md): entitled content launched
under Alloy independently of hosting the Steam client. The expected
`SteamAPI_Init()` warning remains because the Steam client is not hosted in this
lane.

## Certified inputs

| Input | Identity |
| --- | --- |
| Steam app | appid `1272160`; build `24280929`; depot manifest `3716404947812214693` |
| Installed content | 1,422 files; 3,498,258,640 bytes; aggregate SHA-256 `1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e` |
| Game executable | SHA-256 `1fb707b113f25388a6dacdd81140bf2205f4fe93c71e83d3169e58ab98f95455` |
| FEX DLL | SHA-256 `919fcc7e3ba55e3e633f0feda0204e4da223ceae8845968916975529e8f43a9b` |
| DXMT D3D11 | SHA-256 `c8226f467a7b95cfe9535a87ce74a846b4d7db4e66e9776209116832767ca82a` |
| DXMT DXGI | SHA-256 `6aeb949b529f0581ca2e4d1ba40bcd2ac3c5628553457857e26b3c7ae11c07ee` |
| DXMT winemetal PE | SHA-256 `4d9fcd26f0a87922e23fd023d17733af62a9f418906bd3639a0aa8652ba596b8` |
| DXMT winemetal unixlib | SHA-256 `1a5cd19dbb64e726b8a8fef9665ba0ced6fb190511883712778531ac0d38153f` |
| Exact policy snapshot | SHA-256 `f2c698141841c83e03ffde681c97ad628aa596e9df0b94e21166d7b44b8154df` |
| Prototype Wine | commit `de36e21186d2b991895ea53884b7c2507b94764b`; `ntdll.so` SHA-256 `eed95fd78d3041938edebbe41097d4265600ea639e1ce1d0b685ed51f9dbac34` |

No account identifier or credential is present in this record.

## Runtime evidence

The graphical launch produced these independent gates:

1. `alloy_policy_bootstrap` selected policy `sir-brante-24280929`, graphics provider
   `dxmt`, `default 0`, for the certified executable hash, **before imports**.
2. `winemetal.dll` loaded with native `DXGI.DLL` and native `d3d11.dll`; no global
   D3D DLL override was used.
3. Unity reported `Direct3D 11.0 [level 11.1]` on `Apple M2 Pro`.
4. Unity completed Mono assembly reload and input initialization.
5. `GameManager (SetScreenMode)` ran, followed by multiple asset-load and
   unused-asset collection passes.

A separate headless rerun selected the same exact policy, initialized Unity with its
Null device, reloaded Mono, and reached the same game-manager and asset-loading
events. The focused runtime regression corpus also remained green:
`x64hello`, `isa_smoke`, `memory_semantics`, `threads_tls`, `seh_repeat`,
`seh_multi`, and `exception_unwind`. A D3D11 readback smoke used the native provider,
reported feature level 11.0 (maximum 11.1), and reproduced the expected BGR pixel
`191/128/64/255`.

The raw Wine window is not exposed to macOS accessibility automation. Therefore this
record does not claim automated screenshot or click confirmation; the runtime and
Unity player logs establish graphical-device, input, game-manager, and scene-asset
initialization.

## Fault census and resolved blocker

The first title run exposed a Darwin JIT livelock: FEX translated code and the Mono
JIT target occupy separate `MAP_JIT` views, but Darwin's pthread JIT write switch is
per-thread. Switching permissions for one view makes the other unwritable.

Prototype Wine commit `de36e21186d2b991895ea53884b7c2507b94764b` validates the
source and destination mappings and emulates only the observed AArch64 store forms
when translated code writes into another committed Wine JIT view. Unknown or
mismatched faults still follow the normal signal path.

With that prototype, the bounded census emitted 354 records:

- 352 no-access-class records;
- one class-1 `[20 23 20 00]` view-map sample;
- one class-2 `[23 20 20 20]` view-map sample.

Neither non-zero sample blocked boot. Productionizing the generic fix and its
negative guards is tracked in [#30](https://github.com/cleverClosure/Alloy/issues/30).
The existing x18 translation tax remains tracked in
[#8](https://github.com/cleverClosure/Alloy/issues/8).

## Repeatability

[`runtime-launch/launch-sir-brante.sh`](../runtime-launch/launch-sir-brante.sh)
validates the committed fingerprint, prepares an isolated prefix, stages one coherent
FEX/DXMT/Wine runtime, compiles and opens the exact policy snapshot, captures all
input hashes, and offers bounded headless, graphical, and census runs. Its watchdog
stops only the selected prefix. Lane B—hosting the real Steam client inside Alloy—is
later scope and is not a blocker for this Lane-C boot result.
