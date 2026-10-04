"""Comparator failure and label-independence controls. Author: Timur Isaev."""

import copy
from pathlib import Path
import tempfile
import unittest
import uuid

from comparator import compare, selftest
from evidence import build_record
from runner import run
from scenario import Invalid, Scenario
from variance import calibrate

ROOT = Path(__file__).resolve().parent


class ComparatorTests(unittest.TestCase):
    def test_pairs_and_deliberately_broken_classifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"
            raw = run(Scenario.load(ROOT / "scenario-v1.json"), output)
            record = build_record(raw, output)
            samples = [copy.deepcopy(raw) for _ in range(3)]
            for sample in samples:
                sample["run_id"] = str(uuid.uuid4())
            frozen = calibrate(samples)
            self.assertEqual(len(selftest(record, frozen)), 6)
            for forced in ("CLEAN", "REGRESSION"):
                with self.assertRaisesRegex(Invalid, "comparator_selftest"):
                    selftest(record, frozen, lambda *args: {"verdict": forced})

            def reversed_classifier(*args):
                result = compare(*args)
                if result["verdict"] in ("CLEAN", "REGRESSION"):
                    result["verdict"] = "REGRESSION" if result["verdict"] == "CLEAN" else "CLEAN"
                return result

            with self.assertRaisesRegex(Invalid, "comparator_selftest"):
                selftest(record, frozen, reversed_classifier)


if __name__ == "__main__":
    unittest.main()
