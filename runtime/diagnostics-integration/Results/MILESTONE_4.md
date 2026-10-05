<!-- Author: Timur Isaev -->

# Milestone 4 — integrated proof and handoff

5 October 2026, Apple Silicon macOS, Xcode Swift 6, private test-only stores.

## Local results

| Check | Observed result |
| --- | --- |
| Registered Swift integration suite | 9 tests passed |
| Registered live-service integration suite | 47 PASS, 0 FAIL, 0 SKIP; 6 actual-service bundles |
| Final deliberately wrong identity oracle | 46 PASS, 1 expected FAIL, exit 1 |
| Complete reused offline diagnostics package | 46 tests in 7 suites passed |
| test-all selftest | pass/fail/skip/timeout, counts and result reporting passed |
| Scope | diagnostics integration, narrow reused redaction/capture extensions, tools registry only |

The negative control fails exactly `independent-identity-operation-clean`.
The normal proof runs the unchanged service and compiled diagnostic client; it
cannot pass from hand-built events alone. Its expected outcome fixture pins
operation and session outcomes, build/profile/generation IDs and unavailable
provider evidence. The oracle derives operation/session IDs independently from
keys and computes the expected local host identity from measured capabilities.
It verifies every exported correlation and a valid retained diagnostic RPC UUID.

A real failed download is observed before 20 supported synthetic secrets are
planted in its private test error record. The adapter reads that record through
XPC, and all 20 have zero survivors across raw exported bytes and decoded JSON
strings. A supported secret inserted into an otherwise valid resealed bundle
is rejected. The check changes an extra free-text error field, so another state
validator cannot accidentally make a dead scanner look effective.

Corrupted build identity, omitted event, omitted event with corrected count,
omitted native sample with corrected count, and an oversized manifest are
independent rejection controls. The proof retains only typed native summaries,
stops the service, reopens/previews/exports/deletes offline, and confirms the
service's durable JSON records remain byte-identical. Temporary service jobs,
owned native children and test stores are cleaned up.

## Corrections exposed by integration

Duration strings with unrestricted float precision could resemble a card number;
the summary now uses six decimals. Strictly typed canonical protocol UUIDs and
runtime hash identities preserve their numeric runs, with tests proving that
free-text planted secrets still disappear. The adapter additionally verifies
operation payload digests, immutable request identity and terminal session node
consistency. Bundle validation now checks the indexed audit independently of
its outer count. Cleanup after a failed create removes only a bundle actually
published by that call, never a preexisting destination.

## Hosted behavior and residual limits

The two non-GUI suites are registered in the fast tier (53 total registered
suites). The Swift suite has a 300s ceiling; the integrated suite has a 420s
ceiling and 30s cleanup grace, with SIGTERM entering fixture teardown. On an
actual non-arm64 or sub-8GiB host, the unchanged compiler prevents fixture
sessions: 20 PASS and 7 explicitly skipped rows are expected (27 total).
Operation failure/privacy/lifecycle rows still run. Hosted results must be read
separately from the complete local result; native coverage is never inflated.

The signal-abort outcome is service-recorded native exit evidence, not a crash
stack or a general crash classifier. The hang is the service-owned native poll
fixture, not a Wine guest. No provider execution, physical memory-pressure,
production certification, arbitrary-process collection, real saves, upload,
external support message, consent default or production retention is claimed.
The seal is corruption detection, not authentication against a full rewrite.
Known secret grammar is not proof against every possible private value. The
manifest's removed-class list reflects the final bundle filter; earlier adapter
minimization already discarded raw fields and stacks.

Client API, commands, ownership, absence markers, budgets and outcomes are in
[the handoff](../Specs/CLIENT_HANDOFF.md) and [v1 contract](../Specs/LOCAL_DIAGNOSTICS_V1.md).
