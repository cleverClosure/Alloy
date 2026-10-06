"""Hand-authored contract fixtures, not measurement claims. Author: Timur Isaev."""

import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from alloy_lab.common import canonical, hashed


def scenario():
    zero = "0" * 64
    runtime = {"kind": "native", "executable": "python", "files": {
        "python": {"path": "python", "sha256": zero, "bytes": 1}}}
    runtime["sha256"] = hashed(runtime)
    return {
        "version": 2, "id": "known-answer", "revision": 1,
        "subject": {"kind": "native", "path": "subject.py", "sha256": zero}, "runtime": runtime,
        "host": {"os": "Darwin", "architectures": ["arm64"], "minimum_memory_bytes": 0, "requirements": {}},
        "inputs": {"save": {"path": "fixture.sav", "sha256": zero}},
        "steps": [{"id": "run", "phase": "run", "argv": ["{runtime}", "{subject}", "{input:save}"],
                   "environment": {}, "timeout_seconds": 1, "expected_exit": 0}],
        "observables": [{"id": "answer", "source": {"kind": "stdout-json", "step": "run", "path": None, "key": ["answer"]},
                         "comparison": {"class": "exact", "absolute": 0, "relative": 0, "direction": "any"}, "unit": "integer"}],
        "timing_sensitive": False, "timeout_seconds": 1, "retry_limit": 0,
        "context": {"game_build": zero, "profile": zero, "automation": zero, "cache_state": "fresh",
                    "privacy": "local-only-no-accounts"}, "legacy": None,
    }


def evidence():
    definition = scenario()
    host = {"os": "Darwin", "os_release": "test", "os_build": "test", "architecture": "arm64",
            "hardware_class": "test", "firmware": "test", "memory_bytes": 1 << 34, "cpu_count": 8, "capabilities": {}}
    zero = "0" * 64
    identity = lambda value: {"expected": value, "before": value, "after": value}
    record = {
        "version": 2, "scope": "local-engineering-not-certification", "run_id": "run-1", "job_id": "job-1", "attempt": 1,
        "created_at": "2026-10-06T00:00:00Z", "finished_at": "2026-10-06T00:00:01Z", "scenario": definition,
        "source_scenario_sha256": hashed(definition),
        "provenance": {
            "runner": {"id": "fixture-runner", "sha256": zero}, "scheduler": {"id": "fixture-scheduler", "sha256": zero},
            "host": host, "host_class_sha256": hashed(host), "scenario_sha256": hashed(definition),
            "runtime": identity(definition["runtime"]["sha256"]), "subject": identity(zero), "inputs": {"save": identity(zero)},
            "environment_health": {"resource_lock": "shared", "requirements_met": True, "notes": []}},
        "control": "clean", "state": "COMPLETED", "events": [{"state": "SETUP", "elapsed_seconds": 0},
                                                                    {"state": "COMPLETED", "elapsed_seconds": 1}],
        "steps": [{"id": "run", "argv": ["/runtime/python", "/input/subject.py", "/input/fixture.sav"],
                   "exit_code": 0, "elapsed_seconds": 0.5}],
        "observed": {"answer": 42}, "artifacts": [], "failures": [], "duration_seconds": 1,
    }
    for name, data in (("stdout", b'{"answer":42}\n'), ("stderr", b'')):
        record["artifacts"].append({"path": f"steps/run.{name}.log", "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
    # Independent checksum construction deliberately does not call evidence.seal.
    record["integrity"] = {"algorithm": "sha256", "claim": "accidental-edit-detection-only",
                           "sha256": hashlib.sha256(json.dumps(record, sort_keys=True, separators=(",", ":")).encode()).hexdigest()}
    return record
