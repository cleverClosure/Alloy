#!/usr/bin/env python3
"""Real operation, owned native abort/hang and service interruption. Author: Timur Isaev."""
import argparse
import ctypes
import hashlib
import http.server
import json
import os
import signal
import subprocess
import threading
import time
from diagnostic_fixture import ServiceFixture, build, call, operations
from launch_fixture import launch_input


def wait_session(service, identifier, predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = service.request("session.get", {"identifier": identifier})
        if predicate(value):
            return value
        time.sleep(0.04)
    raise RuntimeError("native session observation deadline")


def finished(value):
    return value["state"] in ("FAILED", "SUCCEEDED", "STOPPED", "INTERRUPTED") and not value["liveNodes"]


def abort_owned_fixture(service, identifier):
    snapshot = service.request("session.get", {"identifier": identifier})
    agent = next(node for node in snapshot["nodes"] if node["name"] == "agent")
    holder = agent["lease"]["holder"]
    # Exact kernel start time, executable path and digest before a synthetic abort.
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    info = ctypes.create_string_buffer(136)
    if libproc.proc_pidinfo(holder["processId"], 3, 0, info, len(info)) != len(info):
        raise RuntimeError("owned fixture process identity unavailable")
    import struct
    seconds, micros = struct.unpack_from("QQ", info.raw, 120)
    executable = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(holder["processId"], executable, len(executable)) <= 0:
        raise RuntimeError("owned fixture executable unavailable")
    from pathlib import Path
    path = Path(os.fsdecode(executable.value))
    digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    if (seconds, micros) != (holder["startTimeSeconds"], holder["startTimeMicroseconds"]) or \
            path.name != "alloy-session-fixture" or digest != snapshot["record"]["fixtureDigest"]:
        raise RuntimeError("owned fixture identity mismatch")
    os.kill(holder["processId"], signal.SIGABRT)


def capture(client, service, kind, identifier, mode="terminal", seconds=30):
    return call(client, "capture", service.endpoint, kind, identifier, mode, seconds, timeout=45)


def scenarios(service, client, mirror, check, capture_fn=capture):
    clean_op = operations.execute(service, "inventory.start", {"key": "clean"})
    clean = capture_fn(client, service, "operation", clean_op["operationID"])
    check("successful-operation-control", clean["outcome"] == "clean" and clean["complete"])
    failed_plan = operations.plan(service, mirror + "/bad", "bad-runtime")
    failed = service.request("install.start", {"identifier": failed_plan["planID"], "key": "failed"})
    service.request("operation.run", {"identifier": failed["operationID"]})
    failure = capture_fn(client, service, "operation", failed["operationID"])
    check("actual-operation-failure", failure["outcome"] == "operation-failed" and failure["complete"])
    prepared = operations.plan(service, mirror, "rtg_service_fixture_001")
    operations.execute(service, "install.start", {"identifier": prepared["planID"], "key": "install"})
    host = service.request("host.info")
    if host["architecture"] != "arm64" or host["memoryGiB"] < 8:
        for name in ["native-clean-control", "owned-native-abort", "owned-native-hang",
                     "capture-budget-incomplete", "service-interruption-incomplete", "reconnected-interrupted-session"]:
            check(name, None)
        return [clean, failure]
    preview = service.request("launch.resolve", launch_input(service, operations.DIGEST, len(operations.PAYLOAD)))

    def start(key, scenario):
        value = service.request("fixture.start", {"previewID": preview["previewID"], "key": key, "scenario": scenario})
        return value["record"]["sessionID"]

    identifier = start("clean", "normal")
    normal = capture_fn(client, service, "session", identifier)
    check("native-clean-control", normal["outcome"] == "clean" and normal["complete"])
    identifier = start("abort", "hang")
    wait_session(service, identifier, lambda value: len(value["liveNodes"]) == 3)
    abort_owned_fixture(service, identifier)
    crashed = capture_fn(client, service, "session", identifier)
    stopped = wait_session(service, identifier, finished)
    check("owned-native-abort", crashed["outcome"] == "native-fixture-signal-abort" and crashed["complete"]
          and stopped["exitCode"] == 6 and not stopped["liveNodes"])
    identifier = start("hang", "hang")
    wait_session(service, identifier, lambda value: len(value["liveNodes"]) == 3)
    hung = capture_fn(client, service, "session", identifier, "hang")
    stopped = wait_session(service, identifier, finished, seconds=25)
    check("owned-native-hang", hung["outcome"] == "native-fixture-watchdog-hang" and hung["complete"]
          and len(hung["artifacts"]) == 1 and stopped["exitCode"] == 43 and not stopped["liveNodes"])
    identifier = start("budget", "hang")
    wait_session(service, identifier, lambda value: len(value["liveNodes"]) == 3)
    bounded = capture_fn(client, service, "session", identifier, seconds=0.1)
    check("capture-budget-incomplete", not bounded["complete"] and bounded["outcome"] == "budget-exceeded"
          and bounded["elapsedSeconds"] < 1)
    service.request("session.stop", {"identifier": identifier})
    wait_session(service, identifier, finished)
    identifier = start("interrupted", "hang")
    wait_session(service, identifier, lambda value: len(value["liveNodes"]) == 3)
    process = subprocess.Popen([client, "capture", service.endpoint, "session", identifier, "terminal", "30"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(1)
        service.restart()
        stdout, stderr = process.communicate(timeout=35)
        if process.returncode:
            raise RuntimeError(stderr)
        interruption = json.loads(stdout)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    check("service-interruption-incomplete", not interruption["complete"]
          and interruption["outcome"] == "service-interruption")
    recovered = capture_fn(client, service, "session", identifier)
    stopped = wait_session(service, identifier, finished)
    check("reconnected-interrupted-session", recovered["outcome"] == "service-interruption"
          and not recovered["complete"] and stopped["state"] == "INTERRUPTED" and not stopped["liveNodes"])
    return [clean, failure, normal, crashed, hung, bounded, interruption, recovered]


class Mirror(operations.Mirror):
    def do_GET(self):
        if self.path.startswith("/bad/"):
            self.send_error(404)
        else:
            super().do_GET()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    rows = []

    def check(name, okay):
        if okay is None:
            print("SKIP " + name + ": actual host lacks arm64/8GiB compiler prerequisite", flush=True)
            rows.append(None)
            return
        if args.negative_control and name == "actual-operation-failure":
            okay = not okay
        rows.append(bool(okay))
        print(("PASS " if okay else "FAIL ") + name, flush=True)

    binaries, client = build()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mirror)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    operations.Mirror.gate.set()
    try:
        with ServiceFixture(binaries) as service:
            scenarios(service, client, f"http://127.0.0.1:{server.server_port}", check)
    finally:
        server.shutdown()
        server.server_close()
    print(f"SUMMARY pass={rows.count(True)} fail={rows.count(False)} skip={rows.count(None)} total={len(rows)}")
    return int(False in rows)


if __name__ == "__main__":
    raise SystemExit(main())
