#!/usr/bin/env python3
"""Real service records, not manually assembled adapter inputs. Author: Timur Isaev."""
import argparse
from diagnostic_fixture import ServiceFixture, build, call, operations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    rows = []

    def check(name, result):
        rows.append(bool(result))
        print(("PASS " if result else "FAIL ") + name, flush=True)

    binaries, client = build()
    with ServiceFixture(binaries) as service:
        operation = operations.execute(service, "inventory.start", {"key": "diagnostic-adapter"})
        identifier = operation["operationID"]
        observed = call(client, "observe", service.endpoint, "operation", identifier)
        check("actual-service-operation-identity", observed["targetID"] == ("wrong" if args.negative_control else identifier))
        check("exact-audit-events", [event["fields"][1]["value"] for event in observed["events"][:-1]]
              == [event["state"] for event in operation["events"]])
        identity = observed["events"][0]["correlation"]
        check("read-request-not-original-request", bool(identity["request_id"])
              and identity["session_id"] == "unavailable")
        check("clean-result-is-observed", observed["state"] == "SUCCEEDED" and observed["historyComplete"])
        before = observed["serviceInstanceID"]
        service.restart()
        after = call(client, "observe", service.endpoint, "operation", identifier)
        check("reconnect-preserves-operation-identity", after["targetID"] == identifier
              and after["serviceInstanceID"] != before)
        service.stop_service()
        result = call(client, "observe", service.endpoint, "operation", identifier, okay=False)
        check("disconnect-does-not-report-clean-result", result.returncode == 1 and not result.stdout)
    print(f"SUMMARY pass={sum(rows)} fail={len(rows) - sum(rows)} total={len(rows)}")
    return int(not all(rows))


if __name__ == "__main__":
    raise SystemExit(main())
