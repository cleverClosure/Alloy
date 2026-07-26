# ROLLBACK-001 result 06 — seeded adversarial stress

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `21136e49b9909349800e2b355076a3c8023a617e`

## Exact claim

A deterministic harness ran seeded pseudo-random publish, activate, rollback,
lease, release, and sweep sequences. Activation-family operations and sweeps
run in separate child processes; lease and release operations run in the
coordinator against the same cross-process store lock. The harness killed
activation and collection children at randomly selected committed fault
points, recovered in a fresh store instance, and compared the result with an
independent in-memory reachability model after every step.

In this harness, publish means materializing a new generation through a failed
candidate health window, leaving it available but unreferenced; activate uses
a materialized generation with a passing health window; rollback activates the
model's retained rollback generation. These paths use the production journal
and do not create a stress-only persisted format.

## Oracle

After every operation and recovery, the harness requires:

- active and rollback references equal the model;
- candidate is absent and every journal is terminal;
- every referenced or leased generation validates through its manifest,
  materialized layer, and CAS digest;
- the save sentinel is byte-identical.

After every completed sweep, it additionally requires exact set equality:

- on-disk generations equal active + rollback + live-lease generations;
- on-disk CAS objects equal the unique digests reachable from that set.

Thus reachable loss fails immediately, and an unreachable generation or object
surviving one full sweep also fails immediately.

## Recorded run

`runtime/content-store/run-stress-matrix.sh` ran 48 operations for each seed:

```text
85
740085
12648430
20260726
```

Each seed begins with a seeded permutation containing all six operation kinds,
then continues with pseudo-random choices. The coverage prefix forces a random
process-death point for every activation or sweep operation it contains;
later steps randomly choose a kill or clean completion.

```text
SUMMARY seeds=85 740085 12648430 20260726 steps_per_seed=48 total_steps=192
```

Seed 85 initially exposed a harness defect: it selected a per-item quarantine
fault boundary in a model state with no quarantine item, then incorrectly
expected a kill. The minimized prefix was 17 steps. Random stress selection now
uses stage-completion boundaries, which every model state reaches; the full
fault matrix retains every per-item boundary with seeded garbage. Seed 85
remains in the permanent recorded set and passed after the correction.

All four final runs passed. A future failure prints its exact seed and step;
rerunning the same seed and truncating `STEPS` reproduces and minimizes the
prefix without timing dependence.

## Reproduce

```sh
runtime/content-store/run-stress-matrix.sh
```
