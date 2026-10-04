<!-- Author: Timur Isaev -->

# Enforced three-fork maintenance bound — 4 October 2026

`tools/fork-inventory/check-all.sh` is the single local entrypoint for the generated
Wine, FEX and DXMT inventories and the real upstream replay. It checks committed
inventory drift, literal provenance bindings, patch-header exclusions, exact
patch bytes and bases, explicit maintenance ceilings, dated upstream identities,
real replay controls and unchanged shared source state. It adds no hosted CI or
scheduled job.

The two consecutive full checks produced **byte-identical 2,182-byte output**:

```text
a542ca82d07407f5f88429cfe548d7ed1ff959e90e1d368341b9b3962332f39e
```

The [combined result](../../../tools/fork-inventory/evidence/combined-gate.json)
records Wine's 28 shared commit IDs plus one isolated patch, FEX's 20 retained IDs
(18 live and two historical-only), and DXMT's two committed patches. Independent
per-branch merge-base/count recounts agree with both deduplicated commit unions,
including the previously missed side branches.

Lowering the combined Wine total ceiling from 29 to 28 made the **actual entrypoint**
exit 1 with this named failure, before upstream replay:

```text
FAIL bound:wine_total_maintenance_items:observed_29:limit_28
```

The negative control and both successful runs preserved the shared branches,
HEADs, refs, index hashes and non-excluded dirty-file bytes. The source snapshot
hash also matches the one captured before the final real drills. The existing
excluded DXMT deletion remains metadata only; no excluded content was inspected.
All 32 fork-tool unit controls and all 12 Wine inventory controls passed, including
separate lowered-bound tests for every ceiling and exact preservation controls.

The [proof manifest](../../../tools/fork-inventory/evidence/combined-proof.json)
binds the final entrypoint files by SHA-256, records the independent recounts,
and includes the actual lowered-bound error. [Usage and boundaries](../../../tools/fork-inventory/README.md)
explain that PASS means reproducible bounded maintenance evidence, not an absence
of conflicts. The [fresh replay](2026-10-04-14-three-fork-upstream-replay.md)
contains seven stopped Wine branches, seven stopped live FEX branches and clean
combined DXMT application. It records only the first conflict reached per branch.
An advanced remote tip fails the ordinary check and requires explicit refresh.

Local implementation and proof are complete. Hosted repository lint/CI before
merging the milestone PRs remains blocked by GitHub account billing. Keep #105
open until the separate milestone PRs pass their normal merge gates; #80 already
completed the Wine inventory work and is not reopened.
