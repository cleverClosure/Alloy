# Save snapshots, backups and restore v1

Author: Timur Isaev

## Quiet capture and publication

`snapshot` and `createBackup` hash the complete save tree, clone each regular
file with Apple's descriptor-based `fclonefileat`, compare the clone and source
against that inventory, and publish the complete archive by an exclusive atomic
directory rename. Files and directories are fsynced before publication. The
archive includes its inventory, source title, kind, time, reason and clone/copy
counts. Readers never list an incomplete archive.

On a filesystem reporting `ENOTSUP` or a cross-device clone limitation, verified
streaming copies are allowed and explicitly counted. Other errors, including
disk exhaustion, fail closed. The native APFS positive control requires two
actual clones and zero copies. Snapshots are ordinary private immutable-by-API
directories, not privileged whole-volume APFS snapshots.

`withSessionLease` holds both a scratch lease and the title writer lease. Capture
and replacement refuse with `busy` while that lease is held. A consumer must
pause/drain guest writes, release the writer lease at a safe point, capture, then
resume the lease before allowing further writes. It must not call capture from
inside an active session lease. Cooperative library writes serialize on the
registry lock. Direct writes bypassing the broker/lease contract are unsupported;
source/clone rechecking detects ordinary concurrent changes but cannot replace
whole-tree quiescence.

Periodic capture is opt-in through `BackupPolicy.periodicIntervalSeconds` and
`snapshotIfDue`. The caller schedules it at a quiet boundary with explicit time.
There is no timer, cloud service, automatic save restoration, or automatic archive
retention deletion. Backup policy defaults to disabled. Deletion is explicit and
first atomically retires the archive from the visible namespace.

## Explicit replacement and conflicts

Restore requires an archive ID, title, and the current fingerprint previously
shown to the caller. A mismatch creates a separate local conflict archive and
returns both IDs. The incoming archive remains intact, live saves are unchanged,
and there is no automatic merge.

A matching request first publishes a complete `beforeRestore` archive. It clones
the requested tree into a transaction directory and records a checksummed journal
with exact pre/post inventories. `renameatx_np(RENAME_SWAP)` replaces the entire
save directory in one operation. The displaced directory remains in staging
until the public path is synced and completion recorded. The previous archive
survives cleanup and can only be deleted explicitly.

Recovery runs under the registry lock before every API transaction. Before a
published journal there can be no swap, so incomplete staging is discarded.
After a journal, recovery verifies the preserved archive and requires live saves
to match the whole pre-operation or whole post-operation tree. It retains the
tree already present; it never invokes restore itself. A third state is a named
integrity failure, with evidence preserved. Process-death consistency is tested;
hardware faults, external admin corruption and writes outside the lease contract
are not converted into a claim of automatic data repair.

## Save-path declarations and discovery

`SavePathDeclaration` is a typed sidecar accepted from an authenticated profile
consumer. It binds profile ID/revision to non-overlapping C/G/S guest paths and
title-save-relative destinations. Neither side can grant an arbitrary host path.
The future broker installs the redirections; this package does not run a guest.

The current profile JSON schema has no save-path field. This package does not
silently extend it or modify the compiler. The future profile/schema owner must
adopt the sidecar contract explicitly. `discoverSaves` accepts candidate relative
paths from a later monitored-first-run component and reports exact existing
inventories only inside the title save volume. Snapshot captures the whole volume
so an incomplete declaration cannot silently omit an existing save.

## CLI

```text
snapshot ROOT GAME NOW
snapshot-if-due ROOT GAME NOW
backup-create ROOT GAME NOW REASON
backup-list ROOT GAME
backup-restore ROOT GAME ARCHIVE_ID EXPECTED_FINGERPRINT NOW
backup-delete ROOT GAME ARCHIVE_ID
```

The API remains authoritative for profile declarations, discovery and custom
policies. No CLI command restores during content-store activation or rollback.
