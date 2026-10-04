# WINE-001 result 09 — first rebase drill: 16 commits, zero conflicts, 2 seconds

**Author:** Timur Isaev
**Date:** 24 July 2026
**Fork:** `alloy/spike-wine-001` (16 commits over base `5bb70f2`) · **Upstream:**
wine master `b41409d` (8 new commits at drill time)

## What was drilled

The status row held "rebase drill awaits a newer official Wine master." Upstream moved
(8 commits: cldapi stub, avifil32, winhlp32, server event initial state — 22 files,
none overlapping ours). Drill executed in a scratch `git worktree` — never the live
checkout that build-2 compiles from:

```text
git worktree add <scratch> alloy/spike-wine-001 --detach
git rebase origin/master        # Rebasing (1/16) ... Successfully rebased
wall-clock: 2 s, conflicts: 0
```

All 16 fork commits — ARM64 ID regs, x18 TEB contract, MAP_JIT, shear census, EC
entry redirect, the x18 backstop family, and the winemac DXMT interop table — replay
cleanly onto current master.

## Why no rebuild this time, and when one is required

Upstream's delta touches zero files in common with the fork (verified by diffstat),
so the rebased tree's build output can only differ in four unrelated modules; a
40-minute rebuild would verify nothing the diffstat hasn't. **Trigger for a full
drill (rebase + rebuild + corpus rerun): any upstream delta that touches
`dlls/ntdll/`, `dlls/winemac.drv/`, `dlls/win32u/`, the loader, or exceeds ~200
commits.** The mechanics (worktree isolation, stack replay, timing) are now proven;
the standing risk is conflict *content*, which scales with upstream overlap, not
with time.

### Inventory ceiling added 4 October 2026 (#80)

The generated [Wine inventory](../patch-inventory/INVENTORY.md) now covers all
retained `alloy/*` branches, plus the separately maintained #111 patch. Its
reviewed ceiling is **28 distinct shared commit IDs + 1 isolated patch = 29
maintenance entries**. Reverted history stays counted; this is a conservative
history/replay bound, not a count of active runtime differences. The checker
enforces all three limits and rejects undocumented commits or changed generated
output. [Result 13](2026-10-04-13-wine-patch-inventory.md) records the branch union,
classifications, and positive/negative controls.

**Additional full-drill trigger:** exceeding any inventory ceiling, or changing
the reviewed patch set, branch tips, or upstream baseline so the inventory check
fails, requires an isolated rebase + rebuild + baseline-corpus rerun before
accepting new runtime compatibility evidence. Stop, classify the change, and
review the annotations/bound; do not merely regenerate a larger count. A report
format/citation correction or a branch alias with identical commit membership
can be documented as inventory-only after review, because it introduces no new
patch stack. #105 owns the next fresh upstream drift drill. A drill and runtime
promotion remain separate actions: the #80 inventory performs neither and does
not modify the shared Wine checkout or build-2.

The 16-commit, zero-conflict July result above is historical. It does not certify
the current 28-commit union or the isolated macOS 27 fix against fresh upstream.

## Standing drill recipe

1. `git fetch origin master` in `third_party/src/wine` (never rewrites the branch).
2. Worktree + detached rebase as above; count conflicts; on conflict, resolve in the
   worktree only and record per-commit notes.
3. On trigger-level deltas: configure + build in the worktree, run the baseline
   corpus against it, then fast-forward the real branch only after green.
4. `git worktree remove` — the live tree and build-2 stay untouched throughout.
