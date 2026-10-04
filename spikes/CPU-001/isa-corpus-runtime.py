#!/usr/bin/env python3
"""Read-only Wine runtime guard for the SSE2 milestone. Author: Timur Isaev."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time

def stamp():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def inventory(root):
    """Hash names, file bytes, link targets and modes; never follow source links."""
    entries = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted([*dirs, *files]):
            path = Path(directory) / name
            before = path.lstat()
            entry = {"path": str(path.relative_to(root)), "mode": stat.S_IMODE(before.st_mode)}
            if stat.S_ISLNK(before.st_mode):
                entry.update(kind="link", target=os.readlink(path))
            elif stat.S_ISREG(before.st_mode):
                entry.update(kind="file", size=before.st_size, sha256=digest(path))
                after = path.lstat()
                if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                        after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                    raise RuntimeError(f"runtime file changed while being hashed: {path}")
            elif stat.S_ISDIR(before.st_mode):
                entry.update(kind="directory")
            else:
                raise RuntimeError(f"unsupported mutable runtime entry: {path}")
            entries.append(entry)
    entries.sort(key=lambda entry: entry["path"])
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "entries": entries}


def busy_processes(output, build, own_pid):
    records = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            records[int(parts[0])] = (int(parts[1]), parts[2])
    ancestors = set()
    cursor = own_pid
    while cursor in records and cursor not in ancestors:
        ancestors.add(cursor)
        cursor = records[cursor][0]
    aliases = {str(build), str(build.resolve())}
    for value in tuple(aliases):
        if value.startswith("/private/"):
            aliases.add(value[len("/private"):])
        if value.startswith(("/tmp/", "/var/")):
            aliases.add("/private" + value)
    return [{"pid": pid, "command": command} for pid, (_, command) in records.items()
            if pid not in ancestors and any(alias in command for alias in aliases)]


def assert_idle(build):
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("cannot establish runtime contention: ps failed or returned no process inventory")
    busy = busy_processes(result.stdout, build, os.getpid())
    if busy:
        raise RuntimeError(f"another process is using the runtime: {busy}")
    return {"checked_at": stamp(), "busy_processes": []}


def revision(path):
    def git(*arguments):
        return subprocess.check_output(["git", "-C", str(path), *arguments], text=True).strip()
    return {"path": str(path), "head": git("rev-parse", "HEAD"),
            "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
            "dirty_paths": git("status", "--porcelain").splitlines()}


def bounded(command, log, timeout, env=None, cwd=None):
    """Bound time and diagnostic volume; return actual status, never infer a pass."""
    deadline = time.monotonic() + timeout
    reason = None
    with log.open("wb") as output:
        child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, env=env,
                                 cwd=cwd, start_new_session=True)
        try:
            while child.poll() is None:
                if time.monotonic() >= deadline:
                    reason = "timeout"
                    break
                if log.stat().st_size > 64 * 1024 * 1024:
                    reason = "log limit"
                    break
                try:
                    child.wait(timeout=min(0.1, max(0.001, deadline - time.monotonic())))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    child.wait(timeout=2)
    return {"exit": child.returncode, "failure": reason, "log": str(log)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("build", type=Path)
    snapshot.add_argument("output", type=Path)
    guard = commands.add_parser("check-directory")
    guard.add_argument("build", type=Path)
    guard.add_argument("output", type=Path)
    run = commands.add_parser("run")
    for field in ("build", "wine-source", "fex-source", "baseline", "log"):
        run.add_argument("--" + field, type=Path, required=True)
    run.add_argument("--timeout", type=float, required=True)
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    build = args.build.resolve()
    if args.action == "check-directory":
        if args.output.resolve().is_relative_to(build):
            raise RuntimeError("scratch directories must be outside the read-only runtime")
        return 0
    if args.action == "snapshot":
        if args.output.resolve().is_relative_to(build):
            raise RuntimeError("runtime inventories must be outside the runtime")
        args.output.write_text(json.dumps(inventory(build), indent=2) + "\n")
        return 0
    prefix = Path(os.environ["WINEPREFIX"]).resolve()
    if prefix.is_relative_to(build) or args.log.resolve().is_relative_to(build):
        raise RuntimeError("prefix and logs must be outside the read-only runtime")
    baseline = json.loads(args.baseline.read_text())
    before = {entry["path"]: entry.get("sha256") for entry in baseline["entries"]}
    names = ["loader/wine", "server/wineserver", "dlls/ntdll/ntdll.so",
             "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"]
    identities = {name: digest(build / name) for name in names}
    if any(identities[name] != before.get(name) for name in names):
        raise RuntimeError("runtime binary changed since the baseline inventory")
    primary = Path("/Users/cleverclosure/Developer/Alloy/spikes/WINE-001/work/build-2")
    assert_idle(primary)
    metadata = {"author": "Timur Isaev", **assert_idle(build), "binaries": identities,
                "wine": revision(args.wine_source), "fex": revision(args.fex_source)}
    env = {key: value for key, value in os.environ.items() if not key.startswith("WINE")}
    env.update({key: os.environ[key] for key in ("WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES")
                if key in os.environ})
    env.update(WINELOADER=str(build / "loader/wine"), WINESERVER=str(build / "server/wineserver"))
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    result = bounded([str(build / "loader/wine"), *arguments], args.log, args.timeout, env=env)
    metadata["result"] = result
    args.log.with_suffix(".metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return 124 if result["failure"] else result["exit"] if result["exit"] >= 0 else 128 - result["exit"]


if __name__ == "__main__":
    sys.exit(main())
