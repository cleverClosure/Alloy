<!-- Author: Timur Isaev -->

# Committed Wine downstream inventory

Issue [#80](https://github.com/cleverClosure/Alloy/issues/80) makes the retained
Wine maintenance burden explicit. [INVENTORY.md](INVENTORY.md) is the readable
generated report; [inventory.json](inventory.json) is the equivalent data for
later drift tooling. [annotations.json](annotations.json) is the reviewed input.

The current ceiling is **28 shared commit IDs, two supplemental patches, and 30
total maintenance entries**. All three limits are enforced independently.
The full-drill trigger in [result 09](../results/2026-07-24-09-first-rebase-drill.md)
references this ceiling. [Result 13](../results/2026-10-04-13-wine-patch-inventory.md)
records the real inventory and validation.

## Counting contract

The generator enumerates every local `refs/heads/alloy/` branch in the supplied
Wine checkout, subtracts the entire ancestry of cached `origin/master`, and
unions the remaining commit IDs. It records branch tips, a unique merge-base,
per-branch membership, commit parents, subjects, and changed path names. A shared
commit retained by several branches counts once. A separate commit ID with the
same subject still counts separately: textual patch equivalence is not assumed.
Reverted experiments and their revert commits remain visible history entries,
with explicit status; the total is a conservative history/replay burden, not a
count of active behavioral changes. Empty and merge commits require review
instead of being silently skipped.

All seven retained branches are currently covered, including the task-12 census
and task-59 delay-import branches absent from the current checkout's ancestry.
Remote tracking branches other than `origin/master`, reflogs, deleted branches,
uncommitted/staged contents, and untracked files are outside this committed
inventory. Tracked dirty path names are reported separately on stdout and never
affect generated output. No shared source file contents are read by the normal
inventory path; changed path names come from commit metadata.

The committed first-party `jit-signal/wine.patch` for #111 is an explicit
supplement because its exact isolated Wine commit is absent from the shared
fork. Its SHA-256, commit, parent, branch, paths, and citations are pinned. The
patch and matching isolated commit represent **one** item. If that exact commit
later appears in a retained shared branch, it counts in the shared union and
ceases to count as an extra supplement; branch/output changes still require a
reviewed regeneration. A cherry-picked equivalent with a new ID requires a
manual annotation/supplement update. This report does not install #111 or claim
that the shared runtime includes it.

Issue #177 adds `policy-probe/wine-v2.patch` as the second explicit supplement.
It pins the v2 loader integration without rewriting the shared live policy
commit or disturbing unrelated dirty files. The one-item increase and eventual
folding plan are documented in the [v2 contract](../policy-probe/SNAPSHOT_V2.md).
Both supplements are included in the combined inventory and replay evidence.

## Regenerate and check

Python 3.9+ and Git are the only dependencies. From the Alloy repository root:

```sh
export ALLOY_WINE_SOURCE=/Users/cleverclosure/Developer/Alloy/third_party/src/wine
python3 -B spikes/WINE-001/patch-inventory/inventory.py check
python3 -B spikes/WINE-001/patch-inventory/inventory.py generate
python3 -B spikes/WINE-001/patch-inventory/inventory.py check
python3 -B -m unittest discover -s spikes/WINE-001/patch-inventory -p 'test_*.py' -v
```

Use `--wine PATH` to override the environment. The checkout must remain on the
agreed live `alloy/spike-wine-001` branch. `generate` writes only `inventory.json`
and `INVENTORY.md` in this directory, or in an explicit `--output DIR`; it rejects
destinations inside either supplied source repository and output-file symlinks.
`check` regenerates in memory and compares both committed files byte for byte.
Neither command fetches, checks out, rebases, builds, launches Wine, changes
source files, or refreshes a shared index. Git optional locks and fsmonitor are
disabled. Tests create and mutate only temporary fixture repositories.

On the machine retaining #111's private checkout, verify exact correspondence:

```sh
python3 -B spikes/WINE-001/patch-inventory/inventory.py check \
  --isolated-wine /private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/wine-source
```

This additional check verifies the named private branch, parent, and changed
paths, then hashes the allowed committed diff and compares it to the pinned
first-party patch. It does not expose diff contents or inspect excluded sources.
The default check needs only the shared Wine checkout and tracked Alloy patch;
it makes no claim to re-verify an absent private clone.

## Annotation and failure contract

Each commit has a justification, history status, and at least one exact heading
in a first-party result or patch document. The checker verifies the section
exists. The explanation and classification remain engineering judgments reviewed
against that evidence; heading existence does not prove the judgment. Categories:

- `upstreamable`: a candidate with a portable correctness rationale, not an
  upstream submission, acceptance, or portability proof.
- `Alloy-specific`: an intentional downstream integration contract.
- `temporary-pending-X`: a retained workaround/diagnostic with a named retirement
  condition, including historical experiments awaiting eventual stack cleanup.

Undocumented or stale commits, missing evidence sections, changed supplemental
patch bytes, bound growth, output drift, unexpected checkout, ambiguous merge
bases, and changing source refs during capture all fail with a named reason and
nonzero exit. Changing even a branch alias or the cached upstream tip changes
the report and fails the old committed-output check. A bound may be raised only
through an explicit reviewed annotation/bound change with regenerated evidence;
it is not a silently expanding target.

The report pins a **cached** upstream ref; it provides no freshness guarantee or
new compatibility evidence. #105 owns a fresh fetch/replay and combined
Wine/FEX/DXMT drift procedure. No CI or scheduled job is added here. The retained
July result09 replay remains historical evidence for its 16-commit stack only.
