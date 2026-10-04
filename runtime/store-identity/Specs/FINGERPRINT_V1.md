# Alloy store fingerprint record v1

**Author:** Timur Isaev

**Record:** `alloy-store-001-fingerprint`

**Version:** 1

## 1. Purpose

`FINGERPRINT_V1` is the exact identity of one installed storefront build. It
binds store metadata to the bytes observed beneath one game installation root.
It is an observation, not an installation or update instruction.

The key words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** in this document are
normative.

## 2. Persisted record

Every record MUST validate against
[`fingerprint.v1.schema.json`](fingerprint.v1.schema.json) and contain exactly
these top-level members:

| Member | JSON type | Meaning |
| --- | --- | --- |
| `record` | string | Exactly `alloy-store-001-fingerprint`. |
| `version` | integer | Exactly `1`. |
| `appid` | string | Store application identifier, preserved exactly as supplied. |
| `name` | string | Store display name, preserved exactly as supplied. |
| `buildid` | string | Store build identifier, preserved exactly as supplied. |
| `depots` | object | Depot-id keys mapped to `manifest` and `size` strings. |
| `file_count` | integer | Number of entries in `files`. |
| `total_bytes` | integer | Sum of all `files[].size` values. |
| `aggregate_sha256` | string | Lowercase SHA-256 of the aggregate stream in §5. |
| `files` | array | The complete ordered set of included regular files. |

`appid`, `buildid`, depot ids, depot `manifest`, and depot `size` are nonempty
ASCII digit strings. They are identifiers or source metadata, not JSON numbers;
their exact spelling MUST be retained, including any leading zeroes. Each file
entry contains exactly:

| Member | JSON type | Meaning |
| --- | --- | --- |
| `path` | string | Relative POSIX-style path defined in §3. |
| `size` | integer | Nonnegative byte length. |
| `sha256` | string | Lowercase SHA-256 of the file bytes. |

Unknown members are forbidden at every level. Each included path MUST appear
exactly once. `file_count` MUST equal `files.count`, and `total_bytes` MUST equal
the checked, non-overflowing sum of `files[].size`.

## 3. Path and object rules

The scanner recursively enumerates the selected installation root.

1. It includes every regular file, including regular files whose name or an
   ancestor's name begins with `.`.
2. It does not follow a symlink at any level. Symlinks, sockets, FIFOs, devices,
   and every other non-regular object are skipped.
3. A hard-linked regular file is included once for each path by which it occurs
   beneath the root.
4. `path` is relative to the installation root, uses `/` between components,
   is nonempty, and has no leading `/`, empty component, or `.` or `..`
   component. Components are retained verbatim; the scanner MUST NOT perform
   Unicode or case normalization.
5. Entries are sorted in ascending unsigned-byte lexical order of the UTF-8
   encoding of `path`. No locale, case folding, or filesystem collation enters
   the comparison.

The installation root itself is not a file entry.

## 4. Per-file digest

For each included path, the scanner reads the file bytes from offset zero
through end-of-file and computes SHA-256 over exactly those bytes. `sha256` is
the 64-character lowercase ASCII hexadecimal encoding of that digest. `size` is
the number of bytes hashed.

Integer addition and conversion MUST be checked. A size that cannot be
represented by the implementation or a `total_bytes` overflow is a refusal,
never a wrapped or truncated record.

## 5. Aggregate digest

The aggregate SHA-256 state starts empty. For every `files` entry in the path
order from §3, append exactly:

```text
path UTF-8 + NUL + decimal size + NUL + lowercase sha256 + LF
```

Equivalently, the byte stream for one entry is:

```text
UTF8(path) || 0x00 || ASCII(base10(size)) || 0x00 ||
ASCII(lowercase_sha256) || 0x0a
```

The decimal size has no sign and no leading zeroes; zero is encoded as `0`.
There is no header, separator between entries beyond the terminating line feed,
or final material after the last entry. For an empty installation, the
aggregate is SHA-256 of the empty byte string.

`aggregate_sha256` is the lowercase hexadecimal encoding of the resulting
digest.

## 6. Stable-scan requirement

A fingerprint MUST describe one stable observation, not a mixture of states
from a concurrently changing installation. The scanner therefore:

1. records the candidate path set and observable identity, type, size, and
   mutation metadata before reading;
2. verifies each object is still the same regular, non-symlink object before
   and after hashing; and
3. repeats the directory observation after hashing and compares it with the
   first observation.

If an observed path appears, disappears, changes type or identity, changes size
or mutation metadata, or yields a byte count inconsistent with its observations,
the scanner MUST refuse with the stable-scan error. It MUST NOT return or
persist a partial fingerprint. A caller may retry from the beginning.

This is detection, not prevention: the scanner never locks or modifies the
installation to make it stable.

## 7. Read-only behavior

The scanner opens installation and storefront inputs only for reading. It MUST
NOT create, write, rename, delete, lock, chmod, change timestamps, set extended
attributes, or otherwise mutate anything beneath the installation root or in a
Steam library. It MUST NOT follow symlinks out of the root.

The library returns a record or canonical bytes in memory. A command-line
caller MAY write those bytes to standard output or to a separate output path
chosen by that caller; the output path MUST NOT be inside the scanned
installation. Scanning requires no client process, credentials, depot tooling,
automation, simulated input, or network access.

## 8. Canonical JSON

The canonical v1 encoding is narrowly defined as the output of Foundation
`JSONEncoder` configured with:

- `.sortedKeys`;
- `.withoutEscapingSlashes`; and
- no `.prettyPrinted` formatting.

The encoded JSON bytes are UTF-8, contain no insignificant whitespace, and are
followed by exactly one `0x0a` line feed. All JSON object keys, including depot
ids, therefore use Foundation's lexical sorted-key order. This contract does
not claim RFC 8785/JCS compatibility.

Canonicalization preserves JSON meaning, not historical presentation. The
committed STORE-001 anchor is losslessly round-tripped when:

1. it decodes into `FingerprintRecord`;
2. it validates against the v1 schema and all cross-field invariants here;
3. canonical bytes decode again; and
4. the two decoded `FingerprintRecord` values, and their generic JSON values,
   are exactly equal.

Its original indentation and object-member order need not be reproduced.

## 9. Validation and parity

Schema validation alone is insufficient. A conforming decoder also verifies:

- sorted, unique file paths;
- `file_count` and `total_bytes`;
- each per-file digest when source bytes are available; and
- the aggregate fold.

The Gate 1 fixture proves both directions. An unchanged fixture produces the
known record, and both the Swift scanner and `tools/steam-fingerprint.py`
produce byte-for-byte identical lowercase text for every per-file digest and
the aggregate. A changed fixture byte changes its file digest and aggregate;
hidden regular files remain included, excluded object types remain absent, and
an observed mid-scan mutation is refused.
