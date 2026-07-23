# ROLLBACK-001 result 01 — transactional generation lifecycle

**Author:** Timur Isaev
**Date:** 24 July 2026
**Status:** Phase-0 spike closed
**Repository base:** `48bb4d3`; prototype and this evidence record are one change set
**Host:** MacBook Pro M2 Pro, 16 GB, macOS 26.5.2, APFS, Swift 6.2.4

## Verdict

Pass. A user-space prototype published immutable SHA-256 objects, materialized complete
generations, recorded a rollback target, atomically switched the active reference, recovered
idempotently after process death at every lifecycle boundary, and left the save sentinel
byte-identical.

This closes the Phase-0 transactional-lifecycle proof. It does not promote the prototype into
the Phase-1 runtime store.

## Implemented proof surface

The Swift package under `prototype/` implements:

- durable temporary downloads with explicit `fsync`;
- SHA-256 verification before CAS publication;
- no-clobber CAS publication through a hard link, immutable file modes, deduplication, and
  corrupt-object quarantine;
- immutable generation directories containing a canonical sorted-key manifest and hard-linked
  verified layer;
- same-directory temporary reference files followed by atomic `rename`;
- a durable per-operation JSON journal;
- a process-wide `flock` writer lock;
- a rollback reference written before the active reference;
- health-pass retention and health-failure rollback;
- saves under a separate volume tree never traversed by runtime activation or cleanup;
- strict identifier validation against path traversal.

The prototype intentionally uses one raw layer object per generation. That is sufficient to
exercise the lifecycle invariant without pretending to implement the production archive,
signature, or composition formats.

## Fault matrix

The committed harness bootstraps `generation-a`, writes `save-v1`, starts activation of
`generation-b`, and calls `_exit(97)` at the selected point. A fresh process then runs recovery
twice and verifies:

- active = complete `generation-b`;
- rollback = complete `generation-a`;
- candidate reference removed;
- no incomplete journal remains;
- both generation manifests and all CAS objects re-hash correctly;
- save = `save-v1`.

| Lifecycle stage | After action, before journal | After journal |
| --- | --- | --- |
| download | Pass | Pass |
| verify | Pass | Pass |
| publish CAS | Pass | Pass |
| materialize | Pass | Pass |
| prepare candidate | Pass | Pass |
| record rollback | Pass | Pass |
| switch active | Pass | Pass |
| health window | Pass | Pass |
| retain/collect | Pass | Pass |

An additional healthy-baseline → unhealthy-candidate run restored `generation-a` and preserved
the save.

Harness result:

```text
SUMMARY cases=19 elapsed_seconds=2
```

## Functional tests

`swift test` passed seven tests, including an 18-case parameterized recovery test:

```text
Test run with 7 tests in 0 suites passed after 0.393 seconds.
```

Coverage:

1. successful update retains the previous generation and save;
2. failed health restores the previous active generation;
3. duplicate payloads share one CAS object;
4. an expected-digest mismatch cannot activate;
5. a corrupt pre-existing local object is quarantined and replaced before activation;
6. every action/journal boundary recovers idempotently, including a second recovery pass;
7. traversal identifiers are rejected.

Repository lint also passed with SwiftLint, ShellCheck, shfmt, and Markdownlint active for the
new files.

## Reproduce

```sh
SWIFT_MODULECACHE_PATH=/tmp/alloy-rollback-swift-cache \
CLANG_MODULE_CACHE_PATH=/tmp/alloy-rollback-clang-cache \
swift test --disable-sandbox --package-path spikes/ROLLBACK-001/prototype

spikes/ROLLBACK-001/prototype/run-fault-matrix.sh
tools/lint.sh
```

`--disable-sandbox` disables SwiftPM's nested build sandbox only; the test data remains in a
fresh temporary directory and the outer workspace sandbox remains in force.

## Limits carried into Phase 1

- `_exit` is a deterministic abrupt process-death test, not physical power removal. The
  prototype places `fsync` at the required file/directory boundaries, but a production APFS
  power-cut campaign remains required.
- Layer signature/TUF/DSSE validation, secure archive extraction, file-table validation, and
  provenance attestations are not implemented.
- Materialization uses hard links, not the planned APFS `clonefile` tree path or verified-copy
  fallback.
- Journals are canonical JSON files, not the planned SQLite WAL plus append-only event record.
- Concurrency proof is limited to a single-writer `flock`; multi-game shared-layer leases,
  concurrent launch/update, low-disk behavior, and production garbage collection remain open.
- The prototype retains the rollback generation and removes only the candidate reference. It
  does not implement mark-and-sweep or user-approved rollback-generation deletion.

These are Phase-1 implementation and qualification requirements; none weakens the Phase-0
invariant demonstrated here.
