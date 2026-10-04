<!-- Author: Timur Isaev -->

# Generation, ingest and lease integrity — 4 October 2026

Issue #106 milestone 1 uses deterministic attacks at production activation
checkpoints. R-021 motivates testing the storage primitives a future
Custom/Certified boundary will depend on. Custom/Certified mode itself is not
implemented here: these results prove substrate integrity, not that policy or
protection against an actor with arbitrary write access to the entire store.

## Reproduced gap and repair

On the original implementation, the `after-verify` hook replaced staged bytes
with a same-length payload whose digest differed. Activation rejected only
after hard-link publication, leaving the corrupt bytes under the claimed CAS
digest. The test failed both its expected `digestMismatch` error and its
independent assertion that the destination CAS path must not exist.

Publication now opens the ingest file with `O_NOFOLLOW`, checks a regular file
and declared length, reads bounded chunks through that one descriptor, verifies
the fresh snapshot's digest, and checks the path still identifies that inode.
It durably stages a private copy in the operation's download directory before
atomically hard-linking that copy into CAS. A retained writable descriptor to
the original ingest inode therefore cannot alter published content. Interrupted
private copies remain in download staging, outside the trusted CAS namespace;
normal recovery removes that operation directory after publication.

Activation's optional capacity guard also reserves one private publication copy:
`publicationScratchBytes` is the largest missing object, and
`activationPeakBytesRequired` adds it to the unique missing CAS byte total.
`additionalBytesRequired` and `requireFits` retain their CAS-only meanings;
activation calls the separate `requireActivationFits`. Tests reject one byte
below that peak before creating a journal, account for duplicate objects once,
and require zero scratch for already-present or zero-byte content. These are
logical content estimates, not a reservation of allocation blocks, metadata,
or space against concurrent writers.

## Exact attack and positive controls

| Attack | Required outcome | Positive control |
| --- | --- | --- |
| Symlink swapped after verification | `missingDownload` for the intended object; no CAS path; external bytes and mode unchanged | Original input recovers the same journal twice |
| Same-length bytes swapped after verification | Exact expected/actual `digestMismatch`; no CAS path or active generation | Original input recovers the same journal twice |
| Changed-length staged bytes | Exact `sizeMismatch`; no CAS path | Original input recovers the same journal twice |
| Empty input | Known SHA-256 empty digest and zero scratch | Empty object activates and validates |
| Writable ingest descriptor retained across publication | Writing hostile bytes through it cannot change CAS or the generation | Published bytes equal the original input |
| Initial descriptor/payload digest mismatch | Exact `digestMismatch`; no journal or CAS object | Valid descriptor/payload succeeds |
| B's generation ID with A's manifest digest | Exact manifest `digestMismatch`; no lease created | Independent A and B leases succeed |
| A's identity with B's lease ID on release | `invalidLease(B)`; both persisted records byte-identical | Releasing A leaves B, then B releases |
| On-disk A lease edited to name B | Exact manifest `digestMismatch` before GC | Restoring the record gives zero-removal GC and the original live lease |

## Reproduction

```sh
swift test --package-path runtime/content-store --filter IntegrityAttackTests
swift test --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
```

The complete package run passed **80 tests** (six new test functions, one with
three attack arguments). The existing process-death matrix passed **37 cases**.
The ordinary existing CI package suite includes these tests automatically;
no workflow or registry entry is added for this milestone. Hosted job timing is
recorded on the milestone PR against the existing 900-second budget.
