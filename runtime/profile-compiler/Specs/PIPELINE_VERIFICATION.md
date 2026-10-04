# Full-pipeline verification and pre-signing review

Author: Timur Isaev

Compiler version `0.6.0` completes the six implementation milestones of #101.
The entire package runs in the existing `profile-compiler-swift-test` fast
suite, which `.github/workflows/ci.yml` invokes through `tools/test-all`.
There are no extra external dependencies or excluded-runtime source reads.

## Reproduction

```sh
swift build --package-path runtime/profile-compiler
swift test --package-path runtime/profile-compiler
swift test --package-path runtime/profile-compiler --filter FullPipelineFuzzTests
tools/test-all --tier fast --only profile-compiler-swift-test
tools/lint.sh
```

The complete suite has 57 tests in 13 suites. Its fixed structured-fuzz budget
is 512 iterations with seed `0x101600DCAFE` (decimal `1105418111742`). Each
iteration co-mutates a valid profile, manifest component version/digest, game
build identity, macOS/memory tuple, process ordering, and signed evidence;
the base alternates between the minimal fixture and unchanged converted example.
It then compiles, audits fields directly against the original inputs, and
round-trips the exported artifact before testing one paired invalid mutation.

All 512 clean tuples compiled and all 512 invalid tuples rejected. The completed
run reported zero crashes and zero false accepts. This is a bounded, reproducible
test result, not an exhaustive correctness or security proof.

Before the loop, a seeded bad tuple from **each** of 14 categories must reject:
tampered signature, unsigned input, expired envelope, profile schema, manifest
schema, runtime-generation mismatch, host mismatch, build mismatch, equal-rank
profile conflict, missing workaround owner, expired certification, feature
ceiling, unscoped competitive claim, and secret/verification-bypass environment.
The audit is itself controlled: pretending each bad category returned a clean
output must raise false-accept, and feeding an old output with changed inputs
must raise invalid-output. Disabling the audit deliberately makes this test fail.

The launch regression digests in `Tests/Fixtures/Launch/golden-digests.json`
pin both full outputs after field-by-field inspection against the source profile,
manifest, and doc 05 section 18. Ten separate test processes compare these
goldens; each process also performs ten order-varied compile/re-resolve rounds.
These are regression fixtures, not independent implementations. The independent
binary oracle remains WINE-001's existing CLI and preserved July artifact.

## Measurement controls and CI

- Canonical encoding: 24 published numeric vectors, 10,000 independent
  JavaScriptCore comparisons, byte goldens, and deliberate sorting corruption.
- Envelopes/host: tampered and expired signatures, explicit unsigned mode,
  native Mac capability match, and impossible OS; deliberately bypassed
  signature and OS-minimum checks are caught.
- Resolution: five profile and seven process paired goldens, input-order
  reversal, and twelve deliberate implementation defects, each caught.
- Snapshot: unchanged external CLI, preserved snapshot bytes and recorded
  digest, plus provider corruption and missing-coverage controls.
- Launch semantics: seven disabled validation checks (owner, expiry, ceiling,
  vendor scope, grant scope, round trip, immutable mask) each fail their tests.
- CI was deliberately made red by corrupting a fixture in scratch PR #110
  (run `37150984184`), then green after restoration (`37151188590`). The
  schema milestone and every subsequent merged milestone are gated by the
  same full-package suite. No broken control is in the delivered branches.

## Doc 05 section 26 review checklist

| Pre-signing review item | Compiler evidence / remaining production responsibility |
| --- | --- |
| Selectors match intended builds | Exact fingerprints and signed whole-build aliases; paired stale/unknown/conflict cases |
| Host coverage equals evidence | Exact normalized host/build evidence binding; native Mac positive/negative control |
| Every process has intentional policy | Conjunctive match and precedence goldens; complete observed-process resolution |
| Unknown default is safe | No inherited access, denied network, conservative sync; Wine enforcement gaps remain explicit |
| Provider versions exist | Named bindings and profile layers must occur in the immutable manifest; content store must verify installed bytes |
| Feature masks do not over-report | Synthetic registry ceilings and immutable IDs; real provider ceilings/certification remain future work |
| Minimal filesystem/network grants | Scoped local grants, root/unsafe mappings and unscoped expansion rejected; filesystem enforcement remains a runtime gap |
| Cache invalidation is correct | Domain-separated epochs bind all signed identity/policy inputs and resolved processes; revision-change control |
| Dependency provenance/legal approval | Immutable manifest digest plus signed local approval and license gate; real OSPO approval remains external |
| Workarounds have owner/evidence/review | Required fields, exact scope, introduction revision, finite review lifetime, evidence digests |
| Reliable health checks | Schema-checked and bound by profile digest; actual reliability requires a lab run and remains a runtime gap |
| Accurate readable limitations | Schema-preserved and bound to the profile; editorial and game-specific accuracy require review |
| Certification is current | Test date, finite evidence expiry, lifecycle/ring, exact binding, separate signed vendor scope |
| Rollback generation exists | Distinct generation required in trusted local inventory; content store must verify physical availability |
| Signature/release metadata valid | Test-key/explicit Development Mode verification and ring gates; production chain/rotation/revocation delivery remain excluded |

This checklist is reviewed for the requested **pre-signing compiler prototype**.
It does not authorize stable promotion. Every output carries test/development
provenance, a `local-unregistered:` host ID, synthetic-only feature evidence,
`productionEligible: false`, and explicit runtime coverage gaps. The compiler
does not launch a game or claim the blocked x64 runtime has been repaired.
