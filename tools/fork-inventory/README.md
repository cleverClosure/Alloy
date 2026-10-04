<!-- Author: Timur Isaev -->

# Local fork-maintenance gate

This command inventories every retained Alloy Wine/FEX branch and every committed
DXMT instrumentation patch, enforces explicit maintenance ceilings, reproduces a
real upstream replay, and proves the three shared source checkouts stayed intact.
It is local-only: no workflow, CI registry entry, hosted job or schedule is added.

```sh
tools/fork-inventory/check-all.sh --source-root /path/to/third_party/src
```

From the primary checkout, omit `--source-root` to use `third_party/src`. An
isolated worktree normally needs the explicit path to the shared source roots.
Sources remain read-only: no builds, runtime replacement, shared checkout moves,
index refreshes or live DXMT diffs occur. Network access to the three public
upstreams is required; failures are explicit and never relabeled as a fresh run.

## Counts and ceilings

| Inventory | Enforced ceiling | Meaning |
| --- | ---: | --- |
| Wine shared commits | 28 | Union of seven retained branches, not just live HEAD |
| Wine isolated patches | 1 | The #111 repair, not promoted into the shared source |
| Wine total | 29 | Shared IDs plus isolated repair |
| FEX retained commits | 20 | Union of eight retained branches |
| FEX live union | 18 | Seven live branches |
| FEX historical-only | 2 | Superseded MXCSR experiment; retained, not replayed |
| DXMT patch files | 2 | Committed first-party D3D11 patches; no fork-commit walk |

[`bounds.json`](bounds.json) enforces these ceilings in addition to each
inventory's own policy. A new undocumented commit or patch, stale annotation,
changed provenance binding, changed patch bytes, or exceeded ceiling fails the
command. Counted IDs are maintenance inventory, not net patch effects or runtime
support. Annotation classifications remain auditable engineering judgments;
upstreamable ideas do not authorize contributing assisted FEX implementation.

## Dated replay and explicit refresh

The checked-in [upstream receipt](evidence/upstreams.json) records exact freshly
observed tips and dates. The ordinary check fetches/replays those exact tips and
also verifies the remote has not advanced. It fails with
`receipt:upstream_advanced_refresh_required` when a remote tip changes. To update:

```sh
python3 -B tools/fork-inventory/drill.py refresh --source-root /path/to/third_party/src
tools/fork-inventory/check-all.sh --source-root /path/to/third_party/src
```

Review changed evidence before committing it. Refresh never resolves conflicts,
changes shared refs, raises a maintenance bound or updates annotations. A PASS
means the recorded maintenance evidence reproduced and the ceilings held. The
current result contains seven stopped Wine branches and seven stopped FEX
branches; conflicts are findings, so they do not make a reproduced receipt fail.
Each rebase stops at its first conflicting commit; later conflicts are unknown.
DXMT's two patches currently apply cleanly against its recorded fresh tip.

The Git boundary uses private object borrowers and sparse checkouts. Filtered
commit/tree fetches require server capability support. Only metadata-verified
allowlisted regular blob OIDs receive explicit blob fetches; persistent lazy
fetch URLs use a forbidden protocol. The checkout retains partial-clone semantics
without fetching omitted blobs. Fork refs preserve inherited shallow roots and
automatic maintenance is disabled. Recursive submodules and rename detection
are disabled. DXMT headers are guarded before source-object access, with exact
D3D11 paths; excluded source contents are never read or materialized.

## Verification

```sh
python3 -B -m unittest discover -s tools/fork-inventory -p 'test_*.py'
python3 -B -m unittest discover -s spikes/WINE-001/patch-inventory -p 'test_*.py'
```

The controls cover undocumented side commits/provenance, historical membership,
patch-header exclusions and malformed hunks, real conflicting/clean rebases,
filtered fetch and shallow-boundary behavior, source-byte preservation and every
lowered bound. The real FEX policy commit also has conflicting and unrelated-file
upstream controls in each drill. See the [fresh replay report](../../spikes/WINE-001/results/2026-10-04-14-three-fork-upstream-replay.md)
and [combined gate proof](../../spikes/WINE-001/results/2026-10-04-15-fork-maintenance-bound.md).
