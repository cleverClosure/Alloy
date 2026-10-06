# Settings, cache identity and scratch v1

Author: Timur Isaev

## Versioned settings

`updateSettings` accepts the complete replacement file map, an expected current
fingerprint and explicit time. An empty map is an explicit reset. Before every
replacement, the current settings tree is retained as a settings archive. The
same atomic tree-swap protocol as save restore commits the replacement.

Each update has a monotonically increasing revision, a full tree fingerprint,
time and the previous archive ID. Immutable checked history rows and the current
version are published from the replacement journal. Recovery finishes version
publication only when the new tree is present. A mismatched expected fingerprint
refuses the update without overwriting user changes.

Raw files remain user-owned. `settingsStatus` reports externally changed content
against the recorded version instead of guessing a migration. Consumers can
present that drift and make an explicit replacement/reset request. General
`write` refuses settings: managed settings mutations use `updateSettings`.
There are no automatic compatibility transformations or runtime-triggered resets.
Persistent volume IDs remain stable; settings revision history is separate from
runtime generation identity and from the volume registry.

## Disposable cache epochs

An epoch is SHA-256 over sorted JSON containing the runtime identity, every
provider identity, and named compatibility inputs. Callers must supply complete
content identities and relevant host/profile/compiler epochs; a friendly provider
name alone is insufficient. Identical identity reuses the cache; any changed
input selects a different namespace.

`activateCache` requires a quiet title boundary. A durable disposal journal
records the new selection and the old cache records. Recovery creates/registers
the new namespace, switches the active selection, retires old directories, and
removes only their registry entries. Save/settings volumes cannot appear in a
disposal journal. Old cache data is always regenerable and may be deleted.

The low-level `createCache` API remains available for explicit independent cache
namespaces. Session consumers use `activateCache` and `activeCache`, which apply
identity invalidation. Quotas apply independently to each registered namespace.

## Scratch lifecycle

Scratch expiry selects only elapsed session records for which it can acquire an
exclusive, nonblocking lease. It journals that exact set, atomically moves their
directories into a private disposal area, removes their registry rows and deletes
the retired data. Recovery rolls this intent forward. No new lease can attach
until recovery completes under the registry lock. Process death releases leases;
the next expiry call can clean abandoned sessions. A live session is never
expired solely because its nominal TTL elapsed.

Failed-session diagnostic selection/redaction is a caller operation. The caller
must copy its explicitly retained subset before ending a lease/allowing expiry.
No diagnostics, saves, settings, payload or runtime objects are reached by a
scratch/cache deletion.

## CLI additions

```text
settings-status ROOT GAME
settings-update ROOT GAME EXPECTED_FINGERPRINT NOW JSON_FILE
settings-reset ROOT GAME EXPECTED_FINGERPRINT NOW
cache-status ROOT GAME
cache-activate ROOT GAME IDENTITY_JSON
```

Settings JSON is a dictionary of relative paths to base64 file bytes. Cache JSON
contains `runtimeIdentity`, `providers` and `compatibilityInputs`. The library
enforces the same path and quota checks for CLI and direct API callers.
