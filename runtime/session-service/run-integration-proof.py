#!/usr/bin/env python3
"""One-command local-service handoff for #162/#163. Author: Timur Isaev."""
import argparse
import base64
import hashlib
import http.server
import importlib.util
import json
import threading
from proof_support import PACKAGE, ServiceFixture, build
from launch_fixture import digest, launch_input

spec = importlib.util.spec_from_file_location("session_proof", PACKAGE / "run-session-proof.py")
sessions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sessions)
operations = sessions.operations


def typed(fixture, command, value):
    return json.loads(fixture.call(command, json.dumps(value)).stdout)


def library_bytes():
    return {str(path.relative_to(operations.LIBRARY)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in operations.LIBRARY.rglob("*") if path.is_file()}


def exercise(binaries, mirror, check, negative):
    before = library_bytes()
    with ServiceFixture(binaries, libraries=[operations.LIBRARY]) as fixture:
        catalog = fixture.request("catalog.list", {"limit": 1})
        game = catalog["games"][0]
        detail = fixture.request("catalog.get", {"identifier": game["gameID"]})
        installation = detail["installations"][0]
        check("discover-committed-synthetic-title", game["gameID"] == "steam-910001"
              and game["buildIDs"] == ["21"] and installation["fingerprint"]["file_count"] == 1)
        plan = fixture.request("install.plan", {
            "gameID": game["gameID"], "installationID": installation["installationID"],
            "generationID": "rtg_service_fixture_001",
            "layers": [{"name": "fixture", "version": "1", "digest": operations.DIGEST,
                        "size": len(operations.PAYLOAD), "mediaType": "application/octet-stream", "role": "host-runtime"}],
            "baseURLs": [mirror]})
        queued = fixture.request("install.start", {"identifier": plan["planID"], "key": "handoff-install"})
        cursor = fixture.request("operation.updates", {"operationID": queued["operationID"], "nextIndex": 0})["next"]
        fixture.request("operation.run", {"identifier": queued["operationID"]})
        completed = operations.poll(fixture, queued["operationID"])
        reference = json.loads((fixture.root / "content/references" / game["gameID"] / "active.json").read_text())
        check("install-exact-title-generation", reference == operations.result(completed)
              and operations.object_path(fixture).read_bytes() == operations.PAYLOAD)
        inputs = launch_input(fixture, operations.DIGEST, len(operations.PAYLOAD), discovered=installation)
        preview = typed(fixture, "typed-preview", inputs)
        check("preview-binds-discovered-build", preview["specification"]["gameId"] == game["gameID"]
              and preview["specification"]["inputDigests"]["gameBuild"] == digest(inputs["build"])
              and preview["generation"] == reference)
        check("preview-honestly-incomplete", not preview["specification"]["runtimeReady"]
              and not preview["specification"]["productionEligible"] and preview["specification"]["notYetLowered"])
        fixture.request("launch.game", {"identifier": preview["previewID"]}, code="LAUNCH_NOT_RUNTIME_READY")
        check("real-game-refused", True)
        broken = typed(fixture, "typed-preview", inputs)
        path = fixture.root / "state/previews" / (broken["previewID"] + ".json")
        record = json.loads(path.read_text())
        export = json.loads(base64.b64decode(record["preview"]["canonicalExport"]))
        export["runtimeReady"] = True
        record["preview"]["canonicalExport"] = base64.b64encode(json.dumps(export).encode()).decode()
        path.write_text(json.dumps(record))
        response = json.loads(fixture.call("launch.verify", json.dumps({"identifier": broken["previewID"]}), check=False).stdout)
        check("broken-export-detected-before-clean-control", response["code"] == ("OK" if negative else "CONFLICT"))
        clean = fixture.request("launch.verify", {"identifier": preview["previewID"]})
        check("clean-export-still-verifies", clean == preview)
        start = {"previewID": preview["previewID"], "key": "handoff-stop", "scenario": "hang"}
        session = typed(fixture, "typed-fixture-start", start)
        identifier = session["record"]["sessionID"]
        running = sessions.wait_session(fixture, identifier, lambda value: len(value["liveNodes"]) == 3)
        check("fixture-retains-title-generation", all(node["lease"]["gameId"] == game["gameID"]
              and node["lease"]["generationId"] == reference["generationId"] for node in running["nodes"]))
        typed(fixture, "typed-session-stop", {"identifier": identifier})
        stopped = sessions.wait_session(fixture, identifier, sessions.finished)
        check("typed-client-stops-whole-tree", stopped["state"] == "STOPPED" and len(stopped["nodes"]) == 3)
        start["key"] = "handoff-interrupt"
        identifier = typed(fixture, "typed-fixture-start", start)["record"]["sessionID"]
        sessions.wait_session(fixture, identifier, lambda value: len(value["liveNodes"]) == 3)
        query = {"cursor": cursor, "sessionID": identifier, "previewID": preview["previewID"]}
        before_restart = typed(fixture, "typed-snapshot", query)
        fixture.restart()
        interrupted = sessions.wait_session(fixture, identifier, sessions.finished)
        after_restart = typed(fixture, "typed-snapshot", query)
        check("typed-client-reconnects-after-service-death",
              after_restart["info"]["instanceID"] != before_restart["info"]["instanceID"]
              and after_restart["session"] == interrupted and interrupted["state"] == "INTERRUPTED")
        check("operation-result-and-cursor-survive", after_restart["operation"] == before_restart["operation"]
              and after_restart["operation"]["snapshot"] == completed
              and after_restart["catalog"] == before_restart["catalog"])
        replay = typed(fixture, "typed-fixture-start", start)
        check("interrupted-session-replay-does-not-relaunch", replay == interrupted)
        uninstall = fixture.request("uninstall.plan", {"gameID": game["gameID"],
                                                        "installationID": installation["installationID"]})
        operations.execute(fixture, "uninstall.start", {"identifier": uninstall["planID"], "key": "handoff-uninstall"})
        gc = operations.execute(fixture, "gc.start", {"key": "handoff-gc"})
        check("exact-cleanup-after-reconnect", operations.result(gc)["removedObjectDigests"] == [operations.DIGEST]
              and operations.result(gc)["after"]["leaseCount"] == 0)
    check("read-only-library-unchanged", before == library_bytes())


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
        exercise(binaries, f"http://127.0.0.1:{server.server_port}", check, args.negative_control)
    finally:
        server.shutdown()
        server.server_close()
    print(f"SUMMARY pass={sum(rows)} fail={len(rows) - sum(rows)} total={len(rows)}")
    return int(not all(rows))


if __name__ == "__main__":
    raise SystemExit(main())
