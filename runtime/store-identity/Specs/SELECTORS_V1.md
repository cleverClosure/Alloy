# Alloy evidence selector registry v1

**Author:** Timur Isaev

**Record:** `alloy-store-identity-selector-registry`

**Version:** 1

## 1. Purpose

`SELECTORS_V1` binds a committed evidence artifact to the one exact installed
build for which its claim is valid. A selector is evidence metadata, not a
storefront instruction or a compatibility claim for nearby builds.

The key words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** in this document
are normative.

## 2. Registry record

Every registry MUST validate against
[`selectors.v1.schema.json`](selectors.v1.schema.json) and contain exactly:

| Member | JSON type | Meaning |
| --- | --- | --- |
| `record` | string | Exactly `alloy-store-identity-selector-registry`. |
| `version` | integer | Exactly `1`. |
| `author` | string | Exactly `Timur Isaev`. |
| `selectors` | array | Nonempty, sorted, unique selector records. |

Unknown members are forbidden at every level.

`selectors` MUST be sorted by `selector_id` in ascending unsigned-byte lexical
order of its UTF-8 encoding. Every `selector_id` MUST be unique. Duplicate,
unsorted, malformed, or unsupported records are refusals rather than values an
implementation repairs silently.

## 3. Selector record

Each selector contains exactly:

| Member | JSON type | Meaning |
| --- | --- | --- |
| `selector_id` | string | Stable lowercase identifier for this binding. |
| `artifact` | object | Exact committed artifact kind, path, and SHA-256. |
| `storefront` | string | Exactly `steam` in v1. |
| `game_id` | string | Steam app identifier as an ASCII decimal string. |
| `store_build_id` | string | Steam build identifier as an ASCII decimal string. |
| `manifest_ids` | object | Depot-id keys mapped to exact manifest-id strings. |
| `aggregate_sha256` | string | Exact installed-content aggregate from the anchor. |
| `image_hashes` | object | Required executable image identities used by the artifact. |

`artifact` has exactly `kind`, `path`, and `sha256`. Its `kind` is one of
`fingerprint`, `scene-measurement`, or `launch-policy`. `path` is a
repository-relative POSIX path with no empty, `.` or `..` component.
`sha256` is the lowercase SHA-256 of the exact committed artifact bytes.

`image_hashes` always contains the exact installed image path
`The Life and Suffering of Sir Brante.exe`. A `launch-policy` also contains
`executableSHA256` and `processPolicies[].imageSHA256`, preserving both field
names emitted by the launch harness. All values MUST be identical because they
name the same executable bytes. No other image-hash key is defined by the
committed v1 registry.

## 4. Exact-match semantics

A selector matches an observation only when all of these values are equal:

1. `storefront`;
2. `game_id`;
3. `store_build_id`;
4. the complete `manifest_ids` map;
5. `aggregate_sha256`; and
6. every image digest required by `image_hashes`.

Matching is exact string equality. A missing value, additional or missing
depot, different manifest, different aggregate, or different required image
digest is a non-match. There are no ranges, wildcard builds, implicit
storefront aliases, or case folding.

The artifact path is not authority by itself. A verifier SHOULD resolve it
beneath the selected repository root without following a symlink, require a
regular file, hash its exact bytes, and compare that digest with
`artifact.sha256`.

## 5. Committed v1 bindings

[`../Registry/selectors.v1.json`](../Registry/selectors.v1.json) registers
exactly three artifacts against the STORE-001 Sir Brante anchor:

| Selector | Artifact kind | Artifact path |
| --- | --- | --- |
| `gfx-001.result-06.1272160.24280929` | `scene-measurement` | `spikes/GFX-001/results/2026-07-25-06-sir-brante-title-scene.md` |
| `store-001.fingerprint.1272160.24280929` | `fingerprint` | `spikes/STORE-001/results/fingerprint-1272160-first.json` |
| `store-001.launch-policy.sir-brante-24280929` | `launch-policy` | `spikes/STORE-001/runtime-launch/launch-sir-brante.sh` |

All three selectors MUST contain the exact shared build identity:

```text
storefront: steam
game_id: 1272160
store_build_id: 24280929
manifest_ids: {"1272161":"3716404947812214693"}
aggregate_sha256: 1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e
image_hashes["The Life and Suffering of Sir Brante.exe"]: 1fb707b113f25388a6dacdd81140bf2205f4fe93c71e83d3169e58ab98f95455
```

A committed selector that differs from this anchor is invalid. The registry
does not mutate the historical artifact or broaden its claim.

## 6. Canonical JSON

Canonical selector JSON uses Foundation `JSONEncoder` with:

- `.sortedKeys`;
- `.withoutEscapingSlashes`; and
- no `.prettyPrinted` formatting.

The UTF-8 JSON has no insignificant whitespace and is followed by exactly one
`0x0a` line feed. This is the same narrow canonical encoding used by
`FINGERPRINT_V1`; it does not claim RFC 8785/JCS compatibility.

Schema validation is necessary but insufficient. A conforming validator also
checks sorted unique selector ids, exact-match invariants, image-key semantics,
safe artifact resolution, and the artifact digest.

## 7. Read-only boundary

Selector validation reads only the caller-selected registry, anchor, and
evidence artifacts. It MUST NOT modify a Steam library, evidence artifact,
historical result, or launch script. It requires no client process,
credentials, depot tooling, automation, or network access.
