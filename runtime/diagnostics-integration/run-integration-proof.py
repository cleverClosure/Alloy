#!/usr/bin/env python3
"""Independent failure-bundle oracle through the actual XPC client. Author: Timur Isaev."""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
import tempfile
import threading
import time
import uuid
from pathlib import Path
from diagnostic_fixture import PACKAGE, ROOT, ServiceFixture, build, call, operations

spec = importlib.util.spec_from_file_location("capture_proof", PACKAGE / "run-capture-proof.py")
captures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(captures)
EXPECTED = json.loads((PACKAGE / "Tests/Fixtures/expected-outcomes.json").read_text())
SEEDS = ROOT / "spikes/DIAG-001/prototype/Tests/AlloyDiagnosticsTests/Fixtures"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def text_values(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for item in value.values() for text in text_values(item)]
    if isinstance(value, list):
        return [text for item in value for text in text_values(item)]
    return []


def fields(event):
    return {field["name"]: field["value"] for field in event["fields"]}


def expected_identity(kind, key, service):
    expected = EXPECTED[kind + ":" + key]
    unavailable = "unavailable"
    if kind == "operation":
        identifier = "op-" + digest((expected["kind"] + "\0" + key).encode())
        identity = {name: unavailable for name in ["session_id", "build_id", "host_class_id", "profile_id", "profile_revision"]}
        identity.update(operation_id=identifier, game_id=expected["game"], runtime_generation_id=expected["generation"])
    else:
        identifier = "ses-" + digest(key.encode())
        identity = dict(EXPECTED["sessionIdentity"], session_id=identifier)
        host = service.request("host.info")
        for name in ("gpuFamilies", "features", "entitlements"):
            host[name] = sorted(set(host[name]))
        identity["host_class_id"] = "local-unregistered:" + digest(canonical(host))
    identity.update(process_policy_id=unavailable, provider_build_digests={unavailable: unavailable})
    return identifier, identity


def patch_bundle(path, mutate, recount=False):
    events = json.loads((path / "events.json").read_bytes())
    mutate(events)
    if recount:
        next(item for item in events[0]["fields"] if item["name"] == "event_count")["value"] = str(len(events) - 1)
    data = canonical(events)
    (path / "events.json").write_bytes(data)
    manifest = json.loads((path / "manifest.json").read_bytes())
    record = next(item for item in manifest["files"] if item["path"] == "events.json")
    record["bytes"], record["sha256"] = len(data), digest(data)
    (path / "manifest.json").write_bytes(canonical(manifest))


class Oracle:
    def __init__(self, client, service, root, check):
        self.client, self.service, self.root, self.check = client, service, root, check
        self.store = root / "store"
        call(client, "init-store", self.store)
        self.bundles = []

    def capture(self, client, service, kind, identifier, mode="terminal", seconds=30):
        if seconds == 0.1:
            return captures.capture(client, service, kind, identifier, mode, seconds)
        if kind == "operation":
            record = service.request("operation.get", {"identifier": identifier})
            key = record["idempotencyKey"]
            if key == "failed":
                deadline = time.monotonic() + 10
                while record["state"] != "FAILED" and time.monotonic() < deadline:
                    record = service.request("operation.get", {"identifier": identifier})
                    time.sleep(0.02)
                if record["state"] != "FAILED":
                    raise RuntimeError("actual download failure was not observed")
                # Synthetic privacy fault in a real failed operation's private test journal.
                path = service.root / "state/catalog/operations" / (identifier + ".json")
                record["error"] = (SEEDS / "redaction-seeded.txt").read_text()
                replacement = path.with_suffix(".seed")
                replacement.write_bytes(canonical(record))
                replacement.chmod(0o600)
                os.replace(replacement, path)
        else:
            record = service.request("session.get", {"identifier": identifier})
            key = record["record"]["request"]["key"]
        expected = EXPECTED[kind + ":" + key]
        wanted_id, identity = expected_identity(kind, key, service)
        if wanted_id != identifier:
            raise RuntimeError("independent fixture identifier disagrees with service")
        summary = call(client, "create", service.endpoint, kind, identifier, mode, seconds, self.store, timeout=45)
        preview = call(client, "preview", self.store, summary["bundleID"])
        events = preview["events"]
        exact = all(all(event["correlation"][name] == value for name, value in identity.items()) for event in events)
        requests = [event["correlation"]["request_id"] for event in events]
        exact = exact and all(str(uuid.UUID(value)).lower() == value.lower() for value in requests)
        self.check("independent-identity-" + kind + "-" + key, exact and summary["targetID"] == wanted_id)
        self.check("independent-outcome-" + kind + "-" + key,
                   summary["outcome"] == expected["outcome"] and summary["complete"] == expected["complete"])
        self.bundles.append((kind + ":" + key, summary["bundleID"]))
        artifact = [event for event in events if event["event_code"] in ("runtime.native.sample", "runtime.native.exit")]
        return dict(summary, artifacts=artifact, elapsedSeconds=float(fields(events[0])["elapsed_seconds"]))

    def lifecycle(self):
        snapshots = {str(path): digest(path.read_bytes()) for path in (self.service.root / "state").rglob("*.json")}
        secrets = json.loads((SEEDS / "redaction-secrets.json").read_text())
        for index, (scenario, identifier) in enumerate(self.bundles):
            preview = call(self.client, "preview", self.store, identifier)
            exported = self.root / ("export-" + str(index))
            call(self.client, "export", self.store, identifier, exported)
            values = b"\n".join(path.read_bytes() for path in exported.iterdir())
            # Decode strings too, so JSON escaping cannot hide a supported planted value.
            decoded = "\n".join(text_values(json.loads((exported / "events.json").read_bytes())))
            survivors = [secret for secret in secrets if secret.encode() in values or secret in decoded]
            self.check("zero-planted-secret-survivors-" + scenario, not survivors)
            self.check("exact-export-manifest-" + scenario,
                       json.loads((exported / "manifest.json").read_bytes()) == preview["manifest"])
            call(self.client, "delete", self.store, identifier)
            self.check("deleted-owned-bundle-" + scenario, not (self.store / identifier).exists() and exported.exists())
        after = {str(path): digest(path.read_bytes()) for path in (self.service.root / "state").rglob("*.json")}
        self.check("bundle-deletion-preserves-durable-service-records", snapshots == after)

    def mutations(self):
        def rejected(name, mutate, recount=False, native=False):
            candidate = next(((case, ident) for case, ident in self.bundles if not native or case == "session:hang"), None)
            if candidate is None:
                self.check(name, None)
                return
            _, identifier = candidate
            path = self.store / identifier
            original = {file.name: file.read_bytes() for file in path.iterdir()}
            try:
                patch_bundle(path, mutate, recount)
                result = call(self.client, "preview", self.store, identifier, okay=False)
                self.check(name, result.returncode == 1 and not result.stdout)
            finally:
                for name, data in original.items():
                    (path / name).write_bytes(data)
        rejected("corrupt-identity-detected", lambda events: events[-1]["correlation"].update(build_id="wrong-build"))
        rejected("omitted-event-detected", lambda events: events.pop(1))
        rejected("omitted-event-with-recount-detected", lambda events: events.pop(1), recount=True)
        rejected("omitted-native-artifact-detected", lambda events: events.__setitem__(slice(None),
                 [event for event in events if event["event_code"] != "runtime.native.sample"]), recount=True, native=True)
        rejected("supported-secret-in-sealed-payload-detected", lambda events:
                 events[-1]["fields"].append({"name": "diagnostic_detail", "value": "password=must-not-export",
                                              "data_class": "error_code"}))
        _, identifier = self.bundles[0]
        manifest = self.store / identifier / "manifest.json"
        original = manifest.read_bytes()
        try:
            manifest.write_bytes(b"x" * 1_048_577)
            self.check("oversized-artifact-detected", call(self.client, "preview", self.store, identifier,
                       okay=False).returncode == 1)
        finally:
            manifest.write_bytes(original)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    rows = []

    def check(name, okay):
        if args.negative_control and name == "independent-identity-operation-clean":
            okay = not okay
        rows.append(okay)
        print(("SKIP " if okay is None else "PASS " if okay else "FAIL ") + name, flush=True)

    binaries, client = build()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), captures.Mirror)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    operations.Mirror.gate.set()
    try:
        with tempfile.TemporaryDirectory(prefix="alloy-diag-integrated-") as temporary, ServiceFixture(binaries) as service:
            oracle = Oracle(client, service, Path(temporary).resolve(), check)
            captures.scenarios(service, client, f"http://127.0.0.1:{server.server_port}", check, oracle.capture)
            expected_bundles = 6 if service.request("host.info")["memoryGiB"] >= 8 and \
                service.request("host.info")["architecture"] == "arm64" else 2
            check("expected-failure-bundle-count", len(oracle.bundles) == expected_bundles)
            service.stop_service()
            oracle.mutations()
            oracle.lifecycle()
            check("expected-proof-row-count", len(rows) == (46 if expected_bundles == 6 else 26))
    finally:
        server.shutdown()
        server.server_close()
    print(f"SUMMARY pass={rows.count(True)} fail={rows.count(False)} skip={rows.count(None)} total={len(rows)}")
    return int(False in rows)


if __name__ == "__main__":
    raise SystemExit(main())
