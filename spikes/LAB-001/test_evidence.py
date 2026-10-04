"""Independent schema fixtures and evidence corruption controls. Author: Timur Isaev."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import evidence
import runner
from scenario import Invalid, Scenario

ROOT = Path(__file__).resolve().parent


def fixture():
    """Hand-authored valid record: does not call the evidence builder."""
    def hashed(value):
        data = json.dumps(value, separators=(",", ":"), sort_keys=True, allow_nan=False).encode()
        return hashlib.sha256(data).hexdigest()

    zero = "0" * 64
    run_id = "00000000-0000-4000-8000-000000000001"
    scenario = json.loads((ROOT / "scenario-v1.json").read_text())
    sources = [{"path": f"sources/{name}.py", "bytes": 0, "sha256": zero} for name in ("evidence", "runner", "scenario", "subject")]
    frames = [{"path": f"frame-{index:03d}.ppm", "bytes": 781, "sha256": value} for index, value in enumerate(scenario["expected"]["clean"]["frames"])]
    raw = {
        "version": 1, "run_id": run_id, "scenario_id": "synthetic-rgb-v1", "scenario_sha256": hashed(scenario), "scenario_file_sha256": zero,
        "scenario_definition": scenario, "mode": "clean", "state": "COMPLETED", "argv": ["/python", "/source/subject.py", "--output", "/run", "--mode", "clean"],
        "events": [{"state": state, "elapsed_seconds": elapsed} for state, elapsed in (("SETUP", 0), ("RUN", 0.1), ("TEARDOWN", 0.3), ("COMPLETED", 0.5))],
        "exit_code": 0, "frames": frames, "subject_metrics": {"frame_count": 4, "pixel_count": 1024, "pixel_sum": 344064}, "failure": None,
        "timing": {"setup_seconds": 0.1, "run_wall_seconds": 0.2, "teardown_seconds": 0.1, "wall_seconds": 0.5, "child_user_seconds": 0.1, "child_system_seconds": 0.1, "child_cpu_seconds": 0.2},
        "inputs_before": {key: zero for key in ("runner_sha256", "scenario_validator_sha256", "subject_sha256", "interpreter_sha256")},
        "inputs_after": {key: zero for key in ("runner_sha256", "scenario_validator_sha256", "subject_sha256", "interpreter_sha256")},
    }
    host = {"os": "Darwin", "os_release": "test-release", "os_version": "test-version", "machine": "arm64", "cpu_count": 1, "physical_memory_bytes": 1024}
    record = {
        "version": 1, "created_at": "2026-10-04T00:00:00Z", "scope": "local-synthetic-engineering",
        "runner": {"git_commit": "0" * 40, "source_tree_dirty": False, "source_identity_scope": "archived-capture-time-selected-python-files", "sources": sources},
        "interpreter": {"path": "/python", "sha256": zero, "implementation": "CPython", "version": "3.14.0"}, "host": host,
        "subject": {"path": "/source/subject.py", "sha256": zero}, "scenario": {"effective_sha256": hashed(scenario), "file_sha256": zero},
        "correlation": {"request_id": run_id, "operation_id": run_id, "session_id": run_id, "game_id": "synthetic-rgb", "build_id": zero, "host_class_id": hashed(host), "runtime_generation_id": hashed(sources), "profile_id": "lab-synthetic", "profile_revision": 1, "process_policy_id": "native-python-local", "provider_build_digests": {"python": zero}, "test_plan_digest": hashed(scenario), "scenario_id": "synthetic-rgb-v1", "runner_id": "lab-001-v1", "release_ring": "local-development"},
        "metric_units": {"setup_seconds": "seconds", "run_wall_seconds": "seconds", "teardown_seconds": "seconds", "wall_seconds": "seconds", "child_user_seconds": "seconds", "child_system_seconds": "seconds", "child_cpu_seconds": "seconds", "frame_count": "frames", "pixel_count": "pixels", "pixel_sum": "channel-value-sum"},
        "thresholds": {"scope": "provisional-engineering-only", "calibration_sha256": None, "metrics": {}},
        "certification": {"status": "not-certified", "reviewer_approvals": [], "waivers": [], "limitations": ["Synthetic native subject, not a D3D11 title or Windows comparison.", "No certification, external attestation, or authenticated signature.", "Hashes detect accidental edits; anyone can recompute them.", "Pre/post selected-file identity is not a complete Python or operating-system dependency closure.", "Archived auxiliary runner sources describe capture time; recorded execution inputs are identified separately."]},
        "raw": raw, "artifacts": sources + [{"path": name, "bytes": 0, "sha256": zero} for name in ("raw.json", "stdout.log", "stderr.log")] + frames,
    }
    record["integrity"] = {"algorithm": "sha256", "claim": "accidental-edit-detection-only", "sha256": hashed(record)}
    return record


class EvidenceTests(unittest.TestCase):
    def test_hand_authored_record_and_repeatable_cli(self):
        record = fixture()
        self.assertEqual(evidence.validate(record), record)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            path.write_text(json.dumps(record))
            command = [sys.executable, str(ROOT / "evidence.py"), "validate", str(path)]
            first = subprocess.run(command, check=True, capture_output=True, text=True, timeout=5)
            second = subprocess.run(command, check=True, capture_output=True, text=True, timeout=5)
            self.assertEqual(first.stdout, second.stdout)
            self.assertEqual(first.stderr, "")
            self.assertTrue(first.stdout.startswith("VALID "))

    def test_named_shape_and_semantic_rejections(self):
        def at(path, value):
            def mutate(record):
                target = record
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
            return mutate

        cases = [
            (lambda record: record.pop("host"), "evidence:missing_field"),
            (at(["host", "cpu_count"], True), "host.cpu_count:wrong_type"),
            (at(["interpreter", "sha256"], "0" * 63), "interpreter.sha256:invalid_digest"),
            (at(["unexpected"], 1), "evidence:unexpected_field"),
            (at(["version"], 2), "evidence:unsupported_version"),
            (at(["raw", "timing", "wall_seconds"], float("nan")), "raw.timing.wall_seconds:wrong_type"),
            (at(["raw", "timing", "child_cpu_seconds"], 0.9), "raw.timing:cpu_sum_mismatch"),
            (at(["raw", "scenario_sha256"], "1" * 64), "raw:scenario_digest_mismatch"),
            (at(["raw", "inputs_after", "subject_sha256"], "1" * 64), "raw:execution_inputs_changed"),
            (at(["correlation", "session_id"], "invalid"), "correlation.session_id:invalid_uuid"),
            (at(["certification", "status"], "certified"), "certification:invalid_claim"),
            (at(["thresholds", "metrics"], {"wall_seconds": {"minimum": 0, "maximum": 1}}), "thresholds:calibration_missing"),
            (at(["raw", "subject_metrics", "pixel_sum"], 344065), "integrity:digest_mismatch"),
        ]
        for mutate, reason in cases:
            with self.subTest(reason=reason):
                record = fixture()
                mutate(record)
                with self.assertRaisesRegex(Invalid, reason):
                    evidence.validate(record)

    def test_forged_inventory_paths_and_duplicates_rejected(self):
        record = fixture()
        record["artifacts"].append(copy.deepcopy(record["artifacts"][0]))
        with self.assertRaisesRegex(Invalid, "artifacts:duplicate_path"):
            evidence.validate(record)
        record = fixture()
        record["artifacts"][4]["path"] = "../outside"
        with self.assertRaisesRegex(Invalid, "artifact:unsafe_path"):
            evidence.validate(record)

    def test_real_capture_roundtrip_and_artifact_tampering(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"
            raw = runner.run(scenario, output)
            record = evidence.build_record(raw, output)
            evidence.write_record(record, output / "evidence.json")
            self.assertEqual(evidence.validate(json.loads((output / "evidence.json").read_text()), output), record)
            frame = output / "frame-000.ppm"
            data = frame.read_bytes()
            frame.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
            with self.assertRaisesRegex(Invalid, "artifact:digest_mismatch"):
                evidence.validate(record, output)
            frame.write_bytes(data)
            source = output / "sources" / "subject.py"
            saved = source.read_bytes()
            source.unlink()
            source.symlink_to(ROOT / "subject.py")
            with self.assertRaisesRegex(Invalid, "artifact:symlink"):
                evidence.validate(record, output)
            source.unlink()
            source.write_bytes(saved)
            raw_copy = json.loads((output / "raw.json").read_text())
            raw_copy["mode"] = "seeded"
            (output / "raw.json").write_text(json.dumps(raw_copy))
            with self.assertRaisesRegex(Invalid, "artifact:(size|digest)_mismatch"):
                evidence.validate(record, output)

    def test_real_failure_preserved_and_no_attestation_claim(self):
        scenario = Scenario.load(ROOT / "scenario-v1.json")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "failed"
            raw = runner.run(scenario, output, "error")
            record = evidence.build_record(raw, output)
            self.assertEqual(record["raw"]["failure"]["code"], "EXIT_NONZERO")
            self.assertEqual(record["certification"]["status"], "not-certified")
            self.assertEqual(record["integrity"]["claim"], "accidental-edit-detection-only")
            evidence.validate(record, output)


if __name__ == "__main__":
    unittest.main()
