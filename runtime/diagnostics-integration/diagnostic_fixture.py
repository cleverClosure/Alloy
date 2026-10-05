#!/usr/bin/env python3
"""Isolated diagnostics proof helpers. Author: Timur Isaev."""
import importlib.util
import json
import signal
import subprocess
import sys
import time
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parent.parent
SERVICE = ROOT / "runtime/session-service"
sys.path.insert(0, str(SERVICE))
# Explicit file import avoids colliding with this module's name.
spec = importlib.util.spec_from_file_location("runtime_proof_support", SERVICE / "proof_support.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
sys.modules["proof_support"] = runtime
spec = importlib.util.spec_from_file_location("operation_proof", SERVICE / "run-operation-proof.py")
operations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operations)


class ServiceFixture(runtime.ServiceFixture):
    def stop_service(self):
        if self.loaded:
            subprocess.run(["launchctl", "bootout", self.target], capture_output=True, timeout=15, check=True)
        deadline = time.monotonic() + 10
        while subprocess.run(["launchctl", "print", self.target], capture_output=True, timeout=5).returncode == 0:
            if time.monotonic() >= deadline:
                raise RuntimeError("private diagnostics service cleanup deadline")
            time.sleep(0.1)
        self.loaded = False

    def __exit__(self, *_):
        # Ask the owning service to stop and reap every session before removing its stores.
        if self.loaded:
            sessions = self.request("session.list")
            for session in sessions:
                if session["liveNodes"]:
                    self.request("session.stop", {"identifier": session["record"]["sessionID"]})
            deadline = time.monotonic() + 10
            while any(session["liveNodes"] for session in self.request("session.list")):
                if time.monotonic() >= deadline:
                    raise RuntimeError("owned fixture cleanup deadline")
                time.sleep(0.05)
        self.stop_service()
        self.temporary.cleanup()


def interrupted(*_):
    raise SystemExit(124)


def build():
    signal.signal(signal.SIGTERM, interrupted)
    binaries = runtime.build()
    subprocess.run(["swift", "build", "--package-path", PACKAGE], check=True, timeout=300,
                   stdout=subprocess.DEVNULL)
    client = subprocess.run(["swift", "build", "--package-path", PACKAGE, "--show-bin-path"],
                            check=True, capture_output=True, text=True, timeout=30)
    return binaries, Path(client.stdout.strip()) / "alloy-diagnostics"


def call(client, *args, okay=True, timeout=30):
    result = subprocess.run([client, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    if okay and result.returncode:
        raise RuntimeError("diagnostic client: " + result.stderr)
    return json.loads(result.stdout) if okay else result
