# Durable scheduler and host resource lease

Author: Timur Isaev

## Submission and lifecycle

```sh
python3 tools/lab/lab.py submit /private/tmp/my-lab spikes/LAB-001/scenario-v1.json --priority 10
python3 tools/lab/lab.py work /private/tmp/my-lab --drain
python3 tools/lab/lab.py status /private/tmp/my-lab
python3 tools/lab/lab.py cancel /private/tmp/my-lab JOB_ID
python3 tools/lab/lab.py recover /private/tmp/my-lab
```

The root is an owned 0700 directory. The queue uses SQLite WAL, FULL synchronous
commits, short immediate transactions and versioned schema. Each submission
stores the complete validated definition, its canonical digest, original source
digest, host-selected input/runtime roots, priority, absolute UTC deadline and
control label. Editing a queued definition without its digest is detected. No
scenario or raw result is silently replaced on resubmission.

Higher priorities run first; equal priorities use submission time and job ID.
Admission is non-preemptive. Separate `work` processes provide concurrency; one
`work --drain` process consumes jobs sequentially. Cancellation of queued jobs
and deadlines before admission make no execution claim. An admitted attempt is
durably recorded before its worker starts. Cancellation, elapsed execution
limits, absolute deadlines, output caps and nonzero exits retain named failures.
The default retry limit is zero; the [retry policy](EVIDENCE_STORE.md) retains every
attempt and never upgrades a failed history into a pass.

A job lease protects the ownership transition and worker lifetime. Queue recovery
uses the lease, not the apparent liveness of a potentially reused PID. A RUNNING
row whose lease is free becomes INTERRUPTED, retaining its attempt and failure.
Recovery never marks an abandoned claim completed. An explicitly configured retry
may enqueue another attempt, while retaining the interruption in job history.
A crash after claim but before spawn therefore remains visible without inventing
an evidence record for an execution that was not observed.

## Host-wide shared/exclusive resource

All CLI instances, independent queue roots and worktrees use the fixed location
`/private/tmp/alloy-lab-host/resource.lock`. Timing scenarios take an exclusive
`flock`; functional scenarios take a shared lock. The admission gate prevents
new shared entrants from continuously overtaking an exclusive waiter. Exclusive
work waits for all earlier shared work; functional work can overlap functional
work. Tests may inject private lock roots through the internal Python API to
isolate fixtures; the public CLI has no namespace override.

The host directory and files are owned/private and symlinks or unsafe lock files
are refused. Another user cannot create a second per-user namespace by invoking
this CLI: inaccessible ownership fails closed. This is a cooperative local-user
host lock, not an OS scheduling authority or privileged multiuser service.
Participants that never take it are outside its coverage.

Other agents and heavy work use:

```sh
python3 tools/lab/lab.py lock-check --mode exclusive
python3 tools/lab/lab.py lock-run --mode exclusive --timeout 3600 -- your-build-command arguments
```

`lock-check` is a snapshot (0 available, 1 occupied); it does not reserve a future
interval. `lock-run` holds the lease over the command and its cleanup. Use it for
runtime builds and corpus runs that must not corrupt a timing measurement.
`shared` is available for non-timing functional work. External command logs are
bounded at 8 MiB per stream and forwarded on completion; scenario logs are bounded
at 64 KiB per step/stream (1 MiB for Wine traces). All process lifetimes have explicit time limits.

## Process death and cancellation

The scheduler passes its job and host lock descriptors to a separate worker and
keeps the write end of a parent-liveness pipe. The worker owns the read end and
supervises each child in a new process group. A scheduler SIGKILL closes the pipe;
the worker notices EOF, terminates the owned group, retains interruption evidence,
performs teardown, publishes the attempt and releases the final lock copies.
Closing one descriptor never explicitly unlocks another inherited copy.

The child also inherits the leases: an unexpected worker loss cannot immediately
admit overlapping work while a surviving child retains them. A remaining lease
is treated as occupied, not cleared on a PID heuristic. Direct arbitrary worker
SIGKILL or a trusted program deliberately escaping its process group may require
owned-process cleanup; this is not an adversarial process sandbox. The scheduler-
death proof exercises the supported parent-loss cleanup path. Guest adapters must
also clean their private daemon/prefix resources before returning their lease.

Teardown still runs after a failed step, with at most three seconds per teardown
step (32 steps maximum). A missing worker result is an interruption, never proof
of completion. Queue corruption or a refused environment does not become a pass.
Checksums identify local evidence; they do not authenticate a hostile host account.

## Controls

Real concurrent subprocesses prove disjoint timing intervals and shared functional
admission through a two-process barrier. The interval detector rejects a planted
overlap. Killing a scheduler during a heartbeat-producing child must stop that
heartbeat, publish INTERRUPTED and permit a subsequent clean job. Killing after
the durable claim must recover exactly one interrupted attempt, never a retry.
Additional controls cover priority, queued and running cancellation, queued and
running deadlines, step timeout, output flooding, runtime mismatch without launch,
queue digest corruption, v1/v2 execution and the public CLI's occupied/free result.
