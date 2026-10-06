# Offline metadata verification v1

Author: Timur Isaev

This is a bounded, TUF-shaped development protocol using the
[TUF role and update model](https://theupdateframework.github.io/specification/latest/).
It is not a TUF wire-compatible client. No delegation graph, mirror/network
fetcher, production root, or stable release authority is implemented.

A separately pinned whole-envelope SHA-256 authenticates bootstrap root bytes.
The root also meets its own Ed25519 threshold. Nine disjoint key sets authorize
root, targets, snapshot, timestamp, revocation, profiles, manifests, release
eligibility and evidence. Root keys alone change these authorizations. Metadata
roles cannot sign artifacts; artifact keys cannot sign update metadata. The
root scope is `development` or `lab` and is invariant across an update.

Every metadata payload contains role, version, UTC expiry and scope. Its
role-specific fields are closed: keys/role rules for root, target records for
targets, exact references for snapshot/timestamp, revocation lists for revocation.
Counters are positive integers at most 2^53−1. Timestamps use whole seconds in
canonical UTC. Root role rules allow 1–32 distinct keys and a feasible threshold;
no key can serve two roles. Schemas are package-local: docs remains read-only.

Timestamp binds the exact snapshot envelope's version, byte length and SHA-256.
Snapshot likewise binds targets and revocation. Targets bind each artifact's
payload type/digest, envelope digest/length, expiry and (for profiles) the
profile ID/revision, which is checked against signed payload fields. Artifacts
still require their own role threshold; metadata authorization is not enough.
Outer-envelope byte changes, including a new signature, require new references.
Canonical payload identities stay stable across signatures.

`TrustStore.bootstrap` requires a new private directory. Subsequent opens never
silently recreate missing state. A 0700 directory and 0600 regular files,
no-follow final components, an advisory exclusive file lock, same-directory
atomic rename, and file/directory fsync serialize durable updates. The pin,
accepted role versions and exact envelope digests, last observed time, latest
verified bundle and cumulative revocations are retained. A lower version fails
`rollback`; changed bytes at the same version or inconsistent references fail
`mixAndMatch`. Expiry at the observation instant fails `expired(role)`. Rolling
the clock back fails `freeze`, including after an observed expiry. Failed
metadata updates can advance the clock but never accepted metadata versions.

Offline verification is allowed only while every role and target remains fresh.
There is no stale grace period. Missing freshness stops new selection; a caller
may explicitly refresh or choose another independently valid candidate. This
is the conservative local resolution of doc 05 §25's open offline policy.

`withVerifier` holds the state lock for the complete consumer transaction. Its
verifier expires on closure exit and cannot be reused as a cached authorization.
A `TrustedPayload` describes that transaction only; consumers must verify again
before a later selection/install/launch. Existing sessions and response to an
already-running revoked process remain session-service policy.

The trust state assumes a trusted caller supplies time and the pinned digest.
It cannot resist a local administrator restoring the complete state directory,
clock and program together. It does not use a trusted online clock, TPM or
hardware monotonic storage. The parent directory must be controlled by the
user; same-user malicious file replacement is outside this prototype's threat
boundary. Corrupt or deleted state fails closed instead of resetting counters.
