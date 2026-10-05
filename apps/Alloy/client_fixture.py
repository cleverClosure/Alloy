#!/usr/bin/env python3
"""Client proof adapter for asynchronous launchd deregistration. Author: Timur Isaev."""
import subprocess
import time
from proof_support import ServiceFixture as RuntimeServiceFixture


class ServiceFixture(RuntimeServiceFixture):
    def stop_service(self):
        if self.loaded:
            subprocess.run(["launchctl", "bootout", self.target], capture_output=True, timeout=15)
        deadline = time.monotonic() + 10
        while subprocess.run(["launchctl", "print", self.target], capture_output=True, timeout=5).returncode == 0:
            if time.monotonic() >= deadline:
                raise RuntimeError("private client-proof service still registered after bootout")
            time.sleep(0.1)
        self.loaded = False

    def __exit__(self, *_):
        self.stop_service()
        self.temporary.cleanup()
