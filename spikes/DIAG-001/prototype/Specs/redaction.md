<!-- Author: Timur Isaev -->

# Offline redaction boundary

The redaction layer combines required content classification with a bounded text scanner. It does not infer arbitrary private content from text or binary data. The proof covers the committed synthetic fixtures and documented generated patterns; it does not establish universal secret recognition.

## Public entry points

- `RedactionScanner.scan(_ text: String, maxUTF8Bytes: Int = 1_048_576)` returns `RedactionScanResult.text` and aggregate `findings`.
- `EventRedactor.redact(_ event: StructuredEvent, maxUTF8Bytes: Int = 1_048_576)` returns a sanitized `event`, `removedClasses`, and aggregate `findings`.
- `DocumentRedactor.redact(_ data: Data, declaredClasses: Set<DataClass>, maxUTF8Bytes: Int = 1_048_576)` returns optional `data`, `retainedClasses`, `removedClasses`, and aggregate `findings`. `data == nil` means exclude the entire file.
- `RedactionFuzzer.run(seed: UInt64, iterations: Int = 240)` returns a reproducible report with planted/surviving counts and catch rate. Reports contain no generated secrets.

`RedactionFinding` contains only a `DataClass` and detection count. Overlapping pattern detections may count the same source bytes under multiple classes; counts represent detections, not unique secret identities. Replacement merges overlapping ranges so a secret cannot survive due to one rule changing another rule's input. The scanner uses UTF-16 ranges consistently with Foundation regular expressions, preserving surrounding Unicode. Input and output are bounded in UTF-8 bytes. A document with no detections returns the original `Data` exactly.

## Classification is mandatory

All ten sensitive classes in [the model taxonomy](diagnostic-model.md#data-taxonomy) are excluded as whole event fields or whole documents: credentials, home paths, chat/voice, sensitive URLs, save/game content, tokens/cookies, module/process/file inventory, gameplay video, screenshots, and usernames. A document declaring any such class is excluded even if it also declares a permitted class. Its `removedClasses` lists all declared content removed with that file; `retainedClasses` is empty. This handles opaque media and arbitrary private prose without pretending a regular expression can identify them.

The caller must classify data honestly. An empty document class set fails. Documents otherwise eligible for scanning must decode as UTF-8 without replacement characters. Binary or unknown encodings declared as ordinary text fail; a correctly classified sensitive binary is excluded outright. The seven essential telemetry classes may remain, but their text is still scanned for known sensitive patterns. A successful scan is not consent, and this implementation chooses no shipped consent level, region rule, retention policy, or upload behavior.

Correlation fields, provider map keys and values, event codes, and field names are scanned too. Known sensitive patterns in these metadata slots fail with `unsafeMetadata(field:)`, which contains a fixed schema-path label only. They are never silently rewritten into different correlation identities. Callers must supply safe opaque identifiers. Arbitrary personal information in opaque identifiers cannot be recognized universally; this mechanism does not authorize using personal values as identifiers.

## Recognized text grammar

The scanner removes these known shapes even inside a field/document declared as an essential class:

- Credential assignments such as `api_key=`, `password=`, and `client_secret=`, and selected recognizable API-key prefixes.
- Card-shaped runs of 13–19 digits with optional spaces or hyphens. This is a conservative shape check, not validation that a number is a payment card. Longer digit-only hashes are not treated as cards.
- Bearer values, token/session assignments, cookie headers, and JWT-shaped values.
- `/Users/` and `/home/` prefixes, Windows user-home paths, escaped backslashes/slashes, and percent-encoded separators or home-directory labels. Path scanning stops at whitespace or record punctuation; quoted/encoded unusual paths still require correct class assignment.
- HTTP(S) URLs with query strings, fragments, or userinfo. Query/fragment URLs are conservatively considered sensitive regardless of individual parameter names.
- Explicit synthetic `<save>`, `<save_content>`, `<save-content>`, `SAVE_CONTENT[...]`, `<chat>`, and `CHAT_CONTENT[...]` boundaries.
- Username assignments.

Save/chat markers are test mechanisms. Real save files, unmarked chat, voice, screenshots, video, and process inventory are handled by class-aware exclusion, not by these markers. Unsupported encodings, obfuscation, unmarked credentials, and semantic privacy require upstream classification or future independently tested transforms. The default one-megabyte limit is a local resource bound, not a consent policy.

## Verification and reproducibility

The literal fixture pair contains a clean 316-byte UTF-8 text and a seeded version with 20 independently enumerated secrets. Tests first require every planted value to exist in the original, then search for every value in the redacted output and serialized findings. The clean fixture's actual byte-change count is logged. Separate controls cover all ten whole-content exclusions, mixed-class documents, arbitrary unmarked private prose, every correlation slot, provider keys/values, event/field names, overlapping matches, Unicode preservation, idempotence, invalid UTF-8, and input/output limits.

The fuzzer uses SplitMix64 and twelve grammars: API-key assignments, card-shaped digit runs, macOS paths, Windows paths, two percent-encoded path forms, sensitive URLs, bearer values, cookie headers, marked save/chat content, and username assignments. Every generated value is inserted at a random offset in its own random ASCII padding record; records are then assembled into one synthetic bundle. Padding uses letters, punctuation, and whitespace, so insertion cannot extend a card digit run past its defined grammar or split an earlier planted secret. This precisely scopes the randomized proof. Seeded values are generated independently from the scanner's regex implementation. Each seed is run twice and reports must match.

```sh
swift test --package-path spikes/DIAG-001/prototype --filter RedactionTests
```

Observed on 4 October 2026: all 10 redaction tests passed. Seeds `3517317121`, `3517317122`, and `3517317123` each planted 360 values with zero survivors and catch rate `1.0` (1,080 unique trial insertions, plus deterministic reruns). The literal seeded fixture had zero survivors; the clean fixture remained byte-identical. No networking or external package dependency is used.
