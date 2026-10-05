#!/usr/bin/env python3
# Author: Timur Isaev
"""Prove v2 fields from inside synthetic guests in a verified private runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def windows(path):
    return "Z:" + str(path).replace("/", "\\")


def bounded(argv, log, env, cwd, descriptors=(), timeout=90):
    started = time.monotonic()
    with log.open("wb") as output:
        process = subprocess.Popen([str(value) for value in argv], env=env, cwd=cwd,
                                   stdout=output, stderr=subprocess.STDOUT,
                                   pass_fds=descriptors, start_new_session=True)
        failure = None
        while process.poll() is None:
            if time.monotonic() - started > timeout or log.stat().st_size > 8 * 1024 * 1024:
                failure = "timeout-or-log-limit"
                os.killpg(process.pid, signal.SIGKILL)
                break
            time.sleep(0.05)
        code = process.wait(timeout=10)
    if failure:
        raise RuntimeError(f"{log.name}: {failure}")
    return {"exit": code, "seconds": round(time.monotonic() - started, 3), "log": str(log)}


def verify(args):
    result = json.loads(subprocess.check_output([
        str(args.materializer), "verify", str(args.store), args.game], timeout=90))
    root = Path(os.environ["ALLOY_RUNTIME_GENERATION"]).resolve()
    if Path(result["path"]).resolve() != root:
        raise RuntimeError("ALLOY_RUNTIME_GENERATION differs from verified active tree")
    return root, result


def compile_guests(args, output):
    for arch, triple in [("native", "aarch64"), ("x64", "x86_64")]:
        cc = args.toolchain / (triple + "-w64-mingw32-clang")
        base = output / arch
        base.mkdir()
        for provider in ["stock", "configured", "restricted"]:
            directory = base / provider
            directory.mkdir()
            subprocess.run([str(cc), "-O2", "-nostdlib", "-ffreestanding", "-fno-stack-protector", "-shared",
                            '-DPROVIDER_NAME="' + provider + '"', str(HERE / "guest-v2/provider.c"),
                            "-lkernel32", "-Wl,--entry,DllMainCRTStartup", "-Wl,--out-implib," + str(directory / "provider.a"),
                            "-o", str(directory / "alloygraphics.dll")], check=True, timeout=60)
        for role in ["single", "launcher", "game", "unknown"]:
            args_cc = [str(cc), "-O2", "-nostdlib", "-ffreestanding", "-fno-stack-protector",
                       '-DROLE_NAME="' + role + '"', str(HERE / "guest-v2/probe.c"),
                       str(base / "stock/provider.a"), "-lkernel32", "-Wl,--entry,entry",
                       "-o", str(base / (role + ".exe"))]
            if role == "launcher":
                args_cc.append("-DLAUNCH_CHILDREN")
            subprocess.run(args_cc, check=True, timeout=60)
        shutil.copyfile(base / "stock/alloygraphics.dll", base / "alloygraphics.dll")
    # One native launcher starts an x64 game and a native unknown child.
    shutil.copyfile(output / "x64/game.exe", output / "native/game.exe")


def main(args):
    root, verified = verify(args)
    processes = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True, timeout=5)
    for row in processes.splitlines():
        if any(path in row for path in [str(root / "loader/wine"), str(root / "server/wineserver"),
                                       "/Alloy/spikes/WINE-001/work/build-2/loader/wine"]):
            raise RuntimeError("selected or shared runtime is busy")
    args.output.mkdir(mode=0o700)
    compile_guests(args, args.output)
    prefix = args.output / "prefix"
    prefix.mkdir()
    working = args.output / "working"
    working.mkdir()
    loader, server = root / "loader/wine", root / "server/wineserver"
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("WINE", "DYLD", "ALLOY_POLICY", "FEX"))}
    env.update(WINEPREFIX=str(prefix), WINELOADER=str(loader), WINESERVER=str(server), LANG="stock",
               WINEDEBUG="-all,+alloy,+module,+loaddll,+xtajit", WINEDLLOVERRIDES="mscoree,mshtml=", FEX_SILENTLOG="1")
    report = {"author": "Timur Isaev", "runtime": verified, "runs": [], "status": "incomplete",
              "winePatchSHA256": sha(HERE / "wine-v2.patch"),
              "guestSHA256": {str(path.relative_to(args.output)): sha(path)
                              for path in sorted(args.output.glob("*/*.exe"))}}

    def cleanup():
        for option in ["-k", "-w"]:
            result = subprocess.run([str(server), option], env=env, capture_output=True, timeout=15)
            # -k returns 1 without a diagnostic when this prefix has no running server.
            if result.returncode and not (option == "-k" and result.returncode == 1 and not result.stderr):
                raise RuntimeError(f"private server cleanup failed: {result}")

    def invoke(label, executable, source=None, expected=None, absent=False, failure=None, transport=None):
        local = dict(env)
        descriptor = None
        try:
            if source is not None:
                source_file = args.output / (label + ".json")
                source_file.write_text(json.dumps(source, sort_keys=True))
                snapshot = args.output / (label + ".snapshot")
                subprocess.run([str(args.compiler), "compile-v2", str(source_file), str(snapshot)],
                               stdout=subprocess.DEVNULL, check=True, timeout=30)
                original = snapshot.read_bytes()
                if transport == "corrupt":
                    snapshot.chmod(0o600)
                    value = bytearray(original)
                    value[-1] ^= 1
                    snapshot.write_bytes(value)
                    snapshot.chmod(0o400)
                descriptor = os.open(snapshot, os.O_RDONLY)
                snapshot.unlink()
                local.update(ALLOY_POLICY_REQUIRED="1", ALLOY_POLICY_SNAPSHOT_FD=str(descriptor),
                             ALLOY_POLICY_SNAPSHOT_SHA256=hashlib.sha256(original).hexdigest())
                if transport == "mismatch":
                    local["ALLOY_POLICY_SNAPSHOT_SHA256"] = "0" * 64
                if transport == "missing":
                    del local["ALLOY_POLICY_SNAPSHOT_FD"]
            result = bounded([loader, executable], args.output / (label + ".log"), local,
                             executable.parent, () if descriptor is None else (descriptor,))
            cleanup()
            text = Path(result["log"]).read_text(errors="replace")
            if failure:
                if result["exit"] == 0 or failure not in text or "IMPORT id=" in text or "GUEST id=" in text:
                    raise RuntimeError(f"{label}: wrong failure or guest ran: {result}")
            else:
                if result["exit"] != 0:
                    raise RuntimeError(f"{label}: guest failed: {result}")
                for marker in expected or []:
                    lines = [line.lower() for line in text.splitlines()]
                    matched = marker.lower() in lines
                    if marker.startswith("PROVIDER ") and " path=" not in marker:
                        matched = any(line.startswith(marker.lower() + " path=") for line in lines)
                    if not matched:
                        raise RuntimeError(f"{label}: missing complete observation {marker}: {result}")
            mapped = re.findall(r'alloy_builtin_image path="([^"]+/libarm64ecfex.dll)"', text)
            if any(Path(path).resolve() != root / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
                   for path in mapped):
                raise RuntimeError("loaded a FEX image outside the selected generation")
            if absent and mapped:
                raise RuntimeError(f"{label}: unexpectedly loaded FEX")
            report["runs"].append({"label": label, **result, "expectedFailure": failure, "mappedFEX": mapped})
            return text
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def source(policy, processes=()):
        return {"schemaVersion": 2, "defaultPolicy": policy, "processPolicies": list(processes)}

    def policy(arch, provider="configured", **fields):
        return {"id": provider, "graphicsProvider": provider,
                "providerDirectory": windows(args.output / arch / provider),
                "dllRoutes": [{"module": "alloygraphics", "loadOrder": "native"}], **fields}

    native = args.output / "native/single.exe"
    x64 = args.output / "x64/single.exe"
    try:
        result = bounded([loader, "wineboot", "-u"], args.output / "wineboot.log", env, args.output)
        cleanup()
        if result["exit"]:
            raise RuntimeError("private prefix initialization failed")
        invoke("stock-native", native, expected=[
            "IMPORT id=stock LANG=stock cwd=" + windows(native.parent) + " fex=0",
            "PROVIDER role=single name=stock"], absent=True)
        active = policy("native", cpuProvider="native-arm64ec", environment={"LANG": "configured"},
                        workingDirectory=windows(working))
        invoke("all-fields", native, source(active), expected=[
            "IMPORT id=configured LANG=configured cwd=" + windows(working) + " fex=0",
            "GUEST id=single LANG=configured cwd=" + windows(working) + " fex=0",
            "PROVIDER role=single name=configured path=" + windows(args.output / "native/configured/alloygraphics.dll")], absent=True)
        invoke("absent-fields", native, source({"id": "stock"}), expected=[
            "IMPORT id=stock LANG=stock cwd=" + windows(native.parent) + " fex=0"], absent=True)
        no_route = dict(active, dllRoutes=[{"module": "alloygraphics", "loadOrder": "disabled"}])
        invoke("disabled-import", native, source(no_route), failure="Importing dlls")
        # The prefix has no FEX registry entry. Stock x64 must refuse while v2
        # selects FEX explicitly, proving policy changes execution, not labels.
        invoke("absent-cpu-refusal", x64, source({"id": "stock"}), failure="x64 emulation not implemented")
        translated = policy("x64", cpuProvider="fex-arm64ec", environment={"LANG": "translated"})
        text = invoke("fex-selection", x64, source(translated), expected=[
            "IMPORT id=configured LANG=translated cwd=" + windows(x64.parent) + " fex=1",
            "PROVIDER role=single name=configured"])
        if str(root / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll") not in text:
            raise RuntimeError("FEX selected without exact builtin mapping evidence")
        invoke("native-rejects-x64", x64, source(policy("x64", cpuProvider="native-arm64ec")),
               failure="policy-cpu-incompatible")
        for mode in ["corrupt", "mismatch", "missing"]:
            invoke(mode, native, source(active), failure="policy-descriptor-missing" if mode == "missing"
                   else "policy-expected-digest", transport=mode)
        report["status"] = "pass"
    finally:
        cleanup()
        _, after = verify(args)
        report["runtimeUnchanged"] = after == verified
        (args.output / "proof.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["runtimeUnchanged"]:
        raise RuntimeError("verified runtime changed")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--materializer", type=Path, required=True)
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--game", default="policy177")
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=HERE / ".build/debug/alloy-policy-compile")
    parser.add_argument("--output", type=Path, required=True)
    main(parser.parse_args())
