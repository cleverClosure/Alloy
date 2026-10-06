# Milestone 3: immutable evidence and automatic comparisons

Author: Timur Isaev

The registered `lab-evidence-store` proof executes LAB-001 through real scheduled
workers. An explicit baseline produces a fresh CLEAN control; the seeded subject
automatically reports REGRESSION for both frame-0 and pixel_sum (344,065 instead
of the known 344,064). A failing first attempt followed by a successful retry
retains both immutable records and reports FLAKY, worst verdict FAILED, failure
fraction 0.5 and gating_pass false. A changed cached job classification cannot
hide that history; a corrupted attempt comparison is rejected.

Eight actual timing calibration runs freeze the independent max(50 ms, 4×range)
envelope. Seven are refused. A constructed timing value beyond that envelope
regresses; even a resealed baseline with inflated limits fails recomputation.
Calibration reuse and changed host identity are INCOMPARABLE. Changing only the
diagnostic control label does not change a candidate's verdict. Deliberately dead
and reversed comparators fail the independent clean/seeded audit.

Record deduplication, explicit compare-and-swap baseline replacement, corrupt
object reads and corrupt existing-object publication have controls. Separate
processes are SIGKILLed immediately before and after the record-index transaction:
reopening sees either no indexed record or the complete validated record. Repeating
publication is idempotent in both cases. Runtime manifest and source archive bytes
are revalidated on evidence-store reads. These are local engineering records,
not signed game certification or a statistical reliability estimate.

```sh
python3 -B -m unittest discover -s tools/lab/tests -v
tools/test-all --only lab-contracts --only lab-scheduler --only lab-evidence-store
```
