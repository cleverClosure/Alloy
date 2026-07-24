# M12-005 result 02 — GPTK 4.0 beta 1 reference baseline is green

**Author:** Timur Isaev
**Date:** 25 July 2026
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (25F84)
**Status:** Green; task #9 done criteria met

## Outcome

The original D4 reference scene renders successfully through Apple's current
evaluation package, `Evaluation environment for Windows games 4.0 beta 1`.
The founder personally performed the account-bound, license-gated lab install.
Three consecutive runs passed readback validation and produced a byte-identical
image.

This closes the comparison gap left by
[result 01](2026-07-24-01-d3dmetal-reference-green.md), which used the
D3DMetal 3.0 provider bundled with CrossOver.

## Founder-only installation boundary

[`install-gptk-lab.sh`](../scene/install-gptk-lab.sh) enforces the boundary
from task #9:

- it refuses non-interactive execution;
- it mounts the Apple disk image read-only and displays the bundled license;
- the founder must personally type `I ACCEPT`;
- it copies only the package's `redist/lib` tree, license, README, and a hash
  manifest into ignored `spikes/M12-005/work/`;
- it preserves an earlier task-local provider as a dated backup instead of
  deleting it.

The runner uses the signed CrossOver 26.3 installation but overlays the
task-local GPTK provider through `CX_APPLEGPTK_LIBD3DSHARED_PATH` and
`WINEDLLPATH`. It does not modify CrossOver, the user's Steam bottle, or any
other existing bottle.

## Provider identity and backend proof

Apple's [Game Porting Toolkit page](https://developer.apple.com/games/game-porting-toolkit/)
identifies GPTK 4 as the current toolkit. The account-bound download page
listed this beta on 8 June 2026.

| Component | Identity |
| --- | --- |
| Evaluation package | `Evaluation environment for Windows games 4.0 beta 1` |
| Source DMG SHA-256 | `4272f3bf08a62138dc6c8c4d421b8b165f8e08d52f64f45cb87cdd9acec6c4ba` |
| CrossOver host | 26.3 |
| D3DMetal | `PROGRAM:D3DMetal PROJECT:D3DMetal-4.0b1` |
| D3DMetal SHA-256 | `0fb4a9dfd10fc6d90b41b1e6aaa03e19a373af9368a2fd3152dc4cf5cc3bd443` |
| `libd3dshared.dylib` SHA-256 | `66005073540dc91001ea11685160a71e302bfd79c2ee7b9fe5be560ae17621e2` |
| GPTK D3D12 DLL SHA-256 | `562719036d18851bc433dc06c43f8f6fa2f540426d073c856f2edf583b24a39a` |
| Installed manifest SHA-256 | `5fa6a4337fe2762e77fee8e2d2e5970212fcabd3e866019c6486663cf16c79ac` |
| Backend proof on every run | `set_graphics_backend using d3dmetal as the graphics backend` |

## Timing baseline

Command:

```sh
spikes/M12-005/scene/run-reference.sh
```

The first run followed installation; runs 2 and 3 were immediate repeats in
the same isolated lab. Run 3 is the cache-warm comparison anchor. The spread
in setup and first-frame time is retained because it captures real
initialization and shader-cache behavior rather than a benchmark guarantee.

| Measurement | Run 1: post-install | Run 2: repeat | Run 3: cache-warm anchor |
| --- | ---: | ---: | ---: |
| D3D12 setup | 721.360 ms | 208.668 ms | 187.617 ms |
| First submitted frame | 195.273 ms | 149.873 ms | 26.788 ms |
| Warm mean (119 frames) | 8.411 ms | 4.713 ms | 6.165 ms |
| Warm p50 | 8.402 ms | 3.723 ms | 3.711 ms |
| Warm p95 | 12.996 ms | 12.104 ms | 15.894 ms |
| Exit | PASS | PASS | PASS |

These are single-machine engineering measurements, not product performance
claims.

## Deterministic visual result

All three runs produced:

| Check | Result |
| --- | ---: |
| Nonuniform pixels | 230,397 / 230,400 |
| Pixel FNV-1a 64 | `825861ee12085256` |
| PNG SHA-256 | `6300cd9f0717bb89d8d4a3fffc9a290edbe0834a2f4c64a29ad1888e9fd62974` |

![GPTK 4 D3D12 reference scene](2026-07-25-gptk4-reference.png)

The PNG is also byte-identical to the D3DMetal 3.0 image in result 01. The
reference scene therefore has stable visual output across the provider
refresh, while the timing tables preserve the version-specific comparison.

## Legal and clean-room boundary

- Use is internal and non-commercial, consistent with
  [SPIKE-LEGAL-001](../../../docs/research/SPIKE-LEGAL-001-preliminary-findings.md)
  and decision
  [D-021](../../../docs/docs/14_DECISION_LOG.md).
- GPTK, D3DMetal, CrossOver, the installed provider manifest, bottles, PEs,
  raw logs, and raw bitmaps remain outside version control.
- The only committed binary is the PNG output produced by Alloy's original
  first-party workload.
- GPTK is an answer key only; it is not a shipping Alloy dependency or
  Metal12 implementation input.
- No excluded D3D12 translation implementation was read or consulted.

The required reference render, baseline image, timings, and lab-only handling
record are now complete.
