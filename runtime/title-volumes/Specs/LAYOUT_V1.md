# Layout, registry and ownership v1

Author: Timur Isaev

## Durable identities

The package adopts doc 04 §9.2 and content-store's convention:

```text
metadata/title-volumes/registry.json
metadata/title-volumes/registry.lock
metadata/title-volumes/leases/<volume-id>
volumes/<game-id>/payload/<build-id>/
volumes/<game-id>/saves/
volumes/<game-id>/settings/
volumes/<game-id>/caches/<epoch>/
volumes/<game-id>/sessions/<session-id>/
```

The payload parent is reserved for the storefront; this package does not install
or delete game payloads. It never modifies content-store metadata, generations,
objects or references. Game IDs and scope IDs are lowercase ASCII identifiers,
bounded to 128 bytes; this prevents case aliases on default APFS.

Registry rows implement the semantics of Appendix E's `volumes` table: game,
kind, root-relative path, independent generation, quota and backup policy. A
save/settings volume ID hashes game + kind; a disposable volume additionally
includes its epoch/session. Runtime generation is deliberately absent from
persistent identity. The versioned registry is a bounded, checksummed JSON
document, replaced with write/fsync/rename/directory-fsync under an OS file lock.
The checksum detects corruption; it is not authentication against the owner.

Open never guesses an empty registry after corruption or deletion. Interrupted
initial bootstrap before the first registry publication fails closed and needs
explicit operator recovery. Created but unpublished empty layout directories
can be adopted by a repeat `createTitle`; registry state remains authoritative.

## Filesystem boundary

The configured root is a trusted canonical absolute path. Every component is
opened without following symlinks. All later operations are relative to open
directory descriptors. Descendant mounts, symlinks, multiply-linked files,
special files, foreign ownership, group/other-readable managed files and
non-private managed directories are refused. Shared content-store container
directories may be owner-writable 0755; title directories remain 0700.

Paths use NFC components, reject traversal and Windows-reserved names, and
detect case aliases. The traversal budget is 32 levels and 10,000 entries.
Regular file fingerprints stream SHA-256 instead of loading arbitrary trees
into memory. Root/configuration and metadata are host-service-owned; an
untrusted guest must never receive their handles or permission to reparent a
title root. This is a storage library, not a replacement for the filesystem
broker's Windows sharing rules and access authorization.

## Quotas and sessions

Quota checks precede managed writes, include all files in the selected volume,
and reject an already over-quota tree. They never delete saves or settings.
These are library/broker quotas, not APFS filesystem-enforced quotas: consumers
must route writes through enforcement or audit direct guest writes at a quiet
boundary. An external writer can exceed a quota; `inventory` detects it.

Scratch has an explicit expiry and a process-owned shared lease. Expiry takes
a nonblocking exclusive lease, so a still-running session survives its nominal
TTL. Process death releases the OS lease; expiry can then remove scratch. A
scratch cleanup cannot name a save path. Clean session cleanup and retained
diagnostic export remain caller decisions. There is no diagnostic upload.

All cooperating mutations serialize on one store lock. Live guest writers must
be paused and handles drained before a multi-file snapshot or replacement. A
per-file APFS clone does not provide whole-tree isolation from external writes;
the consumer contract must enforce this quiet boundary.
