#!/usr/bin/env python3
"""Versioned local engineering evidence. Author: Timur Isaev."""

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
import uuid

from scenario import Invalid, digest, fields, number, require, strict_json

ROOT = Path(__file__).resolve().parent
TIMINGS = ("setup_seconds", "run_wall_seconds", "teardown_seconds", "wall_seconds", "child_user_seconds", "child_system_seconds", "child_cpu_seconds")
COUNTERS = ("frame_count", "pixel_count", "pixel_sum")
INPUTS = ("runner_sha256", "scenario_validator_sha256", "subject_sha256", "interpreter_sha256")
UNITS = {**{key: "seconds" for key in TIMINGS}, "frame_count": "frames", "pixel_count": "pixels", "pixel_sum": "channel-value-sum"}
FAILURES = ("SETUP_FAILURE", "RUN_FAILURE", "TEARDOWN_FAILURE", "RUN_TIMEOUT", "OUTPUT_LIMIT", "EXIT_NONZERO", "CAPTURE_FAILURE", "INPUT_CHANGED")
LIMITATIONS = ["Synthetic native subject, not a D3D11 title or Windows comparison.", "No certification, external attestation, or authenticated signature.", "Hashes detect accidental edits; anyone can recompute them.", "Pre/post selected-file identity is not a complete Python or operating-system dependency closure.", "Archived auxiliary runner sources describe capture time; recorded execution inputs are identified separately."]


def canonical(value):
    """Canonical JSON bytes shared by evidence and subsequent report producers."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def hash_value(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def file_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def text(value, path):
    require(type(value) is str and bool(value), f"{path}:wrong_type")


def integer(value, path, minimum=0):
    require(type(value) is int, f"{path}:wrong_type")
    require(value >= minimum, f"{path}:out_of_range")


def finite(value, path):
    number(value, path)
    require(value <= 1e18, f"{path}:out_of_range")


def identifier(value, path):
    text(value, path)
    try:
        require(str(uuid.UUID(value)) == value, f"{path}:invalid_uuid")
    except ValueError as error:
        raise Invalid(f"{path}:invalid_uuid") from error


def artifact(value, path):
    fields(value, ("path", "bytes", "sha256"), path)
    name = value["path"]
    text(name, f"{path}.path")
    parsed = PurePosixPath(name)
    require(not parsed.is_absolute() and all(part not in ("", ".", "..") for part in name.split("/")) and "\\" not in name, f"{path}:unsafe_path")
    integer(value["bytes"], f"{path}.bytes")
    digest(value["sha256"], f"{path}.sha256")


def counters(value, path):
    fields(value, COUNTERS, path)
    for key in COUNTERS:
        integer(value[key], f"{path}.{key}")


def scenario_definition(value):
    fields(value, ("version", "id", "command", "timeout_seconds", "capture", "expected"), "scenario")
    require(type(value["version"]) is int and value["version"] == 1, "scenario:unsupported_version")
    require(type(value["id"]) is str and re.fullmatch(r"[a-z0-9-]+", value["id"]), "scenario:invalid_id")
    require(value["command"] == ["{python}", "{root}/subject.py", "--output", "{output}", "--mode", "{mode}"], "scenario:unsupported_command")
    finite(value["timeout_seconds"], "scenario.timeout_seconds")
    require(0.01 <= value["timeout_seconds"] <= 60, "scenario.timeout_seconds:out_of_range")
    fields(value["capture"], ("format", "width", "height", "count"), "scenario.capture")
    for key in ("width", "height", "count"):
        integer(value["capture"][key], f"scenario.capture.{key}")
    require(value["capture"] == {"format": "ppm-p6", "width": 16, "height": 16, "count": 4}, "scenario.capture:unsupported_shape")
    fields(value["expected"], ("clean", "seeded"), "scenario.expected")
    for mode in ("clean", "seeded"):
        expected = value["expected"][mode]
        fields(expected, ("frames", "metrics"), f"scenario.expected.{mode}")
        require(type(expected["frames"]) is list and len(expected["frames"]) == 4, "scenario.expected.frames:wrong_shape")
        for value_hash in expected["frames"]:
            digest(value_hash, "scenario.expected.frames")
        counters(expected["metrics"], f"scenario.expected.{mode}.metrics")


def raw_record(raw):
    fields(raw, ("version", "run_id", "scenario_id", "scenario_sha256", "scenario_file_sha256", "scenario_definition", "mode", "state", "argv", "events", "exit_code", "frames", "subject_metrics", "failure", "timing", "inputs_before", "inputs_after"), "raw")
    require(type(raw["version"]) is int and raw["version"] == 1, "raw:unsupported_version")
    identifier(raw["run_id"], "raw.run_id")
    scenario_definition(raw["scenario_definition"])
    require(raw["scenario_id"] == raw["scenario_definition"]["id"], "raw:scenario_id_mismatch")
    for key in ("scenario_sha256", "scenario_file_sha256"):
        digest(raw[key], f"raw.{key}")
    require(raw["scenario_sha256"] == hash_value(raw["scenario_definition"]), "raw:scenario_digest_mismatch")
    require(raw["mode"] in ("clean", "seeded", "hang", "error"), "raw:invalid_mode")
    require(raw["state"] in ("COMPLETED", "FAILED"), "raw:invalid_state")
    require(type(raw["argv"]) is list and len(raw["argv"]) == 6, "raw.argv:wrong_shape")
    for value in raw["argv"]:
        text(value, "raw.argv")
    require(raw["argv"][2] == "--output" and raw["argv"][4:] == ["--mode", raw["mode"]], "raw.argv:invalid_command")
    require(all(Path(raw["argv"][index]).is_absolute() for index in (0, 1, 3)), "raw.argv:relative_path")
    require(Path(raw["argv"][1]).name == "subject.py", "raw.argv:invalid_subject")
    fields(raw["timing"], TIMINGS, "raw.timing")
    for key in TIMINGS:
        finite(raw["timing"][key], f"raw.timing.{key}")
    timing = raw["timing"]
    require(math.isclose(timing["child_cpu_seconds"], timing["child_user_seconds"] + timing["child_system_seconds"], rel_tol=1e-9, abs_tol=1e-9), "raw.timing:cpu_sum_mismatch")
    require(sum(timing[key] for key in ("setup_seconds", "run_wall_seconds", "teardown_seconds")) <= timing["wall_seconds"] + 1e-9, "raw.timing:wall_sum_mismatch")
    require(type(raw["events"]) is list, "raw.events:wrong_type")
    last = 0
    for event in raw["events"]:
        fields(event, ("state", "elapsed_seconds"), "raw.event")
        text(event["state"], "raw.event.state")
        finite(event["elapsed_seconds"], "raw.event.elapsed_seconds")
        require(last <= event["elapsed_seconds"] <= timing["wall_seconds"], "raw.events:nonmonotonic")
        last = event["elapsed_seconds"]
    states = [event["state"] for event in raw["events"]]
    require(states in (["SETUP", "RUN", "TEARDOWN", raw["state"]], ["SETUP", "TEARDOWN", "FAILED"]), "raw.events:invalid_lifecycle")
    for name in ("inputs_before", "inputs_after"):
        require(type(raw[name]) is dict, f"raw.{name}:wrong_type")
        if raw[name]:
            fields(raw[name], INPUTS, f"raw.{name}")
            for key in INPUTS:
                digest(raw[name][key], f"raw.{name}.{key}")
    require(type(raw["frames"]) is list, "raw.frames:wrong_type")
    for index, frame in enumerate(raw["frames"]):
        artifact(frame, "raw.frame")
        require(frame["path"] == f"frame-{index:03d}.ppm" and frame["bytes"] == 781, "raw.frames:invalid_frame")
    require(raw["exit_code"] is None or type(raw["exit_code"]) is int, "raw.exit_code:wrong_type")
    if raw["state"] == "COMPLETED":
        require(raw["failure"] is None and raw["exit_code"] == 0, "raw:completed_failure")
        require(len(raw["frames"]) == 4 and raw["mode"] in ("clean", "seeded"), "raw:completed_capture_missing")
        counters(raw["subject_metrics"], "raw.subject_metrics")
        require(raw["subject_metrics"]["frame_count"] == 4 and raw["subject_metrics"]["pixel_count"] == 1024, "raw:counter_shape_mismatch")
        require(bool(raw["inputs_before"]) and raw["inputs_before"] == raw["inputs_after"], "raw:execution_inputs_changed")
    else:
        fields(raw["failure"], ("code", "detail"), "raw.failure")
        require(raw["failure"]["code"] in FAILURES, "raw.failure:unknown_code")
        text(raw["failure"]["detail"], "raw.failure.detail")
        require(raw["frames"] == [] and raw["subject_metrics"] == {}, "raw:failed_capture_present")


def seal(record):
    """Update the local checksum; this is not a signature or authentication."""
    payload = {key: value for key, value in record.items() if key != "integrity"}
    record["integrity"] = {"algorithm": "sha256", "claim": "accidental-edit-detection-only", "sha256": hash_value(payload)}
    return record


def validate(record, artifact_dir=None):
    fields(record, ("version", "created_at", "scope", "runner", "interpreter", "host", "subject", "scenario", "correlation", "metric_units", "thresholds", "certification", "raw", "artifacts", "integrity"), "evidence")
    require(type(record["version"]) is int and record["version"] == 1, "evidence:unsupported_version")
    require(record["scope"] == "local-synthetic-engineering", "evidence:invalid_scope")
    text(record["created_at"], "created_at")
    try:
        require(record["created_at"].endswith("Z") and datetime.fromisoformat(record["created_at"].replace("Z", "+00:00")).tzinfo is not None, "created_at:invalid_timestamp")
    except ValueError as error:
        raise Invalid("created_at:invalid_timestamp") from error
    raw = record["raw"]
    raw_record(raw)
    runner = record["runner"]
    fields(runner, ("git_commit", "source_tree_dirty", "source_identity_scope", "sources"), "runner")
    require(type(runner["git_commit"]) is str and re.fullmatch(r"[0-9a-f]{40}", runner["git_commit"]), "runner:invalid_commit")
    require(type(runner["source_tree_dirty"]) is bool, "runner.source_tree_dirty:wrong_type")
    require(runner["source_identity_scope"] == "archived-capture-time-selected-python-files", "runner:invalid_scope")
    require(type(runner["sources"]) is list and bool(runner["sources"]), "runner.sources:wrong_type")
    for entry in runner["sources"]:
        artifact(entry, "runner.source")
        require(re.fullmatch(r"sources/(?!test)[A-Za-z0-9_]+\.py", entry["path"]), "runner.source:invalid_path")
    source_map = {entry["path"]: entry for entry in runner["sources"]}
    require(len(source_map) == len(runner["sources"]), "runner.sources:duplicate_path")
    require({"sources/runner.py", "sources/scenario.py", "sources/subject.py", "sources/evidence.py"} <= source_map.keys(), "runner.sources:missing_core")
    interpreter = record["interpreter"]
    fields(interpreter, ("path", "sha256", "implementation", "version"), "interpreter")
    for key in ("path", "implementation", "version"):
        text(interpreter[key], f"interpreter.{key}")
    require(Path(interpreter["path"]).is_absolute(), "interpreter:relative_path")
    digest(interpreter["sha256"], "interpreter.sha256")
    require(interpreter["path"] == raw["argv"][0], "interpreter:argv_mismatch")
    fields(record["host"], ("os", "os_release", "os_version", "machine", "cpu_count", "physical_memory_bytes"), "host")
    for key in ("os", "os_release", "os_version", "machine"):
        text(record["host"][key], f"host.{key}")
    integer(record["host"]["cpu_count"], "host.cpu_count", 1)
    integer(record["host"]["physical_memory_bytes"], "host.physical_memory_bytes", 1)
    fields(record["subject"], ("path", "sha256"), "subject")
    require(record["subject"]["path"] == raw["argv"][1], "subject:argv_mismatch")
    digest(record["subject"]["sha256"], "subject.sha256")
    fields(record["scenario"], ("effective_sha256", "file_sha256"), "scenario_identity")
    require(record["scenario"] == {"effective_sha256": raw["scenario_sha256"], "file_sha256": raw["scenario_file_sha256"]}, "scenario_identity:mismatch")
    if raw["state"] == "COMPLETED":
        expected_inputs = {"runner_sha256": source_map["sources/runner.py"]["sha256"], "scenario_validator_sha256": source_map["sources/scenario.py"]["sha256"], "subject_sha256": source_map["sources/subject.py"]["sha256"], "interpreter_sha256": interpreter["sha256"]}
        require(raw["inputs_before"] == expected_inputs, "runner:execution_archive_mismatch")
        require(record["subject"]["sha256"] == expected_inputs["subject_sha256"], "subject:digest_mismatch")
    correlation = record["correlation"]
    fields(correlation, ("request_id", "operation_id", "session_id", "game_id", "build_id", "host_class_id", "runtime_generation_id", "profile_id", "profile_revision", "process_policy_id", "provider_build_digests", "test_plan_digest", "scenario_id", "runner_id", "release_ring"), "correlation")
    for name in ("request_id", "operation_id", "session_id"):
        identifier(correlation[name], f"correlation.{name}")
    require(correlation["request_id"] == raw["run_id"] and correlation["operation_id"] == raw["run_id"], "correlation:run_id_mismatch")
    require(correlation["game_id"] == "synthetic-rgb" and correlation["profile_id"] == "lab-synthetic" and type(correlation["profile_revision"]) is int and correlation["profile_revision"] == 1 and correlation["process_policy_id"] == "native-python-local" and correlation["release_ring"] == "local-development", "correlation:invalid_scope")
    require(correlation["build_id"] == record["subject"]["sha256"] and correlation["host_class_id"] == hash_value(record["host"]) and correlation["runtime_generation_id"] == hash_value(runner["sources"]) and correlation["provider_build_digests"] == {"python": interpreter["sha256"]} and correlation["test_plan_digest"] == raw["scenario_sha256"] and correlation["scenario_id"] == raw["scenario_id"] and correlation["runner_id"] == "lab-001-v1", "correlation:identity_mismatch")
    require(record["metric_units"] == UNITS, "metric_units:mismatch")
    thresholds = record["thresholds"]
    fields(thresholds, ("scope", "calibration_sha256", "metrics"), "thresholds")
    require(thresholds["scope"] == "provisional-engineering-only", "thresholds:invalid_scope")
    require(type(thresholds["metrics"]) is dict, "thresholds.metrics:wrong_type")
    if thresholds["calibration_sha256"] is not None:
        digest(thresholds["calibration_sha256"], "thresholds.calibration_sha256")
    require(not thresholds["metrics"] or thresholds["calibration_sha256"] is not None, "thresholds:calibration_missing")
    for metric, bounds in thresholds["metrics"].items():
        require(metric in UNITS, "thresholds:unknown_metric")
        fields(bounds, ("minimum", "maximum"), "thresholds.bounds")
        finite(bounds["minimum"], "thresholds.minimum")
        finite(bounds["maximum"], "thresholds.maximum")
        require(bounds["minimum"] <= bounds["maximum"], "thresholds:reversed_bounds")
    require(record["certification"] == {"status": "not-certified", "reviewer_approvals": [], "waivers": [], "limitations": LIMITATIONS}, "certification:invalid_claim")
    require(type(record["artifacts"]) is list, "artifacts:wrong_type")
    for entry in record["artifacts"]:
        artifact(entry, "artifact")
    artifacts = {entry["path"]: entry for entry in record["artifacts"]}
    require(len(artifacts) == len(record["artifacts"]), "artifacts:duplicate_path")
    require(set(artifacts) == {"raw.json", "stdout.log", "stderr.log"} | set(source_map) | {frame["path"] for frame in raw["frames"]}, "artifacts:inventory_mismatch")
    for entry in runner["sources"] + raw["frames"]:
        require(artifacts[entry["path"]] == entry, "artifacts:binding_mismatch")
    require(artifacts["stdout.log"]["bytes"] <= 65536 and artifacts["stderr.log"]["bytes"] <= 65536, "artifacts:oversized_log")
    fields(record["integrity"], ("algorithm", "claim", "sha256"), "integrity")
    require(record["integrity"]["algorithm"] == "sha256" and record["integrity"]["claim"] == "accidental-edit-detection-only", "integrity:invalid_claim")
    digest(record["integrity"]["sha256"], "integrity.sha256")
    require(record["integrity"]["sha256"] == hash_value({key: value for key, value in record.items() if key != "integrity"}), "integrity:digest_mismatch")
    if artifact_dir is not None:
        directory = Path(artifact_dir).absolute()
        require(directory.is_dir() and not directory.is_symlink(), "artifacts:invalid_directory")
        contents = {}
        for name, entry in artifacts.items():
            path = directory
            for component in PurePosixPath(name).parts:
                path = path / component
                require(not path.is_symlink(), "artifact:symlink")
            require(path.is_file() and stat.S_ISREG(path.stat().st_mode), "artifact:not_regular")
            require(path.stat().st_size == entry["bytes"], "artifact:size_mismatch")
            require(entry["bytes"] <= 4 * 1024 * 1024, "artifact:oversized")
            data = path.read_bytes()
            require(hashlib.sha256(data).hexdigest() == entry["sha256"], "artifact:digest_mismatch")
            contents[name] = data
        require(strict_json(contents["raw.json"].decode()) == raw, "artifact:raw_mismatch")
        if raw["state"] == "COMPLETED":
            require(strict_json(contents["stdout.log"].decode()) == raw["subject_metrics"], "artifact:metrics_mismatch")
            pixel_sum = 0
            for frame in raw["frames"]:
                data = contents[frame["path"]]
                require(data[:13] == b"P6\n16 16\n255\n", "artifact:invalid_frame_header")
                pixel_sum += sum(data[13:])
            require(pixel_sum == raw["subject_metrics"]["pixel_sum"], "artifact:pixel_sum_mismatch")
    return record


def _entry(path, name):
    require(path.is_file() and not path.is_symlink(), "artifact:not_regular")
    return {"path": name, "bytes": path.stat().st_size, "sha256": file_hash(path)}


def build_record(raw, output, session_id=None):
    """Archive local sources and bind already-published raw artifacts."""
    raw = copy.deepcopy(raw)
    raw_record(raw)
    output = Path(output).absolute()
    require(output.is_dir() and not output.is_symlink(), "artifacts:invalid_directory")
    require(strict_json((output / "raw.json").read_text()) == raw, "artifact:raw_mismatch")
    source_dir = output / "sources"
    require(not source_dir.is_symlink(), "artifact:symlink")
    source_dir.mkdir(exist_ok=True)
    sources = []
    for path in sorted(ROOT.glob("*.py")):
        if path.name.startswith("test"):
            continue
        require(not path.is_symlink(), "runner.source:symlink")
        target = source_dir / path.name
        data = path.read_bytes()
        if target.exists():
            require(not target.is_symlink() and target.read_bytes() == data, "runner.source:archive_changed")
        else:
            target.write_bytes(data)
        sources.append(_entry(target, f"sources/{path.name}"))
    repo = ROOT.parents[1]
    commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    dirty = bool(subprocess.check_output(["git", "-C", str(repo), "status", "--porcelain=v1", "--", str(ROOT)], text=True).strip())
    if platform.system() == "Darwin":
        memory = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True))
    else:
        memory = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    host = {"os": platform.system(), "os_release": platform.release(), "os_version": platform.version(), "machine": platform.machine(), "cpu_count": os.cpu_count() or 1, "physical_memory_bytes": memory}
    interpreter = {"path": raw["argv"][0], "sha256": file_hash(raw["argv"][0]), "implementation": platform.python_implementation(), "version": platform.python_version()}
    subject_hash = raw["inputs_before"].get("subject_sha256", file_hash(ROOT / "subject.py"))
    record = {
        "version": 1, "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), "scope": "local-synthetic-engineering",
        "runner": {"git_commit": commit, "source_tree_dirty": dirty, "source_identity_scope": "archived-capture-time-selected-python-files", "sources": sources},
        "interpreter": interpreter, "host": host, "subject": {"path": raw["argv"][1], "sha256": subject_hash},
        "scenario": {"effective_sha256": raw["scenario_sha256"], "file_sha256": raw["scenario_file_sha256"]},
        "correlation": {"request_id": raw["run_id"], "operation_id": raw["run_id"], "session_id": session_id or str(uuid.uuid4()), "game_id": "synthetic-rgb", "build_id": subject_hash, "host_class_id": hash_value(host), "runtime_generation_id": hash_value(sources), "profile_id": "lab-synthetic", "profile_revision": 1, "process_policy_id": "native-python-local", "provider_build_digests": {"python": interpreter["sha256"]}, "test_plan_digest": raw["scenario_sha256"], "scenario_id": raw["scenario_id"], "runner_id": "lab-001-v1", "release_ring": "local-development"},
        "metric_units": dict(UNITS), "thresholds": {"scope": "provisional-engineering-only", "calibration_sha256": None, "metrics": {}},
        "certification": {"status": "not-certified", "reviewer_approvals": [], "waivers": [], "limitations": list(LIMITATIONS)},
        "raw": raw, "artifacts": sources + [_entry(output / name, name) for name in ("raw.json", "stdout.log", "stderr.log")] + copy.deepcopy(raw["frames"]),
    }
    seal(record)
    validate(record, output)
    return record


def write_record(record, path):
    validate(record)
    path = Path(path)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_bytes(canonical(record) + b"\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    checker = commands.add_parser("validate")
    checker.add_argument("record", type=Path)
    checker.add_argument("--artifacts", type=Path)
    builder = commands.add_parser("capture")
    builder.add_argument("directory", type=Path)
    builder.add_argument("--session-id")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            record = validate(strict_json(args.record.read_text()), args.artifacts)
            print(f"VALID {record['raw']['run_id']} {record['integrity']['sha256']}")
        else:
            record = build_record(strict_json((args.directory / "raw.json").read_text()), args.directory, args.session_id)
            write_record(record, args.directory / "evidence.json")
            print(f"CAPTURED {record['raw']['run_id']} {record['integrity']['sha256']}")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"INVALID {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
