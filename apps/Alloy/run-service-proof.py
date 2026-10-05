#!/usr/bin/env python3
"""Exercise the app's real controller across private XPC processes. Author: Timur Isaev."""
import hashlib
import http.server
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
SERVICE = PACKAGE.parents[1] / "runtime/session-service"
sys.path.insert(0, str(SERVICE))
from proof_support import ServiceFixture, build  # noqa: E402
from launch_fixture import launch_input  # noqa: E402

LIBRARY = SERVICE.parent / "store-catalog/Tests/Fixtures/MultiGameLibrary"
PAYLOAD = b"alloy-client-runtime-fixture\n" * 40_000
DIGEST = "sha256:" + hashlib.sha256(PAYLOAD).hexdigest()


class Mirror(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        try:
            for offset in range(0, len(PAYLOAD), 8192):
                self.wfile.write(PAYLOAD[offset:offset + 8192])
                self.wfile.flush()
                time.sleep(0.035)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def build_client():
    subprocess.run(["swift", "build", "--package-path", PACKAGE, "--jobs", "2"], check=True, timeout=300)
    value = subprocess.check_output(["swift", "build", "--package-path", PACKAGE, "--show-bin-path"],
                                    text=True, timeout=30)
    return Path(value.strip())


def write_recipe(fixture, mirror):
    installation = fixture.request("catalog.get", {"identifier": "steam-910001"})["installations"][0]
    fingerprint = installation["fingerprint"]
    recipe = {"install": {"gameID": "steam-910001", "installationID": installation["installationID"],
                          "generationID": "rtg_service_fixture_001",
                          "layers": [{"name": "fixture", "version": "1", "digest": DIGEST,
                                      "size": len(PAYLOAD), "mediaType": "application/octet-stream",
                                      "role": "host-runtime"}], "baseURLs": [mirror]},
              "expectedBuildID": fingerprint["buildid"], "expectedFingerprint": fingerprint["aggregate_sha256"],
              "launch": launch_input(fixture, DIGEST, len(PAYLOAD), discovered=installation)}
    path = fixture.root / "client-fixture.json"
    path.write_text(json.dumps(recipe))
    path.chmod(0o600)
    return path


def probe(binaries, fixture, recipe, command="snapshot", identifier=None):
    argv = [binaries / "alloy-client-probe", fixture.endpoint, recipe, fixture.root / "client", command]
    if identifier:
        argv.append(identifier)
    result = subprocess.run(argv, capture_output=True, text=True, timeout=40)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def wait_probe(binaries, fixture, recipe, predicate):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        value = probe(binaries, fixture, recipe)
        if predicate(value):
            return value
        time.sleep(0.1)
    raise RuntimeError("client observation deadline: " + json.dumps(value))


def run_flow(service, client, mirror, check, with_session):
    with ServiceFixture(service, libraries=[LIBRARY]) as fixture:
        recipe = write_recipe(fixture, mirror)
        broken = json.loads(recipe.read_text())
        broken["expectedBuildID"] = "999999"
        broken_path = fixture.root / "incorrect-build.json"
        broken_path.write_text(json.dumps(broken))
        broken_path.chmod(0o600)
        refused = probe(client, fixture, broken_path, "plan")
        check("incorrect-build-refused-before-clean-control", refused.get("problem") == "CLIENT-BUILD-CHANGED"
              and not refused["planned"] and not refused["operations"])
        observed = probe(client, fixture, recipe)
        check("actual-catalog-builds", [(g["id"], g["builds"]) for g in observed["games"]]
              == [("steam-910001", ["21"]), ("steam-910002", ["42"])])
        clean = probe(client, fixture, recipe, "plan")
        check("service-revalidated-runtime-plan", clean["planned"] and not clean.get("problem"))
        started = probe(client, fixture, recipe, "install")
        identifier = started["operations"][0]["id"]
        replay = probe(client, fixture, recipe, "install")
        check("client-restart-reuses-request", len(replay["operations"]) == 1
              and replay["operations"][0]["id"] == identifier)
        paused = probe(client, fixture, recipe, "pause", identifier)
        check("pause-reaches-service", paused["operations"][0]["state"] == "Paused")
        wait_probe(client, fixture, recipe, lambda v: not v["operations"][0]["workerActive"])
        probe(client, fixture, recipe, "resume", identifier)
        completed = wait_probe(client, fixture, recipe, lambda v: v["operations"][0]["state"] == "Succeeded")
        check("resume-completes-exact-operation", completed["operations"][0]["id"] == identifier
              and completed["operations"][0]["bytesCompleted"] == len(PAYLOAD))
        old = completed["instanceID"]
        fixture.restart()
        restored = probe(client, fixture, recipe)
        check("service-restart-keeps-operation", restored["instanceID"] != old
              and restored["operations"][0]["id"] == identifier
              and restored["operations"][0]["state"] == "Succeeded")
        if with_session:
            session = probe(client, fixture, recipe, "session-start")
            if not session["sessions"]:
                raise RuntimeError("session action failed: " + json.dumps(session))
            session_id = session["sessions"][0]["id"]
            active = wait_probe(client, fixture, recipe, lambda v: len(v["sessions"][0]["liveNodes"]) == 3)
            check("native-session-tree-observed", not active["sessions"][0]["finished"])
            probe(client, fixture, recipe, "session-stop", session_id)
            stopped = wait_probe(client, fixture, recipe, lambda v: v["sessions"][0]["finished"])
            check("native-session-whole-tree-stopped", stopped["sessions"][0]["state"] == "Stopped")
            replay = probe(client, fixture, recipe, "session-start")
            check("session-retry-does-not-relaunch", replay["sessions"] == stopped["sessions"])
        else:
            print("SKIP native session: actual host has less than 8 GiB or is not Apple Silicon", flush=True)


def main():
    rows = []

    def check(name, okay):
        rows.append(bool(okay))
        print(("PASS " if okay else "FAIL ") + name, flush=True)

    service, client = build(), build_client()
    host = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, timeout=5)
    with_session = int(host.strip()) >= 8 * 1024**3 and __import__("platform").machine() == "arm64"
    before = {str(p.relative_to(LIBRARY)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in LIBRARY.rglob("*") if p.is_file()}
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mirror)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        mirror = f"http://127.0.0.1:{server.server_port}"
        run_flow(service, client, mirror, check, with_session)
        with ServiceFixture(service, libraries=[LIBRARY]) as fixture:
            recipe = write_recipe(fixture, mirror)
            started = probe(client, fixture, recipe, "install")
            identifier = started["operations"][0]["id"]
            probe(client, fixture, recipe, "cancel", identifier)
            cancelled = wait_probe(client, fixture, recipe, lambda v: v["operations"][0]["state"] == "Cancelled")
            check("runtime-cancellation-is-terminal", cancelled["operations"][0]["id"] == identifier)
            replay = probe(client, fixture, recipe, "install")
            check("cancelled-retry-does-not-create-operation", len(replay["operations"]) == 1
                  and replay["operations"][0]["state"] == "Cancelled")
    finally:
        server.shutdown()
        server.server_close()
    after = {str(p.relative_to(LIBRARY)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in LIBRARY.rglob("*") if p.is_file()}
    check("storefront-payload-unchanged", before == after)
    print(f"SUMMARY pass={sum(rows)} fail={len(rows) - sum(rows)} total={len(rows)}")
    return int(not all(rows))


if __name__ == "__main__":
    raise SystemExit(main())
