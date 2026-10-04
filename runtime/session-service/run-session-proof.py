#!/usr/bin/env python3
"""Fixed native fixture tree, exact leases and launch refusal. Author: Timur Isaev."""
import argparse
import base64
import http.server
import importlib.util
import json
import threading
import time
from proof_support import PACKAGE, ServiceFixture, build
from launch_fixture import launch_input

spec = importlib.util.spec_from_file_location("operation_proof", PACKAGE / "run-operation-proof.py")
operations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operations)


def wait_session(fixture, identifier, predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fixture.request("session.get", {"identifier": identifier})
        if predicate(value):
            return value
        time.sleep(0.03)
    raise RuntimeError("session deadline: " + json.dumps(value))


def start(fixture, preview, key, scenario):
    value = fixture.request("fixture.start", {"previewID": preview["previewID"], "key": key, "scenario": scenario})
    return value["record"]["sessionID"]


def finished(value):
    return value["state"] in ("SUCCEEDED", "FAILED", "STOPPED", "INTERRUPTED") and not value["liveNodes"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    rows = []

    def check(name, okay):
        rows.append(bool(okay))
        print(("PASS " if okay else "FAIL ") + name, flush=True)

    binaries = build()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), operations.Mirror)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    operations.Mirror.gate.set()
    try:
        with ServiceFixture(binaries, fixture_mode=False) as ordinary:
            ordinary.request("launch.resolve", {}, code="LAUNCH_NOT_RUNTIME_READY")
            ordinary.request("fixture.start", {}, code="LAUNCH_NOT_RUNTIME_READY")
            check("ordinary-service-cannot-enable-fixture", True)
        with ServiceFixture(binaries) as fixture:
            prepared = operations.plan(fixture, f"http://127.0.0.1:{server.server_port}", "rtg_service_fixture_001")
            installed = operations.execute(fixture, "install.start", {"identifier": prepared["planID"], "key": "install"})
            inputs = launch_input(fixture, operations.DIGEST, len(operations.PAYLOAD))
            preview = fixture.request("launch.resolve", inputs)
            check("actual-compiler-preview", preview["specification"]["verification"] == "unsigned-development"
                  and preview["generation"] == operations.result(installed))
            expected_ready = args.negative_control
            check("coverage-gap-preserved", preview["specification"]["runtimeReady"] == expected_ready
                  and not preview["specification"]["productionEligible"]
                  and len(preview["specification"]["notYetLowered"]) > 0)
            verified = fixture.request("launch.verify", {"identifier": preview["previewID"]})
            check("canonical-export-reverified", verified == preview)
            fixture.request("launch.game", {"identifier": preview["previewID"]}, code="LAUNCH_NOT_RUNTIME_READY")
            check("real-game-refused", True)
            tampered = fixture.request("launch.resolve", inputs)
            path = fixture.root / "state/previews" / (tampered["previewID"] + ".json")
            record = json.loads(path.read_text())
            exported = json.loads(base64.b64decode(record["preview"]["canonicalExport"]))
            exported["runtimeReady"] = True
            record["preview"]["canonicalExport"] = base64.b64encode(json.dumps(exported).encode()).decode()
            path.write_text(json.dumps(record))
            fixture.request("launch.verify", {"identifier": tampered["previewID"]}, code="CONFLICT")
            check("tampered-export-refused", True)
            short = fixture.request("launch.resolve", {**inputs, "validForSeconds": 1})
            time.sleep(1.1)
            fixture.request("launch.verify", {"identifier": short["previewID"]}, code="REQUEST_EXPIRED")
            check("expired-preview-refused", True)
            identifier = start(fixture, preview, "normal", "normal")
            normal = wait_session(fixture, identifier, finished)
            check("normal-tree-exit", normal["state"] == "SUCCEEDED" and len(normal["nodes"]) == 3)
            replay = fixture.request("fixture.start", {"previewID": preview["previewID"], "key": "normal", "scenario": "normal"})
            check("session-key-replay", replay == normal)
            fixture.request("fixture.start", {"previewID": preview["previewID"], "key": "normal", "scenario": "hang"},
                            code="CONFLICT")
            check("session-key-conflict", True)
            identifier = start(fixture, preview, "startup", "startupFailure")
            failed = wait_session(fixture, identifier, finished)
            check("startup-failure", failed["state"] == "FAILED" and failed["exitCode"] == 42 and not failed["nodes"])
            identifier = start(fixture, preview, "escalation", "ignoreTermination")
            running = wait_session(fixture, identifier, lambda value: len(value["liveNodes"]) == 3)
            identities = [node["lease"]["holder"] for node in running["nodes"]]
            check("each-node-holds-exact-lease", len({item["processId"] for item in identities}) == 3
                  and all(item["startTimeSeconds"] > 0 for item in identities)
                  and all(node["lease"]["generationId"] == "rtg_service_fixture_001" for node in running["nodes"]))
            fixture.request("session.stop", {"identifier": identifier})
            stopped = wait_session(fixture, identifier, finished)
            check("stop-escalates-and-reaps-tree", stopped["state"] == "STOPPED"
                  and any(node["state"] == "EXITED_ESCALATED" for node in stopped["nodes"]))
            identifier = start(fixture, preview, "agent-death", "hang")
            wait_session(fixture, identifier, lambda value: len(value["liveNodes"]) == 3)
            fixture.request("fixture.kill-agent", {"identifier": identifier})
            dead = wait_session(fixture, identifier, finished)
            check("agent-death-cleans-descendants", dead["state"] == "FAILED" and len(dead["nodes"]) == 3)
            identifier = start(fixture, preview, "service-death", "hang")
            wait_session(fixture, identifier, lambda value: len(value["liveNodes"]) == 3)
            fixture.restart()
            interrupted = wait_session(fixture, identifier, finished)
            check("service-death-reconciled", interrupted["state"] == "INTERRUPTED"
                  and len(interrupted["nodes"]) == 3)
            identifier = start(fixture, preview, "watchdog", "hang")
            wait_session(fixture, identifier, lambda value: len(value["liveNodes"]) == 3)
            bounded = wait_session(fixture, identifier, finished, timeout=25)
            check("unattended-hang-has-hard-deadline", bounded["state"] == "FAILED" and bounded["exitCode"] == 43
                  and len(bounded["nodes"]) == 3
                  and any(node["state"] == "EXITED_WATCHDOG" for node in bounded["nodes"]))
            identifier = start(fixture, preview, "lease", "hang")
            wait_session(fixture, identifier, lambda value: len(value["liveNodes"]) == 3)
            uninstall = fixture.request("uninstall.plan", {"gameID": "fixture", "installationID": "installation"})
            operations.execute(fixture, "uninstall.start", {"identifier": uninstall["planID"], "key": "uninstall"})
            gc = operations.execute(fixture, "gc.start", {"key": "leased-gc"})
            check("live-leases-block-gc", operations.result(gc)["removedObjectDigests"] == []
                  and operations.object_path(fixture).read_bytes() == operations.PAYLOAD)
            fixture.request("launch.verify", {"identifier": preview["previewID"]}, code="NOT_FOUND")
            check("changed-generation-invalidates-preview", True)
            fixture.request("session.stop", {"identifier": identifier})
            wait_session(fixture, identifier, finished)
            gc = operations.execute(fixture, "gc.start", {"key": "released-gc"})
            check("released-leases-allow-gc", operations.result(gc)["removedObjectDigests"] == [operations.DIGEST]
                  and operations.result(gc)["after"]["leaseCount"] == 0)
            check("session-list-exact", len(fixture.request("session.list")) == 7)
    finally:
        server.shutdown()
        server.server_close()
    print(f"SUMMARY pass={sum(rows)} fail={len(rows) - sum(rows)} total={len(rows)}")
    return int(not all(rows))


if __name__ == "__main__":
    raise SystemExit(main())
