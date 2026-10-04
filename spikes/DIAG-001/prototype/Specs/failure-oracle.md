<!-- Author: Timur Isaev -->

# Seeded failure oracle

`SyntheticLaboratory` runs known local operations and records their observed results as classified events. It does not write hand-authored failure logs or embed an expected answer in a bundle. `BundleBuilder` redacts and seals those events. `FailureClassifier` receives only a verified `SealedBundle`; it has no live-system, injection-plan, filename, or oracle-report input.

## Injections and evidence

| Injected case | Actual operation | Evidence consumed by classifier |
| --- | --- | --- |
| Profile mismatch | Write/select an alternative synthetic profile identifier and read it back | Required versus resolved profile identifiers |
| Wrong provider | Select a different synthetic provider-image file and hash its actual bytes | Required versus selected SHA-256 digests |
| Shader compiler crash | Launch the native fatal-error subject under the harness's shader-compiler role; capture it with LLDB | Observed symbolicated fatal error, known site, and assigned process role |
| Permission denial | Remove all permissions from a scratch file, then attempt a real read open | Read operation and observed `EACCES` (`13`) |
| Corrupt cache | Overwrite the first byte of a known cache file, then rehash actual bytes | Expected versus observed SHA-256 digests |
| Memory pressure | Request 65,536 bytes from a bounded 32,768-byte synthetic allocator | Requested/available bytes and observed quota rejection |
| Guest crash | Launch the same native subject under the distinct guest role; capture it with LLDB | Observed symbolicated fatal error, known site, and assigned process role |
| Insufficient evidence | Remove only `process_role` from the observed guest crash | Fatal-error/site evidence remains; no basis to distinguish the two roles |

These are synthetic operations. Profile/provider files model selection rather than a real game resolver or dynamic module loader. Memory pressure is a deterministic local allocation-budget failure, not host-wide physical memory exhaustion. Shader/guest roles are harness-assigned; the subject is not a shader compiler or Wine guest. Actual native crashes, permission failure and cache corruption are observed on this Mac. This closes the scoped offline classifier exercise, not live-runtime incident diagnosis.

Opaque request IDs use letters `a`–`p`, retaining UUID entropy without card-shaped decimal runs. Full SHA-256 evidence is represented in colon-separated eight-hex-character groups. No digest bits are discarded. These representations avoid conservative card-pattern redaction of legitimate numeric substrings without weakening the scanner or exempting caller metadata.

## Classification and controls

A unique supported observation yields one of the seven causes. Missing required signals, contradictory supported causes, mixed correlation identities, and empty evidence return `insufficient_evidence`. Redacted comparison operands cannot establish a mismatch. Classification does not equate the absence of one cause with proof of another.

The test suite generates all eight bundles anew, moves them to unrelated random names, and classifies only their sealed contents after injection scratch state has been deleted. Seven additional controls disable the corresponding injection and must all yield insufficient evidence. Seven signal-removal controls strip each cause's distinguishing field and must also abstain. Contradictory/mixed/empty controls prevent a guessed answer.

The exported fixture set contains eight numbered bundle directories and a separate `oracle.json` mapping expected/observed results. The classifier never reads this mapping. The committed fixture set is a durable sample; fresh generation in `swift test` remains the acceptance oracle.

```sh
swift test --package-path spikes/DIAG-001/prototype --filter OracleTests
swift run --package-path spikes/DIAG-001/prototype DiagnosticsOracle generate \
  /private/tmp/diag-fresh-fixtures \
  spikes/DIAG-001/prototype/.build/debug/AlloyDiagnosticsSubject
swift run --package-path spikes/DIAG-001/prototype DiagnosticsOracle classify \
  /private/tmp/diag-fresh-fixtures/bundle-07
```

Generation requires an absent output directory and a built native subject. It exits unsuccessfully if an injection fails to fire or any expected answer differs. Classification of malformed or unsealed input fails rather than guessing. Both commands operate locally and require no account, game, upload, daemon, or external package.
