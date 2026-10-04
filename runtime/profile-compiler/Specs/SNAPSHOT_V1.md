# Wine snapshot v1 projection

Author: Timur Isaev

The compiler uses a local SPM dependency on the existing first-party
`spikes/WINE-001/policy-probe` library, without editing that spike. There are
no external package dependencies. `PolicySnapshotExporter` lowers resolved
policies into the existing `ALLOYP01` layout through its public compiler API.

The caller supplies the exact executable digest, policy ID, and local Windows
provider-directory binding. The directory is an explicit local input, not a
URL or an inferred installation path. The existing encoder enforces version,
ASCII lengths, route counts, duplicate executable hashes, DLL names, and path
syntax. This adapter also rejects parent traversal in provider paths.

## Coverage

| Resolved field | Wine v1 representation |
| --- | --- |
| Executable digest | Sorted exact-image entry |
| Policy ID | Bounded entry identifier |
| Graphics provider | Provider label and separately supplied directory |
| DLL overrides | Up to eight load-order routes |
| CPU, synchronization, network, diagnostics | Explicit `notYetLowered` entries |
| Feature mask, environment, working directory, services | Explicit gaps when present |
| Path, parent, command line, module, product matching | Resolved before projection; v1 only retains the executable digest |

Two different contexts for the same executable cannot become separate v1
entries: duplicate executable digests are rejected. This format cannot enforce
the complete process policy. `runtimeReady` is false whenever a coverage gap
exists; current resolved policies always include at least CPU, synchronization,
network, and diagnostics gaps. Consumers must preserve this report and must not
treat a successful projection as permission to launch in Certified Mode.

V1 requires a nonempty DLL table. An empty resolved table is represented by one
disabled `__alloy_empty_route__` marker, with an additional `dllOverrides.empty`
coverage gap. This keeps diagnostic export possible without silently claiming
an exact runtime lowering. It does not install a provider or execute any guest.

## External oracle

The preserved July 24 WINE-001 evidence records a 2968-byte snapshot with SHA-256
`39adf17b81e5b35dd7120d66ebe17bae58007ed506fbb51e866e9e209ac700f5` and source digest
`0ed8c8a6225e2c269ebe16d902bc1b590448cfe05efb8946994dcd69a9536348`.
The original `policy-source.json` and `policy-repeat.snapshot` were still
present in the primary checkout's ignored proof artifacts. The source and
base64-encoded snapshot are frozen under `Tests/Fixtures/WineOracle/`.
They retain the original historical `macgaming` directory names, which are
data in this oracle, not paths used for execution.

The unchanged CLI was rebuilt into separate scratch and compiled the preserved
source. Its bytes and SHA-256 match the recorded snapshot. The new test turns
the hand-built process inputs into schema-valid profiles, resolves their rules,
exports them, and compares every output byte with the preserved artifact across
ten runs and reversed process ordering. The oracle's synthetic `restricted`
default marker is supplied explicitly; it is not a new graphics provider in
the approved profile schema.

Reproduce the external comparison without running Wine:

```sh
swift run --package-path spikes/WINE-001/policy-probe \
  --scratch-path /tmp/alloy-policy-oracle-build alloy-policy-compile compile \
  runtime/profile-compiler/Tests/Fixtures/WineOracle/source.json /tmp/oracle.snapshot
shasum -a 256 /tmp/oracle.snapshot
swift test --package-path runtime/profile-compiler --filter PolicySnapshotExportTests
```

The golden is anchored to
[WINE-001 result 08](../../../spikes/WINE-001/results/2026-07-24-08-policy-hook-and-rebase-readiness.md),
not to a digest first calculated by this adapter. Changing the projected
graphics label deliberately breaks the golden; removing a coverage flag
deliberately breaks the field-coverage test. Restored code must pass both.
