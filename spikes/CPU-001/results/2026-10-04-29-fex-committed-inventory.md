<!-- Author: Timur Isaev -->

# CPU-001 result 29 — FEX branch union and literal provenance inventory

Date: 2026-10-04. Issue: #105, milestone 1.

## Measured inventory

The generated [inventory](../patch-inventory/INVENTORY.md) contains **20 distinct
retained commit IDs across eight branches**, of which 18 belong to the live union
and two are exclusive to the explicitly historical MXCSR WIP branch. All branches
share merge-base `0589d9b872861970b9085f114a261a0885b6ccb6` with cached `origin/main`.
The checked-out `ad942313dca79d32133cceaaf617016821e3b952` branch contains only 12;
a HEAD-only inventory would omit real census and anomaly work.

An independent read-only recount used each branch's merge-base and deduplicated
`merge-base..tip`, rather than trusting generated output. Counts in branch order
are 6, 11, 10, 13, 3, 7, 7, 12; the independent union equals 20. Both metadata captures
preserved the live branch and HEAD. Dirty/staged source bytes are outside this
committed-history model.

## Provenance and classification

Every entry, including administrative commits, is marked assisted. The checker
binds literal committed provenance text in the current, census, anomaly and WIP
branch ledgers. Those branch-local records matter: the current ledger does not
contain the census or anomaly sections. Five entries change only the ledger;
the first policy commit is distinguished from code. Six older code entries are
identified by prose rather than embedded SHAs; the reviewed mapping is explicit.
No missing identifier is invented, and the fork's provenance is not modified.

Justifications cite existing first-party result headings. Classifications remain
engineering judgment; a resolving citation does not prove it. `upstreamable`
means a problem/idea candidate only. The fork's existing policy excludes these
exact assisted bytes from upstream contributions without independent founder
reimplementation.

## Validation and limits

Nine scratch-repository tests cover independent live/historical membership,
branch aliases and staged dirt, seeded undocumented commits, invented provenance,
provenance-only role misuse, all three lowered bounds, missing citation sections,
missing historical refs/assistance labels, deterministic output and branch drift,
and source-output/symlink rejection. The generator and repeat checks pass against
the real fork. The negative controls fail with named reasons rather than empty
counts. The independent recount agrees with all eight branch counts and union 20.

No FEX implementation was read or modified. No build, guest, fresh upstream fetch,
rebase, or runtime promotion is claimed by this milestone. Fresh replay belongs
to milestone 3. No CI job or workflow is introduced.
