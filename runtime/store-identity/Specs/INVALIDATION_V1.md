# Alloy evidence invalidation record v1

**Author:** Timur Isaev

**Record:** `alloy-store-identity-invalidation`

**Version:** 1

## 1. Purpose

`INVALIDATION_V1` records that one observed build no longer matches the exact
build identity to which evidence selectors were bound. It names the
superseded selectors and the metadata and content differences that caused the
invalidation.

The key words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** in this document
are normative.

## 2. Persisted record

Every record MUST validate against
[`invalidation.v1.schema.json`](invalidation.v1.schema.json) and contain
exactly:

| Member | JSON type | Meaning |
| --- | --- | --- |
| `record` | string | Exactly `alloy-store-identity-invalidation`. |
| `version` | integer | Exactly `1`. |
| `invalidation_id` | string | Deterministic `sha256:<64 lowercase hex>` identity from §6. |
| `game_id` | string | Store game identifier as an ASCII decimal string. |
| `storefront` | string | Exactly `steam` in v1. |
| `superseded` | object | Build identity to which the selectors were bound. |
| `observed` | object | Newly observed build identity. |
| `metadata_changed` | boolean | Whether build or depot identity changed. |
| `game_content_changed` | boolean | Whether the installed-content aggregate changed. |
| `changed_depot_ids` | array | Exact sorted depot-id difference. |
| `added_file_paths` | array | Exact sorted paths present only in the observation. |
| `removed_file_paths` | array | Exact sorted paths present only in the anchor. |
| `changed_file_paths` | array | Exact sorted paths whose size or digest changed. |
| `selector_ids` | array | Exact sorted selector ids invalidated by this change. |

Unknown members are forbidden. No timestamp, random identifier, host path, or
machine-specific value is part of v1.

## 3. Build identity

Both `superseded` and `observed` contain exactly:

| Member | JSON type | Meaning |
| --- | --- | --- |
| `build_id` | string | Store build identifier as an ASCII decimal string. |
| `manifest_ids` | object | Depot-id keys mapped to exact manifest-id strings. |
| `aggregate_sha256` | string | Lowercase installed-content aggregate SHA-256. |

`metadata_changed` MUST equal the result of comparing `build_id` and the
complete `manifest_ids` map. `changed_depot_ids` MUST be the depot ids whose
presence or manifest value differs between those maps.

`game_content_changed` MUST equal the result of comparing
`aggregate_sha256`. When it is false, all three file-path arrays MUST be empty.
When it is true, at least one file-path array MUST be nonempty. The arrays MUST
be the exact path-set and size-or-digest difference when the two fingerprints
are available.

At least one change boolean MUST be true. The file arrays are pairwise
disjoint.

## 4. Ordered unique arrays

Every array is sorted in ascending unsigned-byte lexical order of the UTF-8
encoding of its member and contains no duplicate. A decoder MUST reject
unsorted or duplicate arrays; it MUST NOT silently sort or deduplicate
persisted input.

`selector_ids` contains every registry selector, and only a registry selector,
whose `storefront`, `game_id`, `store_build_id`, `manifest_ids`, and
`aggregate_sha256` exactly match the superseded identity. It is nonempty.

## 5. Canonical JSON

Canonical invalidation JSON uses Foundation `JSONEncoder` with:

- `.sortedKeys`;
- `.withoutEscapingSlashes`; and
- no `.prettyPrinted` formatting.

The UTF-8 JSON has no insignificant whitespace and is followed by exactly one
`0x0a` line feed. The line feed is part of canonical bytes. This is the same
narrow encoding used by `FINGERPRINT_V1`; it does not claim RFC 8785/JCS
compatibility.

## 6. Deterministic invalidation id

To compute `invalidation_id`:

1. Construct the complete validated invalidation object with
   `invalidation_id` omitted. Every other member, including `record` and
   `version`, remains.
2. Encode that object with the canonical encoding from §5.
3. Include its one terminating `0x0a` line feed in the bytes being hashed.
4. Compute SHA-256 over exactly those bytes.
5. Set `invalidation_id` to `sha256:` followed by the 64-character lowercase
   hexadecimal digest.

A decoder recomputes the id and rejects a mismatch. Because the identity
material has no timestamp, random value, or ordering ambiguity, the same
semantic invalidation always has the same id.

## 7. Idempotent emission

An emitter persists at most one record for an `invalidation_id`. Re-emitting
the same validated identity material returns the existing equal record and
does not create a second logical invalidation. If an existing record under the
same id is malformed, noncanonical, or unequal, emission is refused.

Persistence uses create-if-absent or an equivalently atomic operation outside
the observed Steam library. A crash before publication leaves no visible
record; a crash after publication leaves one complete canonical record. A
rerun converges to that same record.

## 8. Validation order

A conforming implementation validates, before emission:

1. record, version, identifiers, digests, paths, and unknown-field refusal;
2. sorted unique arrays and pairwise-disjoint file classifications;
3. metadata and content booleans against the two identities;
4. changed depot ids and, when source fingerprints are present, file deltas;
5. the exact selector set against the supplied selector registry; and
6. the deterministic invalidation id.

Schema validation alone is insufficient for these cross-field invariants.

## 9. Read-only boundary

Detection and selector lookup consume caller-supplied records. They MUST NOT
modify a Steam library, game installation, anchor, selector registry, or
historical evidence. An emitter writes only to a separate output directory
chosen by its caller. No Steam process, credentials, depot tooling, automation,
or network access is required.
