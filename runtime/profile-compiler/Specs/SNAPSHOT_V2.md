<!-- Author: Timur Isaev -->

# Wine snapshot v2 lowering

Compiler 0.7.0 emits `ALLOYP02` through the first-party `PolicySnapshotV2` API.
The complete [wire contract](../../../spikes/WINE-001/policy-probe/SNAPSHOT_V2.md)
is versioned with the Wine validator and proof. Source schema version is 2;
exported `digest` remains `sha256:` followed by the complete file digest.
The inherited `ALLOY_POLICY_SNAPSHOT_SHA256` value is that digest **without**
the `sha256:` prefix. The launcher must also preserve the read-only descriptor
and `ALLOY_POLICY_REQUIRED=1` across the process tree.

## Coverage and readiness

| Resolved value | V2 behavior |
| --- | --- |
| CPU `fex-arm64ec` | Selects fixed builtin FEX for x64/hybrid images |
| CPU `native-arm64ec` | Native-only admission; refuses x64/hybrid images |
| Graphics label and supplied directory | Binds the provider search path before imports |
| DLL overrides | Zero through 32 canonical routes; no invented empty-table marker |
| Environment | Up to 16 bounded variables, applied to the Windows environment before imports |
| Working directory | Absolute bounded Windows path, set before imports |
| Synchronization `conservative` | Stock Darwin Wine server synchronization; no extra provider requested |
| Network `allow` | No additional network restriction requested |
| Diagnostics `off` | No optional Alloy diagnostics service requested |
| Other CPU/sync/network/debug values | Explicit coverage gap |
| Feature masks and services | Explicit gap whenever present |

The three neutral service values above are no-op lowerings against the pinned
Darwin development runtime. They do not install a synchronization implementation,
grant access beyond host permissions, suppress externally enabled Wine diagnostic
channels, or promise an isolation boundary. Restrictive network values, crash-only
collection, capture and non-conservative synchronization are never converted to
those neutral values. The resolved policy remains in the launch specification.

`PolicySnapshotExport.runtimeReady` is true exactly when every policy supplied to
that export, **including its explicit default**, has no coverage gap. A schema-valid
profile using only supported fields plus the neutral service modes is covered by
a positive test. Changing any one supported mode to an unsupported requirement
makes readiness false and names the required field. Unsupported CPU values are
omitted from the binary projection but remain an explicit blocking gap; a caller
must never execute an export with gaps merely because encoding succeeded.

This is process-policy readiness, not certification or a complete session-launch
permission. `LaunchCompiler` still includes profile-level filesystem, registry,
dependency and service requirements in its own coverage report and always emits
`productionEligible: false`. Its conservative unknown-process default still
requests `networkPolicy=deny` and `debugPolicy=crash-only`; these genuine unresolved
requirements remain visible. Existing complete-launch fixtures therefore remain
not ready. Nothing in this milestone silently relaxes unknown-child containment
or claims enforcement belonging to the session/volume/service epics.

## Bounds and identity

There are at most 1023 exact-image entries plus the required default. Identity
remains the executable SHA-256; contexts for the same executable cannot carry
different entries. Duplicate hashes reject rather than dropping one policy.
Directory bindings remain explicit local inputs, never downloaded or inferred.
Protected loader/transport environment variables, path traversal, unsupported
text encodings and over-limit fields reject rather than truncate.

The v1 oracle and its original source/base64 fixture remain frozen. Tests compile
that source through the explicit historical v1 API and compare all bytes, then
exercise deterministic v2 export separately. Complete-launch golden digests change
because compiler version, snapshot bytes and the field-coverage report change;
profile inputs, signed evidence checks and the production eligibility gate do not.

## Development proof handoff

`swift build --package-path runtime/profile-compiler --product alloy-snapshot-export`
builds a development command for **already resolved, trusted local** policy inputs.
It accepts `RESOLVED-DEVELOPMENT.json NEW_DIRECTORY`. The root object has
`schemaVersion: "alloy-resolved-policy-v2-development"`, `defaultPolicy`, and
`processes`. Each policy contains `id`, `providerDirectory`, and the Codable
`ResolvedProcessPolicy` object; each process contains `imageSHA256` and `policy`.
Optional fields must be omitted when absent. Duplicate keys, unknown fields,
explicit nulls and inputs beyond 4 MiB reject.

The new private output directory contains a read-only `policy.snapshot`, its
`source.json`, and `report.json` with complete-file digest, readiness and gaps.
Existing output directories reject. The command invokes the same
`PolicySnapshotExporter` library used by `LaunchCompiler`; it does not resolve
profile matches, verify signed evidence, authorize a session or launch Wine.
It may write a diagnostic projection with gaps, but a caller must honor the
report and cannot treat successful serialization as permission to execute.
The synthetic Wine tree proof uses a supported-only explicit development default
and asserts a ready report while retaining `productionEligible: false`.

After building, run `python3 runtime/profile-compiler/check-export.py
runtime/profile-compiler/.build/debug/alloy-snapshot-export` for positive and
rejection controls at this command boundary.
