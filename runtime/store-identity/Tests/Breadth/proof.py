#!/usr/bin/env python3
"""Bounded end-to-end synthetic identity proof. Author: Timur Isaev."""

import argparse
from contextlib import contextmanager
import copy
import json
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time

from recipe import RECIPE_PATH, canonical, fingerprint, generate, manifest, payloads, sha256


class BreadthCancelled(Exception):
    """Unwind owned child processes and scratch directories on cancellation."""


_deferring_cancellation = False
_cancel_requested = False


def interrupted(_signal, _frame):
    global _cancel_requested
    if _deferring_cancellation:
        _cancel_requested = True
        return
    # Cleanup must complete even if the caller repeats cancellation.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise BreadthCancelled("command cancelled")


@contextmanager
def deferred_cancellation():
    global _deferring_cancellation
    previous = _deferring_cancellation
    _deferring_cancellation = True
    try:
        yield
    finally:
        _deferring_cancellation = previous
    if _cancel_requested and not previous:
        interrupted(None, None)


@contextmanager
def scratch_directory(selected):
    if selected is None:
        with tempfile.TemporaryDirectory(prefix="alloy-breadth-") as temporary:
            yield Path(temporary)
        return
    # Refuse existing paths: cleanup must never take ownership of caller data.
    created = False
    try:
        with deferred_cancellation():
            selected.mkdir(mode=0o700, exist_ok=False)
            created = True
        with tempfile.TemporaryDirectory(prefix="work-", dir=selected) as temporary:
            yield Path(temporary)
    finally:
        with deferred_cancellation():
            if created:
                selected.rmdir()


def supervised_build(package, temporary, product):
    supervisor = package.parent / "content-store/supervise-parser-command.py"
    require(supervisor.is_file(), "stacked parser command supervisor is missing")
    logfile = temporary / (product + "-build.log")
    command = [sys.executable, str(supervisor), "180", str(logfile), "swift", "build",
               "--disable-sandbox", "--package-path", str(package), "--product", product]
    child = None
    try:
        # A deferred signal is handled only after the child is assigned to this cleanup scope.
        with deferred_cancellation():
            child = subprocess.Popen(command, start_new_session=True)
        status = child.wait(timeout=190)
        log = logfile.read_text() if logfile.exists() else "missing build log"
        require(status == 0, "supervised build %s failed: exit %s\n%s" % (product, status, log[-16000:]))
        print("PASS breadth-build " + product, flush=True)
    finally:
        with deferred_cancellation():
            if child is not None and child.poll() is None:
                # The helper owns Swift's separately grouped children; let it reap them first.
                child.terminate()
                try:
                    status = child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
                    raise RuntimeError("build supervisor did not finish checked cancellation cleanup") from None
                require(status in (0, 130), "build supervisor cleanup failed: exit %s" % status)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def invoke(arguments, expected=0, timeout=60):
    result = subprocess.run([str(value) for value in arguments], capture_output=True,
                            text=True, timeout=timeout, check=False)
    require(result.returncode == expected,
            "exit %s (expected %s): %s\n%s" %
            (result.returncode, expected, arguments[0], result.stderr))
    return result


def snapshot(paths):
    """Detect data/path/identity/mode/mtime changes; omit read-induced atime."""
    values = []
    for root in paths:
        for path in [root] + (list(root.rglob("*")) if root.is_dir() else []):
            info = path.lstat()
            values.append((str(path), info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns,
                           sha256(path.read_bytes()) if path.is_file() else None))
    return sorted(values)


def sample_scan(probe, fixture, output, iteration):
    """Reusable M5 metric: process startup + parse/scan + fingerprint persistence."""
    started = time.perf_counter()
    result = invoke([probe, "scan", fixture["manifest"], fixture["install"], output])
    elapsed = time.perf_counter() - started
    expected = fixture["expected"]
    require(json.loads(output.read_bytes()) == expected, "scanner differs from recipe-byte oracle")
    require(result.stdout == "SCAN aggregate=%s files=%d\n" %
            (expected["aggregate_sha256"], expected["file_count"]), "unexpected scan status")
    require(result.stderr == "", "scan wrote standard error")
    return {"metric": "scan_cli", "appid": expected["appid"], "iteration": iteration,
            "file_count": expected["file_count"], "total_bytes": expected["total_bytes"],
            "aggregate_sha256": expected["aggregate_sha256"], "elapsed_seconds": elapsed}


def observe(cli, root, fixture, registry, label, expected=0):
    state = root / ("state-%s-%s" % (fixture["title"]["appid"], label))
    inputs = [fixture["install"], fixture["manifest"], fixture["anchor"], registry]
    before = snapshot(inputs)
    result = invoke([cli, "observe", "--library-root", root / "library", "--app-id",
                     fixture["title"]["appid"], "--anchor", fixture["anchor"],
                     "--registry", registry, "--state-root", state], expected=expected)
    require(snapshot(inputs) == before, "CLI changed selected input bytes or metadata")
    return result, state


def unchanged_control(cli, root, fixture, registry):
    result, state = observe(cli, root, fixture, registry, "unchanged")
    require(result.stdout == "STATUS appid=%s update=unchanged self_test=PASS invalidation=none\n" %
            fixture["title"]["appid"], "unchanged observation emitted a change")
    require(result.stderr == "", "unchanged CLI wrote standard error")
    require(not list(state.glob("invalidations/*.json")), "unchanged observation persisted an invalidation")


def changed_control(cli, root, fixture, registry, label, changed_files, changed_depots,
                    expected_observed):
    result, state = observe(cli, root, fixture, registry, label)
    appid = fixture["title"]["appid"]
    buildid = fixture["title"]["buildid"]
    pattern = (r"STATUS appid=%s update=changed self_test=PASS created=true "
               r"id=(sha256:[0-9a-f]{64}) superseded=%s observed=%s\n" % (appid, buildid, buildid))
    match = re.fullmatch(pattern, result.stdout)
    require(match is not None and result.stderr == "", "changed CLI status is malformed")
    records = list(state.glob("invalidations/*.json"))
    require(len(records) == 1, "changed CLI did not emit exactly one invalidation")
    raw = records[0].read_bytes()
    record = json.loads(raw)
    checks = {"game_id": appid, "selector_ids": [fixture["selector_id"]],
              "changed_file_paths": changed_files, "changed_depot_ids": changed_depots,
              "added_file_paths": [], "removed_file_paths": [],
              "game_content_changed": bool(changed_files), "metadata_changed": bool(changed_depots),
              "invalidation_id": match[1]}
    require({key: record[key] for key in checks} == checks, "incorrect detector/selector delta")
    require(record["observed"]["aggregate_sha256"] == expected_observed["aggregate_sha256"],
            "invalidation observed digest differs from independent oracle")
    require(record["superseded"]["aggregate_sha256"] == fixture["expected"]["aggregate_sha256"],
            "invalidation superseded digest differs from independent oracle")
    require(record["observed"]["manifest_ids"] ==
            {key: value["manifest"] for key, value in expected_observed["depots"].items()},
            "invalidation did not retain the complete observed depot map")
    again, _ = observe(cli, root, fixture, registry, label)
    require(again.stdout == result.stdout.replace("created=true", "created=false"),
            "repeated changed observation is not idempotent")
    require(records[0].read_bytes() == raw and len(list(state.glob("invalidations/*.json"))) == 1,
            "repeated observation changed invalidation bytes or count")


def mutation_controls(cli, root, fixture, registry):
    title = fixture["title"]
    entries = list(payloads(title))
    dlc_path = next(path for path, _ in entries if path.startswith("DLC/"))
    original = (fixture["install"] / dlc_path).read_bytes()
    changed = bytes([original[0] ^ 1]) + original[1:]
    (fixture["install"] / dlc_path).write_bytes(changed)
    changed_entries = [(path, changed if path == dlc_path else data) for path, data in entries]
    changed_control(cli, root, fixture, registry, "dlc-content", [dlc_path], [],
                    fingerprint(title, entries=changed_entries))
    (fixture["install"] / dlc_path).write_bytes(original)

    original_manifest = fixture["manifest"].read_bytes()
    observed = copy.deepcopy(fixture["expected"])
    depot_id = title["depots"][-1]
    observed["depots"][depot_id]["manifest"] = str(int(observed["depots"][depot_id]["manifest"]) + 1)
    fixture["manifest"].write_bytes(manifest(title, observed))
    changed_control(cli, root, fixture, registry, "dlc-metadata", [], [depot_id], observed)
    fixture["manifest"].write_bytes(original_manifest)
    unchanged_control(cli, root, fixture, registry)


def malformed_controls(cli, probe, root, fixture, registry):
    original = fixture["manifest"].read_bytes()
    fixture["manifest"].write_bytes(b"\xff")
    result, state = observe(cli, root, fixture, registry, "malformed", expected=1)
    error = "ERROR %s: input is not valid UTF-8\n" % fixture["manifest"].name
    require(result.stdout == "" and result.stderr == error, "wrong malformed-manifest rejection")
    require(not list(state.glob("invalidations/*.json")), "malformed fixture emitted invalidation")
    fixture["manifest"].write_bytes(original)
    output = root / "must-not-exist.json"
    result = invoke([probe, "scan", fixture["manifest"], fixture["manifest"], output], expected=1)
    prefix = "ERROR fingerprint install root is not a directory: "
    require(result.stdout == "" and result.stderr.startswith(prefix) and result.stderr.count("\n") == 1 and
            result.stderr.endswith("\n") and Path(result.stderr[len(prefix):-1]).samefile(fixture["manifest"]),
            "wrong malformed-installation scanner rejection")
    require(not output.exists(), "refused scan persisted a partial fingerprint")
    unchanged_control(cli, root, fixture, registry)


def run(args):
    recipe = json.loads(RECIPE_PATH.read_bytes())
    goldens = json.loads(RECIPE_PATH.with_name("expected.v1.json").read_bytes())
    require(goldens["recipe_sha256"] == sha256(RECIPE_PATH.read_bytes()), "recipe digest differs from golden")
    require(len(recipe["titles"]) == len(goldens["fingerprints"]), "golden title count differs")
    for title, golden in zip(recipe["titles"], goldens["fingerprints"]):
        known = fingerprint(title)
        require({key: known[key] for key in golden} == golden, "recipe-byte oracle differs from pinned golden")
    if args.smoke:
        for title in recipe["titles"]:
            title["file_count"] = 12
    package = Path(__file__).resolve().parents[2]
    probe = package / ".build/debug/AlloyStoreIdentityFaultProbe"
    cli = package / ".build/debug/AlloyStoreIdentityCLI"
    samples = []
    started = time.perf_counter()
    with scratch_directory(args.scratch_root) as temporary:
        if not args.skip_build:
            for product in ("AlloyStoreIdentityFaultProbe", "AlloyStoreIdentityCLI"):
                supervised_build(package, temporary, product)
        root = temporary / "generated"
        fixtures, registry = generate(root, recipe["titles"])
        if not args.scan_only:
            # Observe the instrument reject known invalid inputs before trusting the matrix.
            malformed_controls(cli, probe, root, fixtures[0], registry)
            print("PASS malformed-manifest invalidUTF8 malformed-installation notDirectory", flush=True)
        for fixture in fixtures:
            appid = fixture["title"]["appid"]
            for iteration in range(1, args.iterations + 1):
                samples.append(sample_scan(probe, fixture, root / ("scan-%s.json" % appid), iteration))
            if not args.scan_only:
                unchanged_control(cli, root, fixture, registry)
                mutation_controls(cli, root, fixture, registry)
            print("PASS breadth appid=%s files=%d depots=%d pipeline=%s" %
                  (appid, fixture["expected"]["file_count"], len(fixture["expected"]["depots"]),
                   "skipped" if args.scan_only else "PASS"), flush=True)
    result = {"record": "alloy-store-identity-breadth", "version": 1, "author": "Timur Isaev",
              "recipe_sha256": sha256(RECIPE_PATH.read_bytes()), "smoke": args.smoke,
              "mode": "scan-only" if args.scan_only else "full-pipeline",
              "source_sha256": {name: sha256((package / relative).read_bytes()) for name, relative in
                                (("generator", "Tests/Breadth/recipe.py"),
                                 ("harness", "Tests/Breadth/proof.py"),
                                 ("scanner", "Sources/AlloyStoreIdentity/FingerprintScanner.swift"),
                                 ("selectors", "Sources/AlloyStoreIdentity/SelectorModels.swift"))},
              "platform": platform.platform(), "machine": platform.machine(),
              "scan_samples": samples, "elapsed_seconds": time.perf_counter() - started,
              "controls": {} if args.scan_only else
                          {"malformed_manifest": "invalidUTF8", "malformed_installation": "notDirectory",
                           "unchanged": 3, "content_changed": 3, "depot_changed": 3,
                           "idempotent": 6, "input_mutations_by_cli": 0}}
    if args.output:
        args.output.write_bytes(canonical(result))
    for sample in samples:
        print("SAMPLE " + json.dumps(sample, sort_keys=True, separators=(",", ":")), flush=True)
    print("SUMMARY breadth titles=3 files=%d scan_samples=%d malformed=%d status=PASS smoke=%s mode=%s" %
          (sum(title["file_count"] for title in recipe["titles"]), len(samples),
           0 if args.scan_only else 2, str(args.smoke).lower(), result["mode"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--iterations", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--smoke", action="store_true", help="12 files/title; not breadth acceptance")
    parser.add_argument("--scan-only", action="store_true", help="measure scans; omit CLI pipeline controls")
    parser.add_argument("--skip-build", action="store_true", help="use existing debug executables")
    parser.add_argument("--scratch-root", type=Path, help="own a new directory beneath an existing parent")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        run(args)
    except BreadthCancelled as error:
        print("FAIL breadth " + str(error), file=sys.stderr)
        return 130
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print("FAIL breadth " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
