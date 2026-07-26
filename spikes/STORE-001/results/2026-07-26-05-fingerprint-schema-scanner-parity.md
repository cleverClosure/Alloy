# STORE-001 result 05 — fingerprint schema and scanner parity

**Author:** Timur Isaev

**Date:** 26 July 2026

**Disposition:** Pass

**Gate:** 1 — identity schema and scanner parity

**Base:** `b12945e9904b11a927e42b5603d80de8b93fd5dd`

## Claim

Gate 1 promotes the existing STORE-001 fingerprint into a strict v1 record and
a deterministic, read-only Swift scanner without changing the anchor's meaning.

The gate is complete only when all of the following are proven:

1. `fingerprint-1272160-first.json` validates against
   `runtime/store-identity/Specs/fingerprint.v1.schema.json`, decodes as
   `FingerprintRecord`, canonically re-encodes, and decodes to exactly the same
   typed and generic JSON values.
2. A committed synthetic installation produces its independently known file
   sizes, per-file SHA-256 values, count, total bytes, and aggregate.
3. The Swift scanner and `tools/steam-fingerprint.py` agree byte-for-byte on
   every lowercase digest and on the aggregate for that fixture.
4. Hidden regular files participate; symlinks and special objects do not; a
   detected mid-scan mutation is refused rather than yielding a mixed record.
5. The scanner and its proof use no live Steam library, network, client process,
   credentials, depot tooling, or writes to storefront input.

No claim about Steam metadata parsing, update detection, selectors, invalidation
records, watcher crash safety, or the current live Sir Brante installation is
made by this gate.

## Exact inputs

| Input | Role |
| --- | --- |
| `spikes/STORE-001/results/fingerprint-1272160-first.json` | Historical entitled-build value that must round-trip losslessly. |
| `runtime/store-identity/Specs/FINGERPRINT_V1.md` | Normative discovery, hashing, aggregate, stability, and canonical-encoding rules. |
| `runtime/store-identity/Specs/fingerprint.v1.schema.json` | Strict Draft 2020-12 persisted shape. |
| `runtime/store-identity/Tests/Fixtures/` | Synthetic game and metadata inputs; no live library. |
| `tools/steam-fingerprint.py` | Historical parity reference, unchanged in Gate 1. |

The synthetic fixture and the implementation committed by this gate produced:

```text
implementation commit: this Gate 1 commit
fixture appid/buildid: 900000 / 90000042
fixture file_count: 6
fixture total_bytes: 346
fixture aggregate_sha256: 94f9ae3d556e33fcd4f7acfaa36e25521e3542e71e3c67ffa1004adadb6d2d1e
```

## Claim boundary

The fingerprint identifies only the metadata and installation bytes supplied to
one stable scan. It does not prove entitlement, provenance, launchability, or
compatibility, and it does not prevent a storefront from updating later.

Read-only is part of the claim. The scanner may observe the selected fixture
tree; it may not make that tree stable by locking or modifying it. If its
before-and-after observations differ, refusal is the successful behavior.
Canonical round-trip means exact decoded value equality. It deliberately does
not mean reproducing the historical anchor's indentation or member order.

## Both-direction controls

| Direction | Control | Required observation | Status |
| --- | --- | --- | --- |
| Positive — known construction | Scan the untouched synthetic fixture. | Every path, size, digest, count, total, and aggregate equals the committed expectation. | Pass |
| Positive — independent parity | Scan the same fixture with Swift and the Python reference. | Every digest string and the aggregate are byte-for-byte equal. | Pass |
| Positive — historical value | Decode, validate, canonicalize, and decode the committed anchor. | Typed record and generic JSON values are exactly equal before and after. | Pass |
| Negative — byte sensitivity | Change one fixture byte in a scratch copy. | That file digest and the aggregate differ; the untouched control still matches. | Pass |
| Negative — membership | Add a hidden regular file and stage excluded object types in scratch copies. | The hidden file changes membership and aggregate; symlink/special objects never enter the record. | Pass |
| Refusal — unstable view | Mutate a scratch file between scanner observations. | The scan reports the stable-scan refusal and emits no fingerprint. | Pass |
| Posture control | Run the Steam read-only gate. | The strict gate passes unchanged. | Pass |

The unchanged positive runs accompany the mismatch and refusal cases. A
detector that always reports a mismatch, or a scanner that silently omits all
files, therefore cannot satisfy the gate.

## Reproduction

Run from the repository root:

```sh
swift test --disable-sandbox --package-path runtime/store-identity
runtime/store-identity/run-fingerprint-parity.sh
spikes/STORE-001/steam-readonly/steam-automation-gate.sh
tools/lint.sh
```

Expected final record:

```text
swift test: PASS — 7 tests in 1 suite
fingerprint parity: PASS — 7 focused cases
steam read-only gate: PASS — no account interaction
lint: PASS
```

## Validation record

The historical anchor decoded with all strict cross-field invariants, then its
canonical bytes decoded to the same typed record and generic JSON value. The
fixture scan found six files and 346 bytes; Swift and Python independently
produced the aggregate above. A scratch-byte perturbation changed both its file
digest and aggregate, a hidden-file control entered the record while a symlink
and FIFO did not, and the deterministic mid-scan mutation was refused. No test
opened the live Steam library.
