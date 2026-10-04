#!/usr/bin/env python3
# Author: Timur Isaev
"""Bounded synthetic performance samples with real-operation slowdown controls."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import tempfile
import time

PACKAGE = Path(__file__).resolve().parent
REPO = PACKAGE.parents[1]
BASELINE = PACKAGE / "Results/performance-baseline-v1.json"
SUPERVISOR = PACKAGE / "supervise-parser-command.py"
CANCELLATION_SIGNAL = None
CASE_IDS = {"gc-10", "gc-100", "catalog-10", "catalog-100", "catalog-1000",
            "transport-fresh", "transport-resume", "scan-100", "scan-1000", "scan-20000"}


def run_bounded(command, scratch, label, timeout=180, environment=None):
    log = scratch / (label + ".log")
    command = [sys.executable, str(SUPERVISOR), str(timeout), str(log)] + [str(x) for x in command]
    process = None
    try:
        process = subprocess.Popen(command, env=environment)
        deadline = time.monotonic() + timeout + 5
        while process.poll() is None:
            check_cancellation()
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(command, timeout + 5)
            try:
                process.wait(timeout=0.05)
            except subprocess.TimeoutExpired:
                pass
        check_cancellation()
        code = process.returncode
    except BaseException:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2.5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=0.25)
        raise
    if code:
        print(log.read_text()[-16000:] if log.exists() else "missing command log")
        raise AssertionError(f"{label} failed: exit {code}")
    return log.read_text()


def content_samples(scratch, *, control_delay=None):
    output = scratch / ("content-control.json" if control_delay is not None else "content.json")
    environment = dict(os.environ, ALLOY_PERF_OUTPUT=str(output), ALLOY_PERF_ITERATIONS="3",
                       ALLOY_PERF_FIXTURE_ROOT=str(scratch / "stores"))
    for key in ("ALLOY_PERF_CASE", "ALLOY_PERF_DELAY_CASE", "ALLOY_PERF_DELAY_SECONDS", "ALLOY_PERF_HANG_HEARTBEAT"):
        environment.pop(key, None)
    if control_delay is not None:
        environment.update(ALLOY_PERF_CASE="gc-10", ALLOY_PERF_DELAY_CASE="gc-10",
                           ALLOY_PERF_DELAY_SECONDS=str(control_delay), ALLOY_PERF_ITERATIONS="1")
    log = run_bounded(["swift", "test", "--skip-build", "--disable-sandbox", "--package-path", PACKAGE,
                       "--filter", "PerformanceBaselineTests"], scratch, output.stem,
                      environment=environment)
    expected = 1 if control_delay is not None else 21
    assert f"PERF_SAMPLES count={expected} " in log, "performance test did not execute"
    samples = json.loads(output.read_text())
    assert len(samples) == expected
    return samples


def identity_samples(scratch):
    output = scratch / "identity.json"
    run_bounded(["bash", REPO / "runtime/store-identity/run-breadth-proof.sh", "--skip-build",
                 "--scan-only", "--iterations", "3", "--scratch-root", scratch / "identity-fixture", "--output", output], scratch, "identity", timeout=240)
    report = json.loads(output.read_text())
    samples = [{"id": f"scan-{row['file_count']}", "iteration": row["iteration"] - 1,
                "units": row["file_count"], "fixtureDigest": row["aggregate_sha256"],
                "seconds": row["elapsed_seconds"]}
               for row in report["scan_samples"]]
    assert len(samples) == 9
    workloads = {}
    for row in report["scan_samples"]:
        key = f"scan-{row['file_count']}"
        identity = {name: row[name] for name in ("appid", "file_count", "total_bytes", "aggregate_sha256")}
        assert key not in workloads or workloads[key] == identity
        workloads[key] = identity
    return samples, report["recipe_sha256"], workloads


def summarize(samples):
    grouped = {}
    for sample in samples:
        assert sample["id"] in CASE_IDS
        assert isinstance(sample["seconds"], (float, int))
        assert math.isfinite(sample["seconds"]) and sample["seconds"] > 0
        grouped.setdefault(sample["id"], []).append(sample)
    assert set(grouped) == CASE_IDS, sorted(grouped)
    rows = []
    for name, values in sorted(grouped.items()):
        assert len(values) == 3 and sorted(row["iteration"] for row in values) == [0, 1, 2]
        assert len({row["units"] for row in values}) == 1
        assert len({row["fixtureDigest"] for row in values}) == 1
        rows.append({"id": name, "units": values[0]["units"], "fixture_sha256": values[0]["fixtureDigest"],
                     "median_seconds": statistics.median(row["seconds"] for row in values),
                     "samples_seconds": [row["seconds"] for row in values]})
    return rows


def compare(rows, baseline):
    expected = {row["id"]: row for row in baseline["measurements"]}
    failures = []
    for row in rows:
        assert row["units"] == expected[row["id"]]["units"], "measured workload size changed"
        assert row["fixture_sha256"] == expected[row["id"]]["fixture_sha256"], "measured fixture bytes changed"
        limit = expected[row["id"]]["limit_seconds"]
        assert math.isfinite(limit) and limit > 0
        if row["median_seconds"] > limit:
            failures.append(row["id"])
        print(f"{'FAIL' if row['id'] in failures else 'PASS'} {row['id']} "
              f"median={row['median_seconds']:.6f}s limit={limit:.6f}s", flush=True)
    return failures


def cancellation_control(scratch):
    marker = scratch / "cancellation-heartbeat"
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--skip-build",
                                "--hang-control", str(marker)], start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 15
        while not marker.exists():
            check_cancellation()
            assert process.poll() is None and time.monotonic() < deadline, "Swift cancellation control did not start"
            time.sleep(0.01)
        child_scratch = Path(marker.with_suffix(".scratch").read_text())
        assert list((child_scratch / "stores").iterdir()), "control did not create a real performance store"
        import runpy
        supervisor = runpy.run_path(str(REPO / "tools/test-all"))
        suite = next(row for row in supervisor["REGISTRY"] if row.id == "content-store-performance")
        supervisor["_kill_process_group"](process, suite.cleanup_grace)
        output, error = process.communicate(timeout=1)
        assert process.returncode == 1 and "cancelled by SIGTERM" in output, (output, error)
        assert not child_scratch.exists(), "cancelled performance fixtures survived parent cleanup"
        run_bounded([sys.executable, SUPERVISOR, "--verify-heartbeat", marker], scratch, "verify-cancellation", timeout=5)
    finally:
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=5)
    print("PASS performance cancellation stopped actual Swift child and removed real store fixtures", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record-baseline", type=Path)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--hang-control", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--selftest-cancellation", action="store_true")
    args = parser.parse_args()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="alloy-performance-") as temporary:
        scratch = Path(temporary)
        if args.hang_control:
            args.hang_control.with_suffix(".scratch").write_text(str(scratch))
            environment = dict(os.environ, ALLOY_PERF_OUTPUT=str(scratch / "never-written.json"),
                               ALLOY_PERF_ITERATIONS="1", ALLOY_PERF_CASE="gc-10",
                               ALLOY_PERF_HANG_HEARTBEAT=str(args.hang_control),
                               ALLOY_PERF_FIXTURE_ROOT=str(scratch / "stores"))
            run_bounded(["swift", "test", "--skip-build", "--disable-sandbox", "--package-path", PACKAGE,
                         "--filter", "PerformanceBaselineTests"], scratch,
                        "cancellation-child", timeout=60, environment=environment)
            raise AssertionError("deliberately hanging test unexpectedly completed")
        if args.selftest_cancellation:
            cancellation_control(scratch)
            return
        if not args.skip_build:
            for package in (PACKAGE, REPO / "runtime/store-identity"):
                run_bounded(["swift", "build", "--disable-sandbox", "--build-tests", "--package-path", package],
                            scratch, package.name + "-build")
        if not args.record_baseline:
            cancellation_control(scratch)
        baseline = None
        control = None
        if not args.record_baseline:
            baseline = json.loads(args.baseline.read_text())
            assert baseline["record"] == "alloy-content-performance" and baseline["version"] == 1
            assert {row["id"] for row in baseline["measurements"]} == CASE_IDS
            limit = next(row["limit_seconds"] for row in baseline["measurements"] if row["id"] == "gc-10")
            delay = limit + max(0.1, limit * 0.25)
            assert delay <= 10, "control delay exceeds its bound"
            sample = content_samples(scratch, control_delay=delay)[0]
            control = {"id": "gc-10", "delay_seconds": delay, "measured_seconds": sample["seconds"],
                       "limit_seconds": limit}
            assert compare([{"id": "gc-10", "units": sample["units"], "fixture_sha256": sample["fixtureDigest"],
                             "median_seconds": sample["seconds"]}], baseline) == ["gc-10"]
            print("PASS injected-slowdown rejected the delayed real GC operation", flush=True)
        samples = content_samples(scratch)
        scan, recipe, workloads = identity_samples(scratch)
        rows = summarize(samples + scan)
        report = {"record": "alloy-content-performance", "version": 1, "author": "Timur Isaev",
                  "platform": platform.platform(), "machine": platform.machine(), "recipe_sha256": recipe,
                  "measurements": rows, "slowdown_control": control, "scan_workloads": workloads,
                  "content_recipe": {"generation_counts": [10, 100], "catalog_counts": [10, 100, 1000],
                                     "transport_bytes": 196865, "checkpoint_bytes": 65536,
                                     "payload_formula": "byte[index] = index % 251"}}
        medians = {row["id"]: row["median_seconds"] for row in rows}
        report["resume_completion_over_fresh"] = medians["transport-resume"] / medians["transport-fresh"]
        if args.record_baseline:
            # Conservative cross-host threshold: 5x median or 0.1s extra,
            # whichever is larger. Raw numbers remain visible for comparison.
            for row in rows:
                row["limit_seconds"] = max(row["median_seconds"] * 5, row["median_seconds"] + 0.1)
            report["threshold"] = "max(5 * baseline median, baseline median + 0.1 seconds)"
            args.record_baseline.write_text(json.dumps(report, indent=2) + "\n")
            print(f"PASS recorded baseline cases={len(rows)}", flush=True)
        else:
            assert recipe == baseline["recipe_sha256"], "fixture recipe changed; explicitly regenerate and review baseline"
            assert workloads == baseline["scan_workloads"], "effective scan fixture changed"
            assert report["content_recipe"] == baseline["content_recipe"], "content fixture recipe changed"
            failures = compare(rows, baseline)
            report["failures"] = failures
            assert not failures, f"performance regression: {failures}"
        if args.output:
            args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"SUMMARY performance cases={len(rows)} samples={len(samples) + len(scan)} "
              f"slowdown_controls={int(control is not None)} elapsed_seconds={time.monotonic() - started:.3f}")


def check_cancellation():
    if CANCELLATION_SIGNAL:
        raise InterruptedError(f"performance gate cancelled by {CANCELLATION_SIGNAL}")


def cancel_for_cleanup(signum, _frame):
    global CANCELLATION_SIGNAL
    CANCELLATION_SIGNAL = signal.Signals(signum).name


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, cancel_for_cleanup)
    signal.signal(signal.SIGINT, cancel_for_cleanup)
    try:
        main()
    except Exception as error:
        print(f"FAIL performance: {error}", flush=True)
        print("SUMMARY performance fail=1", flush=True)
        raise
