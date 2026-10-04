<!-- Author: Timur Isaev -->

# Real APFS disk pressure — 4 October 2026

Issue #106 milestone 2 uses a private **128 MiB sparse APFS image**, attached
under a unique scratch directory. The filler checks the mounted filesystem,
exact mount point and volume size before writing; its byte bound is 256 MiB.
It writes real bytes until the kernel reports ENOSPC, including progressively
smaller writes to consume the final allocation space. It never fills the host
volume. Every subprocess is bounded; the image is detached and deleted in
cleanup. A cancellation control runs through the actual test-all supervisor
(TERM, registered 15-second grace, group KILL) and verifies both mount and scratch
image disappear for direct mount lookup and exact-image inventory lookup (the
partial-attach cleanup path). Server termination, lookup and detach share one
monotonic 12-second deadline, below the supervisor grace. The shell execs its Python owner so cleanup gets that grace. Hosted macOS detach exceeded the initial local-only subsecond budgets; the suite now
has an explicit cleanup allowance while all other suites retain three seconds.
No sudo, guest runtime, external server or real Steam payload is used.

The [injected results](2026-10-04-disk-pressure-injected.json) contain **5 PASS,
0 FAIL, 5 ENOSPC-path failures**. The [disabled control](2026-10-04-disk-pressure-disabled.json)
contains **5 PASS, 0 FAIL, 0 ENOSPC-path failures**. The latter follows the same
handshakes and recovery checks with filling disabled. Diagnostics retain the
actual errors, with scratch roots and process addresses replaced for portability.

| Point | Observed rejection | Independent recovery check |
| --- | --- | --- |
| Transport after a persisted streaming chunk | Partial-download write, errno 28 | No object published; same operation resumes and replays as verified existing bytes |
| After CAS publication, before generation materialization | Cocoa out-of-space wrapping POSIX errno 28 | Old active manifest/bytes/saves remain valid; same journal recovers twice to the complete new generation |
| Catalog rows reconciled, immediately before transaction commit | SQLite `SQLITE_FULL` (13) | Complete active generation remains valid independently of SQLite; reopen/recover twice rebuilds or reconciles a consistent catalog |
| Fingerprint scan candidate, before output persistence | Atomic output temporary creation, errno 28 | Read-only scan still matches the known one-file record; previous fingerprint stays byte-identical; retry persists exact expected bytes |
| Synthetic invalidation cache publication | Temporary-file open, errno 28 | No partial JSON published; retry creates one canonical record and replay returns it without another record or leftover temporary |

The catalog injection intentionally occurs inside the transaction, after row
reconciliation, so it observes the actual commit write failure. Filling before
database open instead produces SQLite's less-specific `CANTOPEN`; that exploratory
case is not counted as the catalog-write proof.

The scanner itself is read-only and has no cache write to exhaust. Its row above
exercises the real fault-probe scan/output pipeline; the second identity row
exercises production `InvalidationStore.emit`. Synthetic file bytes and manifests
are constructed locally. The selector's currently required anchored executable
filename is used as a filename only; its payload is `synthetic bytes`.

## Reproduce

```sh
runtime/content-store/run-disk-pressure-matrix.sh
```

With no arguments, the wrapper proves cancellation cleanup, then runs injected
and disabled variants. `--selftest-cleanup` runs only the cleanup control. Explicit
`--json PATH` records one variant; `--negative-control` selects the disabled one.
`--skip-build` requires existing binaries. The registered fast suite
`content-store-disk-pressure` runs both variants inside the existing CI job,
with a 300-second bound. The complete local registered run took 16.0 seconds,
reported selected=1/reported=1, and left no attached image. Hosted job timing is
recorded on the milestone PR against the existing 900-second budget.

This is genuine filesystem exhaustion and recovery, not simulated errno
injection. It does not claim resistance to hardware power loss, storage firmware
faults, or concurrent malicious writes to the private store root.
