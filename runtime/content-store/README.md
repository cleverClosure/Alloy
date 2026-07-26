<!-- Author: Timur Isaev -->

# Alloy content store

`AlloyContentStore` is the production successor to
[SPIKE-ROLLBACK-001](../../spikes/ROLLBACK-001/SPIKE.md). It packages the
proved journaled CAS and generation-activation design as a reusable Swift
library under the source layout selected by
[doc 04 §27.1](../../docs/docs/04_TECHNICAL_ARCHITECTURE.md#271-source-organization).

## Guarantees in this package

- Every layer is identified by a caller-authorized `sha256:` digest and size.
- CAS publication never overwrites an existing object; corrupt collisions are
  quarantined before replacement.
- Ordered multi-layer generation manifests use canonical sorted-key JSON and
  component fields aligned with
  [doc 05 §8](../../docs/docs/05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md#8-runtime-manifest).
- Generation directories and active, rollback, and candidate references are
  published atomically and validated before use.
- Every activation transition is recorded in a durable versioned journal.
- Recovery is idempotent after process death on either side of each lifecycle
  journal boundary.
- Save data is stored outside immutable generations and is never traversed by
  activation or recovery.
- Versioned generation leases pin every object used by an exactly identified
  live process and reclaim records left by dead or PID-replaced holders.
- Mark-and-sweep collection roots every game's active, rollback, and candidate
  references plus live leases; it removes unreachable generations, CAS
  objects, abandoned downloads, and quarantine leftovers.
- Dedup-aware disk preflight reports additional CAS bytes, refuses a
  caller-supplied insufficient capacity, and makes activation stage at most one
  payload per missing digest.
- GC reclaim reports separate generation, CAS, download, and quarantine bytes;
  it states whether deferred journals make the value a conservative lower
  bound.
- One process-wide file lock coordinates launch leases, writers, recovery, and
  collection across real processes.

The public entry point is `ContentStore`. Callers provide one or more
`LayerInput` values whose `LayerDescriptor` records name, version, digest,
media type, size, composition role, and optional source, license, SBOM, and
symbols metadata.

## On-disk layout

```text
downloads/<operation-id>/...
objects/sha256/<two-hex>/<remaining-hex>
quarantine/...
generations/<game-id>/<generation-id>/
  manifest.json
  layers/<order>-<digest>
references/<game-id>/{active,rollback,candidate}.json
metadata/journal/<operation-id>.json
metadata/leases/<lease-id>.json
metadata/content-store.lock
volumes/<game-id>/saves/...
```

The local generation manifest is defined by
[`generation-manifest.v1.schema.json`](Specs/generation-manifest.v1.schema.json).
The distributable layer contract and activation journal are defined by:

- [Layer format 1.0](Specs/LAYER_FORMAT_V1.md)
- [`layer-manifest.v1.schema.json`](Specs/layer-manifest.v1.schema.json)
- [Activation journal 1.0](Specs/ACTIVATION_JOURNAL_V1.md)
- [`activation-journal.v1.schema.json`](Specs/activation-journal.v1.schema.json)
- [Generation leases 1.0](Specs/LEASES_V1.md)
- [`generation-lease.v1.schema.json`](Specs/generation-lease.v1.schema.json)

## Build and verify

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
```

The Swift suite covers multi-layer composition, canonical manifests, CAS
deduplication and quarantine, digest and size rejection, save separation,
schema rejection, failed-health rollback, leases, GC, disk planning, backward
compatibility, all lifecycle fault points, and every GC fault boundary.
The process-death matrix terminates a separate updater with `_exit(97)` at the
activation and collection points, recovers in fresh processes, and includes a
failed-health rollback control. The coordination matrix forces four named
two-process interleavings without sleeps. The stress matrix records 192 seeded
operations with process-kill injection and an independent reachability oracle.

## Deliberate boundaries

This extraction owns durable local content identity, materialized generation
metadata, activation references, and recovery. It does not claim that the
remaining EPIC-003 stories are complete:

- transport and resumable downloads;
- TUF/DSSE authorization and Developer ID verification;
- hostile archive extraction and file-table validation;
- Zstandard decompression and APFS tree cloning;
- SQLite catalog integration;

The layer format specifies those trust boundaries now so later components can
implement them without silently changing persisted v1 semantics.
