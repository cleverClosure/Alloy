<!-- Author: Timur Isaev -->

# Alloy layer format 1.0

## Status and scope

Version 1.0 defines the immutable distributable package stored as one CAS
object by `AlloyContentStore`. It specializes the layer structure in
[doc 04 §9.3](../../../docs/docs/04_TECHNICAL_ARCHITECTURE.md#93-layer-format)
and uses the component identity fields required by
[doc 05 §8](../../../docs/docs/05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md#8-runtime-manifest).

The package media type is:

```text
application/vnd.alloy.layer.v1+tar+zstd
```

The SHA-256 identity and declared byte size cover the complete compressed
package. A filename or download URL is never an identity.

## Package entries

```text
layer.json
files/...
metadata/file-table.cbor
metadata/license.spdx.json
metadata/provenance.dsse.json
metadata/symbols.ref
```

`layer.json` MUST validate against
[`layer-manifest.v1.schema.json`](layer-manifest.v1.schema.json). The file table
MUST enumerate every entry below `files/`, using the canonical encoding below.
Clients MUST reject unsupported required features rather than guess.

The SPDX, DSSE, and symbols entries MAY be absent only when `layer.json` omits
the corresponding digest. When a digest is present, the entry is required and
MUST match it.

## Verification order

Before an object can become a materialized layer, an implementation MUST:

1. authorize the expected digest, size, and media type from signed metadata;
2. verify the compressed package size and SHA-256 digest;
3. decode Zstandard and parse the archive without writing outside staging;
4. validate `layer.json` and reject an unsupported major or required feature;
5. validate the complete file table before publishing any unpacked tree;
6. verify license, provenance, symbols, and native-code signatures when
   declared;
7. calculate the canonical file-tree digest;
8. fsync and atomically publish both CAS object and unpacked tree.

The development profile uses an explicit `importDevelopmentLayer` entry point
instead of step 1's production signature authorization. It accepts an expected
descriptor supplied by the local builder, verifies all bytes and native ad-hoc
signatures, and does **not** confer release trust. Its required features are
exactly `canonical-table-v1`, `raw-zstd-v1`, `development-adhoc-v1`, in that order.
Production authorization must never silently fall back to this entry point.

## Archive safety

An extractor MUST reject:

- absolute, empty, `.` or `..` paths;
- path traversal after Unicode and separator normalization;
- duplicate normalized paths and case-fold collisions;
- device nodes, sockets, FIFOs, setuid/setgid bits, and unexpected ownership;
- hard links or symlinks escaping `files/`;
- sparse or expanded data beyond declared resource limits;
- undeclared entries or file-table mismatches;
- native code whose signature does not validate (ad-hoc permitted only for the
  explicit development profile; production requires its authorized identity).

Extraction occurs in a private staging directory. A partial or unsealed tree is
never eligible for a generation reference.

## Canonical file table and tree identity

The table is a definite-length CBOR array of rows:

```text
[relativePath, kind, mode, byteSize, digest, linkTarget]
```

Only unsigned integers, UTF-8 text and arrays are used. Lengths and integers
use their shortest encoding; tags, indefinite lengths and other types are
rejected. See [RFC 8949](https://www.rfc-editor.org/rfc/rfc8949.html).
Rows are sorted by the UTF-8 bytes of `relativePath`. Every parent directory
is explicitly present. `fileTreeDigest` is `sha256:` plus the lowercase hex
SHA-256 of these canonical table bytes, without a newline or wrapper.

| Kind | Mode | Size and digest | Target |
| --- | --- | --- | --- |
| 0: regular | 0444 or 0555 | File byte count and `sha256:` digest of bytes | Empty |
| 1: directory | 0555 | 0 and empty digest | Empty |
| 2: symlink | 0777 | UTF-8 target byte count and `sha256:` digest of target bytes | Relative target |

The symlink mode is a canonical type marker, independent of macOS's
umask-dependent permissions on the link inode. Its target bytes are verified;
the target regular file and every directory have their exact sealed modes
verified. File and directory modes are never normalized away during reuse.

Paths are NFC, at most 240 UTF-8 bytes, and exclude empty, dot and dot-dot
components, backslash, colon and control characters. Case-fold collisions are
rejected. A link may use `..` only while remaining inside the composed root.
Its final target must be a declared regular file; links through directory
symlinks, cycles and chains longer than 32 are refused. Cross-layer links are
resolved at composition. Only identical directory entries may overlap layers.

The development bound is 50,000 entries, 16 MiB metadata and 1 GiB expanded
archive per layer. These are limits, not allocations inferred from untrusted
headers. A composite tree obeys the same file-table validation limits.

## Canonical development archive

The writer emits USTAR entries in this order: canonical `layer.json`,
`metadata/file-table.cbor`, then each `files/` entry in table order. Canonical
JSON uses sorted keys, UTF-8, no insignificant whitespace and no trailing
newline. No PAX, GNU extension, sparse, hard-link or special-file entry is
accepted. Owner IDs, timestamps and owner names are zero/empty; metadata mode
is 0444. Payload type, mode, size, link and content digest must match the table.
The extractor checks checksums, padding, all metadata and every payload before
writing any executable tree. Undeclared metadata is refused.

The Apple SDK does not provide a Zstandard decoder through Compression.
Rather than mislabel another codec or invoke a mutable external executable,
`raw-zstd-v1` uses a deliberately bounded interoperable subset of
[RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html): one standard frame,
single segment, four-byte content size, raw blocks at most 128 KiB, no
dictionary or checksum, and no trailing or concatenated frame. Compressed or
RLE blocks and other frame options are rejected. This saves no storage bytes;
compression is a future required feature, not an implicit format change.
An independent standard decoder can read the writer's output.

## Local publication and use

Import first copies the caller's regular archive into a private file while
hashing, then parses that snapshot. It never publishes a caller-owned mutable
inode. CAS objects are fsynced and sealed 0444. Activation uses the existing
ordered layer descriptors, generation manifest and journal machinery.

Materialization recomputes tables from verified CAS objects and stages the
composed tree beside its destination in `runtime-trees/`. All files and
directories are sealed, checked (including native signatures), fsynced and
renamed with exclusive publication under the store lock. The directory name
is the active generation-manifest digest. The composed tree digest uses the
same canonical table algorithm, after merging layer directories.

Before reuse, verification enumerates and hashes the entire runtime tree and
rejects missing, extra, changed, writable or hard-linked entries. It never
repairs an existing tree silently. Read-only modes prevent accidental writes;
an owner can still chmod files, so digest verification before use remains
mandatory. Prefixes, logs and shader caches belong outside this tree.

`runtime-trees/` is a local development cache, separate from the existing CAS
retention/rollback graph. Current CAS garbage collection does not reclaim
these directories. Remove an unused private store as a unit; automatic tree
cache reclamation and launch-time lease integration are follow-up work.

## Evolution

`schemaVersion` is a decimal `major.minor` string. A new major version may be
incompatible. A minor version is additive only; `requiredFeatures` names any
new semantics that an older reader cannot ignore. Readers reject unsupported
major versions and unknown required features. They never silently reinterpret
an old package.
