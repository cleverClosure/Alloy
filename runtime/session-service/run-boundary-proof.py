#!/usr/bin/env python3
"""Real separate-process XPC boundary and known-bad controls. Author: Timur Isaev."""
import argparse
import base64
import json
import os
import time
from proof_support import ServiceFixture, build


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    rows = []

    def check(name, passed):
        rows.append(bool(passed))
        print(("PASS " if passed else "FAIL ") + name, flush=True)

    with ServiceFixture(build()) as fixture:
        info = json.loads(fixture.call("info").stdout)["payload"]
        check("separate-service-process", info["processID"] != os.getpid() and info["userID"] == os.getuid())
        check("development-capabilities", info["developmentOnly"] and not info["gameLaunchAvailable"])
        request = {"apiVersion": 1, "requestID": "known-request", "credential": fixture.configuration["credential"],
                   "deadline": time.time() + 25, "method": "info",
                   "payload": base64.b64encode(b"{}").decode()}
        cases = [("bad-credential", {"credential": "b" * 64}, "UNAUTHORIZED"),
                 ("unsupported-version", {"apiVersion": 2}, "UNSUPPORTED_VERSION"),
                 ("expired", {"deadline": 1}, "REQUEST_EXPIRED"),
                 ("unknown-method", {"method": "run-shell"}, "MALFORMED_REQUEST")]
        for name, changes, code in cases:
            result = fixture.call("raw", json.dumps({**request, **changes}), check=False)
            expected = "OK" if args.negative_control and name == "bad-credential" else code
            check(name, result.returncode == 2 and json.loads(result.stdout)["code"] == expected)
        result = fixture.call("raw", "not-json", check=False)
        check("malformed-wire", result.returncode == 2 and json.loads(result.stdout)["code"] == "MALFORMED_REQUEST")
        result = fixture.call("raw", json.dumps(request))
        check("healthy-after-rejections", json.loads(result.stdout)["requestID"] == "known-request")
    check("temporary-service-removed", not fixture.loaded)
    failed = len(rows) - sum(rows)
    print(f"SUMMARY pass={sum(rows)} fail={failed} total={len(rows)}")
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
