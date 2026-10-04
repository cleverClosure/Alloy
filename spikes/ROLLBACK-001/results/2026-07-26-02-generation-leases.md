# ROLLBACK-001 result 02 — generation leases

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `21136e49b9909349800e2b355076a3c8023a617e`

## Exact claim

`AlloyContentStore` durably records a versioned lease covering the sorted,
unique CAS-object set of one validated generation. A lease held by an exactly
identified live process remains a collection root regardless of wall-clock
age. A lease whose process has exited, or whose PID has been reused by a
different process identity, is removed under the store lock. Explicit release
is durable and idempotent.

## Implementation

- `Specs/LEASES_V1.md` defines acquisition, release, durability, process
  identity, stale detection, and fail-safe behavior.
- `Specs/generation-lease.v1.schema.json` fixes the persisted JSON contract at
  version 1.0.
- A holder identity combines PID with kernel-reported process start time, so
  PID reuse cannot keep a dead holder's lease alive.
- Kernel process inspection identifies an unreaped zombie as dead immediately;
  `kill(pid, 0)` is not used as a liveness substitute.
- Liveness uncertainty protects data: a process that exists but cannot be
  inspected is treated as live. Wall-clock age is forensic metadata only.
- Malformed and unsupported lease records stop inspection/collection rather
  than granting permission to delete.
- Readers enforce the schema's exact top-level and holder key sets. Collection
  also requires `objectDigests` to equal the validated manifest's exact set.

## Both-direction controls

The lease suite proves:

1. acquisition records canonical sorted-key JSON with every unique object
   digest, and explicit release removes the record;
2. a record with an epoch creation timestamp and the current live process
   remains a root;
3. the same PID with a different recorded start time is stale;
4. unsupported versions and schema-invalid extra properties fail closed;
5. a real `posix_spawn` child is bound through the public holder-PID API and
   protects its generation while that child remains alive;
6. after that child exits, its unreaped zombie is stale before `waitpid`, and
   the next scan removes the lease without an explicit release.

The live and dead controls exercise opposite outcomes through the same
process-identity decision path.

## Reproduce

```sh
swift test --disable-sandbox --package-path runtime/content-store
```

Gate 2 consumes the same live-lease digest set as a mark-and-sweep root.
