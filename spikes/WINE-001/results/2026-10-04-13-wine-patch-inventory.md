<!-- Author: Timur Isaev -->

# WINE-001 result 13 — bounded committed Wine inventory

**Date:** 4 October 2026

**Issue:** [#80](https://github.com/cleverClosure/Alloy/issues/80)

## Outcome

The [generated inventory](../patch-inventory/INVENTORY.md) covers **28 distinct
shared Wine commit IDs across seven retained local branches**, plus **one**
explicitly isolated #111 patch: **29 maintenance entries**. Those counts are
also the reviewed ceilings; raising any ceiling requires an explicit review
and refreshed evidence. [Result 09](2026-07-24-09-first-rebase-drill.md) now
references the ceiling and the full-drill trigger. This supplies EPIC-006's
bounded downstream-patch inventory evidence. It does not supply a fresh rebase,
rebuild, runtime promotion, or current-upstream compatibility result.

The generator and machine-readable data live under `spikes/WINE-001/patch-inventory/`.
They introduce no CI job or scheduled job and are reusable by #105's later
combined fork inventory/drift procedure.

## Exact committed scope

Shared checkout: `alloy/spike-wine-001` at
`420c70bdcb7615c3dc0395d162f93645f098fe56`.
Cached `origin/master`:
`b41409d9be509207c16d814742ceb8273bc201fc` (commit time
`2026-07-23T22:51:03+02:00`). The common merge-base is
`5bb70f23d1278088d9ea55d44efe7d51f87d35bd`.

| Retained branch (`alloy/` prefix) | Downstream commit IDs |
| --- | ---: |
| `lgpl-substitution-proof` | 22 |
| `spike-wine-001` | 25 |
| `task-12-fault-census` | 24 |
| `task-34-jit-view-protect` | 24 |
| `task-59-ec-delayload-thunks` | 24 |
| `task-65-scaleform` | 25 |
| `task-8-absorb-attribution` | 23 |

An independent metadata-only recount using each branch's merge-base range and
a union of IDs matched all seven counts and **28** unique IDs. Counting only
the current branch would miss `a88236486c9652063c66d5f471d6a19d133fea86`,
`619c4c0e1ed7b0fb964c0b29388ff227a7dadf72`, and
`fbbdf994ccd06598da75133c49c7268fd0d10ee4`. The report preserves branch membership
so those retained maintenance obligations are visible.

Deduplication is by commit ID, not subject or inferred textual equivalence.
`420c70b` and `fbbdf99` remain distinct IDs despite sharing a subject. The
reverted `4d5daa4` experiment and `0ef284d` revert remain two history entries,
explicitly marked; they are not claimed to be two active runtime changes.

## Isolated macOS 27 maintenance

The shared checkout does not contain #111's Wine fix. The separately retained
`alloy/task-111-macos27-runtime` commit
`f0937d595166631dd00eaab31fef4fb5a6f37031` has parent `420c70b` and corresponds
exactly to the first-party `spikes/WINE-001/jit-signal/wine.patch`:

```text
SHA-256 da99584650e1c0a9fe38a31608558f0cd9980968bec63adf0b22437080b48c0f
```

The optional isolated check verified its branch, parent, three changed paths,
and exact committed diff bytes against this digest. The tracked patch and
isolated commit count once, as the single supplement. The default check binds
the tracked patch bytes without requiring that private clone to exist.

## Justification and classification

Every shared commit and the supplement has a human-readable justification and
an exact first-party document/section citation in `annotations.json`. Shared
history has **5 upstreamable candidates**, **3 Alloy-specific integration
changes**, and **20 temporary-pending-X entries**. The isolated patch is another
temporary-pending-X item. The candidate category is an engineering judgment,
not an upstream acceptance or proven portability claim. Temporary entries name
the needed design, diagnostic consolidation, or historical stack cleanup.

The section-existence validator prevents dangling citations; semantic review of
the cited result is still required when changing a classification. No source
checkout edits, new designs for Wine internals, or legal approval claims arise
from this inventory.

## Controls and repeatability

The 12 stdlib tests use invented temporary Git repositories, not the live fork.
The positive fixture contains two independent downstream commits and a third
branch alias: its known answer is two union entries with one per branch. A
separate isolated commit/patch raises the known maintenance total to three;
importing that exact commit into a retained branch keeps the total at three.

Negative controls reject an undocumented side-branch commit, stale annotation,
each exceeded ceiling, either edited generated file, a new alias branch, a
changed cached upstream tip, missing cited heading, malformed policy, duplicate
JSON key, excluded-source path metadata, supplemental patch tampering, and a
wrong isolated diff digest. Write guards reject output inside a source checkout
and output-file symlinks. Dirty/staged/untracked fixture changes leave both the
inventory and its source index/content unchanged.

Real `generate` followed by two `check` runs produced identical committed data
and passed. The optional private correspondence check also passed. The live
checkout's two pre-existing dirty files were reported separately:

```text
 M dlls/ntdll/unix/signal_arm64.c
 M dlls/rpcrt4/ndr_stubless.c
```

Those uncommitted diagnostics are outside this committed inventory. They were
not read for classification, incorporated into counts, or changed. The live
branch, HEAD, local branch refs, index, and those file bytes remained unchanged
across the final validation capture. No guests, builds, upstream fetches, or
shared runtime mutations were performed. The cached upstream ref is explicit;
Issue #105 remains responsible for measuring fresh upstream drift.
