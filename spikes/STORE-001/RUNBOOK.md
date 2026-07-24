# STORE-001 entitled install + fingerprint runbook (founder execution)

**Author:** Timur Isaev
**Status:** Entitled build fingerprinted and booted under the Alloy runtime.
**Context:** D-019 chose Steam; the open Phase-0 row is "entitled install, exact build
fingerprint, rerun evidence." The fingerprint tool is `tools/steam-fingerprint.py`
(no credentials touched; works on any existing library).

## Three lanes

- **Lane A — evidence now (recommended first):** install the title with the real
  Windows Steam client in an existing licensed environment (CrossOver bottle on the
  lab machine). This proves the *identity tooling* on a genuinely entitled build:
  discovery, buildid, depot manifests, exact content hash, rerun. The runtime is not
  in the loop yet, and the record says so.
- **Lane B — full-scope proof (later):** the same flow with the Steam client running
  inside the Alloy runtime prefix (SSA §2.G: real client, no protocol emulation).
  Blocked on runtime maturity beyond the current spike scope (client UI/network/DRM
  surface). Lane A's fingerprints remain valid comparison anchors for Lane B.
- **Lane C — entitled title boot (complete for build 24280929):** launch the
  Lane A content under EC Wine + FEX + the inherited per-process policy snapshot.
  This proves the commercial title runtime independently of hosting the Steam client
  itself. The title's `SteamAPI_Init()` warning is expected in this lane.

## Lane A steps (~20 minutes + download time)

1. Sign in to the entitled lab account in the Steam client (CrossOver bottle).
2. Install the pipeline smoke title (D-020: *The Life and Suffering of Sir Brante* —
   small download, DRM-light).
3. List what the tool can see (host shell):

   ```bash
   python3 tools/steam-fingerprint.py \
     "$HOME/Library/Application Support/CrossOver/Bottles/<bottle>/drive_c/Program Files (x86)/Steam"
   ```

4. Fingerprint the exact build (use the appid from step 3):

   ```bash
   python3 tools/steam-fingerprint.py <steam-root> --app <appid> \
     --out spikes/STORE-001/results/fingerprint-<appid>-first.json
   ```

5. **Rerun evidence:** immediately verify once (must be EXACT MATCH), then verify
   again after a Steam client restart + integrity check ("Verify integrity of game
   files"), which is the realistic perturbation:

   ```bash
   python3 tools/steam-fingerprint.py <steam-root> --app <appid> \
     --verify spikes/STORE-001/results/fingerprint-<appid>-first.json
   ```

6. Commit the JSON (minus any account-identifying paths — the record contains only
   appid/build/depot/file hashes) plus a dated results note quoting buildid, depot
   manifest ids, aggregate hash, and both verify outcomes.

## What closes the Phase-0 row

Entitled install discovered by the tool + a committed fingerprint (buildid + depot
manifests + aggregate content hash) + at least one EXACT-MATCH rerun. Lane B and
LAB-001's Windows-side reproduction consume the same JSON as the comparison anchor.

## Lane C — repeatable Alloy runtime launch

The harness refuses an executable that does not match the committed build-24280929
fingerprint. It prepares an isolated prefix, installs the selected FEX DLL, stages
DXMT's D3D11/DXGI provider plus its ARM64EC `winemetal.dll`, links DXMT's unixlib to
one coherent Wine build, compiles an exact-image policy snapshot, and opens that
snapshot read-only before process imports:

```bash
export ALLOY_WINE_BUILD=/path/to/configured-wine-build
export ALLOY_WINE_SOURCE=/path/to/alloy-wine-source
export ALLOY_FEX_DLL=/path/to/libarm64ecfex.dll
export ALLOY_DXMT_PROVIDER_DIR=/path/to/dxmt-provider-directory
export ALLOY_DXMT_PE_DLL=/path/to/aarch64-windows/winemetal.dll
export ALLOY_DXMT_UNIXLIB=/path/to/winemetal.so
export ALLOY_GAME_EXE="/path/to/The Life and Suffering of Sir Brante.exe"

spikes/STORE-001/runtime-launch/launch-sir-brante.sh prepare
spikes/STORE-001/runtime-launch/launch-sir-brante.sh headless --duration 45
spikes/STORE-001/runtime-launch/launch-sir-brante.sh graphical --duration 120
```

`ALLOY_STORE_WORK` may select a different isolated directory, but the harness confines
it to `spikes/STORE-001/work/`, which is ignored. `--census` additionally enables
Wine's virtual-memory census channel for one bounded run. The `--duration` watchdog
stops only that prefix's wineserver; it does not touch a CrossOver bottle or another
Wine worktree.

The required success evidence is:

1. runtime log: policy `sir-brante-24280929`, `default 0`, selected before imports;
2. runtime log: native `DXGI.DLL` and `d3d11.dll` loaded from the staged DXMT provider;
3. player log: Direct3D 11 feature level 11.1 on `Apple M2 Pro`;
4. player log: Mono assembly reload, input initialization, and game assets complete
   without a fault livelock.

Do not add a global `d3d11,dxgi` DLL override. The exact-image policy is the proof:
unrecognized helper and service processes retain the restricted builtin default.
