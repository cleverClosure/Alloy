<!-- Author: Timur Isaev -->

# Alloy generation leases 1.0

## Purpose

A generation lease is the durable statement that one exact live process may
read a generation and every CAS object named by its manifest. A collector MUST
treat every digest in every live lease as a root even if the corresponding
active, rollback, or candidate reference changes after launch.

Each lease is canonical sorted-key JSON stored as
`metadata/leases/<lease-id>.json` and MUST validate against
[`generation-lease.v1.schema.json`](generation-lease.v1.schema.json). Creation
uses a durable same-directory temporary file, atomic rename, and directory
`fsync`. Explicit release removes the record and `fsync`s the lease directory.

## Identity and stale detection

The holder identity is the process ID plus the process start time reported by
the host kernel. A process ID alone is insufficient because IDs can be reused.
A lease is live only when the current process at that ID has the exact recorded
start time. An unreaped zombie is dead, even though a signal-existence check
may still find its PID.

Wall-clock age MUST NOT make a lease stale. If the holder exists but its start
identity cannot be inspected, collection fails safe and treats the lease as
live. If the process no longer exists, or the ID now belongs to a process with
a different start time, the lease is stale and MAY be removed under the store
lock. Malformed or unsupported lease records are errors, not permission to
collect.

## Acquisition and release

The store validates the selected generation and manifest before writing a
lease. `objectDigests` is the sorted, unique set of every layer digest in that
manifest. A launcher may bind the lease to itself or to the exact PID of a
spawned game process before exposing the generation to it. It releases the
lease after the holder exits. Process death needs no release: the next
collection or lease inspection removes its stale record.

Leases do not authorize an object or generation. Signed release metadata and
the generation manifest remain the authorization sources.

## Evolution

Version 1 readers accept only schema `1.0`. Any semantic change to holder
identity, roots, durability, or stale detection requires a new version and an
explicit compatibility policy. Readers reject unknown versions.
