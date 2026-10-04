#!/usr/bin/env python3
# Author: Timur Isaev
"""Real ENOSPC on one bounded private APFS image; never fill the host volume."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sys
import subprocess
import tempfile
import time

PACKAGE = Path(__file__).resolve().parent
IDENTITY = PACKAGE.parent / "store-identity"
CONTENT_PROBE = PACKAGE / ".build/debug/alloy-content-store-fault-probe"
IDENTITY_PROBE = IDENTITY / ".build/debug/AlloyStoreIdentityFaultProbe"
NO_SPACE = re.compile(r"errno 28|SQLite error 13:|No space left on device|NSPOSIXErrorDomain Code=28")


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True,
                          timeout=kwargs.pop("timeout", 60), **kwargs)


def remove_tree(path):
    if not path.exists():
        return
    for base, dirs, files in os.walk(path):
        os.chmod(base, 0o700)
        for name in dirs + files:
            item = Path(base) / name
            if not item.is_symlink():
                os.chmod(item, 0o700)
    shutil.rmtree(path)


def fill_image(mount):
    # A path typo must never turn this into pressure on the developer's disk.
    info = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", str(mount)], timeout=10))
    assert info.get("FilesystemType") == "apfs", info
    assert info.get("MountPoint") == str(mount), info
    assert 0 < info["TotalSize"] <= 256 * 1024 * 1024, info
    filler = mount / "pressure-filler.bin"
    total = 0
    observed = False
    descriptor = os.open(filler, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        for quantum in (1024 * 1024, 4096, 1):
            chunk = b"\xa5" * quantum
            while total <= 256 * 1024 * 1024:
                try:
                    count = os.write(descriptor, chunk)
                    assert count > 0
                    total += count
                except OSError as error:
                    assert error.errno == errno.ENOSPC, error
                    observed = True
                    break
            else:
                raise AssertionError("bounded image did not exhaust within its size")
        try:
            os.fsync(descriptor)
        except OSError as error:
            assert error.errno == errno.ENOSPC, error
            observed = True
    finally:
        os.close(descriptor)
    assert observed, "filler never observed kernel ENOSPC"
    return filler, total


def sanitized_error(error, mount):
    message = error.strip().replace(str(mount), "<APFS>")
    message = message.replace(str(mount).removeprefix("/private"), "<APFS>")
    return re.sub(r"0x[0-9a-fA-F]+", "<address>", message)


def wait_reached(process, marker):
    deadline = time.monotonic() + 25
    while not marker.exists():
        if process.poll() is not None:
            output, error = process.communicate()
            raise AssertionError(f"probe exited before handshake: {output} {error}")
        assert time.monotonic() < deadline, "probe never reached selected point"
        time.sleep(0.01)


def execute_case(name, command, mount, signals, inject, verify_failed, recover, before_pressure=lambda: None):
    reached, resume = signals / (name + ".reached"), signals / (name + ".resume")
    process = subprocess.Popen([str(x) for x in command(reached, resume)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    filler = None
    filled_bytes = 0
    started = time.monotonic()
    try:
        wait_reached(process, reached)
        before_pressure()
        if inject:
            filler, filled_bytes = fill_image(mount)
        resume.write_text("continue\n")
        output, error = process.communicate(timeout=30)
        if inject:
            assert process.returncode != 0, f"{name}: full-volume operation unexpectedly succeeded"
            assert NO_SPACE.search(error) or (process.returncode == 28 and "DISK_PRESSURE ENOSPC" in error), error
            verify_failed(output)
        else:
            assert process.returncode == 0, error
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=10)
        if filler is not None:
            filler.unlink()
    recover(reached, resume)
    row = {"name": name, "status": "PASS", "injected": inject,
           "enospc_failures": int(inject), "filler_bytes": filled_bytes,
           "rejection": sanitized_error(error, mount) if inject else None,
           "seconds": round(time.monotonic() - started, 3)}
    print(f"PASS {name} injected={int(inject)} enospc_failures={int(inject)}", flush=True)
    return row


def verify_generation(root, generation):
    reference = json.loads((root / "references/game/active.json").read_text())
    assert reference["generationId"] == generation, reference
    directory = root / "generations/game" / generation
    manifest_bytes = (directory / "manifest.json").read_bytes()
    assert reference["manifestDigest"] == "sha256:" + hashlib.sha256(manifest_bytes).hexdigest()
    manifest = json.loads(manifest_bytes)
    for index, layer in enumerate(manifest["layers"]):
        digest = layer["digest"].removeprefix("sha256:")
        data = (directory / "layers" / f"{index:03d}-{digest}").read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest
        assert len(data) == layer["size"]
    assert (root / "volumes/game/saves/save.bin").read_bytes() == b"save-v1"


def content_case(name, point, mount, signals, inject, base_url):
    root = mount / name
    if name == "download":
        def command(reached, resume):
            return [CONTENT_PROBE, "transport-handshake", root, base_url, "pressure-fetch", point, reached, resume]
        def failed(_output):
            assert not list((root / "objects/sha256").glob("*/*")), "partial transport reached CAS"
        def recover(_reached, _resume):
            run([CONTENT_PROBE, "transport", root, base_url, "pressure-fetch"])
            run([CONTENT_PROBE, "verify-transport", root, base_url, "pressure-fetch"])
    else:
        run([CONTENT_PROBE, "bootstrap", root, "game", "generation-a", "payload-a", "save-v1"])
        def command(reached, resume):
            return [CONTENT_PROBE, "update-handshake", root, "game", "generation-b", "payload-b", "pass",
                    point, reached, resume]
        def failed(_output):
            verify_generation(root, "generation-a" if name == "materialization" else "generation-b")
        def recover(_reached, _resume):
            run([CONTENT_PROBE, "recover", root])
            run([CONTENT_PROBE, "recover", root])
            run([CONTENT_PROBE, "verify", root, "game", "generation-b", "save-v1"])
            verify_generation(root, "generation-b")
    row = execute_case(name, command, mount, signals, inject, failed, recover)
    remove_tree(root)
    return row


def identity_case(mode, mount, signals, inject):
    name = "identity-" + mode
    root = mount / name
    old_output = []
    def before_pressure():
        if mode == "scan":
            old_output.append((root / "fingerprint.json").read_bytes())
    def command(reached, resume):
        return [IDENTITY_PROBE, "disk-pressure", mode, root, reached, resume]
    def failed(output):
        if mode == "scan":
            assert "read_only=PASS" in output, output
            persisted = json.loads((root / "fingerprint.json").read_text())
            assert persisted["file_count"] == 1
            assert (root / "fingerprint.json").read_bytes() == old_output[0], "prior fingerprint changed"
        else:
            assert not list((root / "cache/invalidations").glob("*.json")), "partial invalidation published"
    def recover(reached, resume):
        result = run(command(reached, resume))
        assert "persistence=PASS" in result.stdout
        if old_output:
            assert (root / "fingerprint.json").read_bytes() == old_output[0]
        if mode == "cache":
            replay = run(command(reached, resume))
            assert "created=false" in replay.stdout
            entries = list((root / "cache/invalidations").iterdir())
            assert len([path for path in entries if path.suffix == ".json"]) == 1
            assert len(entries) == 2, "temporary cache publication survived recovery"
    row = execute_case(name, command, mount, signals, inject, failed, recover, before_pressure)
    assert (root / "library/The Life and Suffering of Sir Brante.exe").read_bytes() == b"synthetic bytes"
    remove_tree(root)
    return row


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-control", action="store_true", help="disable filling; expect zero ENOSPC failures")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--cancel-after-attach", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--selftest-cleanup", action="store_true")
    parser.add_argument("--cleanup-via-inventory", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(arguments)
    if args.selftest_cleanup:
        cleanup_control()
        return
    if not args.skip_build:
        for package in (PACKAGE, IDENTITY):
            run(["swift", "build", "--package-path", package], timeout=180)
    rows = []
    with tempfile.TemporaryDirectory(prefix="alloy-enospc-") as temporary:
        scratch = Path(temporary).resolve()
        mount, signals = scratch / "volume", scratch / "signals"
        mount.mkdir()
        signals.mkdir()
        image_path = scratch / "pressure.sparseimage"
        run(["hdiutil", "create", "-size", "128m", "-fs", "APFS", "-type", "SPARSE",
             "-volname", "AlloyPressure", image_path])
        server = None
        try:
            run(["hdiutil", "attach", image_path, "-mountpoint", mount, "-nobrowse", "-noverify"])
            if args.cancel_after_attach:
                args.cancel_after_attach.write_text(str(mount))
                signal.pause()
                raise AssertionError("cancellation did not interrupt the matrix")
            server = subprocess.Popen(["python3", str(PACKAGE / "Tests/Fixtures/transport_range_server.py")],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            import select
            assert select.select([server.stdout], [], [], 10)[0], "loopback fixture startup timed out"
            base_url = server.stdout.readline().strip()
            assert base_url.startswith("http://127.0.0.1:")
            for name, point in (("download", "after-transport-stream-chunk"),
                                ("materialization", "after-publish-cas"),
                                ("catalog", "after-catalog-reconcile")):
                rows.append(content_case(name, point, mount, signals, not args.negative_control, base_url))
            for mode in ("scan", "cache"):
                rows.append(identity_case(mode, mount, signals, not args.negative_control))
        finally:
            cleanup_deadline = time.monotonic() + 12
            try:
                if server is not None:
                    stop_process(server, cleanup_deadline)
            finally:
                detach_image(mount, image_path, cleanup_deadline, args.cleanup_via_inventory)
    report = {"author": "Timur Isaev", "filesystem": "APFS", "image_mib": 128,
              "injected": not args.negative_control, "cases": rows,
              "pass": len(rows), "fail": 0, "enospc_failures": sum(row["enospc_failures"] for row in rows)}
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")
    print(f"SUMMARY disk-pressure pass={len(rows)} fail=0 enospc_failures={report['enospc_failures']}")


def remaining_cleanup(deadline, maximum):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("private image cleanup exceeded its 12-second deadline")
    return min(maximum, remaining)


def stop_process(process, deadline):
    if process.poll() is None:
        process.terminate()
    try:
        process.communicate(timeout=remaining_cleanup(deadline, 0.5))
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=remaining_cleanup(deadline, 0.5))


def detach_image(mount, image_path=None, deadline=None, via_inventory=False):
    deadline = deadline if deadline is not None else time.monotonic() + 12
    # Fit this suite's fifteen-second TERM cleanup window. Detach only the exact
    # private mount or a device reported for this process's own image file.
    target = mount if mount.is_mount() and not via_inventory else None
    if target is None and image_path is not None:
        inventory = plistlib.loads(subprocess.check_output(["hdiutil", "info", "-plist"], timeout=remaining_cleanup(deadline, 2)))
        for image in inventory.get("images", []):
            if Path(image.get("image-path", "")).resolve() == image_path.resolve():
                entities = image.get("system-entities", [])
                target = next((entry["dev-entry"] for entry in entities if "dev-entry" in entry), None)
                break
    if target is None:
        return
    try:
        run(["hdiutil", "detach", target], timeout=remaining_cleanup(deadline, 4))
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        run(["hdiutil", "detach", "-force", target], timeout=remaining_cleanup(deadline, 4))


def cleanup_control():
    for via_inventory in (False, True):
        cleanup_variant(via_inventory)
    print("PASS cleanup-control test-all supervisor detached mount and inventory paths within registered 15-second grace", flush=True)


def cleanup_variant(via_inventory):
    with tempfile.TemporaryDirectory(prefix="alloy-enospc-control-") as temporary:
        marker = Path(temporary) / "attached"
        command = [sys.executable, str(Path(__file__).resolve()), "--skip-build",
                   "--cancel-after-attach", str(marker)]
        if via_inventory:
            command.append("--cleanup-via-inventory")
        process = subprocess.Popen(command, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        mount = None
        try:
            wait_reached(process, marker)
            mount = Path(marker.read_text())
            # Exercise the actual test-all supervisor, including its final
            # process-group SIGKILL, rather than approximating cancellation.
            import runpy
            supervisor = runpy.run_path(str(PACKAGE.parents[1] / "tools/test-all"))
            suite = next(row for row in supervisor["REGISTRY"] if row.id == "content-store-disk-pressure")
            assert suite.cleanup_grace == 15
            supervisor["_kill_process_group"](process, suite.cleanup_grace)
            output, error = process.communicate(timeout=1)
            assert process.returncode == 1 and "cancelled by SIGTERM" in output, (output, error)
            assert not mount.is_mount(), "cancellation leaked a mounted image"
            assert not mount.parent.exists(), "cancellation left its scratch image behind"
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=2)
            if mount is not None and mount.is_mount():
                detach_image(mount)
                remove_tree(mount.parent)


def interrupt_for_cleanup(_signum, _frame):
    raise InterruptedError("cancelled by SIGTERM")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupt_for_cleanup)
    try:
        if len(sys.argv) == 1:
            cleanup_control()
        main()
        if len(sys.argv) == 1:
            main(["--skip-build", "--negative-control"])
    except Exception as error:
        print(f"FAIL disk-pressure: {error}", flush=True)
        print("SUMMARY disk-pressure fail=1", flush=True)
        raise
