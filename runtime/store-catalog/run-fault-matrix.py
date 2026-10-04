#!/usr/bin/env python3
"""Synthetic CLI lifecycle and every outer journal boundary. Author: Timur Isaev."""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

PACKAGE = Path(__file__).resolve().parent
BINARY = PACKAGE / ".build/debug/alloy-store-catalog"
LIBRARY = PACKAGE / "Tests/Fixtures/MultiGameLibrary"
PAYLOAD = b"catalog synthetic runtime layer\n"
DIGEST = "sha256:" + hashlib.sha256(PAYLOAD).hexdigest()
POINTS = ["temp-written", "temp-synced", "published", "directory-synced"]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        self.wfile.write(PAYLOAD)

    def log_message(self, *_args):
        pass


def invoke(*args, fault=None, control=None, control_id=None, status=0):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ALLOY_CATALOG_")}
    for key, value in (("FAULT", fault), ("CONTROL", control), ("CONTROL_OPERATION", control_id)):
        if value is not None:
            environment["ALLOY_CATALOG_" + key] = value
    child = subprocess.run([str(BINARY), *map(str, args)], env=environment,
                           capture_output=True, text=True, timeout=40)
    assert child.returncode == status, (args, child.returncode, status, child.stdout[-2000:], child.stderr[-2000:])
    return json.loads(child.stdout) if child.returncode == 0 else None


def result(operation):
    return json.loads(base64.b64decode(operation["result"]))


def tree(root):
    return {str(path.relative_to(root)): (path.stat().st_size, path.stat().st_mtime_ns,
                                         hashlib.sha256(path.read_bytes()).hexdigest())
            for path in root.rglob("*") if path.is_file()}


class Scenario:
    def __init__(self, root, mirror):
        self.root = root
        self.state = root / "catalog"
        self.content = root / "content"
        self.mirror = mirror
        root.mkdir(parents=True)
        self.layers = root / "layers.json"
        self.layers.write_text(json.dumps([{"name": "fixture", "version": "1", "digest": DIGEST,
                                            "mediaType": "application/octet-stream", "size": len(PAYLOAD),
                                            "role": "host-runtime"}]))

    def call(self, command, *args, **kwargs):
        return invoke(command, self.state, self.content, *args, **kwargs)

    def plan(self, generation="generation"):
        return self.call("plan-install", "fixture", "installation", generation, self.layers, self.mirror)

    def install(self):
        plan = self.plan()
        queued = self.call("start-install", plan["planID"], "install")
        completed = self.call("run", queued["operationID"])
        assert completed["state"] == "SUCCEEDED", completed
        return plan, completed

    def corrupt(self):
        obj = self.object_path()
        obj.chmod(0o644)
        with obj.open("r+b") as handle:
            handle.write(b"X" * len(PAYLOAD))
        obj.chmod(0o444)
        assert obj.read_bytes() != PAYLOAD

    def object_path(self):
        digest = DIGEST.split(":")[1]
        return self.content / "objects/sha256" / digest[:2] / digest[2:]

    def queue(self, kind, fault=None, status=0):
        options = {"fault": fault, "status": status}
        if kind == "install":
            return self.call("start-install", self.plan()["planID"], "install", **options)
        if kind == "repair":
            return self.call("repair", "installation", "repair", **options)
        if kind == "uninstall":
            if not hasattr(self, "uninstall_plan"):
                self.uninstall_plan = self.call("plan-uninstall", "fixture", "installation")
            return self.call("start-uninstall", self.uninstall_plan["planID"], "uninstall", **options)
        if kind in ("inventory", "gc"):
            return self.call(kind, kind, **options)
        if kind == "discover":
            return self.call("discover-operation", "discover", LIBRARY, **options)
        installs = invoke("discover", LIBRARY)
        return self.call("fingerprint-operation", "fingerprint", installs[0]["installationID"], LIBRARY, **options)

    def prepare(self, kind):
        if kind in ("repair", "uninstall", "gc"):
            self.install()
        if kind == "repair":
            self.corrupt()
        if kind == "gc":
            queued = self.queue("uninstall")
            assert self.call("run", queued["operationID"])["state"] == "SUCCEEDED"

    def verify(self, kind, operation):
        assert operation["state"] == "SUCCEEDED", operation
        value = result(operation)
        if kind in ("install", "repair"):
            assert self.object_path().read_bytes() == PAYLOAD
            layers = list((self.content / "generations/fixture/generation/layers").iterdir())
            assert len(layers) == 1 and layers[0].read_bytes() == PAYLOAD
            assert (self.content / "references/fixture/active.json").is_file()
        elif kind == "uninstall":
            assert not (self.content / "references/fixture/active.json").exists()
        elif kind == "gc":
            assert value["removedObjectDigests"] == [DIGEST], value
            assert value["after"]["objectCount"] == 0
        elif kind == "inventory":
            assert value["objectCount"] == 0 and value["objectBytes"] == 0
        elif kind == "discover":
            assert sorted(item["fingerprint"]["appid"] for item in value) == ["910001", "910002"]
        elif kind == "fingerprint":
            assert value["file_count"] == 1 and value["appid"] in ("910001", "910002")


def lifecycle(case, negative):
    page = invoke("list", LIBRARY)
    assert [item["gameID"] for item in page["games"]] == ["steam-910001", "steam-910002"]
    assert invoke("get", LIBRARY, "steam-910001")["summary"]["buildIDs"] == ["21"]
    plan = case.plan()
    queued = case.call("start-install", plan["planID"], "install")
    paused = case.call("run", queued["operationID"], control="pause", control_id=queued["operationID"])
    assert paused["state"] == "PAUSED"
    assert not (case.content / "references/fixture/active.json").exists()
    completed = case.call("resume", queued["operationID"])
    case.verify("install", completed)
    before = tree(case.root)
    assert case.call("start-install", plan["planID"], "install") == completed
    assert tree(case.root) == before
    other = case.plan("other-generation")
    before = tree(case.root)
    case.call("start-install", other["planID"], "install", status=1)
    assert tree(case.root) == before
    save = case.content / "volumes/fixture/saves/sentinel.sav"
    save.parent.mkdir(parents=True, exist_ok=True)
    save.write_bytes(b"retained synthetic save")
    case.corrupt()
    repaired = case.call("run", case.queue("repair")["operationID"])
    case.verify("repair", repaired)
    expected = b"deliberately wrong oracle" if negative else PAYLOAD
    assert case.object_path().read_bytes() == expected, "independent repaired-byte oracle"
    removed = case.call("run", case.queue("uninstall")["operationID"])
    case.verify("uninstall", removed)
    before = tree(case.root)
    assert case.queue("uninstall") == removed
    assert tree(case.root) == before
    collected = case.call("run", case.queue("gc")["operationID"])
    case.verify("gc", collected)
    assert save.read_bytes() == b"retained synthetic save"
    clean = case.call("gc", "gc-clean")
    assert result(case.call("run", clean["operationID"]))["removedObjectDigests"] == []
    assert case.call("operations")
    assert case.call("operation", completed["operationID"]) == completed


def boundary(case, kind, fault):
    case.prepare(kind)
    if fault.startswith("QUEUED."):
        case.queue(kind, fault=fault, status=-9)
        operation = case.queue(kind)
    else:
        operation = case.queue(kind)
        case.call("run", operation["operationID"], fault=fault, status=-9)
    completed = case.call("run", operation["operationID"])
    case.verify(kind, completed)
    before = tree(case.root)
    assert case.queue(kind) == completed
    assert tree(case.root) == before


def control_boundary(case, stage, point):
    operation = case.queue("install")
    identifier = operation["operationID"]
    if stage == "PAUSED":
        case.call("run", identifier, control="pause", control_id=identifier, fault=stage + "." + point, status=-9)
    elif stage == "RESUMING":
        assert case.call("run", identifier, control="pause", control_id=identifier)["state"] == "PAUSED"
        case.call("resume", identifier, fault=stage + "." + point, status=-9)
    else:
        case.call("cancel", identifier, fault=stage + "." + point, status=-9)
    current = case.call("operation", identifier)
    if stage in ("PAUSED", "RESUMING"):
        command = "resume" if current["state"] == "PAUSED" else "run"
        case.verify("install", case.call(command, identifier))
    else:
        command = "cancel" if current["state"] in ("QUEUED", "RUNNING", "PAUSED") else "run"
        assert case.call(command, identifier)["state"] == "CANCELLED"
        assert not (case.content / "references/fixture/active.json").exists()


def failure_boundary(case, point):
    bad = json.loads(case.layers.read_text())
    bad[0]["digest"] = "sha256:" + "0" * 64
    bad_path = case.root / "wrong-digest.json"
    bad_path.write_text(json.dumps(bad))
    plan = case.call("plan-install", "fixture", "installation", "bad-generation", bad_path, case.mirror)
    operation = case.call("start-install", plan["planID"], "failure")
    case.call("run", operation["operationID"], fault="FAILED." + point, status=-9)
    case.call("run", operation["operationID"], status=1)
    failed = case.call("operation", operation["operationID"])
    assert failed["state"] == "FAILED" and "digest" in failed["error"], failed
    assert not (case.content / "references/fixture/active.json").exists()
    before = tree(case.root)
    assert case.call("start-install", plan["planID"], "failure") == failed
    assert tree(case.root) == before


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--negative-control", action="store_true")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    if not args.skip_build:
        subprocess.run(["swift", "build", "--package-path", str(PACKAGE)], check=True, timeout=180)
    outcomes = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    mirror = f"http://127.0.0.1:{server.server_port}"
    with tempfile.TemporaryDirectory(prefix="alloy-catalog-matrix-") as directory:
        root = Path(directory)

        def check(name, action):
            started = time.monotonic()
            try:
                action(Scenario(root / str(len(outcomes)), mirror))
                verdict, error = "PASS", None
            except Exception as problem:  # One case must not hide later controls.
                verdict, error = "FAIL", str(problem)
            outcomes.append({"name": name, "verdict": verdict, "error": error,
                             "elapsed_seconds": round(time.monotonic() - started, 3)})
            print(f"{verdict} {name}" + (f": {error}" if error else ""), flush=True)

        check("full-cli-lifecycle-and-idempotency", lambda case: lifecycle(case, args.negative_control))
        if not args.negative_control:
            stages = {
                "install": ["FETCHING_0", "VERIFIED", "ACTIVATING"],
                "repair": ["FETCHING_0", "VERIFIED", "REPAIRING"],
                "uninstall": ["UNINSTALLING"], "inventory": ["INVENTORY"],
                "gc": ["COLLECTING"], "discover": ["DISCOVERING"], "fingerprint": ["FINGERPRINTING"]}
            for kind, middle in stages.items():
                faults = [stage + "." + point for stage in ["QUEUED", "STARTING", *middle, "SUCCEEDED"]
                          for point in POINTS]
                faults += [middle[-1] + ".action-complete"]
                if kind in ("install", "repair"):
                    faults += ["FETCHING_0.action-complete"]
                if kind == "gc":
                    faults += ["CONTENT_STORE.after-gc-object-sweep-item"]
                for fault in faults:
                    check(kind + ":" + fault, lambda case, k=kind, f=fault: boundary(case, k, f))
            for point in POINTS:
                check("failure:FAILED." + point, lambda case, p=point: failure_boundary(case, p))
            for stage in ("PAUSED", "RESUMING", "CANCEL_REQUESTED", "CANCELLING", "CANCELLED"):
                for point in POINTS:
                    check("control:" + stage + "." + point,
                          lambda case, s=stage, p=point: control_boundary(case, s, p))
    server.shutdown()
    server.server_close()
    passed = sum(row["verdict"] == "PASS" for row in outcomes)
    failed = len(outcomes) - passed
    print(f"SUMMARY pass={passed} fail={failed} total={len(outcomes)}", flush=True)
    if args.json:
        args.json.write_text(json.dumps({"passed": passed, "failed": failed, "cases": outcomes}, indent=2) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
