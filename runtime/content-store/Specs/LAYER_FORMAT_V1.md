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
MUST enumerate every entry below `files/`, including its normalized relative
path, type, mode, size, and SHA-256 digest. Its canonical CBOR profile and the
tree-digest algorithm remain a required extractor deliverable; clients MUST
reject rather than guess when either is unsupported.

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

The current library implements steps 1, 2, and durable CAS publication. It
materializes the verified package object into an ordered generation view. The
secure extractor implementing steps 3–8 is a separate EPIC-003 component and
MUST preserve this v1 contract.

## Archive safety

An extractor MUST reject:

- absolute, empty, `.` or `..` paths;
- path traversal after Unicode and separator normalization;
- duplicate normalized paths and case-fold collisions;
- device nodes, sockets, FIFOs, setuid/setgid bits, and unexpected ownership;
- hard links or symlinks escaping `files/`;
- sparse or expanded data beyond declared resource limits;
- undeclared entries or file-table mismatches;
- native code whose Developer ID signature does not validate.

Extraction occurs in a private staging directory. A partial or unsealed tree is
never eligible for a generation reference.

## Evolution

`schemaVersion` is a decimal `major.minor` string. A new major version may be
incompatible. A minor version is additive only; `requiredFeatures` names any
new semantics that an older reader cannot ignore. Readers reject unsupported
major versions and unknown required features. They never silently reinterpret
an old package.
