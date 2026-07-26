# STORE-001 result 08 — selector registry and evidence invalidation

**Author:** Timur Isaev

**Date:** 26 July 2026

**Disposition:** Pass

**Gate:** 4 — exact-build selector registry and invalidation records

**Base:** `c688480401d1101c0e521b9db3b08092b77b5dca`

## Claim

Gate 4 registers the three existing Sir Brante evidence artifacts against the
exact Steam build they support and emits one canonical, idempotent invalidation
record when a later observation supersedes that build. No historical evidence
artifact is edited.

The gate is complete only when all of the following are proven:

1. `Registry/selectors.v1.json` contains exactly three unique, UTF-8-sorted
   selector identifiers and no unrecognized persisted members.
2. Each selector names its exact existing artifact path and independently
   verified SHA-256 digest.
3. Every selector is bound to app `1272160`, build `24280929`, depot `1272161`
   manifest `3716404947812214693`, and aggregate
   `1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e`.
4. The selector image map contains the exact executable key and digest used by
   the existing launch evidence.
5. The registry strictly decodes, canonically re-encodes, and round-trips
   without semantic or ordering loss.
6. An unchanged observation returns no invalidation and leaves its empty
   output directory untouched before every changed or refusal case.
7. The first combined-update emission creates one record; repeating the same
   call creates nothing, returns the same record and identifier, preserves
   byte-for-byte canonical output, and leaves exactly one final JSON file.
8. The record names all three selector identifiers and the superseded build
   `24280929`; a registry with no exact selector match is refused.
9. A pre-existing target with noncanonical or conflicting bytes is refused
   instead of being overwritten, when that target condition is exercised.

## Exact registered evidence

| Selector ID | Existing artifact | Expected SHA-256 |
| --- | --- | --- |
| `store-001.fingerprint.1272160.24280929` | `spikes/STORE-001/results/fingerprint-1272160-first.json` | `5c6b43999284b699461fb64e916b21eb17d0ea9067460bac51c1e2c269dadc5a` |
| `gfx-001.result-06.1272160.24280929` | `spikes/GFX-001/results/2026-07-25-06-sir-brante-title-scene.md` | `aa1a853eac5661694e1d08d16a4a543821c03c9e53b916fa18b5fe42802a5001` |
| `store-001.launch-policy.sir-brante-24280929` | `spikes/STORE-001/runtime-launch/launch-sir-brante.sh` | `ac203ae4bdc3bdc7915aff16416abf5fd275bc38adedcee8916aa5538bf6ea4d` |

All three selectors use executable-image key
`The Life and Suffering of Sir Brante.exe` with SHA-256
`1fb707b113f25388a6dacdd81140bf2205f4fe93c71e83d3169e58ab98f95455`.
The launch-policy selector additionally binds the existing
`executableSHA256` and `processPolicies[].imageSHA256` evidence keys to that
same digest.

## Exact inputs

| Input | Role |
| --- | --- |
| `runtime/store-identity/Specs/SELECTORS_V1.md` | Normative exact-build selector contract. |
| `runtime/store-identity/Specs/selectors.v1.schema.json` | Strict persisted selector shape. |
| `runtime/store-identity/Specs/INVALIDATION_V1.md` | Normative invalidation identity and idempotence contract. |
| `runtime/store-identity/Specs/invalidation.v1.schema.json` | Strict persisted invalidation shape. |
| `runtime/store-identity/Registry/selectors.v1.json` | Promoted registry under test. |
| `spikes/STORE-001/results/fingerprint-1272160-first.json` | Trusted fingerprint anchor and one registered artifact. |
| Existing GFX result 06 and Sir Brante launch harness | Registered evidence checked independently by digest. |

## Both-direction controls

| Direction | Control | Required observation | Status |
| --- | --- | --- | --- |
| Positive — registry | Decode the committed registry and hash each named artifact from disk. | Exact three IDs, paths, digests, build keys, depot, aggregate, and image key match. | Pass |
| Positive — changed | Stage a combined manifest and file update derived from the committed anchor. | One invalidation names all three selectors and superseded build `24280929`. | Pass |
| Positive — idempotence | Emit the identical update twice. | First result is created, second is reused; ID, record, and canonical bytes are equal; one JSON file remains. | Pass |
| Negative — unchanged | Emit the unchanged anchor before every changed or refusal case. | Result is `nil` and the selected output directory remains empty. | Pass |
| Negative — registry mismatch | Remove all exact-build matches in a scratch registry value. | Changed update is refused and no output is created. | Pass |
| Negative — corrupt target | Replace the expected existing target bytes in scratch output. | Retry refuses the conflict and does not overwrite it. | Pass |
| Posture | Run the Steam read-only automation gate before and after the gate. | Both strict posture checks pass unchanged. | Pass |

The unchanged control accompanies every changed or refusal invocation. A writer
that always emits, or one that always rejects, therefore cannot satisfy this
gate.

## Claim boundary

This gate promotes existing evidence references and deterministic invalidation
persistence. It does not claim a long-running watcher, background scheduling,
live storefront discovery, instrument self-test, process-kill recovery, or a
current live-installation result. Those remain later gates.

## Reproduction

Run from the repository root:

```sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
swift test --disable-sandbox --package-path runtime/store-identity
runtime/store-identity/run-fingerprint-parity.sh
runtime/store-identity/run-metadata-parser-proof.sh
runtime/store-identity/run-update-watcher-proof.sh
runtime/store-identity/run-selector-invalidation-proof.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
tools/lint.sh
```

Expected final record:

```text
pre-change steam read-only gate: PASS — no account interaction
swift test: PASS — 17 tests in 4 suites
fingerprint parity: PASS — 7 focused cases
metadata parser proof: PASS — 14 hostile cases with paired clean controls
update watcher proof: PASS — 4 changed cases and 4 unchanged controls
selector proof: PASS — 3 cases, 3 unchanged controls, 3 selectors, 1 record
post-change steam read-only gate: PASS — no account interaction
lint: PASS
```

## Validation record

The committed registry decoded strictly, canonically round-tripped, and matched
all three independently hashed evidence artifacts. Its selectors matched the
exact Sir Brante anchor, including the executable digest and both additional
launch-policy image-hash keys. A combined staged update created one canonical
record naming all three selectors and superseded build `24280929`; the repeated
emission reused the same identifier, URL, record, and bytes while exactly one
final JSON file remained. The unchanged control left its output root empty
before each of the three cases. A registry with no exact build match and a
corrupt pre-existing target were both refused without creating or overwriting
an invalidation. The full package, every cumulative proof, both Steam posture
checks, and repository lint passed.
