"""Direct subject and scenario controls, independent of the runner. Author: Timur Isaev."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from scenario import Invalid, Scenario

ROOT = Path(__file__).resolve().parent


class SubjectTests(unittest.TestCase):
    def test_direct_subject_known_pixels_and_digests(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        # Independent closed-form oracle, not imported from the renderer.
        for mode in ("clean", "clean", "clean", "clean", "clean", "seeded"):
            with tempfile.TemporaryDirectory() as directory:
                completed = subprocess.run(scenario.argv(directory, mode), capture_output=True, text=True, timeout=5, check=True)
                self.assertEqual(json.loads(completed.stdout), scenario.definition["expected"][mode]["metrics"])
                for index in range(4):
                    data = (Path(directory) / f"frame-{index:03d}.ppm").read_bytes()
                    self.assertEqual(data[:13], b"P6\n16 16\n255\n")
                    self.assertEqual(len(data), 781)
                    for offset, actual in enumerate(data[13:]):
                        pixel, channel = divmod(offset, 3)
                        y, x = divmod(pixel, 16)
                        expected = (x * 16, y * 16, index * 64)[channel]
                        if mode == "seeded" and index == 0 and offset == 0:
                            expected = 1
                        self.assertEqual(actual, expected)
                    self.assertEqual(hashlib.sha256(data).hexdigest(), scenario.definition["expected"][mode]["frames"][index])

    def test_reject_scenario_mutations(self):
        original = json.loads((ROOT / "scenario-v1.json").read_text())
        mutations = (
            ("version", 2, "unsupported_version"),
            ("version", True, "unsupported_version"),
            ("timeout_seconds", 0, "out_of_range"),
            ("timeout_seconds", True, "wrong_type"),
            ("timeout_seconds", 10 ** 400, "out_of_range"),
            ("command", ["sh", "-c", "anything"], "interpreter_required"),
            ("command", original["command"] + ["--mode", "clean"], "unsupported_template"),
            ("command", original["command"][:-1] + ["{mode"], "unsupported_template"),
            ("extra", 1, "unexpected_field"),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scenario.json"
            for key, value, reason in mutations:
                with self.subTest(key=key, value=value):
                    mutated = dict(original, **{key: value})
                    path.write_text(json.dumps(mutated))
                    with self.assertRaisesRegex(Invalid, reason):
                        Scenario.load(path)


if __name__ == "__main__":
    unittest.main()
