#!/usr/bin/env python3
"""Bounded synthetic run lifecycle and parent-observed capture. Author: Timur Isaev."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import resource
import selectors
import signal
import subprocess
import sys
import time
import uuid

from scenario import Invalid, Scenario, fields, require, strict_json

ROOT = Path(__file__).resolve().parent
OUTPUT_LIMIT = 65536


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def execution_inputs(scenario):
    return {
        "runner_sha256": sha256(Path(__file__)),
        "scenario_validator_sha256": sha256(ROOT / "scenario.py"),
        "subject_sha256": sha256(scenario.path.parent / "subject.py"),
        "interpreter_sha256": sha256(Path(sys.executable).resolve()),
    }


def capture(output, scenario):
    metrics = strict_json((output / "stdout.log").read_text())
    fields(metrics, ("frame_count", "pixel_count", "pixel_sum"), "subject_metrics")
    for key, value in metrics.items():
        require(type(value) is int and value >= 0, f"subject_metrics.{key}:wrong_type")
    expected_names = [f"frame-{index:03d}.ppm" for index in range(4)]
    require(sorted(path.name for path in output.glob("*.ppm")) == expected_names, "frames:wrong_count")
    frames = []
    pixel_sum = 0
    for name in expected_names:
        path = output / name
        require(not path.is_symlink() and path.is_file(), "frames:not_regular")
        require(path.stat().st_size == 781, "frames:wrong_size")
        data = path.read_bytes()
        require(data.startswith(b"P6\n16 16\n255\n"), "frames:wrong_header")
        frames.append({"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        pixel_sum += sum(data[13:])
    require(metrics == {"frame_count": 4, "pixel_count": 1024, "pixel_sum": pixel_sum}, "subject_metrics:capture_mismatch")
    return frames, metrics


def run(scenario, output, mode="clean"):
    """One run, with a failure record even when setup or child execution fails.

    The parent is single-threaded and starts one child at a time. RUSAGE_CHILDREN
    deltas therefore measure this run's reaped child, not unrelated system CPU.
    """
    output = Path(output).absolute()
    scenario = Scenario(scenario.path, copy.deepcopy(scenario.definition))
    started = time.monotonic()
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    record = {
        "version": 1,
        "run_id": str(uuid.uuid4()),
        "scenario_id": scenario.definition["id"],
        "scenario_sha256": hashlib.sha256(json.dumps(scenario.definition, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest(),
        "scenario_file_sha256": sha256(scenario.path),
        "scenario_definition": scenario.definition,
        "mode": mode,
        "state": "FAILED",
        "argv": scenario.argv(output, mode),
        "events": [],
        "exit_code": None,
        "frames": [],
        "subject_metrics": {},
        "failure": None,
        "timing": {},
        "inputs_before": {},
        "inputs_after": {},
    }
    process = None
    made_output = False
    run_started = None
    run_ended = None
    setup_ended = started
    teardown_started = started

    def event(state):
        record["events"].append({"state": state, "elapsed_seconds": time.monotonic() - started})

    def fail(code, detail):
        if record["failure"] is None:
            record["failure"] = {"code": code, "detail": detail}

    event("SETUP")
    try:
        output.mkdir(parents=True, exist_ok=False)
        made_output = True
        record["inputs_before"] = execution_inputs(scenario)
        # Pipe reads are bounded, and no more than OUTPUT_LIMIT bytes per log
        # reach disk. A fast writer cannot outrun a filesystem polling limit.
        with (output / "stdout.log").open("wb") as stdout, (output / "stderr.log").open("wb") as stderr:
            setup_ended = time.monotonic()
            event("RUN")
            run_started = time.monotonic()
            process = subprocess.Popen(record["argv"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, stdout)
                selector.register(process.stderr, selectors.EVENT_READ, stderr)
                while selector.get_map():
                    remaining = scenario.definition["timeout_seconds"] - (time.monotonic() - run_started)
                    if remaining <= 0:
                        fail("RUN_TIMEOUT", "scenario deadline exceeded")
                        break
                    for key, _ in selector.select(min(0.01, remaining)):
                        block = os.read(key.fd, 8192)
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        sink = key.data
                        room = OUTPUT_LIMIT - sink.tell()
                        sink.write(block[:room])
                        if len(block) > room:
                            fail("OUTPUT_LIMIT", "child log exceeded 65536 bytes")
                            break
                    if record["failure"] is not None:
                        break
            # A child may close both pipes but continue running.
            if record["failure"] is None:
                try:
                    process.wait(timeout=max(0.001, scenario.definition["timeout_seconds"] - (time.monotonic() - run_started)))
                except subprocess.TimeoutExpired:
                    fail("RUN_TIMEOUT", "scenario deadline exceeded")
            run_ended = time.monotonic()
    except OSError as error:
        fail("SETUP_FAILURE" if process is None else "RUN_FAILURE", str(error))
    finally:
        teardown_started = time.monotonic()
        event("TEARDOWN")
        if process is not None:
            try:
                # Clean the complete process group, including descendants whose
                # leader has already exited. A disappeared group is normal.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            except OSError as error:
                fail("TEARDOWN_FAILURE", str(error))
            finally:
                try:
                    record["exit_code"] = process.wait(timeout=2)
                except subprocess.TimeoutExpired as error:
                    fail("TEARDOWN_FAILURE", str(error))
                    # Reap the direct child even if group cleanup was denied.
                    process.kill()
                    record["exit_code"] = process.wait(timeout=2)
                process.stdout.close()
                process.stderr.close()
            try:
                record["inputs_after"] = execution_inputs(scenario)
                if record["inputs_after"] != record["inputs_before"]:
                    fail("INPUT_CHANGED", "execution input changed during the run")
            except OSError as error:
                fail("INPUT_CHANGED", str(error))
        if process is not None and record["failure"] is None and record["exit_code"] != 0:
            fail("EXIT_NONZERO", f"subject exited {record['exit_code']}")
        if made_output and record["failure"] is None:
            try:
                record["frames"], record["subject_metrics"] = capture(output, scenario)
            except (OSError, ValueError) as error:
                fail("CAPTURE_FAILURE", str(error))
        if record["failure"] is None:
            record["state"] = "COMPLETED"
        event(record["state"])
        finished = time.monotonic()
        usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        user = usage_after.ru_utime - usage_before.ru_utime
        system = usage_after.ru_stime - usage_before.ru_stime
        record["timing"] = {
            "setup_seconds": max(0, setup_ended - started),
            "run_wall_seconds": max(0, (run_ended or teardown_started) - (run_started or teardown_started)),
            "teardown_seconds": finished - teardown_started,
            "wall_seconds": finished - started,
            "child_user_seconds": user,
            "child_system_seconds": system,
            "child_cpu_seconds": user + system,
        }
        if made_output:
            (output / "raw.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", type=Path, default=ROOT / "scenario-v1.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("clean", "seeded", "hang", "error"), default="clean")
    args = parser.parse_args()
    try:
        result = run(Scenario.load(args.scenario), args.output, args.mode)
    except (Invalid, OSError, ValueError) as error:
        parser.exit(2, f"INVALID: {error}\n")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["state"] == "COMPLETED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
