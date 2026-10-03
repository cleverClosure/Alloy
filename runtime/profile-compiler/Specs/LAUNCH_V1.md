# Local LaunchSpecification, version 1

Author: Timur Isaev

`LaunchCompiler.compile` accepts explicit signed candidate envelopes, build and
host observations, client eligibility, a clock, local volume/grant bindings,
observed processes, and a signed local evidence envelope. It returns canonical
LaunchSpecification JSON plus the Wine snapshot projection and coverage report.
It performs no network request, file installation, runtime rebuild, or guest
launch. Production trust and runtime enforcement remain outside this package.

## Artifact and reproducibility

The output contains every doc 05 section 18 field: exact game/build/launcher,
local host class, runtime generation, profile ID/revision/digest, policy compiler
version and snapshot digest, local volumes, grant IDs, certification level and
matrix digest, and creation time. It also includes component digests, input
digests, CPU/shader cache epochs, resolved processes, the conservative default,
verification provenance, and the v1 field-coverage report. Profile-level
filesystem authorization, registry, dependencies, health, telemetry, and runtime
settings that require execution are also explicitly listed as not yet lowered.

`launchSpecId` is `ls_` plus the SHA-256 of canonical output with an empty ID.
The explicit clock makes repeat compilation deterministic. Component mappings,
process ordering, winning rule IDs, and coverage gaps have deterministic order.
Cache epochs bind profile, manifest, eligibility, evidence (including masks and
workarounds), normalized build/host, and resolved processes. They intentionally
invalidate conservatively when any of these inputs changes. They do not use
free memory or wall-clock time as capability identity.

`verifyExport` recompiles the authoritative tuple and compares complete
canonical bytes before decoding the exported object. Altered component IDs,
unknown fields, policy changes, and changed identity cannot survive a round
trip. The two valid launch fixtures include the **unchanged** converted example
profile and hand-built runtime manifests. Ten repeated and order-reversed
compiles produce identical bytes and re-resolve to identical component digests,
meeting RUN-001's exported-session acceptance condition.

## Signed local evidence

The published schemas are unchanged. `LaunchEvidence`, inside the separate
`application/vnd.alloy.local-launch-evidence+json;version=1` test envelope,
binds exact profile, manifest, release metadata, game/launcher build, host, and
matrix digests. Unknown evidence fields fail closed. It supplies local lifecycle
eligibility, finite certification expiry, workaround records, synthetic masks
and ceilings, provider/component bindings, process fingerprints, and dependency
approval digests. This is a compiler fixture contract, not a control-plane API.

The original example omits optional certification expiry and its launcher rule
uses a path with allowed networking. Its companion supplies finite evidence
expiry and a separately signed exact launcher fingerprint. The observed image
must match that fingerprint before access can expand; a path alone cannot grant
access. When the profile contains its own certification expiry, the companion
cannot extend it. Neither fixture is a real certification claim.

Active lifecycle states must agree with the release ring. Superseded, expired,
revoked, rejected, quarantined, and unknown states reject. Evidence must be
current and cannot claim a future test date. Unsigned inputs require explicit
Development Mode, development rings, and experimental status.

Competitive certification requires an additional Ed25519 signature from an
explicitly supplied **vendor** test-key map. Its signed claims bind vendor ID,
competitive scope, profile, build, host, matrix, and expiry. Missing scope,
wrong fingerprints, unknown vendor keys, and tampered signatures reject. The
committed vendor key is separately generated, deliberately public TEST-ONLY
data; it is not a publisher approval or a production trust root.

## Workarounds and feature masks

Every supplied workaround requires a unique ID, owner, reason, exact build and
process scope, introduction revision, evidence digests, future review expiry,
removal condition, and risk description. Provider deviations, feature masks,
and DLL overrides require a scoped record. A mask must reference an applicable
workaround and the selected graphics provider.

The registry permits only explicitly synthetic ceiling tables, with
`fixture.*` feature names. Every limit and feature is checked against its
provider ceiling. Once registered, a mask ID cannot change contents. This
tests storage and validation mechanisms without inspecting M12/DXMT code or
asserting any real graphics capability or limit.

## Local security boundaries

Volumes are opaque local IDs. Used grants must match the game, permitted
purpose, and requested access; raw host paths are never exported as grant IDs.
Host-root/Z-drive mappings, writable runtime mappings, duplicate drive letters,
unscoped native DLL/network expansion, and provider path traversal reject.
Environment permits only bounded locale/timezone values in LANG, LC_ALL, and
TZ. Host-loader injection and verification-bypass variables reject. Registry
operations are limited to HKCU Software, with credential-bearing value names
rejected. This is not a general secret detector: free prose and evidence still
need human review before any future production release.

Profile layers, selected providers, and dependency digests must exist in the
immutable manifest. Dependencies additionally require explicit approval and a
license gate. Stable selection requires a distinct rollback generation in the
caller's available-generation inventory. This inventory is a trusted local
input; the compiler does not claim to hash installed artifacts or replace the
content store's verification.

The output is always `productionEligible: false`. Current Wine v1 coverage
gaps also make it `runtimeReady: false`. Those are material limitations, not
warnings that a consumer may discard. This milestone exports a fully bound
local plan; future trust-chain and runtime work must provide production roots,
registered host classes, real certified ceilings, and enforcement for the
reported fields before the plan authorizes a production launch.
