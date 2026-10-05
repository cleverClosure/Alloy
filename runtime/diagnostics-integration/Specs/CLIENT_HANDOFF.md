<!-- Author: Timur Isaev -->

# Diagnostic client handoff

This package completes the **local integration slice** of #163. It does not
implement every EPIC-009 production requirement. The runtime service remains
unchanged; the app can consume this library or executable later.

## Swift consumer

Depend on the `AlloyDiagnosticsIntegration` product in this local Swift package.
Run synchronous calls off the UI thread. Hold an explicit private store URL and
an explicit export destination selected by the caller:

```swift
let connection = try DiagnosticConnection(endpoint: endpointPath)
let observer = try CaptureSession(connection: connection, budgetSeconds: 30)
let capture = try observer.capture(kind: "session", identifier: sessionID, sampleHang: true)
let store = try BundleLifecycle(root: storeURL)
let configuration = connection.client.configuration
try store.requireSeparate(from: [configuration.stateRoot, configuration.contentRoot, endpointPath]
    + (configuration.libraryRoots ?? []))
let summary = try store.create(capture)
let bundle = try store.inspect(summary.bundleID)
let privacyPreview = bundle.preview
try store.export(summary.bundleID, to: explicitDestination)
try store.delete(summary.bundleID)
```

Initialize a new store once with `BundleLifecycle.initialize`; it never adopts
or overwrites an existing directory. The CLI additionally checks library and
endpoint separation. A GUI consumer must likewise include all configured
library roots and its endpoint in `requireSeparate` before capture/export.
The result retains the current test-local lifecycle, not a product retention
policy. There is no upload API, external message or consent default to expose.

## Outcomes and incomplete evidence

| Outcome | Required observation |
| --- | --- |
| `clean` | SUCCEEDED, STOPPED or CANCELLED; this says no captured failure, not successful game execution |
| `operation-failed` | Actual FAILED operation with a complete, indexed audit history |
| `native-fixture-signal-abort` | Native fixture FAILED, recorded exit 6, native-exit artifact |
| `native-fixture-watchdog-hang` | Owned stack sampled at `FixtureMain.run:poll`, FAILED exit 43, sample artifact |
| `native-fixture-failed` | Other native fixture failure; no more specific diagnosis claimed |
| `service-interruption` | Instance changed, transport interrupted after an observation, or durable INTERRUPTED snapshot |
| `budget-exceeded` | Observation budget expired; service work is not cancelled |
| `native-capture-incomplete` | Owned native sampling could not collect the required evidence |

The last three outcomes always have `complete: false`. No observation at all
cannot become a bundle: the client returns an error. Complete session capture
still has snapshot-only history; do not show it as a full event stream. A
normal native fixture is the hang/crash control, never a Wine guest or provider
certification result. Exit 6 alone is not a general-purpose crash classifier.

## Verification and privacy

Use `summary`/`preview` after reopening; both revalidate the seal, identities,
indexed operation audit and outcome-specific artifacts. A recomputed manifest
hash does not hide a changed identity or an omitted hang artifact. Hashes do
not authenticate against someone deliberately rewriting every expected fact.

Exact canonical runtime UUID/hash identities have narrowly typed scanner rules
so long digit runs remain identities. Free text has no such exception. Elapsed
seconds are rounded to six decimals; the final proof caught that unrestricted
float text could resemble a card number. Known secrets are removed before
export; unknown secret grammars and semantic re-identification remain outside
the proof. No raw launch exports, capabilities, library paths, save data, native
module inventory or stack text are copied into bundles.

Every event timestamp is the **observation time**. The service's audit entries
have no event timestamps; the adapter does not invent historical occurrence times.
Original mutation RPC IDs and native provider/process-policy evidence are
explicitly unavailable. The diagnostic read's verified request ID is retained.

## Reproduce

```sh
python3 tools/test-all --only diagnostics-integration-swift --only diagnostics-integration-proof
python3 runtime/diagnostics-integration/run-integration-proof.py --negative-control
swift test --package-path spikes/DIAG-001/prototype
```

The independent expected-outcome fixture pins all six bundle outcomes and the
known session identities. Operation/session IDs are independently derived from
the service's documented key scheme; host identity is independently calculated
from actual host capabilities. The test creates a real failed operation before
planting 20 documented synthetic secret values in its isolated error record.
All subsequent capture reads use the unchanged XPC service and the adapter.
It then stops the service and inspects/exports/deletes offline. Corrupted
identities, removed events (with and without corrected counts), removed capture
artifacts, planted secrets in a resealed payload and oversized files must fail.

Full native rows require the unchanged compiler's real arm64/8GiB prerequisite.
A smaller host reports explicit skips; it still proves actual operation failure,
identity, privacy and offline bundle lifecycle. No inflated host capabilities
or manually assembled event fixtures can substitute for the registered proof.
