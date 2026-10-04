#!/usr/bin/env python3
"""Prove the Wine patch's Darwin JIT resume bridge. Author: Timur Isaev."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
MODES = ["direct", "legacy", "bridge", "bridge-blocked", "bridge-nested", "bridge-threaded",
         "corrupt-gpr", "corrupt-simd"]
SUMMARY = re.compile(r"mode=(\S+) threads=(\d+) iterations=(\d+) faults=(\d+) restores=(\d+) "
                     r"nested=(\d+) failures=(\d+) bounded=(\d+)")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def patch_header():
    path = "dlls/ntdll/unix/darwin-jit-resume.h"
    marker = f"diff --git a/{path} b/{path}\n"
    patch = (HERE / "wine.patch").read_text()
    if patch.count(marker) != 1:
        raise ValueError("the Wine patch must contain exactly one bridge header")
    section = patch.split(marker, 1)[1].split("\ndiff --git ", 1)[0]
    if "new file mode 100644\n" not in section:
        raise ValueError("expected the complete added bridge header")
    rows, in_hunk = [], False
    for line in section.splitlines():
        if line.startswith("@@ "):
            in_hunk = True
        elif in_hunk:
            if not line.startswith("+"):
                raise ValueError("the complete bridge header must contain only added lines")
            rows.append(line[1:])
    header = ("\n".join(rows) + "\n").encode()
    if header != (HERE / "darwin-jit-resume.h").read_bytes():
        raise ValueError("reviewed header and installable Wine patch have diverged")
    return header


def validate(mode, result):
    lines = result.stdout.splitlines()
    match = SUMMARY.fullmatch(lines[0]) if len(lines) == 1 else None
    if not match or match[1] != mode:
        raise ValueError(f"{mode}: missing exact result")
    observed = tuple(int(match[i]) for i in range(2, 9))
    if mode == "legacy":
        valid = ((result.returncode == 3 and observed == (1, 1, 4, 0, 0, 0, 1)) or
                 (result.returncode == 0 and observed == (1, 1, 1, 0, 0, 0, 0)))
        if not valid or result.stderr:
            raise ValueError("legacy transition neither succeeded nor reached the bounded repeat-fault control")
    else:
        faults = 0 if mode == "direct" else 512 if mode == "bridge-threaded" else 1
        corrupted = mode.startswith("corrupt-")
        expected = (8 if mode == "bridge-threaded" else 1, 64 if mode == "bridge-threaded" else 1,
                    faults, faults, int(mode == "bridge-nested"), int(corrupted), 0)
        if result.returncode != int(corrupted) or observed != expected:
            raise ValueError(f"{mode}: unexpected exit or state: {result.returncode}, {observed}")
        expected_error = ("mismatch x9: 108 != 109\n" if mode == "corrupt-gpr" else
                          "mismatch v15 byte 0\n" if mode == "corrupt-simd" else "")
        if result.stderr != expected_error:
            raise ValueError(f"{mode}: corruption must fail only its named state check")
    return {"mode": mode, "exit": result.returncode, "summary": result.stdout.strip(),
            "diagnostic": result.stderr.strip(), "status": "PASS"}


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        print("SKIP: Darwin JIT signal proof requires an arm64 macOS host")
        return 77
    runs = HERE.parent / "work/jit-signal-runs"
    runs.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=runs))
    report = {"author": "Timur Isaev", "started_at": datetime.now(timezone.utc).isoformat(),
              "host": platform.uname()._asdict(), "cases": []}
    try:
        (work / "darwin-jit-resume.h").write_bytes(patch_header())
        for name in ("signal-probe.c", "register-probe.S"):
            (work / name).write_bytes((HERE / name).read_bytes())
        report["source_sha256"] = {name: digest(HERE / name) for name in
                                    ("darwin-jit-resume.h", "signal-probe.c", "register-probe.S", "wine.patch")}
        compiler = "/usr/bin/clang"
        report["compiler"] = subprocess.check_output([compiler, "--version"], text=True, timeout=10)
        build = subprocess.run([compiler, "-arch", "arm64", "-O2", "-Wall", "-Wextra", "-Werror",
                                str(work / "signal-probe.c"), str(work / "register-probe.S"),
                                "-o", str(work / "signal-probe")], capture_output=True, text=True, timeout=60)
        (work / "build.log").write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(f"native compilation failed: {work / 'build.log'}")
        report["binary_sha256"] = digest(work / "signal-probe")
        for mode in MODES:
            result = subprocess.run([str(work / "signal-probe"), mode], capture_output=True, text=True, timeout=15)
            (work / f"{mode}.log").write_text(result.stdout + result.stderr)
            report["cases"].append(validate(mode, result))
            print(f"PASS {result.stdout.strip()}", flush=True)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(f"FAIL: {error}", file=sys.stderr)
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Native JIT signal report: {work / 'report.json'}", flush=True)
    return int(bool(report.get("error")) or len(report["cases"]) != len(MODES))


if __name__ == "__main__":
    sys.exit(main())
