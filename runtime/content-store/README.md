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
- One process-wide file lock serializes writers sharing a store root.

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

## Build and verify

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
```

The Swift suite covers multi-layer composition, canonical manifests, CAS
deduplication and quarantine, digest and size rejection, save separation,
schema rejection, failed-health rollback, and all 18 lifecycle fault points.
The process-death matrix terminates a separate updater with `_exit(97)` at the
same 18 points, recovers twice in fresh processes, and includes a
failed-health rollback control.

## Deliberate boundaries

This extraction owns durable local content identity, materialized generation
metadata, activation references, and recovery. It does not claim that the
remaining EPIC-003 stories are complete:

- transport and resumable downloads;
- TUF/DSSE authorization and Developer ID verification;
- hostile archive extraction and file-table validation;
- Zstandard decompression and APFS tree cloning;
- SQLite catalog integration;
- object leases, mark-and-sweep garbage collection, and disk planning;
- concurrent launch/update coordination beyond the single-writer lock.

The layer format specifies those trust boundaries now so later components can
implement them without silently changing persisted v1 semantics.
