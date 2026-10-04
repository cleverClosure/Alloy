<!-- Author: Timur Isaev -->

# DXMT committed patch inventory and exclusion guard

[inventory.json](inventory.json) inventories the **two committed first-party
patch files** under `spikes/GFX-001/instrumentation/`. DXMT's retained
`alloy/task-11-metrics` branch equals cached upstream: a commit-history-only
inventory would incorrectly report no maintained changes. The generator enumerates
all retained Alloy refs and fails if a branch introduces unreviewed fork commits.
The live checkout's uncommitted deletions and modifications are outside this model;
no `git diff`, `git log -p`, source-wide search or live source file read occurs.

```sh
python3 -B tools/fork-inventory/dxmt_inventory.py check --dxmt /path/to/dxmt
python3 -B tools/fork-inventory/dxmt_inventory.py generate --dxmt /path/to/dxmt
python3 -B -m unittest discover -s tools/fork-inventory -p 'test_dxmt_inventory.py' -v
```

`ALLOY_DXMT_SOURCE`, `--annotations` and `--output` are available. Patches are read
from Alloy's committed HEAD and checked against their working copies and pinned
SHA-256 values. The reviewed sidecar declares the exact base of patch 0001 from
result 06's measured input table because that patch lacks an embedded base header;
patch 0002 declares the same base in its own preamble. Neither patch is edited.
Each declaration's exact literal and each classification's evidence heading are
checked. Classification is engineering judgment, not upstream acceptance.

## Boundary before materialization

The parser checks every `diff --git`, `---` and `+++` path before reading any
DXMT target blob. It rejects excluded path components (`d3d12`, `vkd3d*`), traversal,
quoted/ambiguous paths, renames/copies, binary patches, symlinks and submodules.
This patch model permits only regular files under `src/d3d11/`, and additionally
requires the exact per-patch path allowlist in the reviewed policy. The two real
patches touch seven distinct files, of which one is new.

Each base apply-check creates a private Git repository/index borrowing existing
objects read-only. A non-cone sparse checkout at the exact base commit selects
only approved paths; modes are checked before checkout and actual materialized
files afterward. `git apply --check` runs there and scratch state is removed.
Hooks, global/system Git configuration, submodule recursion and lazy fetching are
disabled in scratch commands. This stage performs no network access. No excluded
source blob is read, copied, displayed or written. The live index and refs are not
modified. The guard is a concrete path boundary, not a legal certification.

## Controls and limits

The two real base apply-checks pass at
`e520fea415ba4b82b0c346dae77bbb1be4897453`. Eleven tests use inert original fixtures:
valid application with unchanged source, wrong context and malformed hunks,
excluded paths rejected before repository access, secondary-header and orphan unified-diff bypasses,
traversal and ambiguous paths, rename/copy/binary/mode attacks, duplicate/mismatched
headers, source symlinks, new regular files, and deterministic output drift.
A seeded `src/d3d12/fake.cpp` path is only a string in a synthetic patch and is
rejected before any such file can exist. No excluded implementation is used.

The bound is two patch files. A new file, changed bytes, unexpected branch
history, moved base declaration or allowed path, failed base application, and
stale generated output require reviewed regeneration. This is a cached-base
applicability check, not fresh-upstream compatibility or a build/runtime test.
The generalized fresh replay arrives in the next milestone. No CI job is added.
