# Submitting lab, certification and performance work

Author: Timur Isaev

The local queue, v2 evidence store and comparator are ready for synthetic tests
and future certification/performance consumers. They do not certify a real title,
sign evidence, supply Windows reference hardware or create cloud infrastructure.
Windows-reference scenarios have a format slot but the Mac worker refuses them.

## Functional and performance submissions

Author a v2 scenario following [CONTRACTS.md](CONTRACTS.md). Supply immutable input
files, an explicit runtime inventory and stable comparison rules. The original
LAB-001 v1 scenario remains accepted without moving its historical results.

```sh
python3 tools/lab/lab.py submit /private/tmp/my-lab scenario-v2.json \
  --input-root /private/tmp/inputs --runtime-root /private/tmp/runtime --priority 10
python3 tools/lab/lab.py work /private/tmp/my-lab --drain
python3 tools/lab/lab.py status /private/tmp/my-lab
```

Submission returns a job ID. Status exposes lifecycle separately from comparison
classification, every attempt and its immutable record address. Cancel by job ID;
use `--deadline UNIX_SECONDS` to bound queueing plus execution. Retry limits are in
the scenario, default zero. Consumers must use `history_summary.gating_pass` and
retain worst verdict/regression flags; COMPLETED means execution finished, not
that a comparison passed. See [EVIDENCE_STORE.md](EVIDENCE_STORE.md).

For timing observables, set `timing_sensitive: true`. It is mandatory for elapsed
observations and performance comparison. Take eight separate calibration samples,
explicitly freeze their record addresses with `baseline-set`, then run fresh
holdouts with `work --drain --require-clean`. Do not add calibration noise to the
baseline after inspecting a candidate. Functional jobs use a shared lease;
timing jobs use the exclusive host lease. No claim is made about nonparticipating
background processes, frequency/thermal stabilization or statistical confidence.

Every agent running heavy work should participate for the entire operation:

```sh
python3 tools/lab/lab.py lock-run --mode exclusive --timeout 3600 -- your-build-command args
python3 tools/lab/lab.py lock-check --mode exclusive
```

The check is advisory; only `lock-run` reserves the interval. Do not wrap `work`
or the guest proof in `lock-run`: the scheduler already acquires this lease, and
nested acquisition can deadlock. Never remove lock files to recover a worker.
`recover QUEUE_ROOT` uses actual lease ownership and preserves interrupted attempts.

## Wine guest adapter

Select a verified development runtime generation explicitly through
`ALLOY_RUNTIME_GENERATION`, following the runtime-build materializer's verify
procedure. Do not fall back to an arbitrary shared build. On this Mac the old
shared build has the #104/#111 x64 fault-storm risk; the final proof instead used
the verified #176 runtime in an isolated copy. Workspaces and prefixes stay outside
the sealed generation. The lab neither rebuilds Wine/FEX nor changes registration
in another prefix.

The adapter inventories every regular runtime file, including Wine, wineserver,
FEX and bundled libraries/data. Runtime symlinks must first be materialized in a
private copy; missing/extra files and links are refused before and after execution.
The canonical lab inventory digest is distinct from the upstream content-store
manifest and generation digests. Keep the materializer verification when producing
the copy. OS frameworks remain part of the recorded host identity, not this binary
inventory. A checksum match is not production trust or proof against a hostile
account swapping files between checks.

```sh
python3 tools/lab/lab.py wine-scenario \
  --runtime-root "$ALLOY_RUNTIME_GENERATION" --subject /private/tmp/inputs/known-answer.exe \
  > /private/tmp/inputs/scenario-v2.json
python3 tools/lab/lab.py submit /private/tmp/my-lab /private/tmp/inputs/scenario-v2.json \
  --input-root /private/tmp/inputs --runtime-root "$ALLOY_RUNTIME_GENERATION"
python3 tools/lab/lab.py work /private/tmp/my-lab --drain
```

`wine-scenario` generates the bundled known-answer guest's two-observable contract;
adapt its steps and observables explicitly for another subject. It accepts x64 and
native ARM64 PE files. x64 setup registers the selected runtime's FEX in the new
per-attempt prefix. No global/persistent prefix is reused. Each attempt runs bounded
wineboot, registration where needed, guest, server stop and server wait steps.
Teardown runs after failure and parent loss as well as normal completion. The stop
step accepts 0 or 1 because Wine returns 1 when no server remains; wait must return
0 within three seconds. Other failure/timeout results remain failures. Wine traces
are capped at 1 MiB per step/stream; ordinary native scenarios remain at 64 KiB.

The general `expected_exit` field accepts one integer or a bounded unique list of
integers. Actual exit codes remain in evidence and completed records are checked
against those exact allowed values. No error output is erased to force a pass.

Run the complete local real-guest control with explicit inputs:

```sh
export ALLOY_RUNTIME_GENERATION=/private/tmp/verified-runtime-copy
export ALLOY_TOOLCHAIN_BIN=/path/to/llvm-mingw/bin
tools/test-all --only lab-wine-guest
```

It builds the bundled x64 Windows guest, submits actual scheduled work, checks the
mapped FEX image path, and retains the queue/CAS and a `proof.json` under the printed
private evidence directory. Positive controls return answer 42 and sum 21; seeded
controls return 43 and 22 and automatically regress both gates. A wrong runtime
digest must be INCOMPARABLE with zero executed steps. A hanging guest must time out
and leave no selected-runtime process or held lab lease. The full suite skips
honestly when explicit runtime/toolchain inputs are absent. For a native ARM64-only
runtime, invoke `prove-guest.py --architecture arm64` with the same inputs.

The fast tier registers contracts, scheduler, evidence-store and Wine-boundary
controls without requiring Wine. No benchmark, game compatibility, graphics or
production release claim follows from these known-answer controls. The lease is
cooperative, and arbitrary worker SIGKILL or malicious process-group escape still
requires owned-process cleanup as described in [SCHEDULER.md](SCHEDULER.md).
