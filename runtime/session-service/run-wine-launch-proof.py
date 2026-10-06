#!/usr/bin/env python3
"""Separate-client policy/lease controls on an immutable Wine runtime. Author: Timur Isaev."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from proof_support import PACKAGE, ServiceFixture, build, run


def private_cleanup(root):
    # Materialized runtime directories are sealed. Only this proof's disposable copy is removed.
    for parent, directories, _ in os.walk(root):
        os.chmod(parent, 0o700)
        for name in directories:
            path = Path(parent) / name
            if not path.is_symlink():
                path.chmod(0o700)


def policy(name, cpu):
    return {"id": name, "providerDirectory": "C:\\alloy\\providers\\x86_64-windows",
            "resolved": {"ruleIds": [name], "cpuProvider": cpu, "graphicsProvider": name,
                         "syncProvider": "conservative", "dllOverrides": {"alloyblocked": "disabled"},
                         "environment": {"LANG": name}, "workingDirectory": "G:\\cwd",
                         "networkPolicy": "allow", "debugPolicy": "off", "services": {}}}


def terminal(fixture, identifier):
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        state = fixture.request("session.get", {"identifier": identifier})
        if state["state"] in ("SUCCEEDED", "FAILED", "STOPPED", "INTERRUPTED"):
            return state
        time.sleep(0.1)
    raise RuntimeError("session completion deadline")


def main(args):
    processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True, timeout=5)
    if any("/loader/wine" in row or "/server/wineserver" in row for row in processes.splitlines()):
        raise RuntimeError("Wine runtime is busy")
    binaries = build()
    with tempfile.TemporaryDirectory(prefix="alloy-payload-", dir="/private/tmp") as payload_path:
        payload = Path(payload_path)
        (payload / "cwd").mkdir(mode=0o700)
        executable = payload / "probe.exe"
        subprocess.run([str(args.toolchain / "x86_64-w64-mingw32-clang"), "-nostdlib",
                        "-Wl,--entry,entry", "-Wl,--subsystem,console", str(PACKAGE / "guest-smoke.c"),
                        "-lkernel32", "-o", str(executable)], check=True, timeout=60)
        fixture = ServiceFixture(binaries)
        fixture.configuration["syntheticPayloadRoot"] = str(payload)
        fixture.endpoint.write_text(json.dumps(fixture.configuration))
        # Let the service initialize its own empty roots before importing content.
        # Existing unowned nonempty roots must continue to refuse adoption.
        fixture.__enter__()
        stopped = run(["launchctl", "bootout", fixture.target])
        if stopped.returncode:
            raise RuntimeError("private initialization service did not stop")
        fixture.loaded = False
        result = run([args.materializer, "import-development", args.package, fixture.root / "content", "synthetic181"],
                     timeout=180)
        if result.returncode:
            private_cleanup(fixture.root)
            fixture.temporary.cleanup()
            raise RuntimeError(result.stdout + result.stderr)
        runtime = json.loads(result.stdout)
        source = {"schemaVersion": "alloy-synthetic-session-v1", "syntheticOnly": True,
                  "filesystem": "title-volumes-namespace-v1", "gameID": "synthetic181", "buildID": "smoke-one",
                  "runtimeGenerationID": runtime["generationId"], "runtimeTreeDigest": runtime["treeDigest"],
                  "defaultPolicy": policy("unknown", "native-arm64ec"),
                  "processes": [{"path": "G:\\probe.exe", "machine": "x64",
                                 "imageSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                                 "policy": policy("game", "fex-arm64ec")}]}
        reports = []
        with fixture:
            try:
                if not fixture.request("info")["gameLaunchAvailable"]:
                    raise RuntimeError("synthetic driver not advertised")
                for label, fault, expected in [("valid", None, "OK"),
                                                ("corrupt-policy", "wine.corrupt-snapshot", "POLICY_INTEGRITY"),
                                                ("missing-lease", "wine.missing-lease", "GENERATION_LEASE_MISSING"),
                                                ("valid-after-faults", None, "OK")]:
                    fixture.configuration["testFault"] = fault
                    fixture.endpoint.write_text(json.dumps(fixture.configuration))
                    fixture.restart()
                    preview = fixture.request("launch.synthetic.resolve", {
                        "source": base64.b64encode(json.dumps(source).encode()).decode(),
                        "entryPath": "G:\\probe.exe", "key": label, "maximumSeconds": 10})
                    if not preview["specification"]["runtimeReady"]:
                        raise RuntimeError("supported synthetic specification is not ready")
                    handle = fixture.request("launch.game", {"identifier": preview["previewID"]})
                    state = terminal(fixture, handle["sessionID"])
                    directory = fixture.root / "state/wine-sessions" / handle["sessionID"]
                    log = directory / "wine.log"
                    trace = log.read_text(errors="replace") if log.exists() else ""
                    mapped = []
                    if state["code"] != expected:
                        raise RuntimeError(json.dumps(state) + "\n" + trace[-5000:])
                    if expected == "OK":
                        if state["state"] != "SUCCEEDED" or "ALLOY_SYNTHETIC_ENTRY" not in trace:
                            raise RuntimeError("guest did not succeed: " + trace[-5000:])
                        mapped = re.findall(r'alloy_builtin_image path="([^"]+libarm64ecfex.dll)"', trace)
                        image = Path(runtime["path"]) / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
                        if not mapped or any(Path(path).resolve() != image.resolve() for path in mapped):
                            raise RuntimeError("guest did not load the verified generation's builtin FEX: "
                                               + repr(mapped) + "\n" + trace[-5000:])
                    elif "ALLOY_SYNTHETIC_ENTRY" in trace:
                        raise RuntimeError("rejected session executed its guest")
                    reports.append({"label": label, "state": state["state"], "code": state["code"], "mappedFEX": mapped,
                                    "events": state["events"]})
                verified = run([args.materializer, "verify", fixture.root / "content", "synthetic181"], timeout=90)
                if verified.returncode or json.loads(verified.stdout) != runtime:
                    raise RuntimeError("runtime changed during the proof")
                print(json.dumps({"author": "Timur Isaev", "runtime": runtime, "status": "pass",
                                  "runtimeUnchanged": True, "imageSHA256": source["processes"][0]["imageSHA256"],
                                  "runs": reports}))
            finally:
                private_cleanup(fixture.root)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--materializer", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    main(parser.parse_args())
