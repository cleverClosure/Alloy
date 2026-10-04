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

After repository CI became available, two more full local checks reproduced
the same 2,182 bytes and hash above, including after the final milestone was
rebased onto the separately merged prerequisites. The advertised upstream tips
still match the receipt, all 32 fork-tool and 12 Wine controls passed again,
and the original tested-source manifest still matches the final implementation.
Shared source identities and allowed dirty bytes remain unchanged.

The existing repository CI passed for each preceding milestone:

| Milestone | Hosted run | Result | Job wall time |
| --- | --- | --- | --- |
| FEX inventory (#148) | [37189487259](https://github.com/cleverClosure/Alloy/actions/runs/37189487259) | 25 suites passed | 209s |
| DXMT inventory (#149) | [37203086163](https://github.com/cleverClosure/Alloy/actions/runs/37203086163) | 30 suites passed | 485s |
| Fresh replay (#153) | [37203682645](https://github.com/cleverClosure/Alloy/actions/runs/37203682645) | 30 suites passed | 426s |

These are the existing repository lint, engine self-test, and fast-suite gates;
the fork-specific check remains local-only. The suite count increased because
the independently merged storage-hardening task extended the existing registry.
This task adds no workflow, registry entry, hosted job, or schedule.

The [merge-validation record](../../../tools/fork-inventory/evidence/merge-validation.json)
preserves the continuation checks, source-manifest verification, and preceding
CI receipts. The final milestone [PR #154](https://github.com/cleverClosure/Alloy/pull/154)
also requires its own green CI run; its final result and wall time are recorded
on that PR before #105 is reconciled. #80 remains complete.
