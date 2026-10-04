<!-- Author: Timur Isaev -->

# LAB-001 — deterministic Mac runner

Status: **Mac synthetic engineering slice passed**, 4 October 2026, issue #77.
This closes the Mac half of D9 as scoped by that issue. The complete canonical
Mac/Windows, real-title hypothesis remains open.

## Hypothesis and scope

A native deterministic subject can be run repeatedly on this Mac with exact
captured output identity, a reproducible evidence record, bounded lifecycle,
measured cost and rerun variance, and controls that distinguish a known visual
regression from an unchanged rerun.

This deliberately substitutes a synthetic subject for doc 16's canonical
SPIKE-LAB-001 prototype of **one D3D11 title**. It implements the scenario,
lifecycle, frame capture, provenance and comparison mechanisms without claiming
that real-game scheduling or the Windows/Mac oracle has been proven.

Explicit follow-ons are #15's Windows hardware/runner half, binding a real title
with fixed save/input, and a Wine-exercising subject. Wine/FEX sources and the
shared runtime were not involved. General retry/flaky-test waivers, hosted CI,
GPU/game frame pacing, certification thresholds, production signing and shipped
privacy policy are outside this slice.

## Method

The stdlib-only subject writes four fixed 16×16 RGB PPM images. Independent tests
check every pixel against a closed-form formula and committed SHA-256 values.
A seed changes exactly one red byte from zero to one and increments the channel
sum by one. The parent hashes actual captured bytes rather than trusting a
subject-reported digest.

The runner supervises setup, execution and teardown with a deadline, bounded
stdout/stderr capture and process-group cleanup. It measures elapsed and reaped
child CPU time and preserves named failures. The evidence validator binds the
effective scenario, source/interpreter inputs, archived selected sources, host
capabilities, correlation fields and artifacts. Its SHA-256 checksum detects
accidental edits; it is not authentication or trusted execution attestation.

Eight calibration runs establish a **provisional engineering-only envelope**.
The timing slack is four times observed calibration range, with a stated 50ms
floor appropriate to this short interpreter workload. Deterministic counters
must match exactly. The envelope, algorithm and sample digests are frozen;
evaluation cannot reuse calibration sample IDs. These are harness constants,
not the per-title product decisions in doc 07 §8.

Every full invocation then runs five fresh clean processes and one seeded
process. It validates actual files, checks the known-answer oracle, evaluates
variance and performs all comparisons. Six independent evidence-pair controls
also execute every time. Always-clean, always-regression and reversed comparator
mutants must fail the self-test. An independent Decimal implementation audits
all ten statistics from raw samples.

## Acceptance and evidence

| Criterion | Result |
| --- | --- |
| Direct subject known-answer proof | Five clean executions and one seeded execution match independent pixels/digests |
| Bounded failures | Actual hang, nonzero exit, log flood and descendant controls pass |
| Strict evidence and integrity | Independent valid fixture; malformed, tampered, symlink and identity controls pass |
| Independent variance audit | All ten metrics agree for calibration and both final holdout batches |
| Mandatory dual control | Both final runs: four CLEAN comparisons and one REGRESSION seed |
| Comparator self-test | Both final runs: all six cases pass; three broken classifiers rejected |
| Stable frozen envelope | Both final runs pass the same unchanged envelope |
| Cost | Full function 0.511813s / 0.509195s; shell invocation 0.59s / 0.59s |

The [closing report](results/2026-10-04-01-mac-runner-stability.md) records the
source commit, commands, host and limits. The [committed evidence dataset](results/2026-10-04-stability-evidence.json)
contains all 20 evidence records, including raw measurements, calibration,
comparison reports and shell costs. Bound image/log/source bytes remain in
the local `work/acceptance-*` directories; committed source and scenario files
allow a fresh reproduction, with expected differences in IDs, timestamps and
timings.

## Reproduce

Use Python 3 with its standard library on macOS. No package installation,
account, signing identity or external service is needed. Choose fresh output
directories; inspect shared workload before making timing claims.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s spikes/LAB-001 -p 'test_*.py' -v
python3 spikes/LAB-001/variance.py calibrate --runs 8 --output /tmp/lab-calibration
/usr/bin/time -p python3 spikes/LAB-001/lab.py --runs 5 --calibration /tmp/lab-calibration/calibration.json --output /tmp/lab-proof-a
/usr/bin/time -p python3 spikes/LAB-001/lab.py --runs 5 --calibration /tmp/lab-calibration/calibration.json --output /tmp/lab-proof-b
python3 spikes/LAB-001/check_variance.py /tmp/lab-proof-a/full.json
python3 spikes/LAB-001/check_variance.py /tmp/lab-proof-b/full.json
```

See [scenario](SCENARIO.md), [lifecycle](LIFECYCLE.md), [evidence](EVIDENCE.md),
[variance](VARIANCE.md) and [comparison](COMPARISON.md) for the versioned contracts
and measurement boundaries. A failed run exits nonzero; no retry changes its
classification or silently adjusts its envelope.
