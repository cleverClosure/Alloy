#!/usr/bin/env python3
"""Run #78's controls against a private census runtime. Author: Timur Isaev."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from check import CASES, analyze, coverage, mutation_controls, require

# Reuse the existing bounded-process, busy-runtime and complete-inventory guards.
spec = importlib.util.spec_from_file_location("isa_runtime", HERE.parent / "isa-corpus-runner.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def verify(work, report):
    texts = {}
    for label in CASES:
        path = work / (label + ".log")
        require(runtime.digest(path) == report["runs"][label]["log_sha256"], "log changed: " + label)
        texts[label] = path.read_text(errors="replace")
    results = report["runs"]
    report["controls"] = {label: analyze(label, texts[label], results[label]) for label in CASES}
    report["reader_mutations_rejected"] = mutation_controls(texts, results)
    report["coverage"] = coverage()
    report["calibration_verdict"] = "PASS"


def source_identity(path):
    identity = runtime.revision(path)
    diff = subprocess.check_output(["git", "-C", str(path), "diff", "--binary", "HEAD"])
    identity["diff_sha256"] = hashlib.sha256(diff).hexdigest()
    return identity


def run(args, work, report):
    build = args.wine_build.resolve()
    require(not build.is_relative_to(args.shared_root.resolve()), "use a private runtime outside the shared checkout")
    loader, server = build / "loader/wine", build / "server/wineserver"
    files = [loader, server, build / "dlls/ntdll/ntdll.so",
             build / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"]
    require(all(path.is_file() for path in files), "runtime artifact missing")
    report["sources"] = {"wine": source_identity(args.wine_source), "fex": source_identity(args.fex_source)}
    require(report["sources"]["fex"]["head"].startswith("77f9ae5") and
            not report["sources"]["fex"]["dirty_paths"], "expected the unmodified issue-37 FEX telemetry source")
    compiler = args.toolchain / "x86_64-w64-mingw32-clang"
    report["compiler"] = {"path": str(compiler), "sha256": runtime.digest(compiler)}
    report["guest_binaries"] = {}
    for label, source, define in [
            ("fault-clean", "fault-probe.c", "PROVOKE_FAULT=0"),
            ("fault-positive", "fault-probe.c", "PROVOKE_FAULT=1"),
            ("decoder-clean", "decoder-probe.c", "PROBE_KIND=0"),
            ("decoder-invalid", "decoder-probe.c", "PROBE_KIND=1"),
            ("decoder-unimplemented", "decoder-probe.c", "PROBE_KIND=2")]:
        binary = work / (label + ".exe")
        subprocess.run([str(compiler), "-O2", "-Wall", "-Wextra", "-Werror", "-fms-extensions",
                        "-Xclang", "-fasync-exceptions", "-D" + define, str(HERE / source),
                        "-o", str(binary)], check=True)
        report["guest_binaries"][binary.name] = runtime.digest(binary)
    binary = work / "telemetry.exe"
    subprocess.run([str(compiler), "-O2", "-Wall", "-Wextra", "-Werror", "-mcx16",
                    str(HERE.parent / "testcases/telemetry_probe.c"), "-o", str(binary)], check=True)
    report["guest_binaries"][binary.name] = runtime.digest(binary)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("WINE", "FEX_", "ALLOY_CENSUS"))}
    prefix = work / "prefix"
    prefix.mkdir()
    env.update(WINEPREFIX=str(prefix), WINELOADER=str(loader), WINESERVER=str(server),
               WINEDEBUG="-all,+loaddll,+xtajit,+seh,+pid", WINEDLLOVERRIDES="xtajit64=n;mscoree,mshtml=",
               DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/lib", FEX_SILENTLOG="0",
               ALLOY_CENSUS="1", ALLOY_CENSUS_INTERVAL="1", ALLOY_CENSUS_FAULT_INTERVAL="1")
    shared = args.shared_root / "spikes/WINE-001/work/build-2"
    runtime.assert_idle(shared)
    runtime.assert_idle(build)
    before = runtime.inventory(build)
    (work / "runtime-before.json").write_text(json.dumps(before, indent=2) + "\n")
    report["runtime"] = {"build": str(build), "prefix": str(prefix), "before_sha256": before["sha256"],
                         "artifacts": {str(path.relative_to(build)): runtime.digest(path) for path in files}}

    def cleanup():
        for option in ("-k", "-w"):
            log = work / ("server" + option + ".log")
            result = runtime.bounded([str(server), option], log, 10, env=env)
            # wineserver -k returns 1 with no output when this prefix already has no server.
            absent = option == "-k" and result["exit"] == 1 and log.stat().st_size == 0
            require(result["failure"] is None and (result["exit"] == 0 or absent), "private server cleanup failed")
        runtime.assert_idle(build)

    def invoke(label, arguments, timeout=60):
        runtime.assert_idle(shared)
        runtime.assert_idle(build)
        require({str(path.relative_to(build)): runtime.digest(path) for path in files} ==
                report["runtime"]["artifacts"], "runtime changed before invocation")
        log = work / (label + ".log")
        result = runtime.bounded([str(loader), *arguments], log, timeout, env=env, cwd=work)
        cleanup()
        report["runs"][label] = {**result, "log_sha256": runtime.digest(log)}
        require(result["exit"] == 0 and result["failure"] is None, "guest or setup failed: " + label)
        print(label + ": exited 0", flush=True)

    try:
        invoke("wineboot", ["wineboot", "-u"], 120)
        registration = work / "select-fex.reg"
        registration.write_text('REGEDIT4\n\n[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Wow64\\amd64]\n@="libarm64ecfex.dll"\n')
        invoke("register", ["regedit", str(registration)])
        for label in CASES:
            name = label if label.startswith(("fault-", "decoder-")) else "telemetry"
            binary = work / (name + ".exe")
            require(runtime.digest(binary) == report["guest_binaries"][binary.name], "guest changed before execution")
            arguments = [str(binary)] + ([label] if name == "telemetry" else [])
            invoke(label, arguments)
            require(runtime.digest(binary) == report["guest_binaries"][binary.name], "guest changed during execution")
        verify(work, report)
    finally:
        try:
            cleanup()
        finally:
            after = runtime.inventory(build)
            (work / "runtime-after.json").write_text(json.dumps(after, indent=2) + "\n")
            report["runtime"]["after_sha256"] = after["sha256"]
            report["runtime"]["unchanged"] = before == after
            require(before == after, "selected runtime changed during calibration")
            require(report["sources"] == {"wine": source_identity(args.wine_source),
                                           "fex": source_identity(args.fex_source)}, "selected sources changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", type=Path, help="verify a saved report and its hashed logs without executing guests")
    parser.add_argument("--wine-build", type=Path)
    parser.add_argument("--wine-source", type=Path)
    parser.add_argument("--fex-source", type=Path)
    parser.add_argument("--shared-root", type=Path, default=runtime.PRIMARY)
    parser.add_argument("--toolchain", type=Path, default=runtime.PRIMARY / "tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin")
    args = parser.parse_args()
    if args.replay:
        report = json.loads((args.replay / "report.json").read_text())
        require(report.get("calibration_verdict") == "PASS" and report["runtime"]["unchanged"],
                "saved run did not complete successfully")
        verify(args.replay, report)
        print("PASS replay: 9 guest controls, 12 damaged-evidence controls; CAS tears remain unmonitored")
        return
    if not all((args.wine_build, args.wine_source, args.fex_source)):
        parser.error("provide all three private runtime/source paths")
    parent = HERE.parent / "work/anomaly-census-runs"
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    report = {"author": "Timur Isaev", "started_at": runtime.stamp(), "runs": {},
              "coverage": coverage(), "calibration_verdict": "FAIL"}
    report["host"] = {"architecture": platform.machine(),
                      "macos": subprocess.check_output(["sw_vers"], text=True).strip()}
    inputs = [HERE / name for name in ("run.py", "check.py", "fault-probe.c", "decoder-probe.c",
                                       "wine-census-resume.patch")]
    inputs += [HERE.parent / "isa-corpus-runner.py", HERE.parent / "testcases/telemetry_probe.c"]
    report["inputs"] = {str(path.relative_to(HERE.parent)): runtime.digest(path) for path in inputs}
    try:
        run(args, work, report)
        require(report["inputs"] == {str(path.relative_to(HERE.parent)): runtime.digest(path) for path in inputs},
                "test inputs changed during calibration")
    except Exception as error:
        report["calibration_verdict"] = "FAIL"
        report["error"] = str(error)
        raise
    finally:
        report["finished_at"] = runtime.stamp()
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(work / "report.json", flush=True)
    print("PASS: 9 guest controls, 12 damaged-evidence controls; CAS tears remain unmonitored")


if __name__ == "__main__":
    main()
