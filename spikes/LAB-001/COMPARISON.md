<!-- Author: Timur Isaev -->

# Mandatory comparison controls

The full harness requires a previously frozen calibration and creates a fresh
output directory. There is no option to skip either control or the comparator
self-test.

```sh
python3 spikes/LAB-001/variance.py calibrate --runs 8 --output /tmp/lab-calibration
/usr/bin/time -p python3 spikes/LAB-001/lab.py --runs 5 --calibration /tmp/lab-calibration/calibration.json --output /tmp/lab-full
python3 spikes/LAB-001/check_variance.py /tmp/lab-full/full.json
```

Each full invocation captures five unseeded runs and one real seeded run,
validates every evidence record against its artifact files, checks the committed
known pixel/frame/counter oracle, evaluates holdout variance, compares each
unseeded rerun to the first, and compares the seeded run to the first. The seed
changes one visual byte and its channel sum. `full.json` retains every verdict,
reason, evidence path, calibration digest, variance metric and total cost.

Comparison first checks evidence validity, calibration semantics and host/input
identity. Different identities or failed lifecycles are `INCOMPARABLE`, never
`CLEAN`. It compares actual frame hashes, counters and measured timing deltas.
Mode labels do not determine classification. A passing full invocation requires
every unseeded comparison to be `CLEAN`, the real seeded comparison to be
`REGRESSION`, and holdout variance to pass the unchanged engineering envelope.

Six synthetic evidence-pair controls additionally run every time: identical
observations, a changed mode label alone, a changed frame with a clean label,
a changed counter, a known timing increase beyond the envelope, and a different
host. These constructed fixtures test the comparator independently of fresh
subject execution; they are not represented as real measurements. Unit controls
substitute always-clean, always-regression and reversed classifiers and require
each broken classifier to fail loudly. Artifact integrity protects the actual
captured records; the constructed comparator fixtures intentionally have no
corresponding artifact directory.

The first complete development invocation used the frozen milestone-4
calibration and reported four `CLEAN` reruns, one `REGRESSION` seed and six passed
self-tests. All ten independently recomputed variance metrics agreed. Its full
function took 0.523008 seconds; `/usr/bin/time -p` measured 0.61 seconds for the
whole invocation. These are harness costs on this Mac, not game frame pacing.
The committed-source consecutive acceptance runs are recorded by milestone six.
