# ROLLBACK-001 result 12 — everything races everything

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Validation:** 62 Swift tests, 37 fault cases, 6 deterministic concurrency
cases, and 192 seeded stress operations passed; strict lint passed
**Repository base:** `df88debee606b9ddfe4f6e5728f6655d52b1cdfb`

## Exact claim

The extended adversarial harness proves that transport downloads,
including real process death and exact Range resume, compose safely with
activation, rollback, leases, lease release, and garbage collection. An
in-flight transport operation's versioned staging remains protected while its
sidecar is live. A `published` sidecar roots its CAS digest through the
publication/operation-cleanup boundary. A completed transport publishes its
authorized digest exactly once, removes completed staging, and is subsequently
reused without another transfer. After every recovery through a newly opened
store, the rebuildable SQLite catalog reports exact zero divergence from disk
truth.

No test uses the public network. The transport fixture binds only to
`127.0.0.1`, and every process uses the production transport, activation,
lease, collection, catalog, and recovery paths.

## Both-direction controls

The completed gate establishes both sides of each safety claim:

1. a live transport sidecar protects its partial payload from collection,
   while unrelated abandoned download staging is swept;
2. a process killed after the first durable 64 KiB checkpoint resumes that
   exact prefix, while an uninterrupted control produces the same final
   digest and bytes;
3. the first successful publication transfers the remaining authorized bytes,
   while a repeated fetch reuses the same CAS object with zero transferred
   bytes and no second publication;
4. a `published` transport sidecar protects its CAS object through collection,
   while retry removes the sidecar and a later collection removes that
   otherwise unreferenced object;
5. a live lease preserves its generation through a sweep, while release makes
   that otherwise unreachable generation collectible;
6. activation and rollback move references in opposite model directions, and
   both remain valid through intervening downloads and recovery;
7. `downloader-before-gc` and `gc-before-downloader` reverse the forced
   two-process ordering around the same store lock and transport sidecar;
8. every clean or recovered state reports zero catalog divergence; a nonzero
   `catalogAhead` or `diskAhead` set is an immediate harness failure.

## Deterministic two-process interleavings

`runtime/content-store/run-concurrency-matrix.sh` extends the existing
marker-file and `kqueue` handshake pattern with a real downloader process and
a real collector process. The cases use named library boundaries, nonblocking
`flock` contention proofs where the global lock is involved, and explicit
continuation markers. They use no sleeps, scheduler guesses, or in-process
thread substitutes. Transport-fixture readiness is delivered through a
bounded FIFO read rather than polling sleeps.

The transport/collection coverage forces both orderings:

1. **`downloader-before-gc`:** the downloader pauses at its first
   `after-transport-stream-chunk` durable checkpoint with a live sidecar.
   Collection runs to completion and preserves both transport staging and
   leased generation A alongside active C and rollback B. The downloader then
   resumes, publishes and reuses one verified object, and cleans its operation
   directory. Releasing A's lease followed by collection removes A.
2. **`gc-before-downloader`:** collection pauses at `after-gc-mark`. A
   downloader child emits its entered marker before opening `ContentStore`,
   then blocks on the collector's store-wide `flock`. Collection continues and
   sweeps seeded abandoned staging and unreachable generation A. Only after
   the lock is released may the downloader open the store, fetch, publish, and
   reuse its verified object.

Each case verifies the authorized payload bytes and digest, completed staging
cleanup, exactly one CAS object for the digest, active and rollback validity,
and catalog consistency from a newly opened store.

The `downloader-before-gc` case also kills a second downloader at
`after-transport-publication`. The collector then proves that the surviving
`published` sidecar roots the verified CAS payload despite the absence of a
generation or lease root. Retry reuses that payload without transfer, removes
the sidecar, and a final collector proves that the now-unrooted object is
reclaimable. The focused transport regression independently checks the same
protect/retry/reclaim sequence through both the reclaim estimator and the
collector.

## Stress model and invariants

The seeded harness adds `download` as a seventh operation beside `publish`,
`activate`, `rollback`, `lease`, `release`, and `sweep`. Each seed starts with
a shuffled coverage prefix containing every operation, then continues with
deterministic pseudo-random choices.

The in-memory model tracks the active and rollback generations, materialized
generation payloads, live leases, and whether the fixed unreferenced transport
object is present. A completed download sets that transport-object state; a
completed sweep clears it. After every operation, a fresh `ContentStore`
instance performs explicit recovery and the oracle requires:

- active and rollback references equal the model;
- candidate is absent and every activation journal is terminal;
- every referenced or leased generation validates through its manifest,
  materialized layer, and CAS digest;
- the save sentinel remains byte-identical;
- actual presence of the transport digest in CAS equals the model;
- `catalogConsistencyReport()` has empty `catalogAhead` and `diskAhead`.

Every completed download separately verifies its payload and digest, then
requires its operation staging to be absent before and after a zero-transfer
CAS-reuse control.

After every completed sweep, the stronger exact oracle additionally requires:

- on-disk generations equal active + rollback + live-lease generations;
- on-disk CAS objects equal the unique digests reachable from those
  generations;
- the unreferenced transport object has been removed.

The permanent seed set is:

```text
85
740085
12648430
20260726
```

Each seed ran 48 steps, for 192 modeled operations in the recorded run. The
harness prints the seed, step, operation, and selected fault on every step so a
future failure can be reduced to a permanent regression.

## Process-death and resume behavior

The first forced `download` in every seed died in a child process at
`after-transport-stream-chunk`, leaving exactly one durable 64 KiB prefix. The
coordinator retried the same operation ID and base URL and required:

- `resumedFromByteCount == 65536`;
- transferred bytes equal the authorized size minus 65536;
- the final bytes and SHA-256 equal the fixture payload;
- the transport staging directory is removed;
- a second fetch reuses CAS and transfers zero bytes.

Later downloads select from the production transport death points when the
unreferenced object is absent:

- `after-transport-stream-chunk`;
- `before-transport-verification`;
- `after-transport-verification`;
- `before-transport-publication`;
- `after-transport-publication`.

Each killed child exited through `_exit(97)`. Resume occurred through a new
store instance and the same persisted operation record, not through a caught
error or a stress-only recovery format. If the object was already present,
later download operations exercised the clean CAS-reuse path instead.

The forced checkpoint-resume controls occurred at seed/step `85/6`,
`740085/2`, `12648430/0`, and `20260726/6`. Every one recorded
`resume=65536`. The byte-identical uninterrupted control is the permanent Gate
2 exact-Range-resume test, which remained green in the 62-test suite.

## Reproduce

Final validation ran:

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
```

Recorded stress breadth:

```text
seeds=85 740085 12648430 20260726
steps_per_seed=48
total_steps=192
```

Recorded validation summaries:

```text
swift test: 62 tests passed
fault matrix: SUMMARY cases=37
concurrency matrix: SUMMARY cases=6
stress matrix: SUMMARY seeds=85 740085 12648430 20260726 steps_per_seed=48 total_steps=192
strict lint: pass
```
