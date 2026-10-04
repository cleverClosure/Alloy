# STORE-001 result 06 — defensive Steam metadata parser

**Author:** Timur Isaev

**Date:** 26 July 2026

**Disposition:** Pass

**Gate:** 2 — defensive VDF and appmanifest metadata parser

**Base:** `823581c188edadb5d98d62bae31454b49fa409c1`

## Claim

Gate 2 adds a dependency-free, bounded parser for the read-only appmanifest
metadata needed to identify an installed build. The parser accepts the clean
synthetic control and refuses malformed, ambiguous, oversized, or numerically
invalid hostile inputs with typed errors.

This gate is complete only when all of the following are proven:

1. The clean fixture yields its exact app, build, install-directory, disk-size,
   and installed-depot metadata.
2. Truncated quoted values and objects are refused.
3. Extra or missing structural tokens are refused.
4. Duplicate keys are refused both at the app and depot levels.
5. Negative, non-numeric, and overflowing unsigned sizes are distinguished
   without trapping or truncating.
6. The 8 MiB input, 64-level nesting, and 1 MiB quoted-token bounds are
   enforced, and invalid UTF-8 is refused.
7. Every hostile-case invocation parses the unchanged clean control first, so
   an implementation that rejects all inputs cannot pass.

The proof is fixture-only. It does not inspect a live library, watch for
updates, launch any process, access the network, or modify storefront state.

## Exact inputs

| Input | Role |
| --- | --- |
| `runtime/store-identity/Tests/Fixtures/SteamMetadata/clean-appmanifest.acf` | Known-good appmanifest control. |
| `runtime/store-identity/Tests/Fixtures/SteamMetadata/*.acf` | Truncation, structure, duplicate-key, and numeric hostile cases. |
| Generated 8 MiB, 64-level, 1 MiB-token, and invalid-UTF-8 values | Deterministic resource-bound controls that do not require large committed fixtures. |
| `runtime/store-identity/run-metadata-parser-proof.sh` | Focused package proof. |

## Both-direction controls

| Direction | Control | Required observation | Status |
| --- | --- | --- | --- |
| Positive | Parse the clean fixture alone. | All required typed fields and both installed depots match their exact expectations. | Pass |
| Positive alongside every negative | Parse the clean fixture in the same parameterized invocation before each hostile input. | The clean control succeeds 14 times while its paired hostile input fails. | Pass |
| Negative — truncation | Truncate a quoted value and nested object. | Both are refused as truncated input. | Pass |
| Negative — structure | Add a closing brace or omit a value token. | Both are refused as malformed nesting. | Pass |
| Negative — ambiguity | Repeat an app key or depot key. | Both are refused as duplicate keys. | Pass |
| Negative — numeric | Supply a negative size and values above `UInt64.max` at app and depot levels. | Invalid unsigned input and both overflows are refused with distinct typed errors. | Pass |
| Negative — resource bounds | Exceed each documented byte/depth/token bound. | Input, nesting, and token limit errors are typed and deterministic. | Pass |
| Negative — encoding | Place an invalid byte sequence in a quoted value. | Invalid UTF-8 is refused before semantic parsing. | Pass |
| Posture | Run the Steam read-only automation gate before and after the gate. | Both strict posture checks pass unchanged. | Pass |

## Reproduction

Run from the repository root:

```sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
swift test --disable-sandbox --package-path runtime/store-identity
runtime/store-identity/run-metadata-parser-proof.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
tools/lint.sh
```

Expected final record:

```text
pre-change steam read-only gate: PASS — no account interaction
swift test: PASS — 10 tests in 2 suites
fingerprint parity: PASS — 7 focused cases
metadata parser proof: PASS — 14 hostile cases, each with a clean control
post-change steam read-only gate: PASS — no account interaction
lint: PASS
```

## Validation record

The standalone clean parse produced app `900000`, build `90000042`, install
directory `Synthetic Game`, 346 bytes, and both expected depot records. The ten
committed hostile fixtures and four generated bound/encoding inputs were each
refused by their named error category after the same invocation first proved
the clean fixture still parsed. The complete Gate 1–2 package ran 10 tests in
two suites; both read-only posture checks and repository lint passed.
