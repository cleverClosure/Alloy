# Development root operations

Author: Timur Isaev

`alloy-trust-dev` creates only development/lab roots. It refuses any directory
inside a Git checkout, creates private directories with mode 0700 and raw
Ed25519 private files with mode 0600, and never prints a private value. Initial
roles use two different keys each with a 2-of-2 threshold. This is a local
exercise, not offline custody, a production ceremony or hardware protection.

```bash
swift build --package-path runtime/trust
BIN=$(swift build --package-path runtime/trust --show-bin-path)
"$BIN/alloy-trust-dev" init /private/tmp/my-alloy-development-root
"$BIN/alloy-trust-dev" sign /private/tmp/my-alloy-development-root \
  'application/vnd.alloy.game-profile+json;version=1' /private/tmp/profile.json profile.envelope.json
"$BIN/alloy-trust-dev" timestamp /private/tmp/my-alloy-development-root
"$BIN/alloy-trust-dev" rotate /private/tmp/my-alloy-development-root root
"$BIN/alloy-trust-dev" revoke /private/tmp/my-alloy-development-root profile gp_example 1
```

Copy the printed SHA-256 pin and `1.root.json` through a trusted separate
channel. Never bootstrap from an untrusted download's own advertised digest.
The CLI retains public numbered roots. Consumers call `TrustStore.rotate` with
successive roots, then `refresh` with the latest complete metadata bundle.
Roots must advance exactly one version and meet both old and new thresholds.
Historical expired roots can authenticate the rotation chain; the final root
must be fresh. Scope changes and reintroduction of a persistently revoked key
are rejected. Versions remain monotonic across rotation; the old bundle is
invalidated until a new one is verified. At most 128 root successors are stored;
a larger history requires an explicitly managed new development bootstrap.

Artifact-key replacement requires re-signing affected artifacts and publishing
new target references. Compromised metadata keys are replaced through the root
role. The narrow revocation role can withdraw artifact keys, payload digests,
and profile ID/revision pairs; it cannot revoke the current metadata authority.
Revocations accumulate in local state and cannot be undone by omitting them
from a newer list. Rotation cannot restore a revoked key.

A cached selection carries no lasting authority: every later launch/selection
must reverify against current revocations under the store lock. Withheld updates
are bounded by metadata expiry, not solved by pretending to know a revocation
that has never reached an offline Mac. No offline expiry grace is implemented.

Authoring commands are intended for one local operator at a time; publish only
a complete verified bundle. Interrupted authoring can leave inconsistent files,
which consumers reject by exact metadata references. The CLI retains old local
private files for this disposable drill; it is not a secure key erasure tool.
Remove the disposable directory when finished. No service, cloud account,
release, production key or production root is created.

The repository scan checks tracked/staged first-party paths for private-key
containers, PEM markers, and encoded private-key/seed fields. It proves a planted
key is caught and a public-only field is accepted. It has exactly two pre-existing
compiler TEST-ONLY keypair fixtures allowlisted by complete file hash; changes to
those files invalidate the exemption. No new private key material is committed.
This structural scanner is not a guarantee against arbitrary obfuscated secrets.
