# STORE-001 result 10 — live read-only observation and closing

**Author:** Timur Isaev

**Date:** 26 July 2026

**Disposition:** Pass

**Gate:** 6 — live read-only observer and STORE-001 closeout

**Base:** `24abb392c223728ff4bc6fc5e4908354baeb3232`

## Live outcome

The production CLI performed exactly one read-only observation of the existing
entitled installation. Its detector self-test passed first, all 1,422 installed
files reproduced the trusted anchor, and no invalidation JSON was created:

```text
STATUS appid=1272160 update=unchanged self_test=PASS invalidation=none
```

This records Branch A: the installed Sir Brante identity still exactly matches
build `24280929`, depot manifest `3716404947812214693`, aggregate digest
`1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e`,
and the committed per-file records.

## Closing claim

Gate 6 closes STORE-001 only after the production CLI self-tests its detector,
observes the existing entitled Sir Brante installation without modifying the
Steam tree, and reports one of two evidenced outcomes:

1. the exact installed identity is unchanged and no invalidation JSON exists;
   or
2. the installed identity has changed and one deterministic invalidation names
   the superseded build and every selector bound to it.

The historical anchor is retained in either outcome. A changed live install
invalidates its exact selectors; it does not rewrite history.

## Exact trusted anchor

| Field | Value |
| --- | --- |
| Title | `The Life and Suffering of Sir Brante` |
| App ID | `1272160` |
| Build ID | `24280929` |
| Depot | `1272161` |
| Depot manifest | `3716404947812214693` |
| Depot size | `3498258640` |
| File count | `1422` |
| Total bytes | `3498258640` |
| Aggregate SHA-256 | `1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e` |
| Executable SHA-256 | `1fb707b113f25388a6dacdd81140bf2205f4fe93c71e83d3169e58ab98f95455` |
| Anchor | `spikes/STORE-001/results/fingerprint-1272160-first.json` |
| Registry | `runtime/store-identity/Registry/selectors.v1.json` |

The exact selector set is:

```text
gfx-001.result-06.1272160.24280929
store-001.fingerprint.1272160.24280929
store-001.launch-policy.sir-brante-24280929
```

## Live inputs

| Input | Recorded value |
| --- | --- |
| Library root | Existing entitled CrossOver Steam library; absolute account-bearing path withheld. |
| App ID | `1272160` |
| State root outside the Steam tree | Isolated randomized directory beneath `/private/tmp`; removed after verification. |
| Process precheck | No matching workload; zero output. |
| First CLI status line | `STATUS appid=1272160 update=unchanged self_test=PASS invalidation=none` |
| Invalidation record path, if applicable | Not applicable; no invalidation JSON existed. |

## Process precheck

Run immediately before the long scan:

```sh
ps aux | rg '[r]un-slice|[m]etal12'
```

**Recorded output:** No output (`rg` exit 1). No `run-slice` or `metal12`
workload was active immediately before the live scan.

## Verification record

| Proof | Required evidence | Status |
| --- | --- | --- |
| Pre-observation gate negative self-test | `GATE-SELFTEST: pass — every check rejects its violation and the gate can still go green` | Pass |
| Pre-observation strict Steam gate | `STEAM-AUTOMATION: pass - discovery is read-only, no account interaction` | Pass |
| Full package tests | `26 tests in 6 suites passed`; repeated after the live scan | Pass |
| Fingerprint parity | `SUMMARY fingerprint-parity cases=7 status=PASS` | Pass |
| Metadata parser | `SUMMARY steam-metadata clean=15 hostile=14 status=PASS` | Pass |
| Update watcher | `SUMMARY update-watcher cases=4 unchanged-controls=4 status=PASS` | Pass |
| Selector invalidation | `SUMMARY selector-invalidation cases=3 unchanged-controls=3 selectors=3 records=1 status=PASS` | Pass |
| Crash fault matrix | `SUMMARY fault-matrix scan-points=1 emit-points=3 self-test=PASS inputs=UNCHANGED recovery=CONVERGED status=PASS` | Pass |
| CLI fixture proof | `SUMMARY cli-fixture unchanged=PASS changed=PASS idempotence=PASS self-test=PASS argument-refusals=4 canonical-refusals=1 traversal-refusals=1 symlink-refusals=2 state-boundary-refusals=2 inputs=UNCHANGED invalidations=1 status=PASS` | Pass |
| Live CLI observation | Exact unchanged `STATUS` line above; one invocation | Pass |
| Post-observation gate negative self-test | Same exact passing self-test summary | Pass |
| Post-observation strict Steam gate | Same exact passing strict-gate summary | Pass |
| Repository lint | `tools/lint.sh` exited 0 before and after the live scan | Pass |

## Live outcome fork

### Branch A — exact installed identity unchanged

Required CLI output:

```text
STATUS appid=1272160 update=unchanged self_test=PASS invalidation=none
```

Required checks:

- no invalidation JSON was created beneath the selected state root;
- the anchor and registry bytes remain unchanged; and
- the anchor remains current only for this exact installed build.

Recorded checks:

- no invalidation directory or JSON was created;
- the state root contained only an empty `watcher-scratch` directory;
- anchor SHA-256 stayed
  `5c6b43999284b699461fb64e916b21eb17d0ea9067460bac51c1e2c269dadc5a`;
  and
- registry SHA-256 stayed
  `0d84e43340f855789c628275f848639e32ea149f639608320e2132e9d4166adb`.

**Recorded status:** Pass.

### Branch B — installed identity changed

Required CLI output shape:

```text
STATUS appid=1272160 update=changed self_test=PASS created=<true|false> id=<sha256:...> superseded=24280929 observed=<buildid>
```

Required checks:

- one deterministic invalidation beneath only the selected state root names
  superseded build `24280929` and all three exact selector IDs;
- `created=true` is expected for the first emission into a clean state root,
  while `created=false` is valid when the exact record already exists;
- the synthetic CLI fixture has already proven that an identical repeat reports
  `created=false`, reuses the same identifier, and preserves canonical bytes;
  the live installation is not rescanned for that proof; and
- the historical anchor, registry, and referenced evidence remain unchanged.

**Recorded status:** Not observed. The single live run took Branch A.

## Both-direction controls

| Direction | Control | Required observation | Status |
| --- | --- | --- | --- |
| CLI fixture unchanged | Invoke the CLI on the exact synthetic anchor after its detector self-test. | Exact unchanged line and no invalidation JSON. | Pass |
| CLI fixture changed | Change one synthetic installed file after the unchanged control. | Exact changed line and one canonical invalidation naming the exact synthetic selector. | Pass |
| CLI fixture idempotence | Repeat only the synthetic changed observation. | `created=false`, same ID, same canonical bytes, and one record. | Pass |
| CLI argument refusal | Exercise missing, duplicate, unknown, and trailing arguments in the CLI fixture proof. | One `ERROR <message>` on standard error and exit 1; no standard output or state write. | Pass |
| CLI canonical input | Supply a semantically valid but noncanonical selector registry. | Refusal before state creation. | Pass |
| CLI traversal | Supply an appmanifest whose `installdir` is `..`. | Refusal without invalidation or input mutation. | Pass |
| CLI symlinks | Replace the appmanifest or install root independently with an in-library symlink. | Both runs refuse without following the symlink into observation. | Pass |
| CLI state boundary | Select a state root contained by the library, then one that contains the library. | Both overlap directions refuse before watcher or invalidation state creation. | Pass |
| Package refusal | Exercise unstable scans, malformed strict inputs, unsafe persistence targets, and a dead self-test detector in package tests. | Refusal before mixed identity or invalidation publication. | Pass |
| Live branch | Run the bounded production CLI against the existing installation. | Exactly Branch A or Branch B, never both. | Pass — Branch A |
| Posture | Run both Steam scripts before and after the live observation. | Both scripts pass on both sides of the scan. | Pass |

## Identity and safety guarantees

The closeout must preserve all of these guarantees:

1. Observation reads only the selected Steam library, appmanifest, installed
   title, trusted anchor, and selector registry.
2. The detector self-test runs before the real observation. A dead detector
   refuses the run.
3. A stable before-and-after scanner view is mandatory; a mixed build is
   refused.
4. Identity binds the exact app, build, depot manifest, regular-file path,
   byte size, file digest, aggregate digest, and executable-image digest.
5. Evidence selectors match only that exact identity.
6. Invalidation identity and canonical bytes are deterministic; retries,
   concurrent emission, stale-state recovery, and crash recovery converge
   without duplicate or partial records.
7. State writes occur only beneath the caller-selected state root. The Steam
   tree, anchor, registry, and historical result artifacts are not modified.
8. Observation performs no Steam launch, client control, account or session
   handling, credential access, or network access.
9. `tools/steam-fingerprint.py` remains a historical parity reference; the
   Swift CLI is the live production observer.

## Work provenance

The implementation was AI-assisted through the repository task lane for
issue #89 and touched only `runtime/store-identity/`,
`spikes/STORE-001/results/`, `spikes/STORE-001/RUNBOOK.md`, and the final-gate
header in `tools/steam-fingerprint.py`. No ADR-0012 excluded source was
consulted.

## Claim boundary and deferred work

This gate can close only the exact identity of one title in one existing live
installation. It does not establish broader storefront compatibility.

The following remain explicitly deferred:

- Lane B: hosting the Steam client inside the Alloy runtime;
- validation and selector coverage for multiple titles; and
- a long-running watcher, daemon, background schedule, or service.

## Reproduction

Run from the repository root, using a state root outside the Steam library:

```sh
ps aux | rg '[r]un-slice|[m]etal12'
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
swift run --package-path runtime/store-identity \
  AlloyStoreIdentityCLI observe \
  --library-root "$LIBRARY_ROOT" \
  --app-id 1272160 \
  --anchor spikes/STORE-001/results/fingerprint-1272160-first.json \
  --registry runtime/store-identity/Registry/selectors.v1.json \
  --state-root "$STATE_ROOT"
spikes/STORE-001/steam-readonly/gate-selftest.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
tools/lint.sh
```

**Final validation record:** Pass. The one live run matched the exact anchor,
created no invalidation, preserved the trusted input bytes, and was enclosed by
green Steam read-only gates. Full tests, every package proof, and repository
lint also passed after observation.
