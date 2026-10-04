#!/usr/bin/env python3
"""Frozen engineering calibration and rerun variance. Author: Timur Isaev."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import statistics
import time

from runner import run
from scenario import Invalid, Scenario, digest, fields, number, require, strict_json

ROOT = Path(__file__).resolve().parent
TIMING = ("setup_seconds", "run_wall_seconds", "teardown_seconds", "wall_seconds", "child_user_seconds", "child_system_seconds", "child_cpu_seconds")
COUNTERS = ("frame_count", "pixel_count", "pixel_sum")
SCOPE = "provisional-engineering-only-not-certification"
DERIVATION = "timing slack=max(0.05 seconds,4*calibration range); deterministic counters exact"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def seal(value):
    result = dict(value)
    result["integrity_sha256"] = hashlib.sha256(canonical(value)).hexdigest()
    return result


def unseal(value):
    require(type(value) is dict and "integrity_sha256" in value, "calibration:missing_integrity")
    core = {key: item for key, item in value.items() if key != "integrity_sha256"}
    require(hashlib.sha256(canonical(core)).hexdigest() == value["integrity_sha256"], "calibration:integrity_mismatch")
    return core


def host_binding():
    from evidence import host_identity

    return host_identity()


def algorithm_digest():
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def values(raw):
    require(raw["state"] == "COMPLETED" and raw["failure"] is None, "sample:failed_run")
    require(raw["inputs_before"] == raw["inputs_after"], "sample:inputs_changed")
    fields(raw["timing"], TIMING, "timing")
    fields(raw["subject_metrics"], COUNTERS, "subject_metrics")
    result = {f"timing.{key}": raw["timing"][key] for key in TIMING}
    result.update({f"subject.{key}": raw["subject_metrics"][key] for key in COUNTERS})
    for key, value in result.items():
        number(value, key)
        require(value < 1e100, f"{key}:out_of_range")
    return result


def summarize(samples):
    require(type(samples) is list and 3 <= len(samples) <= 100, "samples:count_out_of_range")
    require(len({raw["run_id"] for raw in samples}) == len(samples), "samples:duplicate_run")
    binding = {"scenario_sha256": samples[0]["scenario_sha256"], "execution_inputs": samples[0]["inputs_before"], "host": host_binding()}
    for raw in samples:
        require(raw["scenario_sha256"] == binding["scenario_sha256"] and raw["inputs_before"] == binding["execution_inputs"], "samples:identity_mismatch")
    rows = [values(raw) for raw in samples]
    report = {}
    for key in sorted(rows[0]):
        vector = [row[key] for row in rows]
        variance = statistics.pvariance(vector)
        report[key] = {
            "unit": "seconds" if key.startswith("timing.") else {"frame_count": "frames", "pixel_count": "pixels", "pixel_sum": "channel-value-sum"}[key.split(".", 1)[1]],
            "count": len(vector),
            "mean": statistics.mean(vector),
            "population_variance": variance,
            "standard_deviation": math.sqrt(variance),
            "min": min(vector),
            "max": max(vector),
            "range": max(vector) - min(vector),
        }
    return binding, report


def calibrate(samples):
    binding, report = summarize(samples)
    limits = {}
    for key, metric in report.items():
        if key.startswith("subject."):
            require(metric["range"] == 0, "calibration:nondeterministic_subject")
            slack = 0.0
        else:
            # An explicit 50ms measurement-resolution floor prevents treating
            # tiny interpreter startup timings as precise performance claims.
            slack = max(0.05, 4 * metric["range"])
        limits[key] = {"max_range": slack, "max_mean_shift": slack}
    return seal({
        "version": 1,
        "scope": SCOPE,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "binding": binding,
        "algorithm_sha256": algorithm_digest(),
        "samples": [{"run_id": raw["run_id"], "sha256": hashlib.sha256(canonical(raw)).hexdigest()} for raw in samples],
        "derivation": DERIVATION,
        "stats": report,
        "limits": limits,
    })


def validate_calibration(calibration, host=None):
    frozen = unseal(calibration)
    fields(frozen, ("version", "scope", "created_at", "binding", "algorithm_sha256", "samples", "derivation", "stats", "limits"), "calibration")
    require(type(frozen["version"]) is int and frozen["version"] == 1, "calibration:unsupported_version")
    require(frozen["scope"] == SCOPE, "calibration:wrong_scope")
    require(frozen["derivation"] == DERIVATION, "calibration:unknown_derivation")
    require(type(frozen["created_at"]) is str, "calibration:invalid_timestamp")
    try:
        require(datetime.fromisoformat(frozen["created_at"]).tzinfo is not None, "calibration:invalid_timestamp")
    except ValueError as error:
        raise Invalid("calibration:invalid_timestamp") from error
    require(frozen["algorithm_sha256"] == algorithm_digest(), "calibration:algorithm_changed")
    fields(frozen["binding"], ("scenario_sha256", "execution_inputs", "host"), "calibration.binding")
    digest(frozen["binding"]["scenario_sha256"], "calibration.binding.scenario_sha256")
    inputs = frozen["binding"]["execution_inputs"]
    fields(inputs, ("runner_sha256", "scenario_validator_sha256", "subject_sha256", "interpreter_sha256"), "calibration.execution_inputs")
    for value in inputs.values():
        digest(value, "calibration.execution_inputs")
    require(frozen["binding"]["host"] == (host if host is not None else host_binding()), "calibration:host_mismatch")
    require(type(frozen["samples"]) is list and 3 <= len(frozen["samples"]) <= 100, "calibration:invalid_sample_count")
    ids = []
    for sample in frozen["samples"]:
        fields(sample, ("run_id", "sha256"), "calibration.sample")
        require(type(sample["run_id"]) is str and sample["run_id"], "calibration.sample:invalid_id")
        digest(sample["sha256"], "calibration.sample.sha256")
        ids.append(sample["run_id"])
    require(len(set(ids)) == len(ids), "calibration:duplicate_sample")
    keys = {f"timing.{key}" for key in TIMING} | {f"subject.{key}" for key in COUNTERS}
    fields(frozen["stats"], keys, "calibration.stats")
    fields(frozen["limits"], keys, "calibration.limits")
    for key in keys:
        baseline = frozen["stats"][key]
        fields(baseline, ("unit", "count", "mean", "population_variance", "standard_deviation", "min", "max", "range"), f"calibration.stats.{key}")
        unit = "seconds" if key.startswith("timing.") else {"frame_count": "frames", "pixel_count": "pixels", "pixel_sum": "channel-value-sum"}[key.split(".", 1)[1]]
        require(baseline["unit"] == unit, "calibration:unit_mismatch")
        require(type(baseline["count"]) is int and baseline["count"] == len(ids), "calibration:invalid_count")
        for field in ("mean", "population_variance", "standard_deviation", "min", "max", "range"):
            number(baseline[field], f"calibration.{key}.{field}")
            require(baseline[field] < 1e100, "calibration:out_of_range")
        require((baseline["min"] <= baseline["mean"] or math.isclose(baseline["min"], baseline["mean"], rel_tol=1e-12, abs_tol=1e-15)) and (baseline["mean"] <= baseline["max"] or math.isclose(baseline["mean"], baseline["max"], rel_tol=1e-12, abs_tol=1e-15)), "calibration:invalid_mean")
        require(math.isclose(baseline["max"] - baseline["min"], baseline["range"], rel_tol=1e-12, abs_tol=1e-15), "calibration:invalid_range")
        require(math.isclose(baseline["standard_deviation"] ** 2, baseline["population_variance"], rel_tol=1e-12, abs_tol=1e-15), "calibration:invalid_variance")
        require(baseline["population_variance"] <= baseline["range"] ** 2 / 4 + 1e-15, "calibration:variance_out_of_bounds")
        if key.startswith("subject."):
            require(baseline["range"] == 0 and baseline["population_variance"] == 0, "calibration:nondeterministic_subject")
        limit = frozen["limits"][key]
        fields(limit, ("max_range", "max_mean_shift"), f"limits.{key}")
        for field in limit:
            number(limit[field], f"limits.{key}.{field}")
        expected_slack = max(0.05, 4 * baseline["range"]) if key.startswith("timing.") else 0.0
        require(limit == {"max_range": expected_slack, "max_mean_shift": expected_slack}, "calibration:invalid_derivation")
    return frozen


def evaluate(samples, calibration):
    frozen = validate_calibration(calibration)
    binding, report = summarize(samples)
    require(binding == frozen["binding"], "calibration:identity_mismatch")
    require(not ({raw["run_id"] for raw in samples} & {sample["run_id"] for sample in frozen["samples"]}), "calibration:reused_sample")
    violations = []
    for key, observed in report.items():
        baseline = frozen["stats"][key]
        limit = frozen["limits"][key]
        if observed["range"] > limit["max_range"]:
            violations.append(f"{key}:range")
        if abs(observed["mean"] - baseline["mean"]) > limit["max_mean_shift"]:
            violations.append(f"{key}:mean_shift")
    return {"scope": SCOPE, "binding": binding, "stats": report, "limits": frozen["limits"], "violations": violations, "status": "FAIL" if violations else "PASS", "calibration_sha256": calibration["integrity_sha256"]}


def batch(scenario, output, count):
    from evidence import build_record, validate, write_record

    require(type(count) is int and 3 <= count <= 100, "samples:count_out_of_range")
    output.mkdir(parents=True, exist_ok=False)
    samples = []
    for index in range(count):
        run_dir = output / f"run-{index:03d}"
        raw = run(scenario, run_dir)
        record = build_record(raw, run_dir)
        write_record(record, run_dir / "evidence.json")
        validate(record, run_dir)
        require(raw["state"] == "COMPLETED", "batch:failed_run")
        samples.append(raw)
    return samples


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("calibrate", "evaluate"))
    parser.add_argument("--scenario", type=Path, default=ROOT / "scenario-v1.json")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--runs", type=int, default=8)
    parser.add_argument("--calibration", type=Path)
    args = parser.parse_args()
    try:
        require(args.action == "calibrate" or args.calibration is not None, "calibration:required")
        frozen = strict_json(args.calibration.read_text()) if args.calibration else None
        samples = batch(Scenario.load(args.scenario), args.output, args.runs)
        result = calibrate(samples) if args.action == "calibrate" else evaluate(samples, frozen)
        name = "calibration.json" if args.action == "calibrate" else "variance.json"
        (args.output / name).write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
        report = {"action": args.action, "result_file": name, "samples": [f"run-{index:03d}/raw.json" for index in range(args.runs)], "stats": result["stats"], "wall_seconds": time.monotonic() - started}
        (args.output / "batch.json").write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
        print(json.dumps(report, sort_keys=True))
        return 1 if result.get("status") == "FAIL" else 0
    except (Invalid, OSError, ValueError, KeyError) as error:
        parser.exit(2, f"INVALID: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
