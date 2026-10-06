# Session-launch handoff

Author: Timur Isaev

## Library contract

The session-launch consumer can depend on the `AlloyTitleVolumes` product from
`runtime/title-volumes`. The production library imports Apple SDKs only; the
fault-probe executable alone links the existing content-store library to test
runtime lifecycle isolation. No content-store, compiler, service or app source
was modified by this epic.

1. Open `TitleVolumeStore(root:)` at the canonical host-owned content-store root.
   The parent must exist; do not pass `/tmp`/`/var` aliases or a guest-selected
   root. Opening performs recovery under the volume registry lock and fails
   closed on corrupt authoritative state.
2. `createTitle` supplies category quotas and opt-in periodic snapshot policy.
   Its save/settings identities survive every runtime update and rollback.
   For an older content-store save-only title, explicitly call `adoptLegacySaves`
   first while all legacy writers are stopped. It tightens owned 0755/0644 state
   to 0700/0600 without changing bytes; links, ACLs, extra sibling categories,
   foreign ownership and externally writable entries are refused. An interrupted
   permission-only adoption can be repeated. It never deletes an existing save.
3. Authenticate profile save-path declarations before calling `declareSavePaths`.
   The current profile schema has no corresponding field; adopt the typed
   sidecar explicitly rather than silently adding an unsigned schema extension.
4. Construct `CacheIdentity` from the selected runtime's content identity, the
   complete selected provider identities and all compatibility inputs (profile,
   compiler, GPU/host/OS epochs as appropriate). `activateCache` invalidates old
   cache namespaces at a quiet boundary.
5. Create scratch with a unique session ID and expiry. Use `drivePlan` with the
   expected cache identity and host-resolved runtime/payload IDs. The method
   refuses an expired session, mismatched cache identity, aliased IDs, or missing
   volumes. These IDs are locators, not unforgeable security capabilities.
6. Hold `withSessionLease` for the lifetime of guest access. Resolve and validate
   the launch plan inside the lease before handing out broker handles. Leases
   block save snapshots, restore, settings replacement and cache invalidation;
   expiry cannot delete scratch belonging to a live lease.
7. Before an opt-in periodic snapshot, pause/drain guest writers and release the
   lease, call `snapshotIfDue`, then reacquire the lease and resume. Do not call
   snapshot from inside a held lease. The caller must prevent an expiry timer
   from removing its own session during this intentional quiet interval.
8. After process death or a clean close, release the lease. Retain any explicitly
   selected diagnostic subset before `expireScratch`; it removes expired,
   unleased sessions. Save/settings data and backups are never included.

The store lock and title writer leases are advisory OS locks. A filesystem broker
must prevent guest access to metadata, archives and parent directories, enforce
write quotas, and keep all guest writers within this cooperation contract. Raw
host paths are never a substitute for authorization. The package neither mounts
volumes nor implements Windows filesystem sharing/reparse semantics.

## C/G/S/T mapping plan

`DriveMappingPlan.volumeIDs` has exactly the compiler's six required keys:
`runtime`, `game`, `saves`, `settings`, `cache`, `temp`.

| Drive | View | Access |
| --- | --- | --- |
| C | externally resolved runtime generation | read-only |
| G | externally resolved storefront payload | read-only or updater-scoped |
| S | synthetic view with separate `saves` and `settings` bindings | scoped read-write |
| T | this session's scratch volume | scoped read-write |

There is no Z drive, host-root mapping, or archive binding. The cache ID is a
separate broker capability used by providers; it does not add a broad host drive.
Save redirections map declared C/G/S guest locations into the save binding. The
broker must validate the external runtime/payload handles against the selected
launch identity and title; this storage package cannot authenticate a caller's
opaque external handle. Runtime access follows doc 05's stricter read-only rule
instead of the writable-overlay shorthand in doc 04 Appendix A.

Constructing a plan does not grant OS access. The later service/broker builds the
S view, issues constrained handles, translates Windows path semantics and enforces
updater-specific G access. The current library can resolve its registered rows
through `records(gameID:)` for that host-owned integration, without changing its
source. Cache identity is checked against the launch caller's explicit expected
identity before the plan is returned.

## Save and settings user actions

`inventory` returns a full-tree fingerprint. Show the scope/version to the user
and pass that exact fingerprint to `restore` or `updateSettings`. A stale save
restore creates a local conflict archive and returns both IDs, retaining both
sides. A stale settings update refuses the overwrite. Successful replacements
retain the old tree. Empty settings input is an explicit reset, with backup.

The CLI's `audit` and `settings-status` output include the expected fingerprint,
so scripted users do not have to reproduce its encoding. Archives are local,
private, checksummed trees; they are not off-device disaster recovery or cloud
backup. Archive deletion is an explicit caller action. There is no save deletion
API, runtime rollback restore hook, automatic archive retention purge, upload,
XPC surface, storefront cloud-save connection or UI.

## Evidence and limits

`run-fault-matrix.py` independently hashes actual save paths, SIGKILLs only owned
probe processes at every published boundary, opens a fresh process for recovery,
and requires the entire pre/post tree. Its deliberately absent kill point must
be rejected by the monitor. Torn replacement, quota overrun, cross-title escape,
and a deliberately corrupting lifecycle control must all be detected.

The content-store proof executes real library activation, failed-health rollback,
nonempty GC, uninstall and restart recovery against populated shared roots. It
asserts that references change and objects are collected so a no-op cannot count
as preservation evidence. No guest or shared Wine/FEX runtime is used.

The proof covers process death and cooperative file mutation. It does not claim
hardware power-cut testing, cloud conflict detection without supplied input,
protection against the host account/admin rewriting all metadata, or the ability
to recognize arbitrary application-level corruption produced by a game. Doc 09's
residual risk from defective/malicious game writes remains. The monitored-first-
run interface accepts candidates, but guest monitoring is future integration.
