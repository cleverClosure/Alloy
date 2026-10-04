#!/usr/bin/env python3
"""Actual XPC operation recovery over the completed packages. Author: Timur Isaev."""
import argparse
import base64
import hashlib
import http.server
import json
import subprocess
from pathlib import Path
import threading
import time
from proof_support import PACKAGE, ServiceFixture, build

LIBRARY = PACKAGE.parent / "store-catalog/Tests/Fixtures/MultiGameLibrary"
PAYLOAD = b"runtime service verified layer\n"
DIGEST = "sha256:" + hashlib.sha256(PAYLOAD).hexdigest()


class Mirror(http.server.BaseHTTPRequestHandler):
    gate = threading.Event()
    entered = threading.Event()

    def do_GET(self):
        self.entered.set()
        if not self.gate.wait(15):
            self.send_error(503)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        try:
            self.wfile.write(PAYLOAD)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def poll(fixture, identifier, state="SUCCEEDED"):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        operation = fixture.request("operation.get", {"identifier": identifier})
        if operation["state"] == state:
            return operation
        if operation["state"] in ("FAILED", "CANCELLED"):
            raise RuntimeError(f"unexpected operation state: {operation['state']}")
        time.sleep(0.04)
    raise RuntimeError("operation completion deadline")


def execute(fixture, method, payload):
    operation = fixture.request(method, payload)
    fixture.request("operation.run", {"identifier": operation["operationID"]})
    return poll(fixture, operation["operationID"])


def result(operation):
    return json.loads(base64.b64decode(operation["result"]))


def plan(fixture, mirror, generation="generation"):
    return fixture.request("install.plan", {
        "gameID": "fixture", "installationID": "installation", "generationID": generation,
        "layers": [{"name": "fixture", "version": "1", "digest": DIGEST, "size": len(PAYLOAD),
                    "mediaType": "application/octet-stream", "role": "host-runtime"}],
        "baseURLs": [mirror]})


def object_path(fixture):
    digest = DIGEST.split(":")[1]
    return fixture.root / "content/objects/sha256" / digest[:2] / digest[2:]


def run_lifecycle(binaries, mirror, check, negative):
    with ServiceFixture(binaries, libraries=[LIBRARY]) as fixture:
        page = fixture.request("catalog.list", {"limit": 1})
        page2 = fixture.request("catalog.list", {"limit": 1, "cursor": page["nextPageToken"]})
        check("catalog-pages", [page["games"][0]["gameID"], page2["games"][0]["gameID"]]
              == ["steam-910001", "steam-910002"])
        detail = fixture.request("catalog.get", {"identifier": "steam-910001"})
        check("catalog-details", detail["summary"]["buildIDs"] == ["21"])
        discovered = fixture.request("catalog.discover")
        check("read-only-discovery", len(discovered) == 2)
        discovered_op = execute(fixture, "discovery.start", {"key": "discover"})
        check("durable-discovery", result(discovered_op) == discovered)
        fingerprint = execute(fixture, "fingerprint.start",
                              {"identifier": discovered[0]["installationID"], "key": "fingerprint"})
        check("durable-fingerprint", result(fingerprint)["file_count"] == 1)
        inventory = execute(fixture, "inventory.start", {"key": "inventory"})
        check("empty-inventory", result(inventory)["objectCount"] == 0)
        install_plan = plan(fixture, mirror)
        queued = fixture.request("install.start", {"identifier": install_plan["planID"], "key": "install"})
        duplicate = fixture.request("install.start", {"identifier": install_plan["planID"], "key": "install"})
        check("exact-queued-replay", queued == duplicate)
        other = plan(fixture, mirror, "other-generation")
        fixture.request("install.start", {"identifier": other["planID"], "key": "install"}, code="CONFLICT")
        check("conflicting-replay-rejected", True)
        identifier = queued["operationID"]
        first = fixture.request("operation.updates", {"operationID": identifier, "nextIndex": 0})
        Mirror.gate.clear()
        Mirror.entered.clear()
        fixture.request("operation.run", {"identifier": identifier})
        check("real-worker-started", Mirror.entered.wait(10))
        paused = fixture.request("operation.pause", {"identifier": identifier})
        check("pause-observed", paused["state"] == "PAUSED")
        Mirror.gate.set()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            update = fixture.request("operation.updates", {"operationID": identifier, "nextIndex": 0})
            if not update["workerActive"]:
                break
            time.sleep(0.04)
        else:
            raise RuntimeError("paused worker deadline")
        check("no-partial-activation", not (fixture.root / "content/references/fixture/active.json").exists())
        fixture.request("operation.resume", {"identifier": identifier})
        completed = poll(fixture, identifier)
        check("verified-install-bytes", object_path(fixture).read_bytes() == (b"wrong" if negative else PAYLOAD))
        tail = fixture.request("operation.updates", first["next"])
        check("resumable-event-cursor", tail["events"][0]["index"] == first["next"]["nextIndex"]
              and tail["revision"] == len(completed["events"]))
        duplicate_tail = fixture.request("operation.updates", first["next"])
        check("duplicate-subscription-safe", tail["events"] == duplicate_tail["events"])
        fixture.request("operation.updates", {"operationID": identifier, "nextIndex": 999}, code="CONFLICT")
        check("future-cursor-rejected", True)
        old_instance = fixture.request("info")["instanceID"]
        new_info = fixture.restart()
        check("service-restarted", old_instance != new_info["instanceID"])
        replay = fixture.request("install.start", {"identifier": install_plan["planID"], "key": "install"})
        check("terminal-replay-after-restart", replay == completed)
        tail_after = fixture.request("operation.updates", tail["next"])
        check("reconnect-no-lost-events", not tail_after["events"] and tail_after["snapshot"] == completed)
        damaged = object_path(fixture)
        damaged.chmod(0o644)
        with damaged.open("r+b") as stream:
            stream.write(b"X" * len(PAYLOAD))
        damaged.chmod(0o444)
        execute(fixture, "repair.start", {"identifier": "installation", "key": "repair"})
        check("verified-repair-bytes", damaged.read_bytes() == PAYLOAD)
        unused = fixture.request("inventory.start", {"key": "cancel"})
        cancelled = fixture.request("operation.cancel", {"identifier": unused["operationID"]})
        check("queued-cancellation", cancelled["state"] == "CANCELLED")
        uninstall = fixture.request("uninstall.plan", {"gameID": "fixture", "installationID": "installation"})
        execute(fixture, "uninstall.start", {"identifier": uninstall["planID"], "key": "uninstall"})
        check("uninstall-retires-reference", not (fixture.root / "content/references/fixture/active.json").exists())
        gc = execute(fixture, "gc.start", {"key": "gc"})
        check("gc-exact-reclamation", result(gc)["removedObjectDigests"] == [DIGEST]
              and result(gc)["after"]["objectCount"] == 0)
        check("operation-list", len(fixture.request("operation.list")) == 8)


def fault_case(binaries, point, mirror, check):
    with ServiceFixture(binaries, fault=point) as fixture:
        if point == "ACTIVATING.action-complete":
            prepared = plan(fixture, mirror)
            method, payload = "install.start", {"identifier": prepared["planID"], "key": "fault"}
        else:
            method, payload = "inventory.start", {"key": "fault"}
        first = fixture.call(method, json.dumps(payload), check=False)
        if first.returncode == 0:
            identifier = json.loads(first.stdout)["payload"]["operationID"]
            fixture.call("operation.run", json.dumps({"identifier": identifier}), check=False)
        deadline = time.monotonic() + 10
        marker = fixture.root / "state/test-fault-fired"
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        if not marker.exists():
            raise RuntimeError("fault did not fire: " + point)
        fixture.restart()
        replay = fixture.request(method, payload)
        fixture.request("operation.run", {"identifier": replay["operationID"]})
        completed = poll(fixture, replay["operationID"])
        operations = fixture.request("operation.list")
        okay = len(operations) == 1 and operations[0] == completed
        if point == "ACTIVATING.action-complete":
            okay = okay and object_path(fixture).read_bytes() == PAYLOAD
            reference = json.loads((fixture.root / "content/references/fixture/active.json").read_text())
            okay = okay and reference == result(completed)
        else:
            okay = okay and result(completed)["objectCount"] == 0
        check("kill-recover-" + point, okay)


def client_death(binaries, check):
    with ServiceFixture(binaries, fault="REPLY.gate") as fixture:
        child = subprocess.Popen([str(binaries / "alloy-runtime-client"), str(fixture.endpoint),
                                  "inventory.start", "--stdin"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            child.stdin.write(json.dumps({"key": "lost-client"}))
            child.stdin.close()
            deadline = time.monotonic() + 10
            marker = fixture.root / "state/reply-ready"
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not marker.exists() or child.poll() is not None:
                raise RuntimeError("client did not reach the persisted-before-reply boundary")
            child.kill()
            child.wait(timeout=5)
            operation = execute(fixture, "inventory.start", {"key": "lost-client"})
            check("client-killed-after-persist-before-reply", child.returncode == -9
                  and len(fixture.request("operation.list")) == 1
                  and result(operation)["objectCount"] == 0)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            child.stdout.close()
            child.stderr.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    rows = []

    def check(name, okay):
        rows.append(bool(okay))
        print(("PASS " if okay else "FAIL ") + name, flush=True)

    binaries = build()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mirror)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    Mirror.gate.set()
    mirror = f"http://127.0.0.1:{server.server_port}"
    try:
        before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in LIBRARY.rglob("*") if p.is_file()}
        run_lifecycle(binaries, mirror, check, args.negative_control)
        after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in LIBRARY.rglob("*") if p.is_file()}
        check("storefront-fixture-unchanged", before == after)
        client_death(binaries, check)
        for stage in ("QUEUED", "STARTING", "SUCCEEDED"):
            for point in ("temp-written", "temp-synced", "published", "directory-synced"):
                fault_case(binaries, stage + "." + point, mirror, check)
        fault_case(binaries, "ACTIVATING.action-complete", mirror, check)
    finally:
        Mirror.gate.set()
        server.shutdown()
        server.server_close()
    print(f"SUMMARY pass={sum(rows)} fail={len(rows) - sum(rows)} total={len(rows)}")
    return int(not all(rows))


if __name__ == "__main__":
    raise SystemExit(main())
