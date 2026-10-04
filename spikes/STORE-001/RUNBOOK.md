# STORE-001 entitled install + fingerprint runbook (founder execution)

**Author:** Timur Isaev

**Status:** Historical anchor and Lane C boot complete; Gate 6 live observation
passed against the exact anchor.

**Context:** D-019 chose Steam. The committed exact-build anchor is now consumed
by the read-only `AlloyStoreIdentityCLI` observer. The Python fingerprint tool
is retained as a historical fingerprint and parity reference.

The recorded 26 July 2026 Gate 6 observation took Branch A: the entitled
CrossOver installation matched build `24280929` and emitted no invalidation.
See `results/2026-07-26-10-live-readonly-and-closing.md`.

## Gate 6 — live read-only identity observation

This is the authoritative closing procedure for issue 89. It performs one
bounded observation of the existing, user-installed Sir Brante title. It does
not start or control the Steam client, launch the title, use account or session
material, access the network, or write beneath a Steam library.

Run every command from the repository root. Select the Steam library that
contains `steamapps/appmanifest_1272160.acf` and a state root outside every
Steam library:

```sh
export LIBRARY_ROOT="/absolute/path/to/Steam"
export STATE_ROOT="/absolute/path/outside/Steam/alloy-store-identity-state"
```

Do not record an account-bearing library path in the result. The committed
inputs are:

```text
app id:       1272160
anchor:       spikes/STORE-001/results/fingerprint-1272160-first.json
registry:     runtime/store-identity/Registry/selectors.v1.json
```

### 1. Establish an idle host

Before the long file scan, check that no earlier bounded runtime workload is
still active:

```sh
ps aux | rg '[r]un-slice|[m]etal12'
```

No matching line is the required result. If one appears, do not start the live
scan until that workload has ended.

### 2. Run the pre-observation gates

The negative self-test proves that every prohibited posture is rejected and
that a clean repository can still pass. The strict gate then proves that
discovery remains read-only:

```sh
spikes/STORE-001/steam-readonly/gate-selftest.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
swift test --disable-sandbox --package-path runtime/store-identity
runtime/store-identity/run-fingerprint-parity.sh
runtime/store-identity/run-metadata-parser-proof.sh
runtime/store-identity/run-update-watcher-proof.sh
runtime/store-identity/run-selector-invalidation-proof.sh
runtime/store-identity/run-fault-matrix.sh
runtime/store-identity/run-cli-fixture-proof.sh
tools/lint.sh
```

Required Steam summaries are:

```text
GATE-SELFTEST: pass — every check rejects its violation and the gate can still go green
STEAM-AUTOMATION: pass - discovery is read-only, no account interaction
```

The required CLI fixture summary is:

```text
SUMMARY cli-fixture unchanged=PASS changed=PASS idempotence=PASS self-test=PASS argument-refusals=4 canonical-refusals=1 traversal-refusals=1 symlink-refusals=2 state-boundary-refusals=2 inputs=UNCHANGED invalidations=1 status=PASS
```

Do not continue if any command fails.

### 3. Observe the installed title once

The direct executable contract is:

```sh
AlloyStoreIdentityCLI observe \
  --library-root "$LIBRARY_ROOT" \
  --app-id 1272160 \
  --anchor spikes/STORE-001/results/fingerprint-1272160-first.json \
  --registry runtime/store-identity/Registry/selectors.v1.json \
  --state-root "$STATE_ROOT"
```

From the repository, Swift Package Manager can run that same executable:

```sh
swift run --package-path runtime/store-identity \
  AlloyStoreIdentityCLI observe \
  --library-root "$LIBRARY_ROOT" \
  --app-id 1272160 \
  --anchor spikes/STORE-001/results/fingerprint-1272160-first.json \
  --registry runtime/store-identity/Registry/selectors.v1.json \
  --state-root "$STATE_ROOT"
```

The command must emit exactly one of these deterministic standard-output lines:

```text
STATUS appid=1272160 update=unchanged self_test=PASS invalidation=none
STATUS appid=1272160 update=changed self_test=PASS created=<true|false> id=<sha256:...> superseded=24280929 observed=<buildid>
```

For `update=unchanged`, verify that no invalidation JSON was created. The
committed anchor remains current for the exact installed build.

For `update=changed`, preserve the historical anchor without editing it. Verify
that the one record beneath `STATE_ROOT` names superseded build `24280929` and
all three exact selectors:

```text
gfx-001.result-06.1272160.24280929
store-001.fingerprint.1272160.24280929
store-001.launch-policy.sir-brante-24280929
```

Do not repeat the live scan merely to prove idempotence. The CLI fixture proof
already requires an identical synthetic retry to report `created=false`, reuse
the same invalidation identifier, preserve canonical bytes, and leave exactly
one record. The one live run may report `created=false` when the exact record
already exists in the selected state root.

### 4. Re-run the posture gates and record the outcome

```sh
spikes/STORE-001/steam-readonly/gate-selftest.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
tools/lint.sh
```

Copy the process precheck, both pre- and post-observation Steam summaries,
every cumulative proof summary, full test total, CLI fixture proof, lint
result, exact live `STATUS` line, and branch-specific checks into
`spikes/STORE-001/results/2026-07-26-10-live-readonly-and-closing.md`.
Only then may its disposition change from Pending.

### Identity and write guarantees

- The observer reads only the selected library, appmanifest, installed title,
  trusted anchor, and selector registry.
- The exact identity includes app, build, depot manifest, every regular-file
  digest and size, aggregate digest, and executable-image digest.
- The detector self-test passes before the real observation; a dead detector
  or unstable mixed scan refuses the run.
- Selectors match only their exact app, build, depot manifest, aggregate, and
  image identity.
- Changed observations have deterministic invalidation identifiers and
  canonical bytes; repeated and crash-recovery runs converge idempotently.
- Runtime state is written only beneath the caller-selected state root. The
  Steam tree, anchor, registry, and historical results remain unchanged.
- The observer has no Steam launch, client-control, account, session,
  credential, or network behavior.

This closes only the single-title, one-live-installation Sir Brante evidence
leg. Hosting the Steam client inside the Alloy runtime (Lane B), validating
multiple titles, and adding a long-running watcher, daemon, or scheduler remain
deferred.

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

## Historical Lane A steps (~20 minutes + download time)

These steps document how the committed anchor was originally produced. Use the
Gate 6 observer above for current production observation.

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
