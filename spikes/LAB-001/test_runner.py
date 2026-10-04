"""Lifecycle fault controls. Author: Timur Isaev."""

import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import runner
from scenario import Scenario

ROOT = Path(__file__).resolve().parent


class RunnerTests(unittest.TestCase):
    def test_clean_and_seeded_capture(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        with tempfile.TemporaryDirectory() as directory:
            for mode in ("clean", "seeded"):
                output = Path(directory) / mode
                record = runner.run(scenario, output, mode)
                self.assertEqual(record["state"], "COMPLETED")
                self.assertEqual([event["state"] for event in record["events"]], ["SETUP", "RUN", "TEARDOWN", "COMPLETED"])
                self.assertEqual([frame["sha256"] for frame in record["frames"]], scenario.definition["expected"][mode]["frames"])
                self.assertEqual(record["subject_metrics"], scenario.definition["expected"][mode]["metrics"])
                self.assertEqual(record["inputs_before"], record["inputs_after"])
                self.assertGreater(record["timing"]["wall_seconds"], 0)
                self.assertGreater(record["timing"]["child_cpu_seconds"], 0)
                self.assertEqual(json.loads((output / "raw.json").read_text()), record)

    def test_hang_and_nonzero_are_named_failures(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        scenario.definition["timeout_seconds"] = 0.1
        with tempfile.TemporaryDirectory() as directory:
            for mode, reason in (("hang", "RUN_TIMEOUT"), ("error", "EXIT_NONZERO")):
                start = time.monotonic()
                record = runner.run(scenario, Path(directory) / mode, mode)
                self.assertEqual(record["state"], "FAILED")
                self.assertEqual(record["failure"]["code"], reason)
                self.assertLess(time.monotonic() - start, 3)
                self.assertIsNotNone(record["exit_code"])
                self.assertEqual(record["events"][-1]["state"], "FAILED")
                effective = json.dumps(record["scenario_definition"], sort_keys=True, separators=(",", ":")).encode()
                self.assertEqual(record["scenario_sha256"], hashlib.sha256(effective).hexdigest())
                self.assertEqual(record["scenario_definition"]["timeout_seconds"], 0.1)

    def test_existing_output_is_never_overwritten(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "raw.json"
            sentinel.write_text("keep me")
            record = runner.run(scenario, directory)
            self.assertEqual(record["failure"]["code"], "SETUP_FAILURE")
            self.assertEqual(sentinel.read_text(), "keep me")

    def test_bad_capture_and_teardown_are_named(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(runner, "capture", side_effect=ValueError("frames:wrong_header")):
                record = runner.run(scenario, Path(directory) / "capture")
                self.assertEqual(record["failure"]["code"], "CAPTURE_FAILURE")
            with patch.object(runner.os, "killpg", side_effect=PermissionError("seeded teardown failure")):
                record = runner.run(scenario, Path(directory) / "teardown")
                self.assertEqual(record["failure"]["code"], "TEARDOWN_FAILURE")
                self.assertEqual(record["exit_code"], 0)

    def test_real_output_flood_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.json").write_bytes((ROOT / "scenario-v1.json").read_bytes())
            (root / "subject.py").write_text("import os\nwhile True: os.write(1, b'x' * 8192)\n")
            record = runner.run(Scenario.load(root / "scenario.json"), root / "run")
            self.assertEqual(record["failure"]["code"], "OUTPUT_LIMIT")
            self.assertEqual((root / "run/stdout.log").stat().st_size, runner.OUTPUT_LIMIT)
            self.assertIsNotNone(record["exit_code"])

    def test_changed_input_is_rejected(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        before = runner.execution_inputs(scenario)
        after = dict(before, subject_sha256="0" * 64)
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(runner, "execution_inputs", side_effect=[before, after]):
                record = runner.run(scenario, Path(directory) / "changed")
                self.assertEqual(record["failure"]["code"], "INPUT_CHANGED")

    def test_real_descendant_is_stopped_on_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.json").write_bytes((ROOT / "scenario-v1.json").read_bytes())
            (root / "subject.py").write_text(
                "import os, sys, time\nfrom pathlib import Path\n"
                "out = Path(sys.argv[sys.argv.index('--output') + 1])\n"
                "pid = os.fork()\n"
                "if pid == 0:\n"
                " while True:\n"
                "  (out / 'heartbeat').write_text(str(time.monotonic()))\n"
                "  time.sleep(0.01)\n"
                "(out / 'descendant.pid').write_text(str(pid))\n"
                "while True: time.sleep(1)\n"
            )
            scenario = Scenario.load(root / "scenario.json")
            scenario.definition["timeout_seconds"] = 0.2
            record = runner.run(scenario, root / "run")
            self.assertEqual(record["failure"]["code"], "RUN_TIMEOUT")
            self.assertTrue((root / "run/descendant.pid").is_file())
            heartbeat = (root / "run/heartbeat").read_bytes()
            time.sleep(0.05)
            self.assertEqual((root / "run/heartbeat").read_bytes(), heartbeat)
            self.assertIsNotNone(record["exit_code"])


if __name__ == "__main__":
    unittest.main()
