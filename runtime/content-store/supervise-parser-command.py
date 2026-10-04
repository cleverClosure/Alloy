#!/usr/bin/env python3
"""Bound cooperative macOS Swift commands and their separately grouped children.

Author: Timur Isaev

CLI: supervise-parser-command.py SECONDS LOG COMMAND [ARG...]
Exit 124 means timeout, 125 supervisor failure, and 130 cancellation.
The command budget is followed by at most two seconds of checked cleanup;
process launch/syscall scheduling are not hard real-time guarantees. Output
is capped at two MiB. The 256-identity polling census observes cooperative
Swift commands, not adversarial fork-and-detach workloads or a sandbox.
"""
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


class ProcessInfo(ctypes.Structure):
    """Darwin libproc.h proc_bsdinfo; no command strings are logged."""
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved",
    )] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
        ("jobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
        ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
        ("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64),
    ]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_pidinfo.restype = ctypes.c_int
LIBPROC.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_listchildpids.restype = ctypes.c_int
MAX_PROCESSES = 256
LOG_LIMIT = 2 * 1024 * 1024
CANCELLATION_REQUESTED = False


def identity(pid):
    info = ProcessInfo()
    size = ctypes.sizeof(info)
    if LIBPROC.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size or info.status == 5:
        return None  # absent or zombie: it can no longer execute a heartbeat
    return pid, info.seconds, info.microseconds


def refresh(owned):
    queue = list(owned)
    visited = set()
    while queue:
        item = queue.pop()
        if item in visited or identity(item[0]) != item:
            continue
        visited.add(item)
        pids = (ctypes.c_int * MAX_PROCESSES)()
        count = LIBPROC.proc_listchildpids(item[0], pids, ctypes.sizeof(pids))
        if count < 0 or count >= MAX_PROCESSES:
            raise RuntimeError("descendant census failed or exceeded its bound")
        for pid in pids[:count]:  # this API returns PID count, not byte count
            child = identity(pid)
            if child and child not in owned:
                if len(owned) >= MAX_PROCESSES:
                    raise RuntimeError("descendant identity limit exceeded")
                owned.add(child)
                queue.append(child)


def cleanup(process, owned):
    deadline = time.monotonic() + 2.0
    try:
        refresh(owned)
    except RuntimeError:
        pass
    while True:
        # Popen retains ownership of an unreaped direct child even if its initial
        # libproc identity lookup failed during setup.
        if not any(item[0] == process.pid for item in owned) and process.poll() is None:
            process.kill()
        # Descendants first; each signal rechecks the kernel start-time identity.
        for item in sorted(owned, key=lambda value: value[0] == process.pid):
            if identity(item[0]) == item:
                try:
                    os.kill(item[0], signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if process.poll() is not None and not any(identity(item[0]) == item for item in owned):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.005)


def run(timeout, logfile, command):
    process = None
    owned = set()
    result = 125
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        root = identity(process.pid)
        if root:
            owned.add(root)
        elif process.poll() is None:
            raise RuntimeError("initial process identity unavailable")
        deadline = time.monotonic() + timeout
        os.set_blocking(process.stdout.fileno(), False)
        with open(logfile, "wb") as output:
            total = 0
            eof = False
            while True:
                if CANCELLATION_REQUESTED:
                    raise InterruptedError("command supervision cancelled")
                refresh(owned)
                for _ in range(16):
                    try:
                        chunk = os.read(process.stdout.fileno(), 4096)
                    except BlockingIOError:
                        break
                    if not chunk:
                        eof = True
                        break
                    total += len(chunk)
                    if total > LOG_LIMIT:
                        raise RuntimeError("command output exceeded two MiB")
                    output.write(chunk)
                if process.poll() is not None and eof:
                    result = process.returncode if process.returncode >= 0 else 128 - process.returncode
                    break
                if time.monotonic() >= deadline:
                    result = 124
                    break
                time.sleep(0.005)
    finally:
        if process is not None:
            process.stdout.close()
            if not cleanup(process, owned):
                raise RuntimeError("owned command cleanup exceeded two seconds")
    return 130 if CANCELLATION_REQUESTED else result


def verify_heartbeat(path):
    before = Path(path).read_bytes()
    pid, count = map(int, before.split())
    if count <= 0 or identity(pid) is not None:
        raise RuntimeError("production test did not start or remains alive")
    time.sleep(0.15)
    if Path(path).read_bytes() != before:
        raise RuntimeError("production test heartbeat continues after timeout")
    print("PASS production-swift-timeout-child-stopped")


def interrupted(_signal, _frame):
    # Defer cancellation to the polling loop so a signal cannot interrupt
    # process ownership setup or the bounded cleanup that must always finish.
    global CANCELLATION_REQUESTED
    CANCELLATION_REQUESTED = True


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-heartbeat":
        verify_heartbeat(sys.argv[2])
        return 0
    if len(sys.argv) < 4:
        raise ValueError("expected timeout log command...")
    timeout = float(sys.argv[1])
    if not 0 < timeout <= 300:
        raise ValueError("invalid timeout")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        return run(timeout, sys.argv[2], sys.argv[3:])
    except InterruptedError:
        return 130


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL parser supervisor: {error}", file=sys.stderr)
        sys.exit(125)
