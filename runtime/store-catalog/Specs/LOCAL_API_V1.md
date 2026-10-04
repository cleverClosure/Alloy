<!-- Author: Timur Isaev -->

# Local catalog API v1

This package implements the local mechanisms in doc 06 sections 6, 7, 20 and
21. The authority is the explicit local catalog root supplied by its owner;
there is no daemon, remote principal, storefront download, or shipped UI.
JSON keys use the exact Swift property spellings below. Unknown schema versions
are rejected. Timestamps are UTC ISO 8601; IDs are stable strings.

## Catalog records

| Record | Fields and meaning |
| --- | --- |
| GameSummary | `gameID` (`steam-` plus app ID), `name`, sorted unique `buildIDs`, sorted `installationIDs` |
| GameInstallation | `installationID` (SHA-256 of explicit local install path), `libraryPath`, `installPath`, `manifestPath`, `fingerprint` (existing validated AlloyStoreIdentity record) |
| GameDetails | `summary: GameSummary`, `installations: GameInstallation[]` |
| CatalogPage | `snapshotID` (SHA-256 of canonical installation records), `games: GameSummary[]`, optional opaque `nextPageToken` |

One immutable catalog snapshot contains fully fingerprinted installations.
Manifest parsing and fingerprinting use the existing production package.
Pagination is sorted by game ID with a limit of 1–1000; a token from a different
snapshot is rejected. Discovery and refresh return observations; the operation
engine records their durable operation/result envelope in later milestones.

## Installation and storage records

The following field-level contract is the target of the next two milestones.
Each plan is frozen and content-addressed before an operation starts. No plan
names a Steam payload as a mutation target.

| Record | Fields and meaning |
| --- | --- |
| InstallPlan | `planID` (digest of the canonical request), `gameID`, `installationID`, `generationID`, ordered `layers` (existing LayerDescriptor records), ordered `baseURLs` (download mirrors), `requiredObjectBytes` (missing CAS estimate) |
| UninstallPlan | `planID`, `gameID`, `installationID`, `expectedReferences` (active, rollback and candidate generation references); only these Alloy references are retired |
| StorageInventory | `objectCount`, `objectBytes`, `objectReferenceCount`, `generationCount`, `referenceCount`, `leaseCount` from the content-store catalog |

`objectBytes` counts logical unique CAS bytes, not filesystem allocation or
save volumes, temporary downloads, quarantined bytes or metadata. Installation
space estimates cover missing CAS objects; they do not claim a whole-volume
free-space guarantee. Live leases and save volumes survive uninstall. GC owns
subsequent reclamation. Repair uses the original descriptors and verified
replacement bytes and must validate the installed materialization afterwards.

## Operation envelope

| Field | Type / invariant |
| --- | --- |
| `version` | integer 1 |
| `operationID` | `op-` plus SHA-256 of operation kind, NUL separator and idempotency key |
| `kind` | DISCOVER_INSTALLATIONS, REFRESH_BUILD_FINGERPRINT, INSTALL_RUNTIME, UNINSTALL_RUNTIME, REPAIR_INSTALLATION, STORAGE_INVENTORY, COLLECT_GARBAGE |
| `idempotencyKey` | nonempty UTF-8 string, at most 256 bytes, scoped to this local journal root and kind |
| `payload` | canonical sorted-key JSON encoded as base64 by Codable; immutable semantic request |
| `payloadDigest` | lowercase SHA-256 of payload bytes, validated on read |
| `previousAttemptID` | optional existing terminal attempt ID; retry uses a new key and operation |
| `createdAt`, `updatedAt` | UTC ISO 8601 timestamps |
| `state`, `stage` | state below and stable operation-stage code |
| `progress` | unsigned completedUnits/totalUnits and bytesCompleted/bytesTotal; completed never exceeds total |
| `result` | optional canonical result JSON encoded as base64; durable on success |
| `error` | optional failure description |
| `events` | ordered state/stage history, beginning QUEUED; validated against transition graph |
| `canPause`, `canCancel` | explicit current capabilities; false for terminal records |
| `cancellationPolicy` | RETAIN_VERIFIED_OBJECTS; subsequent GC may reclaim unrooted objects |

The allowed edges are QUEUED→RUNNING; RUNNING→PAUSED, SUCCEEDED, FAILED or
CANCELLING; PAUSED→RUNNING or CANCELLING; CANCELLING→CANCELLED. Terminal states
are immutable. RUNNING stage checkpoints preserve state. A queued cancel first
starts the operation then follows CANCELLING→CANCELLED without side effects.
Activation and irreversible publication stages disable pause/cancel; recovery
finishes or reconciles an already-started publication before claiming success.

## Durability and replay

Each operation and its key mapping are the same JSON record. A separate local
`flock` serializes reads and replacements. Writers use a private exclusive
0600 temporary file, write all bytes, fsync it, rename over the record and fsync
the containing directory. A killed process leaves either the old complete
record or the new complete record. Unpublished temporary files are not journal
records. No independently published index can lose the idempotency mapping.

Exact key/payload replay returns the existing operation without another write;
a semantically different payload or retry linkage is rejected. JSON object key
ordering is canonical, while array order remains meaningful. No automatic
expiry is implemented in v1: retaining keys avoids surprise re-execution.
Operators may archive the entire inactive local journal under a separate future
retention policy. This explicitly chooses indefinite local retention over a
silent bounded expiry before such a policy exists.

Fault tests kill a subprocess at every temp-written, temp-synced, published and
directory-synced boundary for both creation and a state transition. Reopening
must produce exactly one valid operation and reach a terminal state. The CLI's
`journal-probe ROOT seed|run` command and `ALLOY_CATALOG_FAULT=STAGE.POINT`
exist solely to reproduce these synthetic process-death controls.

## Worker and installation semantics

`InstallationEngine` takes separate catalog metadata and Alloy content roots.
Plans are saved before returning their content-addressed ID. StartInstall and
StartUninstall enqueue a durable operation; `run(operationID)` drives it. This
split permits a caller to retain the operation ID before work begins. An exact
Start replay only reads the frozen plan and journal, including after success.

A separate worker lock serializes side effects across processes. Pause/cancel
acquire only the journal lock and take effect at cooperative layer boundaries;
an already-running fetch may finish publishing verified CAS bytes. Controls
never publish or activate a partial generation. Resume validates/refetches all
layers, so GC of an unrooted paused download is safe. Publication disables
controls atomically in the journal before entering content-store. Restart keeps
those controls disabled and reconciles the same content-store operation ID.
An error after publication starts leaves RUNNING for explicit recovery rather
than guessing whether a side effect committed. Terminal success follows exact
reference validation.

Content-store supplies three narrow missing primitives: stable activation IDs,
journaled retirement of exactly planned runtime references, and journaled
repair of CAS objects plus their materialized hard links. Repair opens damaged
catalog state explicitly, downloads replacements into a separate healthy
staging store, verifies bytes, applies them through content-store, then validates
the active reference. A healthy installation yields a successful no-repair
result. Repairs refuse changed manifests rather than inventing new identities.
No operation edits the installed Steam title. Uninstall leaves saves and live
leases intact; it retires active/rollback/candidate references and leaves GC to
reclaim subsequently unrooted content.

## Storage operation results

GetStorageInventory and CollectGarbage enqueue the same durable operation
records as installation. Inventory returns the production `CatalogInventory`
fields without relabeling logical object bytes as physical volume usage.
GC uses the content store's active/rollback/candidate references and live leases.
A seeded six-generation test counts CAS paths and byte lengths independently,
then proves the exact removed digest set and unchanged retained bytes. A clean
second sweep is a zero-removal negative control; releasing a lease makes its
otherwise-unrooted generation collectable.

GC saves the initial `CatalogDump` in the RUNNING operation's `result` field
before invoking collection. On success this becomes `GarbageCollectionReport`:
`before`, `after`, sorted `removedObjectDigests`, `removedObjectBytes`, sorted
`removedGenerations`, and `lastPass` (the raw final ContentStore invocation's
counters). A restart preserves the original before/after comparison even if the
first sweep completed before its operation result was recorded. Fault tests
interrupt both a completed sweep and the middle of the object sweep.

The removed sets are differences between the original and final snapshots,
not an attribution log for external writers that may act between a crash and
recovery. The engine serializes its own operations; content-store locks still
protect each individual underlying mutation. `removedObjectBytes` counts only
unique CAS bytes. Neither that field nor inventory includes save volumes,
metadata, downloads, quarantine or filesystem allocation overhead.
