# STORE-001 result 07 — simulated storefront update detection

**Author:** Timur Isaev

**Date:** 26 July 2026

**Disposition:** Pass

**Gate:** 3 — update watcher and superseded-build detection

**Base:** `ab060ca3daeec0b7eddf81dd9e1297f27085f98d`

## Claim

Gate 3 detects when an observed Steam installation no longer matches the exact
build recorded by a fingerprint anchor. It distinguishes storefront metadata
changes from installed-game byte changes, reports depot and file deltas, and
names the superseded build.

Every scenario first evaluates the unchanged Sir Brante anchor and requires no
detection. A detector that always fires therefore cannot satisfy this gate.
All observations are derived from the committed anchor and staged as manifest
and fingerprint copies in isolated scratch directories. The proof never reads
or modifies a live Steam library.

## Exact anchor

| Field | Value |
| --- | --- |
| Record | `spikes/STORE-001/results/fingerprint-1272160-first.json` |
| App | `1272160` |
| Superseded build | `24280929` |
| Depot | `1272161` |
| Depot manifest | `3716404947812214693` |
| Aggregate SHA-256 | `1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e` |

## Both-direction controls

| Scenario | Unchanged control | Simulated observation | Required result | Status |
| --- | --- | --- | --- | --- |
| Launcher/metadata-only | Anchor metadata plus anchor files returns no detection first. | Build becomes `24280930` and depot manifest becomes `3716404947812214694`; files remain byte-identical. | Metadata change only; depot `1272161`; no file paths. | Pass |
| Game-only | Anchor metadata plus anchor files returns no detection first. | Executable digest and aggregate change under build `24280929` and the anchored depot manifest. | Game-content change only; executable in changed paths. | Pass |
| Combined | Anchor metadata plus anchor files returns no detection first. | Build `24280931`, depot manifest `3716404947812214695`, one added file, one removed file, and one changed file. | Both change classes, all exact path sets, and superseded build `24280929`. | Pass |
| Refusal | Anchor metadata plus anchor files returns no detection first. | Metadata says build `24280932` and a new depot manifest while the paired fingerprint still says build `24280929`. | Observation is refused; no detection record is emitted. | Pass |

## Claim boundary

This gate proves pure comparison of caller-supplied metadata and fingerprint
records. It does not discover a Steam installation, schedule background work,
emit persisted invalidations, launch Steam, automate a client, use
credentials, access the network, or write into storefront state. Selector
registry persistence, idempotent invalidation emission, and crash safety remain
later gates.

## Reproduction

Run from the repository root:

```sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
swift test --disable-sandbox --package-path runtime/store-identity
runtime/store-identity/run-fingerprint-parity.sh
runtime/store-identity/run-metadata-parser-proof.sh
runtime/store-identity/run-update-watcher-proof.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
tools/lint.sh
```

Expected final record:

```text
pre-change steam read-only gate: PASS — no account interaction
swift test: PASS — 14 tests in 3 suites
fingerprint parity: PASS — 7 focused cases
metadata parser proof: PASS — 14 hostile cases with paired clean controls
update watcher proof: PASS — 4 changed cases and 4 unchanged controls
post-change steam read-only gate: PASS — no account interaction
lint: PASS
```

## Validation record

The metadata-only observation reported depot `1272161` and superseded build
`24280929` without a file delta. The game-only observation reported only
`The Life and Suffering of Sir Brante.exe`. The combined observation reported
that executable as changed,
`MonoBleedingEdge/EmbedRuntime/MonoPosixHelper.dll` as removed, and
`zz-alloy-added.bin` as added while still naming build `24280929`. A mismatched
manifest/fingerprint pair was refused. Each of those four invocations first
staged and accepted the unchanged anchor with no detection.
