<!-- Author: Timur Isaev -->

# Local bundle and privacy preview

`BundleBuilder.prepare` accepts classified events, optional classified UTF-8 documents, and optional native capture reports. It runs M3 redaction before constructing any export. All ten sensitive classes are excluded by default. Caller declarations are required for arbitrary text; this is not semantic detection of unmarked private prose or binary media.

Native reports are minimized to their typed kind, cause, tool, duration and correlation context. Raw debugger/sample output is excluded because it contains home paths and module inventory. The prototype deliberately sacrifices detailed native stacks in its export until a separately proven structural stack filter exists. M2's local capture still proves symbolication.

## Manifest and preview

The manifest enumerates exactly the exported payload files, their byte lengths, SHA-256 digests, and retained data classes. `events.json` carries the structured events. Optional documents receive generated `document-NNN.txt` names; caller-provided paths or filenames cannot become export metadata. The class union is computed from retained files. Removed classes are separately labeled and are never represented as present payload content.

The fixed event envelope contributes component versions (build/provider/generation), host capability class, game/profile identifiers, stable event code, and runtime outcome/correlation context. Each surviving event field contributes its explicit class. Document classes remain the caller's declared essential classes after filtering. Empty documents contribute no file or class. An empty event array has no data classes. This is a schema/classification inventory, not a claim that an arbitrary prose classifier can infer all semantics.

`PreparedBundle.preview` is computed from the exact immutable manifest before export or any consent selection. It lists the same files/classes, removed classes, total payload bytes, local retention notice, and absent support-case link. No control plane exists, so a link is not fabricated. Local files remain until their owner deletes them. All four explicit consent levels return `DiagnosticUpload.Availability.unavailable`; no default consent level or region policy is selected.

## Export and verification

Exports use a new sibling staging directory, mode `0700`, with payload and manifest files mode `0600`. The destination must not exist. The builder verifies the staged bundle before moving it into place. It never overwrites a prior bundle. The local owner can delete the directory normally.

The reader accepts only the fixed payload naming grammar, one event file, canonical manifest JSON, unique sorted paths, exact directory membership, regular files, and matching sizes/digests. Directory/file symlinks, traversal paths, unexpected files, altered bytes, unknown/noncanonical manifest fields, and retained known secret patterns fail. Events are decoded and re-redacted as a fixed-point check. The byte seal detects accidental changes; anyone who can rewrite the entire bundle can recompute it. It is not a signature or an authenticity claim.

Bounds are one MiB per payload/manifest, eight MiB total payload, 30 input documents, 1,024 events and 32 capture summaries. Event/document accumulation rejects over-budget output incrementally. Unknown UTF-8 text is rejected by the redaction boundary. The reader is a local synthetic prototype: concurrent hostile filesystem replacement is outside this proof, and files are not encrypted. Private filesystem permissions are not encryption. Shipping at-rest encryption, upload encryption, retention automation, support links, and real client/daemon integration remain future work.

There are zero external SwiftPM dependencies. Foundation plus Apple SDK Darwin and CryptoKit supply local process/filesystem access and SHA-256. This follows the existing `runtime/content-store` use of CryptoKit; it does not add a third-party cryptographic implementation. Tests audit package imports/API use for networking and verify the upload boundary remains unavailable.

## Verification

```sh
swift test --package-path spikes/DIAG-001/prototype --filter BundleTests
```

Ten tests cover actual export/read and preview agreement, every sensitive-class exclusion, the M3 clean/20-secret pair, capture minimization, permissions, seal/manifest/path/symlink mutations, resealed sensitive payload rejection, limits, and the absence of networking APIs. The one-MiB and eight-MiB bounds are exercised with real buffers rather than trusting declared lengths.
