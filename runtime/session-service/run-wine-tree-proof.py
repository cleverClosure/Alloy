#!/usr/bin/env python3
"""Complete Wine tree and crash cleanup controls. Author: Timur Isaev."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from proof_support import PACKAGE, ServiceFixture, build, run
from run_wine_support import policy, private_cleanup


def wait_for(fixture, identifier, predicate, seconds=150):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = fixture.request("session.get", {"identifier": identifier})
        if predicate(state):
            return state
        if state["state"] in ("FAILED", "INTERRUPTED", "SUCCEEDED", "STOPPED"):
            raise RuntimeError("unexpected terminal: " + json.dumps(state))
        time.sleep(.05)
    raise RuntimeError("session observation deadline: " + json.dumps(state))


def assert_dead(directory, seconds=10):
    deadline = time.monotonic() + seconds
    while True:
        request_path = directory / "request.json"
        if request_path.exists():
            holder = json.loads(request_path.read_text())["lease"]["holder"]
        else:
            holder = json.loads((directory / "pending.json").read_text())["holder"]
        pids = {holder["processId"]}
        ownership_path = directory / "ownership.json"
        if ownership_path.exists():
            ownership = json.loads(ownership_path.read_text())
            pids.add(ownership["serverLease"]["holder"]["processId"])
            if ownership.get("root"):
                pids.add(ownership["root"]["processId"])
            pids.update(row["unixPID"] for row in ownership["processes"] if row.get("unixPID"))
            pids.update(row["native"]["processId"] for row in ownership["processes"] if row.get("native"))
        elif any((directory / name).exists() for name in ("bootstrap.json", "server.log", "wine.log")):
            raise RuntimeError("cannot prove guest cleanup without durable server ownership: " + str(directory))
        result = run(["ps", "-axo", "pid=,stat=,command="], timeout=5)
        if result.returncode:
            raise RuntimeError("native liveness inspection failed: " + result.stderr)
        live = []
        for line in result.stdout.splitlines():
            fields = line.split(None, 2)
            if len(fields) < 2 or fields[1].startswith("Z"):
                continue
            if int(fields[0]) in pids or (len(fields) == 3 and str(directory) in fields[2]):
                live.append(line)
        if not live:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("native processes survived: " + repr(live))
        time.sleep(.05)


def cleanup_sessions(fixture, expected):
    sessions = fixture.root / "state/wine-sessions"
    identifiers = set(expected) | {path.name for path in sessions.glob("*")}
    errors = []
    for identifier in sorted(identifiers):
        try:
            fixture.request("session.stop", {"identifier": identifier})
            wait_for(fixture, identifier, lambda state: state["state"] in
                     ("STOPPED", "INTERRUPTED", "FAILED", "SUCCEEDED"), seconds=35)
            # A terminal record may have been published before agent exit, or
            # may report failed cleanup. Neither is permission to delete files.
            assert_dead(sessions / identifier)
        except Exception as error:
            errors.append(identifier + ": " + str(error))
    if errors:
        raise RuntimeError("unsafe proof cleanup: " + "; ".join(errors))


def export_diagnostics(fixture, destination):
    if not destination:
        return
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    credential = fixture.configuration["credential"].encode()
    for session in (fixture.root / "state/wine-sessions").glob("*"):
        target = destination / session.name
        target.mkdir(exist_ok=True, mode=0o700)
        for name in ("pending.json", "request.json", "state.json", "ownership.json",
                     "bootstrap.json", "wine.log", "server.log"):
            artifact = session / name
            if artifact.exists():
                data = artifact.read_bytes()
                if credential in data:
                    raise RuntimeError("diagnostic export contains the private endpoint credential")
                output = target / name
                output.write_bytes(data)
                output.chmod(0o600)


def pending_case(fixture, case, identifier, directory):
    started = time.monotonic()
    deadline = started + 25
    if not (directory / "pending.json").exists() or (directory / "request.json").exists():
        raise RuntimeError("delayed preparation did not expose its durable pending gate")
    if case == "pending-stop":
        fixture.request("session.stop", {"identifier": identifier})
    else:
        before = fixture.request("info")["instanceID"]
        after = fixture.restart()["instanceID"]
        if before == after:
            raise RuntimeError("pending service crash did not replace the service instance")
    terminal = wait_for(fixture, identifier, lambda state: state["state"] in
                        ("STOPPED", "INTERRUPTED", "FAILED", "SUCCEEDED"),
                        seconds=max(.01, deadline - time.monotonic()))
    if terminal["state"] not in ("STOPPED", "INTERRUPTED") or terminal["code"] not in ("OK", "SESSION_INTERRUPTED"):
        raise RuntimeError("pending launch cleanup outcome differs: " + json.dumps(terminal))
    assert_dead(directory, seconds=max(.01, deadline - time.monotonic()))
    if terminal["processes"] or any((directory / name).exists() for name in
                                    ("wine.log", "server.log", "ownership.json", "bootstrap.json")):
        raise RuntimeError("cancelled pending launch reached Wine before its lease gate completed")
    elapsed = time.monotonic() - started
    if elapsed > 25:
        raise RuntimeError("pending launch cleanup exceeded 25 seconds")
    return {"case": case, "seconds": elapsed, "guestEntryCount": 0,
            "session": {key: value for key, value in terminal.items() if key != "preview"}}


def main(args):
    os.umask(0o077)
    if args.diagnostics and args.diagnostics.exists() and any(args.diagnostics.iterdir()):
        raise RuntimeError("diagnostic destination must be absent or empty")
    processes = subprocess.check_output(["ps", "-axo", "command="], text=True, timeout=5)
    if any("/loader/wine" in row or "/server/wineserver" in row for row in processes.splitlines()):
        raise RuntimeError("Wine runtime is busy")
    binaries = build()
    payload_owner = tempfile.TemporaryDirectory(prefix="alloy-tree-payload-", dir="/private/tmp")
    fixture = None
    try:
        payload = Path(payload_owner.name)
        (payload / "cwd").mkdir(mode=0o700)
        for role, guest in enumerate(("launcher", "game", "unknown", "brief")):
            machine = "x86_64" if role < 2 else "aarch64"
            subprocess.run([str(args.toolchain / (machine + "-w64-mingw32-clang")), "-nostdlib", "-O2",
                            "-DROLE=" + str(role), "-Wl,--entry,entry", "-Wl,--subsystem,console",
                            str(PACKAGE / "guest-tree.c"), "-lkernel32", "-o", str(payload / (guest + ".exe"))],
                           check=True, timeout=60)
        fixture = ServiceFixture(binaries)
        fixture.configuration["syntheticPayloadRoot"] = str(payload)
        fixture.endpoint.write_text(json.dumps(fixture.configuration))
        fixture.__enter__()
        if run(["launchctl", "bootout", fixture.target]).returncode:
            raise RuntimeError("initialization service cleanup")
        fixture.loaded = False
        imported = run([args.materializer, "import-development", args.package, fixture.root / "content", "tree181"],
                       timeout=180)
        if imported.returncode:
            raise RuntimeError(imported.stdout + imported.stderr)
        runtime = json.loads(imported.stdout)
        source = {"schemaVersion": "alloy-synthetic-session-v1", "syntheticOnly": True,
                  "filesystem": "title-volumes-namespace-v1", "gameID": "tree181", "buildID": "tree-one",
                  "runtimeGenerationID": runtime["generationId"], "runtimeTreeDigest": runtime["treeDigest"],
                  "defaultPolicy": policy("unknown", "native-arm64ec"), "processes": [
                      {"path": "G:\\" + guest + ".exe", "machine": "x64",
                       "imageSHA256": hashlib.sha256((payload / (guest + ".exe")).read_bytes()).hexdigest(),
                       "policy": policy(guest, "fex-arm64ec")} for guest in ("launcher", "game")]}
        reports, expected_sessions = [], []
        with fixture:
            try:
                for case in ("pending-stop", "pending-service-crash", "stop", "force-kill", "watchdog",
                             "lease-revoked", "agent-crash", "service-crash"):
                    fixture.configuration["testFault"] = ("wine.delayed-preparation" if case.startswith("pending-")
                                                          else "wine.unresponsive-server" if case == "force-kill"
                                                          else None)
                    fixture.endpoint.write_text(json.dumps(fixture.configuration))
                    fixture.restart()
                    preview = fixture.request("launch.synthetic.resolve", {
                        "source": base64.b64encode(json.dumps(source).encode()).decode(),
                        "entryPath": "G:\\launcher.exe", "key": case, "maximumSeconds": 15 if case == "watchdog" else 90})
                    expected_sessions.append("wine-" + hashlib.sha256(case.encode()).hexdigest())
                    launch_started = time.monotonic()
                    handle = fixture.request("launch.game", {"identifier": preview["previewID"]})
                    launch_seconds = time.monotonic() - launch_started
                    if launch_seconds > 5:
                        raise RuntimeError(f"launch.game blocked the client for {launch_seconds:.3f}s (limit 5s)")
                    identifier = handle["sessionID"]
                    directory = fixture.root / "state/wine-sessions" / identifier
                    if case.startswith("pending-"):
                        result = pending_case(fixture, case, identifier, directory)
                        reports.append(dict(result, launchRequestSeconds=launch_seconds))
                        continue
                    state = wait_for(fixture, identifier, lambda s: len([
                        p for p in s["processes"] if p["imagePath"].lower().startswith("g:\\")]) == 4)
                    # A short-lived child may already be dead before the trace's exit
                    # line is consumed. Settle those retained creations before checking
                    # native membership of the deliberately long-lived guests.
                    state = wait_for(fixture, identifier, lambda s: all(p["exited"] for p in s["processes"]
                                     if p["imagePath"].lower() in ("g:\\launcher.exe", "g:\\brief.exe")), seconds=10)
                    guests = [p for p in state["processes"] if p["imagePath"].lower().startswith("g:\\")]
                    if len([p for p in guests if p["classification"] == "unknown"]) != 2:
                        raise RuntimeError("unknown process count is wrong")
                    for guest in guests:
                        if not guest["exited"] and guest["imagePath"].lower() != "g:\\launcher.exe":
                            if not guest.get("native"):
                                raise RuntimeError("live guest lacks kernel-bound membership: " + json.dumps(guest))
                    started = time.monotonic()
                    if case in ("stop", "force-kill"):
                        fixture.request("session.stop", {"identifier": identifier})
                    elif case == "agent-crash":
                        record = json.loads((directory / "request.json").read_text())
                        os.kill(record["lease"]["holder"]["processId"], signal.SIGKILL)
                    elif case == "service-crash":
                        fixture.restart()
                    elif case == "lease-revoked":
                        record = json.loads((directory / "request.json").read_text())
                        (fixture.root / "content/metadata/leases" / (record["lease"]["leaseId"] + ".json")).unlink()
                    terminal = wait_for(fixture, identifier, lambda s: s["state"] in
                                        ("STOPPED", "INTERRUPTED", "FAILED"), seconds=25)
                    expected = {"watchdog": "SESSION_WATCHDOG", "agent-crash": "SESSION_INTERRUPTED",
                                "lease-revoked": "GENERATION_LEASE_MISSING"}.get(case, "OK")
                    if terminal["code"] != expected:
                        raise RuntimeError("wrong terminal: " + json.dumps(terminal))
                    if case == "force-kill" and "kill-escalated" not in [e["kind"] for e in terminal["events"]]:
                        raise RuntimeError("forced server did not exercise native kill escalation")
                    assert_dead(directory)
                    reports.append({"case": case, "seconds": time.monotonic() - started,
                                    "launchRequestSeconds": launch_seconds,
                                    "session": {key: value for key, value in terminal.items() if key != "preview"}})
                report = {"author": "Timur Isaev", "status": "pass", "runtime": runtime, "runs": reports}
            finally:
                try:
                    cleanup_sessions(fixture, expected_sessions)
                except BaseException:
                    fixture.preserve()
                    # G: remains at the original path while survivors or later
                    # reconciliation may still refer to the synthetic payload.
                    payload_owner._finalizer.detach()
                    raise
                finally:
                    export_diagnostics(fixture, args.diagnostics)
                    if not fixture.retained:
                        private_cleanup(fixture.root)
    finally:
        try:
            if fixture is not None and fixture.root.exists():
                if not fixture.retained:
                    private_cleanup(fixture.root)
                if fixture.loaded:
                    fixture.__exit__(None, None, None)
                elif not fixture.retained:
                    fixture.temporary.cleanup()
        finally:
            if fixture is not None and fixture.retained:
                payload_owner._finalizer.detach()
                print("retained unsafe-cleanup fixture: " + str(fixture.root), file=sys.stderr)
                print("retained unsafe-cleanup payload: " + str(payload), file=sys.stderr)
            else:
                payload_owner.cleanup()
    print(json.dumps(report))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--materializer", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--diagnostics", type=Path)
    main(parser.parse_args())
