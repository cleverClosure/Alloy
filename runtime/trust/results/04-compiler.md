# Compiler integration and handoff evidence

Author: Timur Isaev

6 October 2026, Apple Silicon. The development and lab positive controls use
fresh local keys and a pinned root, verify a complete timestamp/snapshot/targets/
revocation bundle, and compile signed profile, manifest, release metadata and
evidence envelopes. Their canonical LaunchSpecifications and snapshot bytes
match the test-only path byte for byte. Precise provenance remains distinct in
`CompiledLaunch.verificationProvenance`; production eligibility stays false.

Controls reject tampering independently in all four envelope types; a stale
observed game build; replayed and expired metadata; stable ring claims under a
local root; and a revoked profile revision. Both cached ProfileCandidate
selection and cached LaunchSpecification export are revalidated and reject the
revoked revision. Existing semantic and vendor-scope validation still runs.

Review added maximum-threshold root rotation (32 old + 32 new signatures),
recovery through an expired historical root to a fresh current root, and additive
migration from pre-rotation local state without resetting rollback counters.
The envelope cap is therefore 64 signatures, while authorized role key sets
remain bounded to 32.

Compiler version 0.8.0 and the `verified-local` marker intentionally change the
complete-launch goldens; the prior 0.7.0 evidence remains historical:

| Fixture | SHA-256 |
| --- | --- |
| minimal | `55e604ee843cb2d58fe76a832eb0634f2ea7bfe9b0f5c6fcbc0b961c74688409` |
| example | `1fd9a6e2ac5bc144027bde46b0b3e02ed6202362a09313de37e1c8fb2c41be2c` |

The initial compiler run correctly failed only the two obsolete golden values;
after reviewing the format/version decision, those values were updated. No
attack expectation was relaxed. See [consumer handoff](../Specs/CONSUMER_HANDOFF.md)
for the session-service/content-store integration contract and named residuals.

Final local gate: `tools/test-all --tier fast` reported **44 selected, 44
reported, 44 passed, zero failed, zero skipped**. The trust corpus has 17 tests
in four suites; the compiler corpus has 62 tests in 14 suites (including both
development/lab equivalence cases and the 512 clean/512 mutated pipeline pairs,
14 seeded controls, no false accepts or crashes). Node/OpenSSL's independent
vector check and repository lint also passed. No shared runtime build or guest
was used for this epic.

Final review found that revalidated cached candidates should use the renewed
metadata's effective expiry, rather than retaining the previous check's expiry.
The resolver now selects the freshly verified candidate. Its paired control
rejects expired metadata, then accepts the same candidate after a valid refresh.
The complete compiler suite was rerun after this correction: **63 tests passed**
in 14 suites, including the 512-pair fuzz corpus. All other suites' code is
unchanged from the 44-suite passing run above.

The key-scan control was also strengthened to use the full Git enumeration path:
a temporary repository first passes with a public-only fixture, then fails with
a staged fresh 32-byte private signing seed in JSON, then passes after removal.
No private value is printed or committed, and the temporary repository is removed.
The complete trust gate was rerun: all 17 Swift tests, actual CLI controls and
the end-to-end planted-key scan passed. Other suites retain their passing results.
