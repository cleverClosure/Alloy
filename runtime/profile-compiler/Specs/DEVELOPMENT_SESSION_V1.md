<!-- Author: Timur Isaev -->

# Synthetic development session compilation

`DevelopmentSessionCompiler` is a separate, explicit entry point for the synthetic
session service proof. It does not accept a normal profile or change
`LaunchCompiler`, its conservative unknown default, signed evidence checks or
coverage gaps. It produces a complete `LaunchSpecification` and v2 snapshot from
already resolved, trusted local development inputs. Every result remains
`productionEligible: false`, `certification.level: experimental`, with
`verification: unsigned-synthetic-development` and a distinct
`localFormatVersion: alloy-synthetic-session-v1`.

## Input

The bounded canonical JSON document has exactly these Codable fields:

- `schemaVersion: alloy-synthetic-session-v1`, `syntheticOnly: true`;
- `filesystem: title-volumes-namespace-v1`;
- `gameID`, `buildID`, `runtimeGenerationID`, `runtimeTreeDigest`;
- actual `host` capabilities and fixed ISO-8601 `createdAt`;
- `volumes`: six distinct opaque IDs under `runtime`, `game`, `saves`, `settings`,
  `cache`, `temp`;
- `defaultPolicy`: `id`, `providerDirectory`, complete `ResolvedProcessPolicy`;
- `processes`: 1–32 entries containing `path`, `imageSHA256`, `machine`, `policy`.

Only ARM64 and x64 synthetic images are admitted, by unique SHA-256 and unique
case-insensitive `G:\` path. Provider directories must lie under
`C:\alloy\providers\`; optional working directories must lie on G:. Traversal,
host paths, unknown fields, nulls and unsupported contract versions reject.
Snapshot v2 validates its own field sizes, environment protection and routes.
The explicit default must use native-only CPU admission and contain a disabled
DLL route. It may not silently inherit an identified game's FEX permission.

## Readiness and responsibilities

Readiness means all requested process-policy fields can be lowered, including
the explicit default. Unsupported network, diagnostics, synchronization, CPU,
feature-mask and service requests remain coverage gaps. The supported synthetic
proof requests neutral `allow`, `off`, `conservative` modes explicitly. It does
not relabel the normal profile's `deny` or `crash-only` modes as supported.

The filesystem contract requests **drive namespace assembly only**. The service
must map title volumes and omit Z:, verify executable/provider files and hold
the runtime lease before execution. This is not filesystem authorization or an
adversarial guest sandbox: stock Wine Unix-path access and same-user host access
are not claimed to be contained. A caller requesting filesystem authorization
cannot use this contract. Such normal profiles retain their blocking gap.

The service must explicitly enable synthetic development execution out of band,
compare the host and runtime identities, validate the actual files/volume plan,
and recompute the export. Merely decoding a specification is not authorization.
Ordinary profile data cannot select the native fixture driver or opt into this
entry point. No command line, host executable, grant or production trust is
accepted by this compiler.

Every input is bound through the canonical source digest, including provider
paths and volume identities. The complete snapshot digest and runtime tree digest
are also explicit specification fields. Repeated identical input yields identical
specification and snapshot bytes. `verifyExport` recomputes and compares the
complete canonical export, rejecting added, removed or altered fields.
