<!-- Author: Timur Isaev -->

# Local rerun variance and cost

Calibration and evaluation are separate invocations and separate subjects. The
envelope is frozen before evaluation; its SHA-256 binds its sample IDs, raw-record
digests, algorithm source digest, host capabilities and selected execution inputs.
Reusing a calibration sample ID in evaluation is an error. The validator checks
sample counts, finite values, units, range/mean/variance consistency, derivation,
source identity and host identity before accepting any limits.

```sh
python3 spikes/LAB-001/variance.py calibrate --runs 8 --output /tmp/lab-calibration
/usr/bin/time -p python3 spikes/LAB-001/variance.py evaluate --runs 5 --calibration /tmp/lab-calibration/calibration.json --output /tmp/lab-evaluation
python3 spikes/LAB-001/check_variance.py /tmp/lab-calibration/batch.json
python3 spikes/LAB-001/check_variance.py /tmp/lab-evaluation/batch.json
```

Both commands capture and validate evidence for every run. They write the ten
metrics' count, mean, population variance, standard deviation, minimum, maximum
and range. The seven timing metrics are measured seconds; the three subject
counters use frames, pixels and channel-value sum. The low-level Python
aggregation API is for immediately captured local samples: it observes the host
at call time. It does not infer the originating host of arbitrary historical raw
JSON. Use the CLI's fresh batch path and retain its evidence records.

For each timing metric, the provisional engineering slack is
`max(0.05 seconds, 4 × observed calibration range)`. Both the holdout range and
its mean shift from calibration must fit this slack. The 50ms floor explicitly
admits the imprecision of short interpreter runs; this is a harness calibration,
not a game-performance or doc 07 certification threshold. Deterministic counters
have zero allowed range and mean shift. A hardware/OS/input/algorithm change
requires new calibration. A failed holdout is a failure, not permission to
silently increase the envelope or retry until it passes.

`check_variance.py` does not import the production statistics implementation.
It reads raw records and independently recomputes every field with 50-digit
Decimal arithmetic, checking all ten metric names/units and unique samples.
Comparison allows only floating-point representation error (relative 1e-12,
absolute 1e-15). Its controls include a deliberately wrong reported mean.

`batch.json.wall_seconds` covers the command's main function through evidence,
comparison and result-file writing, excluding the final batch serialization,
stdout output and interpreter startup. The shell's `/usr/bin/time -p` covers
the entire invocation. Keep both numbers; child CPU sums are not elapsed cost.

Milestone-4 measurement on 4 October 2026 used eight calibration and five fresh
holdout runs. The same envelope digest was
`1e2ec074e55f5fcae2551cdb0485b17dd824e5ae35a79464421dd33b46934b50`.
Calibration/holdout internal costs were 0.689077s / 0.447295s; shell real times
were 0.76s / 0.52s, with the difference covering startup/output and shell timer
rounding. Holdout lifecycle wall mean/range were 0.053205s / 0.003508s; child CPU
mean/range were 0.047943s / 0.002302s. All ten metrics passed; all three deterministic
counter variances were zero. Both independent arithmetic audits passed.

Raw records, source archives, frames, and JSON reports are retained under
`work/m4-calibration/` and `work/m4-holdout/`. They identify the development tree
and disclose its dirty state; the final spike proof repeats the complete runner
from committed sources. Unit controls additionally reject sample reuse,
malformed/resealed calibration statistics and integrity tampering, and detect
deliberate timing and deterministic-counter changes.
