"""Known-number variance and frozen-envelope controls. Author: Timur Isaev."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from check_variance import check
from scenario import Invalid
from variance import COUNTERS, TIMING, calibrate, evaluate, seal, summarize, unseal


def samples():
    inputs = {key: "b" * 64 for key in ("runner_sha256", "scenario_validator_sha256", "subject_sha256", "interpreter_sha256")}
    return [{"run_id": str(index), "state": "COMPLETED", "failure": None, "scenario_sha256": "a" * 64, "inputs_before": dict(inputs), "inputs_after": dict(inputs), "timing": {key: value for key in TIMING}, "subject_metrics": dict(zip(COUNTERS, (4, 1024, 344064)))} for index, value in enumerate((1.0, 2.0, 3.0))]


class VarianceTests(unittest.TestCase):
    def test_known_numbers_and_independent_audit(self):
        raw = samples()
        _, report = summarize(raw)
        self.assertEqual(report["timing.wall_seconds"]["mean"], 2)
        self.assertEqual(report["timing.wall_seconds"]["population_variance"], 2 / 3)
        self.assertEqual(report["subject.pixel_sum"]["range"], 0)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = []
            for index, item in enumerate(raw):
                name = f"raw-{index}.json"
                (root / name).write_text(json.dumps(item))
                names.append(name)
            path = root / "batch.json"
            path.write_text(json.dumps({"samples": names, "stats": report}))
            self.assertEqual(check(path), {"metrics": 10, "samples": 3, "status": "PASS"})
            report["timing.wall_seconds"]["mean"] += 1
            path.write_text(json.dumps({"samples": names, "stats": report}))
            with self.assertRaisesRegex(ValueError, "independent_mismatch"):
                check(path)

    def test_frozen_controls_and_tampering(self):
        raw = samples()
        frozen = calibrate(raw)
        with self.assertRaisesRegex(Invalid, "reused_sample"):
            evaluate(raw, frozen)
        for sample in raw:
            sample["run_id"] += "-holdout"
        self.assertEqual(evaluate(raw, frozen)["status"], "PASS")
        slow = copy.deepcopy(raw)
        for item in slow:
            item["timing"]["wall_seconds"] += 100
        self.assertIn("timing.wall_seconds:mean_shift", evaluate(slow, frozen)["violations"])
        wrong = copy.deepcopy(raw)
        wrong[1]["subject_metrics"]["pixel_sum"] += 1
        self.assertEqual(evaluate(wrong, frozen)["status"], "FAIL")
        frozen["limits"]["timing.wall_seconds"]["max_range"] += 100
        with self.assertRaisesRegex(Invalid, "integrity_mismatch"):
            evaluate(raw, frozen)

    def test_resealed_malformed_baseline_rejected(self):
        frozen = calibrate(samples())
        holdout = samples()
        for sample in holdout:
            sample["run_id"] += "-holdout"
        for field, value, reason in (("count", "bad", "invalid_count"), ("range", 0, "invalid_range"), ("mean", 99, "invalid_mean"), ("standard_deviation", 4, "invalid_variance")):
            broken = copy.deepcopy(unseal(frozen))
            broken["stats"]["timing.wall_seconds"][field] = value
            with self.assertRaisesRegex(Invalid, reason):
                evaluate(holdout, seal(broken))

    def test_bad_samples_rejected(self):
        for field, value, reason in (("wall_seconds", True, "wrong_type"), ("wall_seconds", float("nan"), "wrong_type"), ("wall_seconds", 10 ** 400, "out_of_range")):
            raw = samples()
            raw[0]["timing"][field] = value
            with self.assertRaisesRegex(Invalid, reason):
                summarize(raw)
        raw = samples()
        raw[1]["run_id"] = raw[0]["run_id"]
        with self.assertRaisesRegex(Invalid, "duplicate_run"):
            summarize(raw)


if __name__ == "__main__":
    unittest.main()
