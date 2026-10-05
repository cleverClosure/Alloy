#!/usr/bin/env python3
"""Bounded, disposable native GUI fixture; no UI automation. Author: Timur Isaev."""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import threading
import time
import uuid

PACKAGE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("client_proof", PACKAGE / "run-service-proof.py")
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)
COMMANDS = ("offline", "online", "restart-service", "restart-client", "fresh-service", "wrong-build", "live", "stop",
            "preview-loading", "preview-empty", "preview-available", "preview-unsupported", "preview-failed",
            "preview-disconnected")
MARKER = "alloy-client-gui-demo-v1"


class GUIMirror(proof.Mirror):
    chunk_delay = 0.12  # Leave time for a person to inspect and pause/cancel progress.


def private_json(path, value):
    temporary = path.with_name("." + path.name + "-" + uuid.uuid4().hex)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def validate_control(root):
    metadata = root.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise RuntimeError("control directory must be an owner-only real directory")
    if root != root.resolve() or (root / "owner").read_text() != MARKER:
        raise RuntimeError("not an owned Alloy GUI fixture directory")


def library_hashes():
    return {str(path.relative_to(proof.LIBRARY)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in proof.LIBRARY.rglob("*") if path.is_file()}


class Demo:
    def __init__(self, root, service, client, mirror):
        self.root, self.service, self.client, self.mirror = root, service, client, mirror
        self.fixture = None
        self.process = None
        self.recipe = None
        self.log = None
        self.actions = []

    def close_client(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log:
            self.log.close()
            self.log = None

    def close(self):
        self.close_client()
        if self.fixture is not None:
            self.fixture.__exit__(None, None, None)
            self.fixture = None

    def fresh(self):
        self.close()
        self.fixture = proof.ServiceFixture(self.service, libraries=[proof.LIBRARY])
        self.fixture.__enter__()
        self.recipe = proof.write_recipe(self.fixture, self.mirror)
        broken = json.loads(self.recipe.read_text())
        broken["expectedFingerprint"] = "0" * 64
        self.wrong_recipe = self.fixture.root / "wrong-build.json"
        private_json(self.wrong_recipe, broken)
        self.launch("live")

    def launch(self, mode):
        self.close_client()
        executable = PACKAGE / ".build/Alloy.app/Contents/MacOS/alloy-client"
        if mode.startswith("preview-"):
            phase = mode.removeprefix("preview-")
            argv = [executable, "--fixture", phase, "--state-dir", self.fixture.root / ("preview-" + phase)]
        else:
            recipe = self.wrong_recipe if mode == "wrong-build" else self.recipe
            argv = [executable, "--endpoint", self.fixture.endpoint, "--development-fixture", recipe,
                    "--state-dir", self.fixture.root / "gui-client"]
        self.log = open(self.fixture.root / "client.log", "ab")
        os.chmod(self.fixture.root / "client.log", 0o600)
        self.process = subprocess.Popen([str(value) for value in argv], stdout=self.log, stderr=self.log)
        private_json(self.root / "status.json", {"mode": mode, "pid": self.process.pid,
            "endpoint": str(self.fixture.endpoint), "recipe": str(self.recipe),
            "state": str(self.fixture.root / "gui-client"), "service": self.fixture.target})

    def command(self, command):
        self.actions.append(command)
        if command == "fresh-service":
            self.fresh()
        elif command in ("live", "wrong-build") or command.startswith("preview-"):
            self.launch(command)
        elif command == "restart-client":
            self.launch("live")
        elif command == "restart-service":
            self.fixture.restart()
        elif command == "offline" and self.fixture.loaded:
            self.fixture.stop_service()
        elif command == "online" and not self.fixture.loaded:
            subprocess.run(["launchctl", "bootstrap", self.fixture.domain, self.fixture.plist], check=True, timeout=15)
            self.fixture.loaded = True
            self.fixture.wait_ready()
        elif command == "stop":
            return False
        else:
            raise RuntimeError("command is not valid in the current fixture state")
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-dir", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=900)
    parser.add_argument("--command", choices=COMMANDS)
    arguments = parser.parse_args()
    root = arguments.control_dir.absolute()
    if arguments.command:
        validate_control(root)
        request_id = uuid.uuid4().hex
        private_json(root / "command.json", {"command": arguments.command, "id": request_id})
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            result_path = root / "command-result.json"
            if result_path.exists() and json.loads(result_path.read_text()).get("id") == request_id:
                print("GUI control completed: " + arguments.command)
                return 0
            time.sleep(0.1)
        raise RuntimeError("GUI fixture command was not acknowledged")
    if not 60 <= arguments.seconds <= 1800:
        parser.error("--seconds must be 60 through 1800")
    root.mkdir(mode=0o700)  # Refuse an existing directory; never adopt unrelated contents.
    (root / "owner").write_text(MARKER)
    (root / "owner").chmod(0o600)
    validate_control(root)
    service, client = proof.build(), proof.build_client()
    subprocess.run([PACKAGE / "build-app.sh"], check=True, timeout=300)
    before = library_hashes()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GUIMirror)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    demo = None
    try:
        demo = Demo(root, service, client, f"http://127.0.0.1:{server.server_port}")
        demo.fresh()
        print("GUI demo ready: " + str(root), flush=True)
        print("Use --command with this --control-dir; the fixture stops at its deadline.", flush=True)
        deadline = time.monotonic() + arguments.seconds
        while time.monotonic() < deadline:
            command_path = root / "command.json"
            if command_path.exists():
                metadata = command_path.lstat()
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077 or metadata.st_size > 1024:
                    raise RuntimeError("unsafe GUI fixture command")
                request = json.loads(command_path.read_text())
                command = request["command"]
                command_path.unlink()
                if command not in COMMANDS:
                    raise RuntimeError("unknown GUI fixture command")
                keep_running = demo.command(command)
                private_json(root / "command-result.json", {"id": request["id"], "command": command})
                if not keep_running:
                    break
                print("GUI control: " + command, flush=True)
            time.sleep(0.1)
    finally:
        try:
            if demo:
                demo.close()
        finally:
            server.shutdown()
            server.server_close()
        unchanged = library_hashes() == before
        private_json(root / "cleanup.json", {"clientStopped": demo is None or demo.process is None or demo.process.poll() is not None,
            "serviceRemoved": demo is None or demo.fixture is None,
            "storefrontFilesUnchanged": unchanged, "commands": demo.actions if demo else []})
        if not unchanged:
            raise RuntimeError("synthetic storefront files changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
