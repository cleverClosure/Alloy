#!/usr/bin/env python3
"""Run and report every ISA family against a read-only Wine build. Author: Timur Isaev."""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
PRIMARY = Path("/Users/cleverclosure/Developer/Alloy")
PROOF = HERE / "testcases" / "verify-isa-vectors.py"
module_spec = importlib.util.spec_from_file_location("isa_reference_proof", PROOF)
proof = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(proof)
FAMILIES = ["sse2", "sse", "sse3", "ssse3", "sse41", "sse42", "avx", "avx2",
            "bmi1", "bmi2", "flags", "atomics", "x87"]
if set(proof.MANIFEST["families"]) != set(FAMILIES) - {"sse2"}:
    raise ValueError("the committed inventory must cover exactly the twelve new named families")
SSE2_HASH = {False: "21ba41417def5d07", True: "eb480915973927bd"}


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


def loaded_builtin(text, name="libarm64ecfex.dll"):
    return bool(re.search(
        rf'trace:loaddll:build_module Loaded L"[^"\n]*{re.escape(name)}" at [0-9A-Fa-f]+: builtin', text))


def sse2_verdict(text, rc, mutated, instruction=False):
    lines = text.replace("\r", "").splitlines()
    summaries = [line for line in lines if line.startswith("cpu-001 isa-corpus sse2:")]
    match = re.fullmatch(r"cpu-001 isa-corpus sse2: cases=12736 failures=(\d+) "
                         r"checksum=([0-9a-f]{16}) mutate=(none|paddb)", summaries[0]) if len(summaries) == 1 else None
    tag = "paddb" if mutated else "none"
    if not match or match[2] != SSE2_HASH[mutated] or match[3] != tag:
        raise ValueError("SSE2 is missing its exact summary, checksum or mutation tag")
    fail_lines = [line for line in lines if line.startswith("FAIL")]
    if not mutated:
        if rc != 0 or int(match[1]) != 0 or fail_lines:
            raise ValueError("SSE2 clean run did not pass")
    elif rc != 1 or int(match[1]) == 0 or not any(
            re.match(r"FAIL (hand-vector )?paddb\s", line) for line in fail_lines):
        raise ValueError("SSE2 did not detect paddb by name with exit 1")
    if mutated and instruction and (int(match[1]) != 237 or not any(
            re.match(r"FAIL paddb\s", line) for line in fail_lines)):
        raise ValueError("SSE2 instruction comparison did not detect exactly its 236 corrupted cases")
    if mutated and not instruction and int(match[1]) != 1:
        raise ValueError("SSE2 native mutation must fail exactly its one hand vector")
    return match[2]


def guest_verdict(family, text, result, mutated, control=None):
    if result["failure"]:
        raise ValueError(f"{family} {result['failure']} is not a mutation pass")
    if not loaded_builtin(text):
        raise ValueError("no actual libarm64ecfex builtin load event; a lookup is insufficient")
    if family == "sse2":
        return sse2_verdict(text, result["exit"], mutated, instruction=True)
    # Wine's loader diagnostics surround the program output. Retain every FAIL
    # and corpus record while excluding only the loader's unrelated trace lines.
    corpus = "\n".join(line.rstrip("\r") for line in text.splitlines()
                       if line.startswith(("cpu-001 isa-corpus", "op=", "FAIL")))
    return proof.validate(corpus, result["exit"], family, mutated, instruction=True, control=control)


def complete(report):
    if report.get("mode") != "fex" or report.get("error"):
        return False
    if set(report["families"]) != set(FAMILIES):
        return False
    if not report.get("runtime_unchanged") or not report.get("registration_control"):
        return False
    runtime = report.get("runtime", {})
    before, after = runtime.get("before_sha256", ""), runtime.get("after_sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", before) or before != after:
        return False
    expected_labels = ["wineboot", "unregistered", "register"] + [
        f"{family}-{kind}" for family in FAMILIES for kind in ("clean", "mutation")] + ["atomics-tickets"]
    runs = runtime.get("runs", [])
    if [run.get("label") for run in runs] != expected_labels:
        return False
    for run in runs:
        if (run.get("busy_processes") != [] or not run.get("checked_at") or
                run.get("binaries") != runtime.get("binaries") or
                len(run.get("binaries", {})) != 4):
            return False
        for source in ("wine", "fex"):
            if not re.fullmatch(r"[0-9a-f]{40}", run.get(source, {}).get("head", "")):
                return False
    for family in FAMILIES:
        for mutated in (False, True):
            row = report["families"][family].get("mutation" if mutated else "clean", {})
            expected_hash = SSE2_HASH[mutated] if family == "sse2" else proof.MANIFEST["families"][family][
                "mutation_checksum" if mutated else "checksum"]
            if (row.get("status") != "PASS" or row.get("checksum") != expected_hash or
                    row.get("exit") != (1 if mutated else 0) or row.get("failure") is not None or
                    row.get("builtin_loaded") is not True or
                    not re.fullmatch(r"[0-9a-f]{64}", row.get("pe_sha256", ""))):
                return False
    ticket = report["families"]["atomics"].get("tickets", {})
    return (ticket.get("status") == "PASS" and ticket.get("builtin_loaded") is True and
            ticket.get("checksum") == proof.MANIFEST["families"]["atomics"]["ticket_control"]["checksum"] and
            ticket.get("exit") == 1 and ticket.get("failure") is None and
            re.fullmatch(r"[0-9a-f]{64}", ticket.get("pe_sha256", "")) is not None)


def selftest():
    proof.selftest()
    checks = 0
    with tempfile.TemporaryDirectory(prefix="alloy-isa-control-") as scratch:
        root = Path(scratch)
        build = root / "runtime"
        build.mkdir()
        (build / "known").write_text("abc")
        baseline = inventory(build)
        assert baseline["entries"][0]["sha256"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        assert inventory(build) == baseline
        (build / "known").write_text("abd")
        assert inventory(build)["sha256"] != baseline["sha256"]
        (build / "known").write_text("abc")
        (build / "new").write_text("new")
        assert inventory(build)["sha256"] != baseline["sha256"]
        (build / "new").unlink()
        (build / "link").symlink_to("known")
        linked = inventory(build)
        (build / "link").unlink()
        (build / "link").symlink_to("new-target")
        assert inventory(build)["sha256"] != linked["sha256"]
        checks += 5
        fixture = f"1 0 parent {build}\n2 1 runner {build}\n3 1 {build}/loader/wine guest\n"
        assert [record["pid"] for record in busy_processes(fixture, build, 2)] == [3]
        assert not busy_processes("1 0 parent\n2 1 runner\n", build, 2)
        checks += 2
        event = '0024:trace:loaddll:build_module Loaded L"C:\\\\windows\\\\system32\\\\libarm64ecfex.dll" at 00006FFFFCBB0000: builtin'
        assert loaded_builtin(event)
        assert not loaded_builtin('find_builtin_dll looking for "libarm64ecfex.dll"')
        assert not loaded_builtin(event.replace(": builtin", ": native"))
        checks += 3
        clean = "cpu-001 isa-corpus sse2: cases=12736 failures=0 checksum=21ba41417def5d07 mutate=none"
        mutation = "FAIL hand-vector paddb mismatch\ncpu-001 isa-corpus sse2: cases=12736 failures=1 checksum=eb480915973927bd mutate=paddb"
        sse2_verdict(clean, 0, False)
        sse2_verdict(mutation, 1, True)
        for output, rc, changed in [(clean + "\n" + clean, 0, False), (mutation, 142, True),
                                     (mutation.replace("FAIL hand-vector paddb", "FAIL crash"), 1, True),
                                     (clean + "\nFAIL paddb", 0, False)]:
            try:
                sse2_verdict(output, rc, changed)
            except ValueError:
                checks += 1
            else:
                raise RuntimeError("SSE2 reader accepted a deliberately invalid outcome")
        labels = ["wineboot", "unregistered", "register"] + [f"{family}-{kind}"
                  for family in FAMILIES for kind in ("clean", "mutation")] + ["atomics-tickets"]
        artifacts = {f"artifact{i}": "0" * 64 for i in range(4)}
        report = {"mode": "fex", "runtime_unchanged": True, "registration_control": True,
                  "runtime": {"before_sha256": "0" * 64, "after_sha256": "0" * 64, "binaries": artifacts,
                              "runs": [{"label": label, "busy_processes": [], "checked_at": stamp(),
                                        "binaries": artifacts, "wine": {"head": "0" * 40},
                                        "fex": {"head": "0" * 40}} for label in labels]}, "families": {}}
        for family in FAMILIES:
            report["families"][family] = {}
            for mutated in (False, True):
                checksum = SSE2_HASH[mutated] if family == "sse2" else proof.MANIFEST["families"][family][
                    "mutation_checksum" if mutated else "checksum"]
                report["families"][family]["mutation" if mutated else "clean"] = {
                    "status": "PASS", "checksum": checksum, "exit": 1 if mutated else 0,
                    "failure": None, "builtin_loaded": True, "pe_sha256": "0" * 64}
        report["families"]["atomics"]["tickets"] = {
            "status": "PASS", "builtin_loaded": True, "exit": 1, "failure": None, "pe_sha256": "0" * 64,
            "checksum": proof.MANIFEST["families"]["atomics"]["ticket_control"]["checksum"]}
        assert complete(report)
        saved = report["families"]["sse2"].pop("mutation")
        assert not complete(report)
        report["families"]["sse2"]["mutation"] = saved
        report["runtime_unchanged"] = False
        assert not complete(report)
        report["runtime_unchanged"] = True
        report["mode"] = "native-only"
        assert not complete(report)
        report["mode"] = "fex"
        saved_run = report["runtime"]["runs"].pop()
        assert not complete(report)
        report["runtime"]["runs"].append(saved_run)
        saved_run["binaries"] = {}
        assert not complete(report)
        checks += 6
        timed = bounded([sys.executable, "-c", "import time; time.sleep(10)"], root / "timeout.log", 0.1)
        assert timed["failure"] == "timeout" and timed["exit"] != 0
        checks += 1
    print(f"PASS aggregate controls: {checks} inventory/contention/module/verdict/timeout checks", flush=True)
    controls_spec = importlib.util.spec_from_file_location("isa_corpus_controls", HERE / "isa-corpus-controls.py")
    controls = importlib.util.module_from_spec(controls_spec)
    controls_spec.loader.exec_module(controls)
    controls.exercise(run_fex, complete, digest, FAMILIES, proof.MANIFEST)


def native_proofs(args, work, report):
    testcases = HERE / "testcases"
    native = work / "native"
    native.mkdir()
    sse2 = native / "sse2"
    for mutated in (False, True):
        tag = "mutation" if mutated else "clean"
        command = ["bash", str(testcases / "build-isa-corpus-native.sh"), str(sse2)]
        if mutated:
            command.append("-DALLOY_CORPUS_MUTATE_PADDB")
        result = bounded(command, work / f"sse2-{tag}-native-build.log", 180)
        if result["failure"] or result["exit"]:
            raise RuntimeError(f"SSE2 native proof failed: {result}")
        oracle = (sse2 / f"native-oracle-{'PADDB' if mutated else 'clean'}.log").read_text()
        sse2_verdict(oracle, 1 if mutated else 0, mutated)
        binary = work / f"isa_corpus_sse2-{tag}.exe"
        command = [str(args.toolchain / "x86_64-w64-mingw32-clang"), "-O2", "-Wall", "-Wextra", "-Werror"]
        if mutated:
            command.append("-DALLOY_CORPUS_MUTATE_PADDB")
        subprocess.run([*command, str(testcases / "isa_corpus_sse2.c"), "-o", str(binary)], check=True)
        report["families"]["sse2"]["native_" + tag] = {"status": "PASS", "checksum": SSE2_HASH[mutated],
                                                          "pe_sha256": digest(binary)}
        if args.rosetta:
            binary = work / f"isa_corpus_sse2-{tag}-rosetta"
            command = ["/usr/bin/clang", "-arch", "x86_64", "-O2", "-Wall", "-Wextra", "-Werror"]
            if mutated:
                command.append("-DALLOY_CORPUS_MUTATE_PADDB")
            subprocess.run([*command, str(testcases / "isa_corpus_sse2.c"), "-o", str(binary)], check=True)
            result = bounded([str(binary)], work / f"sse2-{tag}-rosetta.log", 30)
            if result["failure"]:
                raise RuntimeError(f"SSE2 Rosetta run failed: {result}")
            sse2_verdict(Path(result["log"]).read_text(), result["exit"], mutated, instruction=True)
            report["families"]["sse2"]["rosetta_" + tag] = {"status": "PASS", "checksum": SSE2_HASH[mutated]}
    command = [sys.executable, str(PROOF), str(native / "families"), "--toolchain", str(args.toolchain)]
    if args.rosetta:
        command.append("--rosetta")
    result = bounded(command, work / "native-families.log", 900)
    if result["failure"] or result["exit"]:
        raise RuntimeError(f"native family proof failed: {result}")
    native_report = json.loads((native / "families" / "verification.json").read_text())
    if set(native_report["families"]) != set(proof.MANIFEST["families"]):
        raise RuntimeError("native proof omitted or added a family")
    for family, details in native_report["families"].items():
        report["families"][family]["native_proof"] = details
    ticket_binary = work / "isa_corpus_atomics-tickets.exe"
    subprocess.run([str(args.toolchain / "x86_64-w64-mingw32-clang"), "-O2", "-std=c11",
                    "-Wall", "-Wextra", "-Werror", "-DALLOY_CORPUS_MUTATE_THREADS",
                    str(testcases / "isa_corpus_atomics.c"), "-o", str(ticket_binary)], check=True)
    report["families"]["atomics"]["ticket_pe_sha256"] = digest(ticket_binary)
    print(f"Native preparation complete for {len(FAMILIES)} families; FEX has not run", flush=True)


def run_fex(args, work, report):
    build = args.wine_build.resolve()
    loader, server = build / "loader/wine", build / "server/wineserver"
    binaries = [loader, server, build / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"]
    ntdll = next((path for path in [build / "dlls/ntdll/ntdll.so", build / "dlls/ntdll/aarch64-unix/ntdll.so"]
                  if path.is_file()), None)
    if ntdll is None:
        raise RuntimeError("the runtime is missing its ntdll Unix binary")
    binaries.append(ntdll)
    for path in binaries:
        if not path.is_file():
            raise RuntimeError(f"missing runtime artifact: {path}")
    prefix = work / "prefix"
    prefix.mkdir()  # New work directory, never an existing prefix.
    env = os.environ.copy()
    for key in [key for key in env if key.startswith("WINE")]:
        env.pop(key)
    env.update(WINEPREFIX=str(prefix), WINELOADER=str(loader), WINESERVER=str(server),
               WINEDEBUG="-all,+loaddll,+xtajit", WINEDLLOVERRIDES="xtajit64=n;mscoree,mshtml=",
               DYLD_FALLBACK_LIBRARY_PATH=os.environ.get("DYLD_FALLBACK_LIBRARY_PATH", "/opt/homebrew/lib"), FEX_SILENTLOG="1")
    report["runtime"] = {"build": str(build), "prefix": str(prefix), "runs": []}
    assert_idle(PRIMARY / "spikes/WINE-001/work/build-2")
    assert_idle(build)
    before = inventory(build)
    (work / "runtime-before.json").write_text(json.dumps(before, indent=2) + "\n")
    report["runtime"]["before_sha256"] = before["sha256"]
    report["runtime"]["binaries"] = {str(path.relative_to(build)): digest(path) for path in binaries}

    def cleanup():
        for option in ("-k", "-w"):
            result = bounded([str(server), option], work / f"server{option}.log", 10, env=env)
            if result["failure"]:
                raise RuntimeError(f"private prefix server cleanup failed: {result}")

    def invoke(label, arguments, timeout=60, dll_overrides=None):
        preflight = assert_idle(build)
        preflight["shared_runtime"] = assert_idle(PRIMARY / "spikes/WINE-001/work/build-2")
        preflight.update(label=label, wine=revision(args.wine_source), fex=revision(args.fex_source),
                         binaries={str(path.relative_to(build)): digest(path) for path in binaries})
        if preflight["binaries"] != report["runtime"]["binaries"]:
            raise RuntimeError("runtime binary changed between invocations")
        invocation_env = env if dll_overrides is None else {**env, "WINEDLLOVERRIDES": dll_overrides}
        preflight["dll_overrides"] = invocation_env["WINEDLLOVERRIDES"]
        result = bounded([str(loader), *arguments], work / f"{label}.log", timeout, env=invocation_env, cwd=work)
        preflight["result"] = result
        report["runtime"]["runs"].append(preflight)
        cleanup()
        return result, Path(result["log"]).read_text(errors="replace")

    try:
        result, _ = invoke("wineboot", ["wineboot", "-u"], 120)
        if result["failure"] or result["exit"]:
            raise RuntimeError(f"private prefix creation failed: {result}")
        # The control must load Wine's known refusal stub. Forcing a nonexistent
        # native xtajit64 instead merely fails while loading kernel32, before
        # the intended emulator-registration control can execute.
        # Restarting the private server can make Wine wait for service startup;
        # use the same finite startup budget as the registered guest runs.
        result, text = invoke("unregistered", [str(work / "isa_corpus_sse2-clean.exe")], 60,
                              dll_overrides="xtajit64=b;mscoree,mshtml=")
        if (result["failure"] or result["exit"] == 0 or "x64 emulation not implemented" not in text or
                not loaded_builtin(text, "xtajit64.dll") or loaded_builtin(text)):
            raise RuntimeError("the fresh unregistered prefix did not produce its expected refusal")
        report["registration_control"] = True
        registration = work / "select-fex.reg"
        registration.write_text('REGEDIT4\n\n[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Wow64\\amd64]\n@="libarm64ecfex.dll"\n')
        result, _ = invoke("register", ["regedit", str(registration)])
        if result["failure"] or result["exit"]:
            raise RuntimeError("FEX registration failed")
        for family in FAMILIES:
            for mutated in (False, True):
                tag = "mutation" if mutated else "clean"
                binary = (work if family == "sse2" else work / "native/families") / f"isa_corpus_{family}-{tag}.exe"
                pe_sha256 = digest(binary)
                recorded = (report["families"][family]["native_" + tag] if family == "sse2" else
                            report["families"][family]["native_proof"][tag])["pe_sha256"]
                if pe_sha256 != recorded:
                    raise RuntimeError(f"{family} {tag} guest changed after native preparation")
                result, text = invoke(f"{family}-{tag}", [str(binary)])
                checksum = guest_verdict(family, text, result, mutated)
                if digest(binary) != pe_sha256:
                    raise RuntimeError(f"{family} {tag} guest changed during its run")
                report["families"][family][tag] = {"status": "PASS", "checksum": checksum,
                                                     "builtin_loaded": True, "pe_sha256": pe_sha256, **result}
                print(f"PASS FEX {family} {tag}: {checksum}", flush=True)
        binary = work / "isa_corpus_atomics-tickets.exe"
        pe_sha256 = report["families"]["atomics"]["ticket_pe_sha256"]
        if digest(binary) != pe_sha256:
            raise RuntimeError("ticket-control guest changed after preparation")
        result, text = invoke("atomics-tickets", [str(binary)])
        checksum = guest_verdict("atomics", text, result, True, control="tickets")
        if digest(binary) != pe_sha256:
            raise RuntimeError("ticket-control guest changed during its run")
        report["families"]["atomics"]["tickets"] = {"status": "PASS", "checksum": checksum,
                                                        "builtin_loaded": True, "pe_sha256": pe_sha256, **result}
    finally:
        try:
            cleanup()
        finally:
            after = inventory(build)
            (work / "runtime-after.json").write_text(json.dumps(after, indent=2) + "\n")
            report["runtime"]["after_sha256"] = after["sha256"]
            report["runtime_unchanged"] = before == after
            if not report["runtime_unchanged"]:
                raise RuntimeError("runtime directory changed; before/after inventories identify the difference")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--native-only", action="store_true", help="build/prove references, explicitly leave FEX NOT RUN")
    parser.add_argument("--rosetta", action="store_true", help="also verify independent x86 Mach-O instruction results")
    parser.add_argument("--wine-build", type=Path, default=Path(os.environ.get("ALLOY_WINE_BUILD", str(PRIMARY / "spikes/WINE-001/work/build-2"))))
    parser.add_argument("--wine-source", type=Path, default=Path(os.environ.get("ALLOY_WINE_SOURCE", str(PRIMARY / "third_party/src/wine"))))
    parser.add_argument("--fex-source", type=Path, default=Path(os.environ.get("ALLOY_FEX_SOURCE", str(PRIMARY / "third_party/src/fex"))))
    parser.add_argument("--toolchain", type=Path, default=Path(os.environ.get("ALLOY_TOOLCHAIN_BIN", str(PRIMARY / "tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin"))))
    args = parser.parse_args()
    selftest()
    if args.selftest:
        return 0
    runs = HERE / "work/isa-corpus-runs"
    if not args.native_only and runs.resolve().is_relative_to(args.wine_build.resolve()):
        raise RuntimeError("the private work directory must be outside the read-only Wine build")
    runs.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=runs))
    report = {"author": "Timur Isaev", "started_at": stamp(), "mode": "native-only" if args.native_only else "fex",
              "families": {name: {"clean": {"status": "NOT RUN"}, "mutation": {"status": "NOT RUN"}} for name in FAMILIES},
              "required_fex_complete": False}
    report["families"]["atomics"]["tickets"] = {"status": "NOT RUN"}
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"interrupted by signal {signum}")
    previous_handlers = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        native_proofs(args, work, report)
        if not args.native_only:
            run_fex(args, work, report)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report["error"] = str(error)
        print(f"FAIL: {error}", file=sys.stderr)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        report["finished_at"] = stamp()
        report["required_fex_complete"] = complete(report)
        (work / "aggregate.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Aggregate report: {work / 'aggregate.json'}", flush=True)
    if report.get("error"):
        return 1
    if args.native_only:
        print("Native preparation passed. Required FEX outcomes: NOT RUN.")
        return 0
    if not report["required_fex_complete"]:
        print("FAIL: incomplete FEX aggregate", file=sys.stderr)
        return 1
    print("PASS: every required FEX clean/mutation outcome observed; runtime directory unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
