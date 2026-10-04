#!/usr/bin/env python3
"""Private, temporary user launchd/XPC service fixture. Author: Timur Isaev."""
import json
import os
from pathlib import Path
import plistlib
import secrets
import signal
import subprocess
import tempfile
import time
import uuid

PACKAGE = Path(__file__).resolve().parent


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, interrupted)


def run(argv, **kwargs):
    return subprocess.run([str(value) for value in argv], capture_output=True, text=True,
                          timeout=kwargs.pop("timeout", 30), **kwargs)


def build():
    result = run(["swift", "build", "--package-path", PACKAGE], timeout=240)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    result = run(["swift", "build", "--package-path", PACKAGE, "--show-bin-path"])
    if result.returncode:
        raise RuntimeError(result.stderr)
    return Path(result.stdout.strip())


class ServiceFixture:
    def __init__(self, binaries):
        self.binaries = binaries
        self.temporary = tempfile.TemporaryDirectory(prefix="alloy-runtime-")
        self.root = Path(self.temporary.name).resolve()
        self.name = "com.alloy.development." + uuid.uuid4().hex
        self.domain = "gui/" + str(os.getuid())
        if run(["launchctl", "print", self.domain]).returncode:
            self.domain = "user/" + str(os.getuid())
        self.target = self.domain + "/" + self.name
        for name in ("state", "content"):
            (self.root / name).mkdir(mode=0o700)
        self.configuration = {"serviceName": self.name, "credential": secrets.token_hex(32),
                              "stateRoot": str(self.root / "state"),
                              "contentRoot": str(self.root / "content")}
        self.endpoint = self.root / "endpoint.json"
        self.endpoint.write_text(json.dumps(self.configuration))
        self.endpoint.chmod(0o600)
        self.plist = self.root / "service.plist"
        self.plist.write_bytes(plistlib.dumps({
            "Label": self.name,
            "ProgramArguments": [str(binaries / "alloy-runtime-service"), str(self.endpoint)],
            "MachServices": {self.name: True}, "RunAtLoad": True,
            "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            "StandardOutPath": str(self.root / "stdout.log"),
            "StandardErrorPath": str(self.root / "stderr.log"),
        }))
        self.loaded = False

    def __enter__(self):
        result = run(["launchctl", "bootstrap", self.domain, self.plist])
        if result.returncode:
            self.temporary.cleanup()
            raise RuntimeError("private launchd bootstrap: " + result.stderr)
        self.loaded = True
        try:
            self.wait_ready()
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def wait_ready(self):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            result = self.call("info", check=False)
            if result.returncode == 0:
                return json.loads(result.stdout)["payload"]
            time.sleep(0.1)
        raise RuntimeError("service startup deadline: " + (self.root / "stderr.log").read_text())

    def call(self, method, payload=None, check=True):
        command = [self.binaries / "alloy-runtime-client", self.endpoint, method]
        result = run(command, input=payload, timeout=15)
        if check and result.returncode:
            raise RuntimeError(f"client {method} failed: {result.stdout} {result.stderr}")
        return result

    def __exit__(self, *_):
        if self.loaded:
            result = run(["launchctl", "bootout", self.target])
            if result.returncode:
                raise RuntimeError("private service cleanup: " + result.stderr)
            self.loaded = False
            if run(["launchctl", "print", self.target]).returncode == 0:
                raise RuntimeError("private service still registered")
        self.temporary.cleanup()
