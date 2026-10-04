<!-- Author: Timur Isaev -->

# Offline diagnostics acceptance

Date: 4 October 2026. Host: Apple M2 Pro, arm64, macOS 27.0 (26A428), Apple Swift 6.4 (swiftlang-6.4.0.34.1).
Issue #103's six milestones were implemented in an isolated worktree. Shared
Wine/FEX sources and runtime binaries were not used or changed.

## Result

The scoped offline hypothesis passed. The complete package's terminal tests
cover the model, taxonomy, native capture, redaction, local bundles and
bundle-only failure classification. All eight generated bundles match their
literal expected answers; disabling each of the seven injections produces no
false diagnosis.

| Evidence | Observation |
| --- | --- |
| Identity/taxonomy | 11 tests; nine correlation groups; 17 classes; 21 source category references |
| Native capture/lifecycle | Eight tests; actual symbolication and sampled hang; positive timeout/overflow controls; child heartbeat stops after debugger timeout |
| Redaction | Ten tests; 20 literal secrets removed; clean 316 bytes unchanged |
| Fuzz seed `3517317121` | 360 insertions, zero survivors, catch rate 1.0 |
| Fuzz seed `3517317122` | 360 insertions, zero survivors, catch rate 1.0 |
| Fuzz seed `3517317123` | 360 insertions, zero survivors, catch rate 1.0 |
| Bundle/preview | Ten tests; exact inventory, secret exclusions, permissions, malformed/tampered/symlink controls and size bounds |
| Classifier | Seven matched causes + one insufficient-evidence fixture; seven disabled controls; seven missing-signal controls; mixed/conflicting/empty evidence abstains |

The three fuzz seeds are each rerun deterministically. The count of 1,080 is
unique trial insertions, not doubled by replay. Detection counts can overlap
across rules; zero-survivor exact string searches are the correctness oracle.

## Reproduction and durable evidence

```sh
swift test --package-path spikes/DIAG-001/prototype
swift run --package-path spikes/DIAG-001/prototype DiagnosticsOracle generate \
  /private/tmp/diag-new-oracle \
  spikes/DIAG-001/prototype/.build/debug/AlloyDiagnosticsSubject
swift run --package-path spikes/DIAG-001/prototype DiagnosticsOracle classify \
  /private/tmp/diag-new-oracle/bundle-07
```

Generation requires a previously absent destination. It ran real local
operations and exported [these eight sealed bundles](../prototype/Tests/AlloyDiagnosticsTests/Fixtures/oracle/oracle.json).
The final command reports `insufficient_evidence`. The mapping file is outside
the sealed bundle directories and is never an input to the classifier. Fresh
tests regenerate the cases, delete injection scratch state and move the bundle
directories to random names before classifying them. Committed examples are
also read through the seal verifier and checked against literal answers.

Each earlier milestone was verified independently of subsequent uncommitted
work by exporting its exact commit into a clean temporary source snapshot:

| Milestone | Source commit | Local result |
| --- | --- | --- |
| Native capture | `b34f4e2` | 19 tests passed in 10.824s |
| Redaction | `ad8a4cb` | 29 tests passed in 10.498s |
| Local bundles | `6e7e6ba` | 39 tests passed in 9.304s |

The integrated model, capture, redaction, bundle and generated-oracle run passed
43 tests before the additional committed-fixture verification was added. Final
source/test evidence is recorded below after that last control.

## Interpretation

The expected diagnoses are profile mismatch, wrong provider, shader compiler
crash, permission denial, corrupt cache, memory pressure, guest crash, and
insufficient evidence. The first two use synthetic selection files and actual
byte reads/digests. Permission denial is a real `EACCES`; cache corruption is
an actual overwritten byte. Memory pressure is a 65,536-byte request rejected
by a 32,768-byte local quota. Two actual native fatal errors have different
harness-assigned roles. These prove the specified synthetic contracts, not
real game/provider/compiler diagnosis or physical host-memory behavior.

Raw native traces remain local capture evidence and are excluded from exported
bundles. Exported typed summaries preserve cause and correlation without
asserting a proven structural filter for arbitrary stacks. The manifest reports
retained schema classes; arbitrary text still requires honest caller
classification. The known textual grammar and class-level exclusion limitations
are documented in [redaction](../prototype/Specs/redaction.md).

No regional/default consent policy was selected. Local export requires no
simulated consent, and the preview exists beforehand. Upload is an unavailable
interface at every consent level. Encryption, support links, production
retention and real client/daemon wiring remain deferred. Apple SDK CryptoKit
supplies hashes, following the existing content-store package; Package.swift
has no external dependencies and source tests prohibit networking APIs.

The native process census is bounded, cooperative and tested against LLDB's
actual separate-session children. It is not a hostile-process sandbox.
SHA-256 file seals are accidental-integrity checks, not authentication or
encryption. Private file permissions do not change that distinction.

## Final committed-source proof

Source commit: `9fcbfef202e1e1fb5c0cfe50cdf22e6ff995410e`. A clean `git archive`
snapshot containing the package and its source privacy document passed **44
tests in six suites in 10.623 seconds**. This includes all committed-fixture
checks. The [complete test log](2026-10-04-offline-diagnostics-tests.log) and
[structured evidence](2026-10-04-offline-diagnostics-evidence.json) are committed
alongside this report. The evidence binds the log and all 17 fixture JSON files
by SHA-256 and records the host/toolchain, command, seed results and oracle rows.

Log SHA-256: `4d413cabe4f5e549772d66fab22a60fcb467ea418ec95385f26d29ee94cc4b92`.

The final scope audit found no changes under `docs/`, `.github/`,
`third_party/`, or the Wine spike/runtime. The shared primary checkout remained
clean. Repository lint passed for each implementation milestone. Hosted CI
checks repository policy and existing registered suites; the 44-test native
diagnostics acceptance remains explicitly local for this issue.
