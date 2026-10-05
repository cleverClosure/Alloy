#!/usr/bin/env python3
"""Offline lifecycle of a bundle created from the live service. Author: Timur Isaev."""
import argparse
import hashlib
import tempfile
from pathlib import Path
from diagnostic_fixture import ServiceFixture, build, call, operations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    rows = []

    def check(name, okay):
        if args.negative_control and name == "export-matches-preview":
            okay = not okay
        rows.append(bool(okay))
        print(("PASS " if okay else "FAIL ") + name, flush=True)

    binaries, client = build()
    with tempfile.TemporaryDirectory(prefix="alloy-diag-lifecycle-") as temporary, ServiceFixture(binaries) as service:
        root = Path(temporary).resolve()
        store = root / "store"
        call(client, "init-store", store)
        operation = operations.execute(service, "inventory.start", {"key": "lifecycle"})
        summary = call(client, "create", service.endpoint, "operation", operation["operationID"], "terminal", 5, store)
        identifier = summary["bundleID"]
        before = {str(path.relative_to(service.root)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in (service.root / "state").rglob("*.json")}
        service.stop_service()
        preview = call(client, "preview", store, identifier)
        check("offline-preview-and-summary", summary == call(client, "summary", store, identifier)
              and preview["summary"] == summary and preview["manifest"]["localOnly"])
        exported = root / "exported"
        call(client, "export", store, identifier, exported)
        expected = {item["path"]: item["sha256"] for item in preview["manifest"]["files"]}
        actual = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in exported.iterdir() if path.name != "manifest.json"}
        check("export-matches-preview", expected == actual)
        check("restrictive-permissions", all(path.stat().st_mode & 0o077 == 0
              for path in [store, exported, *exported.iterdir(), *store.rglob("*")]))
        unrelated = root / "unrelated"
        unrelated.write_text("must survive")
        refused = call(client, "export", store, identifier, unrelated, okay=False)
        check("existing-destination-refused", refused.returncode == 1 and unrelated.read_text() == "must survive")
        link = root / "link"
        link.symlink_to(exported, target_is_directory=True)
        refused = call(client, "export", store, identifier, link, okay=False)
        check("symlink-destination-refused", refused.returncode == 1)
        refused = call(client, "delete", store, "../unrelated", okay=False)
        check("deletion-traversal-refused", refused.returncode == 1 and unrelated.exists())
        call(client, "delete", store, identifier)
        after = {str(path.relative_to(service.root)): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in (service.root / "state").rglob("*.json")}
        check("delete-preserves-service-and-export", before == after and unrelated.exists()
              and exported.exists() and not (store / identifier).exists())
    print(f"SUMMARY pass={sum(rows)} fail={len(rows) - sum(rows)} total={len(rows)}")
    return int(not all(rows))


if __name__ == "__main__":
    raise SystemExit(main())
