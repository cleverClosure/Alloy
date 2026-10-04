#!/usr/bin/env python3
"""Live host truth/refusal control without a fabricated memory class. Author: Timur Isaev."""
import subprocess
from proof_support import ServiceFixture, build
from launch_fixture import launch_input


def main():
    rows = []

    def check(name, okay):
        rows.append(bool(okay))
        print(("PASS " if okay else "FAIL ") + name, flush=True)

    binaries = build()
    with ServiceFixture(binaries) as fixture:
        host = fixture.request("host.info")
        memory = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], timeout=5)) // (1 << 30)
        print(f"CAPABILITY architecture={host['architecture']} memoryGiB={host['memoryGiB']}", flush=True)
        check("host-memory-is-not-inflated", host["memoryGiB"] == memory)
        inputs = launch_input(fixture, "sha256:" + "0" * 64, 0)
        if memory < 8 or host["architecture"] != "arm64":
            fixture.request("launch.resolve", inputs, code="CONFLICT")
            check("compiler-refuses-ineligible-real-host", True)
        else:
            # Successful compilation must still refuse an uninstalled generation.
            fixture.request("launch.resolve", inputs, code="NOT_FOUND")
            check("eligible-host-still-requires-installed-generation", True)
        check("refusal-created-no-preview-or-session", not list((fixture.root / "state/previews").iterdir())
              and fixture.request("session.list") == [])
        check("game-launch-remains-unavailable", fixture.request("info")["gameLaunchAvailable"] is False)
    print(f"SUMMARY pass={sum(rows)} fail={len(rows) - sum(rows)} total={len(rows)}")
    return int(not all(rows))


if __name__ == "__main__":
    raise SystemExit(main())
