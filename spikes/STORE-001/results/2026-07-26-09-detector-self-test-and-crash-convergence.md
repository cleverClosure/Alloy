# STORE-001 result 09 — detector self-test and crash convergence

**Author:** Timur Isaev

**Date:** 26 July 2026

**Disposition:** Pass

**Gate:** 5 — detector self-test and crash-safe invalidation convergence

**Base:** `c32bf3142af10541d42b0509e18dfa6f43865f5b`

## Claim

Gate 5 makes every watcher run prove its detector with a deterministic scratch
perturbation before observing the caller-selected installation. It also proves
that invalidation publication converges to one canonical record across stale
temporary files, concurrent emitters, and hard process termination at each
persistence boundary.

This gate is complete only when all of the following are proven:

1. Every unchanged and changed run stages the same deterministic perturbation
   beneath a caller-selected scratch parent and requires the detector to report
   its exact game-only file delta before calling the real observer.
2. The detector first receives an unchanged baseline control and must return no
   change, then receives the one-byte perturbation and must return its exact
   delta. An injected detector that always returns no change is refused and the
   real observer is never called.
3. Scratch children are removed after an unchanged run, changed run, dead
   detector, and observer failure.
4. A synchronized exact temporary record left before final publication is
   safely reconciled on rerun.
5. A temporary name hard-linked to an already complete final record is removed
   on rerun without replacing or duplicating the final record.
6. Matching bytes reachable only through a symlink, plus directory and FIFO
   targets, are refused without blocking.
7. Publication fault points occur in the exact order: temporary-file sync,
   final-link publication, then invalidation-directory sync.
8. Concurrent identical emitters converge without sleeps to one deterministic
   identifier, one canonical final JSON file, and exactly one creator.
9. Separate-process kills after temporary sync, after final link, and after
   directory sync leave only a pre-publication or complete-publication state;
   a clean rerun converges to one canonical final record at every fault point.

## Exact self-test delta

The self-test creates a tiny baseline installation beneath its scratch root,
copies that installation, changes one byte without changing file length, and
scans both trees with the production `FingerprintScanner`. It then runs the
production detector against those two independently scanned fingerprints. It
does not derive from or mutate the caller's anchor.

The baseline file is exactly four bytes at `probe.bin`; the copied observation
changes exactly its first byte and preserves its four-byte length. The required
detection and proof are:

```text
metadata_changed: false
game_content_changed: true
changed_depot_ids: []
added_file_paths: []
removed_file_paths: []
changed_file_paths: ["probe.bin"]
baseline_aggregate_sha256 != perturbed_aggregate_sha256
baseline file size == perturbed file size == 4
proof.changedFilePath: "probe.bin"
proof.byteCount: 1
```

The real observation is unreachable until this exact result has passed.

## Exact inputs

| Input | Role |
| --- | --- |
| `UpdateWatcherRun` production API | Orders self-test, real observation, and detector calls. |
| `InvalidationStore` canonical publisher | Implements create-if-absent publication and stale-state reconciliation. |
| `AlloyStoreIdentityFaultProbe` executable | Terminates a separate process at named persistence boundaries. |
| `runtime/store-identity/run-fault-matrix.sh` | Runs every kill point followed by deterministic recovery verification. |
| Committed Sir Brante fingerprint and selector registry | Trusted anchor and exact invalidation selectors. |

All files created by the unit tests and fault matrix are beneath isolated
scratch roots outside the observed installation.

## Both-direction controls

| Direction | Control | Required observation | Status |
| --- | --- | --- | --- |
| Positive — self-test then unchanged | Run the live detector, then return the unchanged anchor from the observer. | Exact self-test passes first; real detection is `nil`; scratch is empty. | Pass |
| Positive — self-test then changed | Run the live detector, then return a combined build and content update. | Exact self-test passes first; real update is detected; scratch is empty. | Pass |
| Negative — dead detector | Inject a detector that returns `nil` for both the unchanged and perturbed scratch scans. | Run is refused after the exact two detector calls but before observation; scratch is empty. | Pass |
| Negative — observer failure | Pass the self-test, then throw from the real observer. | Observer error propagates and scratch is empty. | Pass |
| Recovery — stale exact temporary | Stage canonical temporary bytes under the exact generated UUID grammar, plus a malformed near-miss, after an unchanged control. | Rerun emits one final record, removes the exact stale temporary, and leaves the near-miss untouched. | Pass |
| Recovery — linked temporary | Hard-link canonical temporary and final names after an unchanged emission control. | Rerun reuses the final record and removes the temporary name. | Pass |
| Refusal — unsafe target | Place a matching symlink, directory, or FIFO at the deterministic final path. | Rerun refuses without following, replacing, or blocking on the target. | Pass |
| Ordering | Record each in-process publication hook after an unchanged no-hook control. | Hooks report temporary sync, final link, directory sync exactly once and in order. | Pass |
| Concurrency | Start identical emitters together after an unchanged no-output control. | One creates; all others reuse; every result and byte is equal; no temporary remains. | Pass |
| Process death | Kill the probe independently at every persistence hook. | Each clean rerun converges to the same one-record canonical state. | Pass |
| Posture | Run the Steam read-only automation gate before and after the gate. | Both strict posture checks pass unchanged. | Pass |

Every changed, recovery, ordering, and concurrency case starts with an
unchanged observation or dead-detector control. An implementation that always
emits, always reports a change, or skips its self-test therefore cannot pass.

## Claim boundary

This gate proves detector wiring and crash convergence only with synthetic,
scratch-staged observations. It does not perform a live storefront scan, start
a long-running daemon, schedule background work, or claim that the installed
Sir Brante build is still current. The live read-only check remains Gate 6.

## Reproduction

Run from the repository root:

```sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
swift test --disable-sandbox --package-path runtime/store-identity
runtime/store-identity/run-fingerprint-parity.sh
runtime/store-identity/run-metadata-parser-proof.sh
runtime/store-identity/run-update-watcher-proof.sh
runtime/store-identity/run-selector-invalidation-proof.sh
runtime/store-identity/run-fault-matrix.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
tools/lint.sh
```

Expected final record:

```text
pre-change steam read-only gate: PASS — no account interaction
swift test: PASS — 26 tests in 6 suites
fingerprint parity: PASS — 7 focused cases
metadata parser proof: PASS — 14 hostile cases with paired clean controls
update watcher proof: PASS — 4 changed cases and 4 unchanged controls
selector proof: PASS — 3 cases, 3 unchanged controls, 3 selectors, 1 record
fault matrix: PASS — 1 scan point, 3 emit points, inputs unchanged, recovery converged
post-change steam read-only gate: PASS — no account interaction
lint: PASS
```

## Validation record

The self-test suite made the detector receive its unchanged baseline and
one-byte changed copy before the observer on both unchanged and changed runs.
The dead detector made exactly those two calls, returned no change for both,
and was refused before observation. Observer failure propagated after a
successful self-test. Every scratch parent was empty afterward.

The recovery suite removed an exact UUID-form temporary while preserving its
malformed near-miss, reconciled a temporary hard-linked to an existing final,
and refused symlink, directory, and FIFO final targets without replacement or
blocking. Eight simultaneous emitters yielded exactly one creator and seven
reusers with one identifier, one canonical final JSON file, and no generated
temporary file.

The separate-process matrix exited exactly `97` after one scanned candidate and
after each of temporary sync, final link, and directory sync. The scan rerun
was byte-identical to its clean baseline. A pre-link death recovered by
creating the expected final; both post-link deaths recovered by reusing it.
Every second retry preserved the same bytes and identifier, all input hashes
remained unchanged, and every cumulative proof, both Steam posture checks, and
repository lint passed.
