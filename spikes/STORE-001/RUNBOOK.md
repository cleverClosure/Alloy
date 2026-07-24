# STORE-001 entitled install + fingerprint runbook (founder execution)

**Author:** Tim Isaev
**Status:** Tooling ready; execution needs entitled lab-account credentials (founder).
**Context:** D-019 chose Steam; the open Phase-0 row is "entitled install, exact build
fingerprint, rerun evidence." The fingerprint tool is `tools/steam-fingerprint.py`
(no credentials touched; works on any existing library).

## Two lanes

- **Lane A — evidence now (recommended first):** install the title with the real
  Windows Steam client in an existing licensed environment (CrossOver bottle on the
  lab machine). This proves the *identity tooling* on a genuinely entitled build:
  discovery, buildid, depot manifests, exact content hash, rerun. The runtime is not
  in the loop yet, and the record says so.
- **Lane B — full-scope proof (later):** the same flow with the Steam client running
  inside the Alloy runtime prefix (SSA §2.G: real client, no protocol emulation).
  Blocked on runtime maturity beyond the current spike scope (client UI/network/DRM
  surface). Lane A's fingerprints remain valid comparison anchors for Lane B.

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
