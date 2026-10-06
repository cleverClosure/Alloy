# Rotation, revocation and private-key controls

Author: Timur Isaev

6 October 2026: all 14 Swift tests (three suites, including the parameterized
role corpus) passed on Apple Silicon. The compromised-key drill replaced both
root and profile-signing keys. Old-only and new-only root successors failed
`belowThreshold`; the cross-signed successor passed. Skipped/replayed roots
failed `rollback(root)` and cross-scope roots failed `wrongRole`. The retired
profile signature failed after rotation; a replacement profile passed after
refresh and reopening persisted state.

A previously accepted profile revision failed `revokedTarget` after withdrawal,
including when a later revocation list omitted it. The next revision passed.
Revoking its signer then failed `revokedKey`, including after reopening state.
An attempted revocation of update-authority keys failed `wrongRole`.

The actual development CLI ran init, artifact signing, timestamp refresh, root
rotation and profile/key revocation in a disposable directory. All 18 initial
keys were 32-byte files with mode 0600 inside a mode-0700 directory. Git-contained
initialization, reinitialization, metadata output collisions, update-authority
revocation and unsafe key permissions were rejected. The directory was removed
after the test; only public diagnostic outcomes were printed.

The first-party key scan passed with no newly committed private material; its
planted PEM and encoded-key controls fired, and its public-only control stayed
clear. The two existing, intentionally public compiler TEST-ONLY keypair files
remain exact-hash exemptions, not development signing identities.
