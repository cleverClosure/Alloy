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
