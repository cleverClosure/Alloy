"""Positive fixtures and semantic corruption controls. Author: Timur Isaev."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from fixtures import evidence, scenario
from alloy_lab.common import Invalid, decode, hashed
from alloy_lab.evidence import seal, validate as validate_evidence
from alloy_lab.scenario import LEGACY, read, validate


class Contracts(unittest.TestCase):
    def test_hand_authored_shapes_and_checksum(self):
        validate(scenario())
        validate_evidence(evidence())

    def test_v1_lossless_migration_and_known_oracle(self):
        source = (LEGACY / "scenario-v1.json").read_bytes()
        migrated, original = read(LEGACY / "scenario-v1.json")
        self.assertEqual(original, hashlib.sha256(source).hexdigest())
        self.assertEqual(migrated["legacy"], {"source_sha256": original, "definition": json.loads(source)})
        self.assertEqual(migrated["steps"][0]["timeout_seconds"], json.loads(source)["timeout_seconds"])
        self.assertEqual(len(migrated["observables"]), 7)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v2.json"
            path.write_text(json.dumps(migrated))
            self.assertEqual(read(path)[0], migrated)
        self.assertEqual(migrated["legacy"]["definition"]["expected"]["clean"]["metrics"]["pixel_sum"], 344064)

    def test_duplicate_nonfinite_and_boolean_values_refused(self):
        for data in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}'):
            with self.subTest(data=data), self.assertRaises(Invalid):
                decode(data)
        for key, value in (("version", True), ("revision", True), ("timeout_seconds", True), ("retry_limit", 4)):
            changed = scenario()
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(Invalid):
                validate(changed)

    def test_bad_paths_templates_runtime_and_observable_types(self):
        cases = []
        for path in ("../outside", "/absolute", "one//two", "one/../two", "bad\0path"):
            changed = scenario()
            changed["subject"]["path"] = path
            cases.append(changed)
        changed = scenario()
        changed["steps"][0]["argv"].append("{unknown}")
        cases.append(changed)
        changed = scenario()
        changed["runtime"]["files"]["python"]["sha256"] = "1" * 64
        cases.append(changed)
        changed = scenario()
        changed["observables"][0]["comparison"]["class"] = "performance"
        cases.append(changed)
        changed = scenario()
        changed["observables"][0]["source"]["step"] = "missing"
        cases.append(changed)
        for changed in cases:
            with self.subTest(changed=changed), self.assertRaises(Invalid):
                validate(changed)
        clean = scenario()
        clean["timing_sensitive"] = True
        clean["observables"][0]["comparison"]["class"] = "performance"
        validate(clean)

    def test_resealed_semantic_tampering_cannot_claim_completion(self):
        def change(path, value):
            record = evidence()
            target = record
            for part in path[:-1]:
                target = target[part]
            target[path[-1]] = value
            return seal(record)
        for path, value in (
            (("provenance", "runtime", "before"), "1" * 64),
            (("provenance", "subject", "after"), "1" * 64),
            (("provenance", "inputs", "save", "after"), "1" * 64),
            (("provenance", "host_class_sha256"), "1" * 64),
            (("provenance", "scenario_sha256"), "1" * 64),
            (("provenance", "environment_health", "resource_lock"), "not-acquired"),
            (("scope",), "certified"), (("attempt",), 2), (("observed",), {}),
            (("steps", 0, "exit_code"), 23), (("state",), "FAILED"),
        ):
            with self.subTest(path=path), self.assertRaises(Invalid):
                validate_evidence(change(path, value))
        record = evidence()
        record["observed"]["answer"] += 1
        with self.assertRaisesRegex(Invalid, "integrity:mismatch"):
            validate_evidence(record)
        record = evidence()
        record["state"] = "INCOMPARABLE"
        record["events"][-1]["state"] = "INCOMPARABLE"
        record["provenance"]["runtime"]["before"] = "1" * 64
        record["failures"] = [{"code": "RUNTIME_MISMATCH", "detail": "expected and observed runtime differ"}]
        validate_evidence(seal(record))

    def test_artifact_bytes_json_binding_and_symlink_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "steps").mkdir()
            stdout = root / "steps/run.stdout.log"
            stdout.write_bytes(b'{"answer":42}\n')
            (root / "steps/run.stderr.log").write_bytes(b'')
            validate_evidence(evidence(), root)
            record = evidence()
            record["observed"]["answer"] = 43
            with self.assertRaisesRegex(Invalid, "observed:artifact_mismatch"):
                validate_evidence(seal(record), root)
            stdout.write_bytes(b'{"answer":43}\n')
            with self.assertRaisesRegex(Invalid, "artifact:corrupt"):
                validate_evidence(evidence(), root)
            stdout.unlink()
            stdout.symlink_to(root / "steps/run.stderr.log")
            with self.assertRaisesRegex(Invalid, "path:symlink"):
                validate_evidence(evidence(), root)

    def test_cli_repeats_and_rejects_corrupt_records(self):
        cli = Path(__file__).resolve().parents[1] / "lab.py"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            path.write_text(json.dumps(evidence()))
            command = [sys.executable, str(cli), "validate-evidence", str(path)]
            first = subprocess.run(command, capture_output=True, text=True, timeout=5, check=True)
            second = subprocess.run(command, capture_output=True, text=True, timeout=5, check=True)
            self.assertEqual(first.stdout, second.stdout)
            record = evidence()
            record["scope"] = "certified"
            path.write_text(json.dumps(record))
            self.assertEqual(subprocess.run(command, capture_output=True, timeout=5).returncode, 2)


if __name__ == "__main__":
    unittest.main()
