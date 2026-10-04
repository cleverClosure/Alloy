<!-- Author: Timur Isaev -->

# AlloyStoreCatalog

Local Swift library and CLI over AlloyStoreIdentity and AlloyContentStore.
Only explicit library roots are scanned. Storefront files are read-only;
malformed manifests and unsafe install paths are omitted. Catalog snapshots
are immutable, content-versioned, grouped by Steam app ID and sorted by ID.
Pagination tokens are opaque and bound to that snapshot. Fingerprint refresh
uses the existing scanner and refuses a manifest changed during the scan.

```sh
swift test --package-path runtime/store-catalog
swift run --package-path runtime/store-catalog alloy-store-catalog list LIBRARY
swift run --package-path runtime/store-catalog alloy-store-catalog discover LIBRARY
swift run --package-path runtime/store-catalog alloy-store-catalog get LIBRARY steam-910001
swift run --package-path runtime/store-catalog alloy-store-catalog fingerprint LIBRARY INSTALL_ID
```

The added MultiGameLibrary fixture contains two synthetic titles, Atlas
(app 910001/build 21) and Boreal (app 910002/build 42). Tests also check the
existing synthetic library's pinned fingerprint and malformed manifests.
No external Swift package, account, network service, or real game is needed.
The [local API contract](Specs/LOCAL_API_V1.md) defines the catalog, plans and
operation records. `InstallationEngine` enqueues install/uninstall/repair
operations and runs them through a separate durable journal. Pause/cancel are
cooperative before publication; retries reconcile the same content-store ID.
An isolated staging store supplies verified repair bytes for corrupted CAS and
materialized generation hard links. Shared runtime builds and storefront game
payloads are never mutated by this package.

## Operation CLI

Each engine command takes `STATE_ROOT CONTENT_ROOT` before its arguments.
The content root is an Alloy-owned runtime store. It must never be a storefront
installation. Plans consume a JSON array of existing `LayerDescriptor` records;
download mirrors use content-store's existing digest-addressed HTTP protocol.

| Command | Arguments after roots | Result |
| --- | --- | --- |
| `plan-install` | GAME INSTALL GENERATION LAYERS_JSON URL… | frozen InstallPlan |
| `start-install` | PLAN_ID KEY | queued/replayed Operation |
| `plan-uninstall` | GAME INSTALL | frozen UninstallPlan |
| `start-uninstall` | PLAN_ID KEY | queued/replayed Operation |
| `repair` | INSTALL KEY | queued/replayed Operation |
| `inventory`, `gc` | KEY | queued/replayed Operation |
| `run`, `pause`, `resume`, `cancel`, `operation` | OPERATION_ID | Operation |
| `operations` | none | Operation array |
| `discover-operation` | KEY LIBRARY… | queued/replayed discovery |
| `fingerprint-operation` | KEY INSTALL_ID LIBRARY… | queued/replayed refresh |

`run` drives a queued or interrupted operation. A paused operation requires
`resume`; terminal replay is immutable. `run`/`resume` exit nonzero for FAILED.
Read-only library commands remain `list`, `get`, `discover` and `fingerprint`.
The operation result is canonical JSON encoded as Codable's base64 `Data` field.
Repair staging has its own CAS under STATE_ROOT and is outside CONTENT_ROOT's
logical inventory accounting; it may be reused by later repairs.

## Complete local proof

```sh
swift test --package-path runtime/store-catalog
python3 runtime/store-catalog/run-fault-matrix.py --json /tmp/catalog-proof.json
```

The matrix uses a private loopback HTTP server, temporary stores and the
committed synthetic library. It drives every CLI API, the complete
install→pause→resume→repair→uninstall→GC lifecycle, exact idempotency replay,
conflicting keys, and independent byte/hash-set oracles. It kills and reopens
processes at every named journal write boundary for all seven operation kinds,
control transitions and failed digest verification, plus post-action and partial
GC boundaries. Each row is named PASS/FAIL and a final SUMMARY counts all rows.

`--skip-build` uses the already-built CLI. `--negative-control` deliberately
uses the wrong repaired-byte oracle: it must exit 1 and report one failed row.
The ordinary run must report `pass=163 fail=0 total=163`. These are local crash
recovery proofs, not a simulated power-loss or physical disk durability claim.

Fault controls are disabled by default. `ALLOY_CATALOG_FAULT=STAGE.POINT` kills
only the synthetic CLI process at an instrumented point. The matrix's
`ALLOY_CATALOG_CONTROL=pause|cancel` and `ALLOY_CATALOG_CONTROL_OPERATION=ID`
exercise a real control call after the first layer fetch. They are test hooks,
not a user-facing background service.

Both proof commands are registered as fast suites in `tools/test-all` and run
in the existing on-PR CI job. The [hosted gate evidence](Results/2026-10-04-ci-proof.md)
records the deliberate assertion failure, repaired green run, and job budget.
