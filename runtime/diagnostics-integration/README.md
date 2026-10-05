<!-- Author: Timur Isaev -->

# Local runtime diagnostics

A non-GUI Swift client joining the existing runtime XPC API to `AlloyDiagnostics`.
It only observes the current-user development service; no upload, game launch,
provider execution, production consent or retention policy is supplied.

```sh
swift test --package-path runtime/diagnostics-integration
python3 runtime/diagnostics-integration/run-adapter-proof.py
swift run --package-path runtime/diagnostics-integration alloy-diagnostics \
  observe /absolute/private/endpoint.json operation op-identifier
```

`observe ENDPOINT operation|session ID` returns minimized, redacted JSON. Failure
prints a stable code on stderr and exits 1 without raw RPC data. An observation
is not yet a bundle. See the [integration contract](Specs/LOCAL_DIAGNOSTICS_V1.md).

Capture a failure or clean control from an existing target:

```sh
swift run --package-path runtime/diagnostics-integration alloy-diagnostics \
  capture /absolute/private/endpoint.json session ses-identifier hang 30
python3 runtime/diagnostics-integration/run-capture-proof.py
```

The capture proof owns all injected failures and native processes. Full session
coverage requires actual arm64 hardware with at least 8 GiB, matching the
unchanged compiler; smaller hosts explicitly skip those six session rows.
