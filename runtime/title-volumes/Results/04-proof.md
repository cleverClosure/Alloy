# Milestone 4 — crash consistency and consumer handoff

Author: Timur Isaev

## Result

On 6 October 2026, the local Apple Silicon Mac passed the complete fast tier:
46 selected suites, 46 passes, no failures, no skips and no registry audit error.
The final focused title-volume run passed 24 tests in five suites, including the
last decoded-NUL root-path control added after the full tier's title-volume run.
The test-all engine self-test passed with 58 registered suites. Repository lint
and a direct SwiftLint scan of all 22 package Swift files passed.

[The machine-readable fault report](04-fault-matrix.json) records all 35 real
SIGKILL cases, six clean operations and six positive detector/negative controls.
The process supervisor requires both the exact boundary marker and SIGKILL; a
probe that never reaches its requested boundary is deliberately rejected. An
independent Python oracle hashes actual paths and contents after a fresh process
opens the store. Save replacement must be the complete pre- or post-operation
tree, and every unrelated title must remain unchanged.

| Operation | Process-death cases | Required result |
| --- | ---: | --- |
| Snapshot | 6 | Live save tree unchanged; partial archive never published |
| Backup | 6 | Live save tree unchanged; partial archive never published |
| Restore | 6 | Exact old or restored tree, original retained in an archive |
| Settings | 7 | Settings metadata recovers with its tree; saves unchanged |
| Cache | 6 | Disposable cache recovery; saves unchanged |
| Scratch | 4 | Disposable cleanup recovery; saves unchanged |

The clone-file boundary is exercised after both the first and second file for
snapshot and backup. Additional controls detect a planted torn replacement,
quota overrun, cross-title escape and deliberately corrupting lifecycle probe.
A live child lease prevents scratch deletion; killing that child releases the
OS lease and permits expiry. The clean counterparts pass.

## Real content-store integration

The probe links the existing `AlloyContentStore` package without changing its
source. It activates two different generations, fails a third generation's
health check and verifies rollback to the second, collects a nonzero number of
generations and objects, uninstalls, and runs restart recovery. Independent save
hashes remain identical at every step. This checks real transitions rather than
accepting a no-op as evidence. A legacy title first populated through the actual
content-store save API is explicitly adopted with unchanged bytes and tightened
permissions. A hard-linked legacy file is refused without changing the outside
file's permissions.

The [consumer contract](../Specs/CONSUMER_HANDOFF.md) publishes the C/G/S/T plan,
six required compiler volume keys, cache compatibility identity, quiet writer
boundaries, profile save-path sidecar and monitored-discovery input interface.
The current profile schema has no save-path field, so the typed sidecar is an
explicit integration contract rather than an unverified schema extension.

## Validation history

The first full local tier had two failures in unchanged service proofs: a missing
native hang sample and a launchd cleanup check that still saw the removed service.
Both suites passed when rerun alone (47 diagnostic assertions and 38 operation
assertions), then the entire fast tier passed without modifying those suites or
weakening checks. Hosted milestone 3 also caught an overlong Swift line; it was
wrapped before rerunning CI. Neither failure is counted as a passing run.

The final root control initially showed that Foundation's legacy URL `path`
property leaves an encoded NUL escaped. Root validation now uses the explicitly
decoded path and rejects NUL before any filesystem operation. The final focused
run includes this refusal and the symlink-alias refusal, with ordinary roots as
positive controls.

## Reproduction and limits

```sh
swift test --package-path runtime/title-volumes
python3 runtime/title-volumes/run-fault-matrix.py
tools/test-all --selftest
tools/test-all --tier fast
tools/lint.sh
```

The harness uses synthetic files and owned child processes. It never starts an
x64 guest or modifies the shared Wine/FEX runtime. APFS clone use has a positive
unit control; a verified streaming-copy fallback handles unsupported filesystems.
This is process-death evidence, not hardware power-cut testing. Production
callers must stop/cooperate with writers and enforce broker access and quotas.
Archives are local copies, with no automatic save deletion or retention purge;
cloud backup, guest monitoring, filesystem mounting, UI and XPC remain outside
this package's scope. The full local tier covers native service checks that the
existing hosted low-memory policy skips.
