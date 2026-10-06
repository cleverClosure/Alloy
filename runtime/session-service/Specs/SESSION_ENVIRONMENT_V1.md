<!-- Author: Timur Isaev -->

# Synthetic session environments

Milestone 1 of #181 supplies prefix construction and fixed Wine control commands.
It does not yet wire `launch.game`; the existing readiness refusal and
`info.gameLaunchAvailable: false` remain intact.

## Template and reproducibility

A private cache key binds the generation ID, verified runtime tree digest and
`prefix-v1` recipe. A process-shared file lock serializes cold bootstrap and
publication. Wineboot initializes a scratch prefix using the exact runtime's
loader/server, then stops, reboots to settle pending DLL replacements, and stops
again. The runtime generation is never a write destination.

Fresh synthetic hives use fixed initial registry timestamps and runtime-derived
MachineGuid, MachineId and VideoID values. This normalization is limited to new
templates; it is never applied to a user prefix or persistent saves/settings.
Pending replacements reject publication. Default drive links and host user-folder
links are removed. Internal prefix links become relative; runtime file links stay
bound to the verified tree. Files, directories, modes and link targets enter the
template digest, with bounded regular-file reads and no hard links or special
files. A changed cache rejects; it is never silently accepted or repaired.

Every session receives a copy with separate writable inodes. `templateDigest`
hashes the complete normalized template inventory. `prefixDigest` hashes that
digest plus the canonical title-volume drive plan. It is the deterministic
construction identity before guest writes, not a live filesystem checksum: host
mount locations and per-session absolute symlink addresses are represented by the
plan's opaque IDs. Two cold caches on the same host/runtime must produce the same
template bytes; two identical construction inputs must produce the same prefix
digest. File modification times outside the registry are not input semantics.

## Namespace and environment

The supplied title-volume plan must contain C/G/S/T, six required opaque volume
IDs, no host-root mapping, and no unsupported save redirections. Persistent IDs
are resolved against the title registry and their inventories checked before
mapping. S exposes separate saves/settings links; T selects session scratch.
The cache volume is tracked by its identity but is not a guest drive.

C contains the private Windows prefix; immutable runtime files remain in the
verified generation. G is the verified synthetic payload supplied by the caller.
The caller holds both the generation lease and `withSessionLease` for the whole
guest lifetime. The environment is built from an allowlist, with private HOME,
temporary directory and WINEPREFIX, and exact WINELOADER/WINESERVER paths. Parent
Wine, FEX, policy, DYLD and unrelated environment settings are not inherited.
Each distinct prefix creates a separate wineserver namespace.

This development namespace is not an adversarial filesystem sandbox or a quota
broker. C's session-local hive changes are disposable; the read-only runtime
generation is distinct. The driver must verify runtime/payload bytes and actual
bindings before launching. Normal profiles requiring filesystem authorization
retain their unresolved gate. No host Z: drive or implicit folder grant is added.

## Proof

`swift test --package-path runtime/session-service` covers copied-file isolation,
deterministic construction, private mappings, saved bytes, scrubbed environment,
cache tampering and aliased cache roots. The optional full-tier
`runtime-service-environment` suite runs two cold caches against an already
materialized runtime. It verifies the tree before/after, holds a generation lease,
starts two foreground Wine servers, proves stopping one leaves the other alive,
then proves both exact PID/start-time identities are dead.

```sh
ALLOY_SESSION_CONTENT_STORE=/absolute/canonical/private-store \
ALLOY_SESSION_GAME=policy177 \
  python3 runtime/session-service/run-environment-proof.py
```

The proof uses the lab's exclusive host lock, fixed deadlines and fresh private
directories. It does not rebuild or select shared `build-2` and does not install
a system service.
