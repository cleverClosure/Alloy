<!-- Author: Timur Isaev -->

# Offline diagnostic model, version 1

The M1 model layer uses Foundation and the Swift standard library. This layer creates no processes, reads no player data, makes no network requests, and adds no dependencies. Tests use synthetic values and the repository's existing privacy document. This milestone provides identities and explicit content classifications for subsequent capture, redaction, bundle, and classifier modules.

## Correlation and events

[`CorrelationID`](../Sources/AlloyDiagnostics/CorrelationID.swift) implements the nine identity groups in [operations doc §5](../../../../docs/docs/10_OBSERVABILITY_OPERATIONS_AND_RELEASE.md#5-observability-model). Game/build and profile/revision each contain two independently required strings. The JSON keys are `request_id`, `operation_id`, `session_id`, `game_id`, `build_id`, `host_class_id`, `runtime_generation_id`, `profile_id`, `profile_revision`, `process_policy_id`, and `provider_build_digests`. Provider names map to opaque digest identifiers; the model does not imply digest verification or prescribe a hash algorithm. Lab `test_plan`, `scenario`, `runner`, and `release_ring` carry the remaining doc §5 context when applicable and are omitted when unavailable. The model does not select a ring.

`StructuredEvent` adds `schema_version: 1`, a stable `event_code`, an integer `timestamp_unix_milliseconds`, and named `EventField` values. Each value requires a `DataClass`; there is no unclassified or public fallback. Duplicate field names, missing required identity members, empty/control-character identifiers, negative timestamps, unknown JSON fields, unknown classes, and unsupported event versions fail decoding. Identifiers and event names are caller-supplied metadata, not a redaction guarantee. Free-text data belongs in classified fields. Collection bounds and sensitive-content removal belong to subsequent modules.

`DiagnosticsJSON.encode` uses sorted keys and preserves string content. The committed literal [`event-v1.json`](../Tests/AlloyDiagnosticsTests/Fixtures/event-v1.json) independently fixes every wire key and synthetic value. Tests compare encoded bytes against that fixture, decode it into a separately constructed value, and test the standalone correlation round trip.

## Data taxonomy

[`DataClass.references`](../Sources/AlloyDiagnostics/DataClass.swift) carries the exact source categories below from [security doc §17.1 and §18](../../../../docs/docs/09_SECURITY_PRIVACY_THREAT_MODEL.md#17-telemetry-privacy). Multiple source phrases map to one case only where this table records the grouping. Classification says what content is present; it does not authorize collection or export.

| Enum case | Exact document category | Section |
| --- | --- | --- |
| `componentVersions` | product/component versions | 17.1 |
| `metadataVerification` | signed metadata result | 17.1 |
| `errorCode` | stable error code | 17.1 |
| `hostCapabilities` | coarse host capability class | 17.1 |
| `gameProfileIdentifiers` | game/profile identifiers | 17.1 |
| `runtimeOutcome` | severe crash/device-loss/rollback outcome | 17.1 |
| `pseudonymousClientIdentifier` | pseudonymous rotating client identifier | 17.1 |
| `saveGameContent` | save content; save/game content | 17.1; 18 |
| `chatVoiceContent` | chat/voice; chat | 17.1; 18 |
| `gameplayVideo` | gameplay video | 17.1 |
| `screenshots` | screenshots | 17.1 |
| `homePaths` | full home paths; home prefixes | 17.1; 18 |
| `credentials` | credentials | 17.1 |
| `moduleProcessFileInventory` | unrelated process/file inventory | 17.1 |
| `usernames` | usernames | 18 |
| `tokensCookies` | tokens; cookies | 18 |
| `sensitiveURLs` | URLs/query strings where sensitive | 18 |

The inventory case includes the issue's “module/process inventory” wording: modules are process/file inventory. The source document itself says “unrelated process/file inventory”; this alias does not claim that §18 names modules or that unrelated inventory should be collected. Grouping tokens and cookies follows the issue's requested group while preserving both independent §18 citations. Visual content and usernames remain explicit cases even though the issue's abbreviated seven-group list omits them.

The document coverage test reads §17.1 bullets and §18 redaction/exclusion categories directly from the repository document, requiring all 21 source references to map exactly once across all 17 cases and requiring every enum case to cite a source. It rejects previously unseen §18 instructions pending category review. A positive failure control inserts a synthetic new document category and proves it is detected as unmapped. Package code does not depend on these document files at runtime; this repository verification test intentionally requires them.

## Consent mechanism

`ConsentLevel` exposes `off`, `essential`, `diagnostic`, and `lab`, exactly as named in security doc §17.2. No initializer, stored default, consent decision, regional behavior, retention duration, or upload implementation is provided. Those decisions are outside this local model milestone.

## Verification

```sh
swift test --package-path spikes/DIAG-001/prototype
swiftlint lint --strict --no-cache --quiet spikes/DIAG-001/prototype
```
