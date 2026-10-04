#!/usr/bin/env python3
"""Full LAB-001 run: variance plus mandatory dual controls. Author: Timur Isaev."""

import argparse
import json
from pathlib import Path
import time
import uuid

from comparator import compare, selftest
from evidence import build_record, seal, validate, write_record
from runner import run
from scenario import Invalid, Scenario, require, strict_json
from variance import batch, evaluate, unseal

ROOT = Path(__file__).resolve().parent


def bind_thresholds(record, calibration, session):
    record["correlation"]["session_id"] = session
    record["thresholds"]["calibration_sha256"] = calibration["integrity_sha256"]
    for key, bounds in calibration["limits"].items():
        name = key.split(".", 1)[1]
        center = calibration["stats"][key]["mean"]
        slack = bounds["max_mean_shift"]
        record["thresholds"]["metrics"][name] = {"minimum": max(0, center - slack), "maximum": center + slack}
    return seal(record)


def oracle(raw, scenario, mode):
    expected = scenario.definition["expected"][mode]
    require(raw["state"] == "COMPLETED", f"oracle:{mode}:failed_lifecycle")
    require([frame["sha256"] for frame in raw["frames"]] == expected["frames"], f"oracle:{mode}:frame_mismatch")
    require(raw["subject_metrics"] == expected["metrics"], f"oracle:{mode}:counter_mismatch")


def full(scenario, output, calibration, count=5):
    started = time.monotonic()
    unseal(calibration)
    session = str(uuid.uuid4())
    samples = batch(scenario, output, count)
    variance = evaluate(samples, calibration)
    records = []
    for index, raw in enumerate(samples):
        oracle(raw, scenario, "clean")
        directory = output / f"run-{index:03d}"
        record = bind_thresholds(strict_json((directory / "evidence.json").read_text()), calibration, session)
        validate(record, directory)
        write_record(record, directory / "evidence.json")
        records.append(record)
    seeded_dir = output / "seeded"
    seeded_raw = run(scenario, seeded_dir, "seeded")
    seeded = bind_thresholds(build_record(seeded_raw, seeded_dir, session), calibration, session)
    validate(seeded, seeded_dir)
    write_record(seeded, seeded_dir / "evidence.json")
    oracle(seeded_raw, scenario, "seeded")
    controls = selftest(records[0], calibration)
    clean_comparisons = [compare(records[0], record, calibration) for record in records[1:]]
    seeded_comparison = compare(records[0], seeded, calibration)
    passed = variance["status"] == "PASS" and all(result["verdict"] == "CLEAN" for result in clean_comparisons) and seeded_comparison["verdict"] == "REGRESSION"
    report = {
        "version": 1, "status": "PASS" if passed else "FAIL", "session_id": session,
        "scope": "local-synthetic-engineering", "calibration_sha256": calibration["integrity_sha256"],
        "unseeded": clean_comparisons, "seeded": seeded_comparison, "comparator_selftest": controls,
        "variance": variance, "stats": variance["stats"],
        "samples": [f"run-{index:03d}/raw.json" for index in range(count)],
        "evidence": [f"run-{index:03d}/evidence.json" for index in range(count)] + ["seeded/evidence.json"],
        "wall_seconds": time.monotonic() - started,
        "cost_scope": "full() entry through validation and comparison; excludes final report serialization and interpreter startup",
    }
    (output / "full.json").write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", type=Path, default=ROOT / "scenario-v1.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--calibration", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    try:
        report = full(Scenario.load(args.scenario), args.output, strict_json(args.calibration.read_text()), args.runs)
        print(json.dumps({"status": report["status"], "unseeded": [item["verdict"] for item in report["unseeded"]], "seeded": report["seeded"]["verdict"], "selftest_cases": len(report["comparator_selftest"]), "wall_seconds": report["wall_seconds"]}, sort_keys=True))
        return 0 if report["status"] == "PASS" else 1
    except (Invalid, OSError, ValueError, KeyError) as error:
        parser.exit(2, f"FAIL: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
