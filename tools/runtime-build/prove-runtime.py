#!/usr/bin/env python3
"""Execute bounded guests only from a verified generation. Author: Timur Isaev."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

from inputs import BuildError, digest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("corpus", REPO / "spikes/CPU-001/isa-corpus-runner.py")
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


def prove(args):
    root = Path(os.environ["ALLOY_RUNTIME_GENERATION"]).resolve()
    checked = json.loads(subprocess.check_output([str(args.materializer), "verify", str(args.store), args.game]))
    if Path(checked["path"]).resolve() != root:
        raise BuildError("environment does not select the verified active runtime")
    corpus.assert_idle(corpus.PRIMARY / "spikes/WINE-001/work/build-2")
    corpus.assert_idle(root)
    args.output.mkdir(mode=0o700)
    prefix = args.output / "prefix"
    prefix.mkdir()
    loader, server = root / "loader/wine", root / "server/wineserver"
    image = root / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
    before = corpus.inventory(root)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("WINE", "DYLD"))}
    env.update(WINEPREFIX=str(prefix), WINELOADER=str(loader), WINESERVER=str(server),
               WINEDEBUG="-all,+module,+loaddll,+xtajit", WINEDLLOVERRIDES="xtajit64=n;mscoree,mshtml=",
               FEX_SILENTLOG="1")
    compiler = args.toolchain / "x86_64-w64-mingw32-clang"
    subprocess.run([str(compiler), "-nostdlib", "-Wl,-e,entry", "-Wl,--subsystem,console",
                    str(REPO / "spikes/WINE-001/testcases/x64min.c"), "-o", str(args.output / "x64min.exe")], check=True)
    subprocess.run([str(compiler), "-O2", "-mavx2", "-mbmi", "-mbmi2", "-msse4.2",
                    str(REPO / "spikes/CPU-001/testcases/isa_smoke.c"), "-o", str(args.output / "isa_smoke.exe")], check=True)
    report = {"author": "Timur Isaev", "runtime": checked, "fexSHA256": digest(image), "runs": []}

    def cleanup():
        for option in ("-k", "-w"):
            result = corpus.bounded([str(server), option], args.output / ("server" + option + ".log"), 10, env)
            if result["failure"]:
                raise BuildError("private server cleanup timed out")

    def invoke(label, arguments, expected, marker=None, fex=False, refusal=False):
        run_env = dict(env)
        if refusal:
            run_env["WINEDLLOVERRIDES"] = "xtajit64=b;mscoree,mshtml="
        result = corpus.bounded([str(loader), *arguments], args.output / (label + ".log"), 120, run_env, args.output)
        cleanup()
        text = Path(result["log"]).read_text(errors="replace")
        actual = re.findall(r'alloy_builtin_image path="([^"]+)" base=\S+ size=\d+', text)
        loaded = [path for path in actual if path.endswith("/libarm64ecfex.dll")]
        if result["failure"] or (expected is not None and result["exit"] != expected):
            raise BuildError(f"{label} failed: {result}")
        if marker and marker not in text:
            raise BuildError(f"{label} missing expected output")
        if fex and (not loaded or any(Path(path).resolve() != image for path in loaded)
                    or not corpus.loaded_builtin(text)):
            raise BuildError(f"{label} did not map the exact generation FEX image: {loaded}")
        if not fex and loaded:
            raise BuildError(f"{label} unexpectedly loaded FEX")
        if refusal and (result["exit"] == 0 or not corpus.loaded_builtin(text, "xtajit64.dll")):
            raise BuildError("unregistered emulator control did not refuse execution")
        report["runs"].append({"label": label, **result, "loadedFEXPaths": loaded})

    try:
        invoke("wineboot", ["wineboot", "-u"], 0)
        invoke("native-cmd", ["cmd", "/c", "echo alloy-native-ok"], 0, "alloy-native-ok")
        invoke("unregistered", [str(args.output / "x64min.exe")], None,
               "x64 emulation not implemented", refusal=True)
        registration = args.output / "fex.reg"
        registration.write_text('REGEDIT4\n\n[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Wow64\\amd64]\n@="libarm64ecfex.dll"\n')
        invoke("register", ["regedit", str(registration)], 0)
        invoke("x64min", [str(args.output / "x64min.exe")], 42, fex=True)
        invoke("isa-smoke", [str(args.output / "isa_smoke.exe")], 0,
               "cpu-001 isa advertisement ok", fex=True)
    finally:
        cleanup()
        report["runtimeUnchanged"] = corpus.inventory(root) == before
        (args.output / "proof.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["runtimeUnchanged"]:
        raise BuildError("runtime changed during execution")
    subprocess.run([str(args.materializer), "verify", str(args.store), args.game], check=True)
    print("PASS native cmd, refusal control, x64min=42, ISA smoke, exact mapped FEX path, unchanged verified runtime")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--materializer", type=Path, required=True)
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--game", default="runtime176")
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        prove(args)
    except (BuildError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"FAIL: {error}\n")
