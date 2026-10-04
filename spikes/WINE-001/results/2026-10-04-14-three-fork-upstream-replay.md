<!-- Author: Timur Isaev -->

# Fresh three-fork upstream replay — 4 October 2026

The mechanized replay fetched current upstream metadata and the explicitly
allowlisted regular blobs required for the retained Wine/FEX patches and the
committed DXMT patch files. It rebased all seven live Wine branches and all seven
live FEX branches in private sparse repositories. Both DXMT patches were checked
together against the fresh upstream tip. No runtime was built or launched.

| Fork | Fresh upstream | Result |
| --- | --- | --- |
| Wine | `455e3509b98a6919fd4ad1def4803e08c41c03b2` | 7/7 branches stop at their first commit; one unmerged path at each stop |
| FEX | `3648ee97e8354bb2e6757da8bdb00c48439a561d` | 7/7 live branches stop at their second commit; two unmerged paths at each stop |
| DXMT | `fb4515681daefb789a4d0f403c4bdbca88f3b3de` | Both committed D3D11 patches apply cleanly together |

Wine stops at `0e693a03c13706c1837d6e543d29350d51d80c1c`, with
`dlls/ntdll/unix/virtual.c` unmerged. FEX successfully replays one commit, then
stops at `635922cfa7734e9869ea2ae97667e953310e5590`, with
`FEXCore/Source/Interface/Core/CPUBackend.cpp` and
`Source/Windows/Common/JITGuardPage.h` unmerged. These are **first stopping
conflicts**, not a count of all conflicts that resolving the complete stacks
would reveal. The per-branch report records every unattempted commit.

The superseded FEX `alloy/task-7-mxcsr-wip` branch remains in the inventory as
historical and is not replayed. Wine's isolated #111 patch remains counted; its
upstream application is blocked by the preceding shared Wine stack conflict.
No attempt is made to count it as clean by applying it directly to bare upstream.

The raw [drill report](../../../tools/fork-inventory/evidence/drill.json) binds
all input inventories by SHA-256 and records exact original commit identities,
first stops, controls and shared-checkout preservation. The [upstream receipt](../../../tools/fork-inventory/evidence/upstreams.json)
records anonymous remote URLs, observation times and upstream commit times.
This replaces the old July result's compatibility numbers for these current tips;
[the historical result](2026-07-24-09-first-rebase-drill.md) remains an account of
its original observation.

## Controls and repository boundaries

The actual retained FEX policy commit is replayed against two scratch upstreams.
A deliberately conflicting first line in its provenance file produces exactly
that conflict; an unrelated upstream file replays cleanly. Eight unit controls
also cover real Git conflict/replay, missing-object rejection and an actual local
filtered upload-pack whose omitted upstream blob stays absent while the complete
fork stack replays cleanly.

The initial attempts failed during Git setup, before trustworthy replay evidence:
partial-clone connectivity and explicit-blob negotiation needed separate handling,
and an inherited shallow boundary disappeared from an unreferenced private cache.
The final implementation retains the fork refs, disables automatic maintenance,
and preserves filtered-object bookkeeping in the sparse replay checkout. A known
object-graph failure is rejected even if an unmerged path also exists; it cannot
be relabeled as a conflict finding.

Commit/tree fetches require an advertised filter capability and use `blob:none`.
Exact regular-blob OIDs are verified from allowed path metadata before an explicit
blob fetch; no tree closure is requested in that step. Lazy fetching is disabled
and persistent promisor URLs use an explicitly denied protocol. Recursive
submodule fetching and rename detection are disabled. DXMT headers are guarded
before any source-object access; only the exact D3D11 allowlist materializes.
Excluded source contents are never read, fetched or materialized.

All three shared branches, HEADs, refs, index hashes and non-excluded dirty-file
bytes matched before and after the run. The existing excluded DXMT deletion is
observed only as path/status metadata. The primary checkout and shared runtime
remain untouched. This is patch-maintenance evidence, not runtime compatibility
or permission to upstream assisted implementation bytes.

Run `python3 -B tools/fork-inventory/drill.py refresh --source-root /path/to/third_party/src`
to advance the dated receipt. `check` replays that receipt and also requires that
the currently advertised tips still match; upstream movement requires an explicit
refresh and review. No workflow, job or schedule is added.
