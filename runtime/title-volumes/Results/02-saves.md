# Milestone 2 — save archives and conflict-preserving restore

Author: Timur Isaev

Twelve Swift tests (including eleven parameterized snapshot/restore failure
boundaries) pass on native APFS. The clean backup control records two APFS clones
and zero fallback copies, restores exact bytes, and retains the displaced state.
Interrupted snapshot publication leaves live saves unchanged; interrupted
directory replacement recovers exactly the old or new multi-file tree.

Negative controls cover stale restore fingerprints, wrong-title archives, a
planted truncated archive, an active writer lease, backwards policy time and
discovery traversal. Conflict handling preserves both local and incoming
versions. The local tests throw at boundaries; the final milestone adds real
process-kill supervision and the independent content-store lifecycle proof.

The initial milestone's hosted runner self-test correctly caught a missed suite
count update. The declared count was corrected from 56 to 57; no checks were
removed or weakened. Registry registration is covered by the engine self-test.
