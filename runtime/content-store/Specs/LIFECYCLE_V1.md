<!-- Author: Timur Isaev -->

# Content-store lifecycle hooks 1.0

These hooks support a caller-owned installation operation engine. They do not
replace that engine's user-visible state machine or idempotency-key store.
All filesystem mutations run under the existing content-store writer lock.
The activation journal remains schema 1.0 without a field or encoding change.

## Stable activation identity

`activate` accepts an optional `operationID: String? = nil` before
`healthOutcome`. Omission preserves generated activation IDs. A supplied ID
selects the existing activation journal when present. Reuse requires identical
game ID, generation ID, ordered descriptors, and health outcome; otherwise it
throws `ContentLifecycleError.conflictingOperation`.

An incomplete matching activation resumes. A completed matching activation
returns its original result without executing stages again or changing active
and rollback references. That result is historical: a later installation or GC
may have superseded it. A failed health check returns the recorded previous
active reference, matching the original activation behavior. An aborted journal
stays terminal and throws `abortedOperation`; retry requires a new operation ID.
A new caller-specified activation ID refuses another pending activation for the
same game. Legacy calls that omit an ID retain their existing staging behavior;
operation engines must serialize game mutations and always supply their IDs.

## Reference snapshots and uninstall

`referenceSnapshot(gameID:)` returns `GenerationReferences`, a Codable value
with `active`, `rollback`, and `candidate` nullable `GenerationReference` fields.
Each reference has the existing `generationId` and `manifestDigest` fields.
The snapshot is read and validated under the store lock. Repair selection may
pass `validateContents: false` to inspect reference metadata whose target bytes
are damaged. Reference decoding, identifiers, and digest syntax still validate;
only target generation/content validation is skipped. The default remains `true`.

`uninstall(gameID:expectedReferences:operationID:faultInjector:)` requires an
exact current snapshot before recording intent. It retires only Alloy runtime
references. It preserves generation directories, CAS objects, live leases,
and all save volumes. Collection is a separate operation. A stale snapshot
throws `staleReferences` before making an intent record.

Replay tolerates already-absent references but refuses a different current
reference. Completed replay returns the original snapshot and cannot uninstall
a later installation. Reusing its ID with a different request is an error.

## Repair from authorized bytes

`ContentStore(root:allowDamagedCatalog:)` defaults to normal catalog validation.
Passing `true` explicitly permits opening damaged state for `repairObjects`;
it skips only initial catalog validation. It is not a relaxed integrity policy
for normal install, transport, inspection, or collection methods.

`repairObjects(_:operationID:faultInjector:)` accepts verified `LayerInput`
values. The caller obtains replacement bytes through an independently healthy
staging content store's `fetchObject` path. No network behavior or artifact
authorization is added to this hook. The store verifies every input's size and
SHA-256 before accepting it.

Repair checks all generation manifests and rejects unrelated damaged layers,
changed referenced manifest identities, symlinks, and unsafe directory entries.
It stages replacement bytes durably in `metadata/repair-payloads/<operationId>/`
before recording intent. A corrupt CAS object is atomically replaced through a
staged hard link; all affected materialized generation links are then replaced
atomically. This is necessary because replacing a CAS pathname alone leaves
existing generation hard links attached to the old corrupt inode. Directory
permissions are resealed on recovery. File modes are never changed on a corrupt
generation hard link to repair its contents in place.

Every affected generation and the final catalog validate before repair reaches
`applied`. Staged payloads are removed before the terminal `complete` record.
A repeated completed request returns its original Codable `RepairResult` with
`objectCount` (unique input digests) and `generationCount` (affected generations).
References, generation manifest identities, leases, and saves remain unchanged.
Manifest reconstruction and missing unrelated objects are outside this hook.

## Maintenance journal fields

Maintenance records live at `metadata/lifecycle/<operationId>.json`. They use
sorted-key JSON, same-directory temporary writes, file fsync, atomic rename,
and directory fsync, matching the existing store journal durability model.

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | string | Exactly `1.0`. |
| `operationID` | string | Validated local operation identifier, matching filename. |
| `kind` | string | `uninstall` or `repair`. |
| `gameID` | string or absent | Required only for uninstall. |
| `references` | object or absent | Original reference snapshot, uninstall only. |
| `layers` | array | Ordered validated layer descriptors, repair only. |
| `generations` | array | Affected `{gameID, reference}` records, repair only. |
| `state` | string | `prepared`, `applied`, or `complete`. |

Uninstall follows `prepared → complete`. Each reference removal is replayable.
Repair follows `prepared → applied → complete`. `prepared` can replay CAS and
generation-link replacement from staged bytes; `applied` only cleans staging
and completes the record. Terminal journals are immutable. Unknown versions,
invalid identifiers, malformed records, and conflicting requests fail closed.

Construction recovers these maintenance journals before validating the normal
catalog. Activation and `recoverAll` also recover them before proceeding;
collection already calls `recoverAll` under the same lock. The repair staging
area is outside ordinary abandoned-download and quarantine collection roots.

## Evidence

`LifecycleExtensionTests` covers exact activation replay, all existing
activation action/journal boundaries, stale uninstall plans, later-install
replay, leased-generation retention, shared-inode corruption, manifest changes,
and a symlink sentinel. `LifecycleProcessTests` launches the existing fault
probe in a fresh process and requires abrupt exit 97 at each of 18 activation,
9 repair, and 4 uninstall boundaries before reopening and validating recovery.
The repair process exits include the intervals before CAS and materialized-link
renames and while a generation directory is temporarily writable.

Run both new and existing regressions with:

```sh
swift test --package-path runtime/content-store
```
