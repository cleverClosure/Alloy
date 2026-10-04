<!-- Author: Timur Isaev -->

# LAB-001 lifecycle capture

`runner.py` executes one scenario through `SETUP → RUN → TEARDOWN → COMPLETED`
or `FAILED`. It creates a fresh output directory, starts one native Python child
in its own process group, bounds its lifetime, collects frames and logs, then
reaps the child. Existing output directories are rejected without changing them.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 spikes/LAB-001/runner.py --output /tmp/lab-run-1
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s spikes/LAB-001 -p 'test_*.py' -v
```

`raw.json` binds the effective scenario definition using SHA-256 of sorted,
compact JSON, separately records the original scenario file's SHA-256, and
records the exact argument array. It retains lifecycle events, return code,
subject counters, and parent-computed digests of the actual PPM bytes. Captured
pixel counts and sums must agree with the subject's stdout metrics. Logs are
drained through bounded pipe reads and never exceed 65,536 bytes per stream.
Pre/post hashes bind the runner, scenario validator, subject and Python binary;
an input changed during execution causes `INPUT_CHANGED`. These are local
observations, not trusted execution attestation.

Named failures include `SETUP_FAILURE`, `RUN_FAILURE`, `RUN_TIMEOUT`,
`EXIT_NONZERO`, `OUTPUT_LIMIT`, `CAPTURE_FAILURE`, and `TEARDOWN_FAILURE`.
Timeout and output-limit paths kill the child process group, including children
that inherit it. This is process supervision for a trusted synthetic subject,
not a sandbox against an adversarial program that escapes its process group.

Durations use the parent's monotonic clock, in seconds. `wall_seconds` measures
setup through completed teardown/capture, excluding serialization of `raw.json`
and command-line printing. Later aggregate cost measurement covers the full
harness. `child_user_seconds` and `child_system_seconds` are `RUSAGE_CHILDREN`
deltas in this single-child, sequential parent; their sum is `child_cpu_seconds`.
These measure reaped child CPU, not the parent's CPU, system-wide load, or
orphaned descendant CPU. The synthetic subject itself starts no descendants.
Subject frame/pixel counters are deterministic data counts, not performance
measurements or real game frame timings.

The controls run actual clean and seeded subjects, a hanging subject, a subject
exiting 23, an output-flooding child, and a forked descendant writing a heartbeat.
They prove successful capture, bounded log files, named failure states and
stopped descendant activity after timeout. Separate injected capture/teardown
errors verify those named failures, including reaping after a cleanup error.
