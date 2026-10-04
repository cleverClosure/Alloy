<!-- Author: Timur Isaev -->

# Committed FEX maintenance inventory

[INVENTORY.md](INVENTORY.md) and [inventory.json](inventory.json) are generated
from every retained local `alloy/*` branch, subtracting cached `origin/main`.
They reuse the Wine inventory's Git metadata, citation, path and bound helpers.
The conservative ceiling is **20 retained commit IDs, 18 live IDs, and two IDs
reachable only from historical `alloy/task-7-mxcsr-wip`**. All three are enforced.
The WIP branch remains visible but is excluded from the later live replay drill.

```sh
python3 -B tools/fork-inventory/fex_inventory.py check --fex /path/to/fex
python3 -B tools/fork-inventory/fex_inventory.py generate --fex /path/to/fex
python3 -B -m unittest discover -s tools/fork-inventory -p 'test_fex_inventory.py' -v
```

`ALLOY_FEX_SOURCE` supplies the default checkout path. The shared checkout stays
on `alloy/task-8-dispatcher-teb`. These commands never fetch, build, launch guests,
modify the fork or refresh its index. Uncommitted/staged contents are excluded.
`generate` writes the two generated files here; `check` compares bytes in memory.
`--annotations` and `--output` allow reviewed policies and scratch drift checks.
Output within the source repository and output-file symlinks are rejected.

Every ID is conservatively marked assisted, including five provenance-only
commits and the initial fork-policy commit. Code commits bind a literal entry
in committed `PROVENANCE-ALLOY.md`; administrative commits bind the introduction
or section they record. The checker restricts provenance-only roles to commits
changing that single file. It reads the committed ledger at named retained refs,
including census and anomaly side branches absent from the live ledger, and
records ledger blob IDs and SHA-256 digests. Six older code entries have no SHA
in their original text: their subject-to-literal mappings are reviewed annotation
inputs, not a claim that the old ledger contained identifiers it did not contain.

Unknown commits, absent literals, missing citations, stale annotations, missing
historical branches, ambiguous merge bases, drift and ceiling growth fail closed.
A seeded new commit fails as `provenance:undocumented_commit`; an annotation with
an invented literal fails as `provenance:undocumented_entry`. Literal matching
checks traceability, not authorship or the quality of a classification. No source
provenance record is rewritten. `upstreamable` labels only a problem/idea candidate:
**the exact assisted changes require independent founder reimplementation before
upstream contribution**, per the existing fork exception.

Counts represent retained history and administrative/replay burden, not twenty
active runtime changes. This inventory pins cached upstream metadata; it does
not itself claim fresh compatibility. See [result29](../results/2026-10-04-29-fex-committed-inventory.md).
