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
- Dedup-aware disk preflight reports additional CAS bytes. Activation also
  checks peak logical content bytes, including one private publication copy
  of the largest missing object, before starting. Metadata/allocation overhead
  and concurrent writers are outside this estimate. Duplicate missing digests
  share one staged input.
- GC reclaim reports separate generation, CAS, download, and quarantine bytes;
  it states whether deferred journals make the value a conservative lower
  bound.
- Ordered mirrors fetch caller-authorized objects by digest through Foundation
  `URLSession`; durable partial records resume exact Range checkpoints and
  restart cleanly when a server ignores Range.
- Transport rejects wrong, truncated, oversized, stalled, length-disagreeing,
  and redirect-loop responses before CAS publication. Verified payloads use
  the existing non-overwriting publication path.
- `metadata/catalog.sqlite` indexes objects, generations, references, and
  leases for constant-time inventory. Disk remains the only truth: missing,
  invalid, or divergent catalogs are detected and rebuilt automatically.
- One process-wide file lock coordinates launch leases, writers, recovery, and
  collection across real processes. Per-operation transport locks allow
  network streaming without holding that global lock.

The public entry point is `ContentStore`. Activation callers provide one or
more `LayerInput` values; transport callers pass a caller-authorized
`LayerDescriptor` and ordered base URLs to `fetchObject`. The descriptor
records name, version, digest, media type, size, composition role, and optional
source, license, SBOM, and symbols metadata.

## On-disk layout

```text
downloads/<activation-operation-id>/<order>-<digest>.part
downloads/<transport-operation-id>/
  transport.json
  <order>-<digest>.part
objects/sha256/<two-hex>/<remaining-hex>
quarantine/...
generations/<game-id>/<generation-id>/
  manifest.json
  layers/<order>-<digest>
references/<game-id>/{active,rollback,candidate}.json
metadata/journal/<operation-id>.json
metadata/leases/<lease-id>.json
metadata/transport-locks/<operation-id>.lock
metadata/catalog.sqlite
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
- [Transport 1.0](Specs/TRANSPORT_V1.md)
- [`transport-record.v1.schema.json`](Specs/transport-record.v1.schema.json)
- [Rebuildable catalog 1.0](Specs/CATALOG_V1.md)
- [`catalog.v1.sql`](Specs/catalog.v1.sql)

## Build and verify

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
```

The 62-test Swift suite covers multi-layer composition, canonical manifests,
CAS deduplication and quarantine, transport resume and hostile responses,
digest and size rejection, save separation, schema rejection, failed-health
rollback, leases, GC, disk planning, rebuildable-catalog convergence, backward
compatibility, and focused fault-boundary recovery.
The process-death matrix terminates separate updater, collector, or downloader
processes with `_exit(97)`, recovers in fresh processes, and passes all 35
exposed production fault points plus restart and rollback controls, for 37
cases. The coordination matrix forces six named two-process interleavings
without sleeps. The stress matrix records 192 seeded operations across
activation, rollback, leases, collection, and kill/resume transport with
independent reachability and catalog-consistency oracles.

## Deliberate boundaries

This extraction owns durable local content identity, materialized generation
metadata, activation references, resumable verified transport, rebuildable
inventory, and recovery. It does not claim that the remaining EPIC-003 stories
are complete:

- TUF/DSSE authorization and Developer ID verification;
- hostile archive extraction and file-table validation;
- Zstandard decompression and APFS tree cloning;

The layer format specifies those trust boundaries now so later components can
implement them without silently changing persisted v1 semantics.

The [lifecycle hooks](Specs/LIFECYCLE_V1.md) provide stable activation replay,
expected-reference uninstall, and explicitly authorized corruption repair for
callers that own a separate installation operation journal.
