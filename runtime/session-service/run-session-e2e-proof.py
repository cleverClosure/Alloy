#!/usr/bin/env python3
"""Separate-client Windows policy, persistence and recovery proof. Author: Timur Isaev."""

import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time
import uuid

from proof_support import ServiceFixture, build, run
from run_wine_support import policy, private_cleanup

GAME = "session181"
ROLES = ("launcher", "game", "unknown")
SAVE = b"Alloy session service save proof v1\n"
TERMINAL = ("SUCCEEDED", "FAILED", "STOPPED", "INTERRUPTED")


def read_json(path):
    return json.loads(path.read_bytes())


def trace_at(directory):
    path = directory / "wine.log"
    return path.read_text(errors="replace") if path.exists() else ""


def process_table():
    result = run(["ps", "-axo", "pid=,stat=,command="], timeout=5)
    if result.returncode:
        raise RuntimeError("cannot verify native process inventory: " + result.stderr)
    return result.stdout.splitlines()


def wait_for(fixture, identifier, predicate, seconds=150):
    deadline = time.monotonic() + seconds
    state = None
    while time.monotonic() < deadline:
        state = fixture.request("session.get", {"identifier": identifier})
        if predicate(state):
            return state
        if state["state"] in TERMINAL:
            directory = fixture.root / "state/wine-sessions" / identifier
            raise RuntimeError("unexpected terminal: " + json.dumps(state) + "\n" + trace_at(directory)[-6000:])
        time.sleep(.05)
    raise RuntimeError("session observation deadline: " + json.dumps(state))


def session_record(directory):
    path = directory / "request.json"
    return read_json(path if path.exists() else directory / "pending.json")


def assert_dead(directory, seconds=25):
    deadline = time.monotonic() + seconds
    while True:
        record = session_record(directory)
        identities = [record["lease"]["holder"] if "lease" in record else record["holder"]]
        unix_pids = set()
        ownership_path = directory / "ownership.json"
        if ownership_path.exists():
            ownership = read_json(ownership_path)
            identities.append(ownership["serverLease"]["holder"])
            if ownership.get("root"):
                identities.append(ownership["root"])
            identities += [row["native"] for row in ownership["processes"] if row.get("native")]
            unix_pids = {row["unixPID"] for row in ownership["processes"] if row.get("unixPID")}
        elif any((directory / name).exists() for name in ("bootstrap.json", "server.log", "wine.log")):
            raise RuntimeError("cannot prove guest cleanup without durable server ownership: " + str(directory))
        # Conservative PID checks may reject PID reuse; they never credit a live PID as dead.
        pids = {row["processId"] for row in identities} | unix_pids
        survivors = []
        for line in process_table():
            fields = line.split(None, 2)
            if len(fields) < 2 or fields[1].startswith("Z"):
                continue
            if int(fields[0]) in pids or (len(fields) == 3 and str(directory) in fields[2]):
                survivors.append(line)
        if not survivors:
            return len(pids)
        if time.monotonic() >= deadline:
            raise RuntimeError("session processes survived: " + repr(survivors))
        time.sleep(.05)


def correlation(state, directory):
    record = session_record(directory)
    expected = {"sessionID": state["sessionID"],
                "launchSpecID": state["preview"]["specification"]["launchSpecId"],
                "generationID": state["preview"]["generation"]["generationId"],
                "correlationID": record["correlationID"]}
    uuid.UUID(expected["correlationID"])
    events = state["events"]
    if not events or any(event["correlation"] != expected for event in events):
        raise RuntimeError("diagnostic correlation differs from the launched specification")
    sequence = [event["sequence"] for event in events]
    if any(right != left + 1 for left, right in zip(sequence, sequence[1:])):
        raise RuntimeError("diagnostic event sequence has a gap or duplicate")
    return expected


def inventory(state, exited=False):
    rows = [row for row in state["processes"] if row["imagePath"].lower().startswith("g:\\")]
    by_path = {row["imagePath"].lower(): row for row in rows}
    if len(rows) != 3 or set(by_path) != {"g:\\" + role + ".exe" for role in ROLES}:
        raise RuntimeError("complete launcher/game/unknown inventory differs: " + json.dumps(rows))
    launcher, game, unknown = [by_path["g:\\" + role + ".exe"] for role in ROLES]
    if game.get("parentIdentifier") != launcher["identifier"] or unknown.get("parentIdentifier") != game["identifier"]:
        raise RuntimeError("guest process parent chain differs")
    if len({row["identifier"] for row in rows}) != 3 or any(not row.get("unixPID") for row in rows):
        raise RuntimeError("guest creation identities are missing or aliased")
    for role, row in zip(ROLES, (launcher, game, unknown)):
        native = row.get("native", {})
        if native.get("processId") != row["unixPID"] or not native.get("startTimeSeconds"):
            raise RuntimeError("guest has no kernel-bound birth identity: " + role)
        if row["classification"] != ("unknown" if role == "unknown" else "known") or row["policyID"] != role:
            raise RuntimeError("guest policy classification differs")
        if row["exited"] != exited:
            raise RuntimeError("guest liveness differs from the observed session phase")
    births = {(row["native"]["processId"], row["native"]["startTimeSeconds"],
               row["native"]["startTimeMicroseconds"]) for row in rows}
    if len({row["unixPID"] for row in rows}) != 3 or len(births) != 3:
        raise RuntimeError("concurrent guests share a native process identity")
    return rows


def observe_policy(trace, runtime, variant, allowed):
    observations = []
    for role in ROLES:
        suffix = f" id={role} LANG={role} cwd=G:\\cwd-{role} fex={int(role == 'game')}"
        imported, entered = "IMPORT" + suffix, "GUEST" + suffix
        if trace.count(imported) != 1 or trace.count(entered) != 1 or trace.index(imported) >= trace.index(entered):
            raise RuntimeError("policy was not observed before imports and at entry for " + role + "\n" + trace[-6000:])
        if f"POLICY role={role} import=1 entry=1 provider=1" not in trace:
            raise RuntimeError("provider identity or guest policy check failed for " + role)
        if f"RUNTIME role={role} variant={variant}" not in trace or f"READY role={role}" not in trace:
            raise RuntimeError("runtime provider marker or ready observation missing for " + role)
        observations.append({"role": role, "import": imported, "entry": entered,
                             "providerDirectory": "C:\\alloy\\providers\\" + role, "variant": variant})
    if f"RESTRICTION allowed={int(allowed)}" not in trace:
        raise RuntimeError("unknown process DLL restriction result differs")
    if ("BLOCKED_IMPORT allowed=1" in trace) != allowed:
        raise RuntimeError("disabled DLL oracle did not distinguish its positive control")
    if "SAVE role=game durable=1" not in trace:
        raise RuntimeError("guest did not durably write its S: save")
    mapped = re.findall(r'alloy_builtin_image path="([^"]+libarm64ecfex.dll)"', trace)
    expected = Path(runtime["path"]) / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
    if not mapped or any(Path(path).resolve() != expected.resolve() for path in mapped):
        raise RuntimeError("game did not load the verified runtime's exact builtin FEX: " + repr(mapped))
    return {"policies": observations, "mappedFEX": mapped, "unknownDLLAllowed": allowed}


def make_source(runtime, payload, allowed=False):
    policies = {role: policy(role, "fex-arm64ec" if role == "game" else "native-arm64ec") for role in ROLES}
    for role, value in policies.items():
        value["providerDirectory"] = "C:\\alloy\\providers\\" + role
        value["resolved"]["workingDirectory"] = "G:\\cwd-" + role
        value["resolved"]["dllOverrides"]["alloygraphics"] = "native"
    if allowed:
        policies["unknown"]["resolved"]["dllOverrides"].update(alloyblocked="native", alloynever="disabled")
    return {"schemaVersion": "alloy-synthetic-session-v1", "syntheticOnly": True,
            "filesystem": "title-volumes-namespace-v1", "gameID": GAME, "buildID": "session-e2e-one",
            "runtimeGenerationID": runtime["generationId"], "runtimeTreeDigest": runtime["treeDigest"],
            "defaultPolicy": policies["unknown"], "processes": [
                {"path": "G:\\" + role + ".exe", "machine": "x64" if role == "game" else "arm64",
                 "imageSHA256": hashlib.sha256((payload / (role + ".exe")).read_bytes()).hexdigest(),
                 "policy": policies[role]} for role in ("launcher", "game")]}


@contextmanager
def tampered_runtime(runtime):
    # Only modify this fixture's independently materialized file, never package/CAS bytes.
    path = Path(runtime["path"]) / "providers/game/alloygraphics.dll"
    details = path.lstat()
    if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1:
        raise RuntimeError("tamper target is not an independent regular runtime file")
    original = path.read_bytes()
    modified = bytearray(original)
    modified[-1] ^= 1
    try:
        path.chmod(stat.S_IMODE(details.st_mode) | stat.S_IWUSR)
        path.write_bytes(modified)
        path.chmod(stat.S_IMODE(details.st_mode))
        yield
    finally:
        path.chmod(stat.S_IMODE(details.st_mode) | stat.S_IWUSR)
        path.write_bytes(original)
        path.chmod(stat.S_IMODE(details.st_mode))
        if path.read_bytes() != original or stat.S_IMODE(path.stat().st_mode) != stat.S_IMODE(details.st_mode):
            raise RuntimeError("disposable runtime tamper restoration failed")


class Proof:
    def __init__(self, args, fixture, payload):
        self.args, self.fixture, self.payload = args, fixture, payload
        self.reports, self.identifiers, self.launch_seconds = [], [], {}
        self.save = fixture.root / "content/volumes" / GAME / "saves/session-proof.bin"

    def activate(self, package):
        result = run([self.args.materializer, "import-development", package, self.fixture.root / "content", GAME],
                     timeout=180)
        if result.returncode:
            raise RuntimeError("runtime activation: " + result.stdout + result.stderr)
        return json.loads(result.stdout)

    def verify_runtime(self, expected):
        result = run([self.args.materializer, "verify", self.fixture.root / "content", GAME], timeout=90)
        if result.returncode or json.loads(result.stdout) != expected:
            raise RuntimeError("active immutable runtime changed: " + result.stdout + result.stderr)

    def verify_save(self):
        if self.save.read_bytes() != SAVE:
            raise RuntimeError("S: save changed across stop or runtime activation")
        return hashlib.sha256(SAVE).hexdigest()

    def fault(self, value=None):
        self.fixture.configuration["testFault"] = value
        self.fixture.endpoint.write_text(json.dumps(self.fixture.configuration))
        self.fixture.restart()

    def start(self, label, runtime, allowed=False):
        marker = self.payload / "allow-blocked"
        if allowed:
            marker.write_bytes(b"synthetic positive control\n")
        elif marker.exists():
            marker.unlink()
        source = make_source(runtime, self.payload, allowed)
        preview = self.fixture.request("launch.synthetic.resolve", {
            "source": base64.b64encode(json.dumps(source).encode()).decode(),
            "entryPath": "G:\\launcher.exe", "key": label, "maximumSeconds": 90})
        if not preview["specification"]["runtimeReady"] or preview["specification"]["productionEligible"]:
            raise RuntimeError("synthetic specification readiness differs")
        identifier = "wine-" + hashlib.sha256(label.encode()).hexdigest()
        self.identifiers.append(identifier)
        started = time.monotonic()
        handle = self.fixture.request("launch.game", {"identifier": preview["previewID"]})
        self.launch_seconds[identifier] = time.monotonic() - started
        if handle["sessionID"] != identifier:
            raise RuntimeError("launched session identity differs from its deterministic request key")
        if self.launch_seconds[identifier] > 5:
            raise RuntimeError(f"launch.game blocked the client for {self.launch_seconds[identifier]:.3f}s (limit 5s)")
        return identifier, self.fixture.root / "state/wine-sessions" / identifier

    def positive(self, label, runtime, variant, allowed=False, crash=False):
        identifier, directory = self.start(label, runtime, allowed)

        def ready(state):
            trace = trace_at(directory)
            guests = [row for row in state["processes"] if row["imagePath"].lower().startswith("g:\\")]
            # Guest output and the server trace are separate streams. A creation
            # can be published before its init-first-thread/native observation.
            return state["state"] == "RUNNING" and state["healthChecks"] > 0 and all(
                f"READY role={role}" in trace for role in ROLES) and len(guests) == 3 and all(
                    row.get("unixPID") and row.get("native") for row in guests)

        running = wait_for(self.fixture, identifier, ready)
        inventory(running)
        observation = observe_policy(trace_at(directory), runtime, variant, allowed)
        self.verify_save()
        before = self.fixture.request("info")["instanceID"]
        started = time.monotonic()
        deadline = started + 25
        if crash:
            after = self.fixture.restart()["instanceID"]
            if before == after:
                raise RuntimeError("service restart did not replace its process instance")
        else:
            self.fixture.request("session.stop", {"identifier": identifier})
        terminal = wait_for(self.fixture, identifier, lambda state: state["state"] in TERMINAL,
                            seconds=max(.01, deadline - time.monotonic()))
        outcomes = {("STOPPED", "OK"), ("INTERRUPTED", "SESSION_INTERRUPTED")} if crash else {("STOPPED", "OK")}
        if (terminal["state"], terminal["code"]) not in outcomes:
            raise RuntimeError("session cleanup outcome differs: " + json.dumps(terminal))
        inventory(terminal, exited=True)
        identities = assert_dead(directory, seconds=max(.01, deadline - time.monotonic()))
        stopped_in = time.monotonic() - started
        if stopped_in >= 25:
            raise RuntimeError("session cleanup exceeded its 25-second deadline")
        trace = trace_at(directory)
        if not crash and any(f"STOP role={role} cooperative=1" not in trace for role in ROLES):
            raise RuntimeError("graceful stop did not reach every guest")
        correlation(terminal, directory)
        self.verify_save()
        self.verify_runtime(runtime)
        self.reports.append({"case": label, "secondsToStop": stopped_in,
                             "launchRequestSeconds": self.launch_seconds[identifier],
                             "serviceInstanceChanged": crash, "deadNativeIdentities": identities,
                             "observations": observation, "session": {k: v for k, v in terminal.items() if k != "preview"}})

    def refusal(self, label, runtime, expected):
        identifier, directory = self.start(label, runtime)
        started = time.monotonic()
        deadline = started + 25
        state = wait_for(self.fixture, identifier, lambda value: value["state"] in TERMINAL,
                         seconds=max(.01, deadline - time.monotonic()))
        if state["state"] != "FAILED" or state["code"] != expected:
            raise RuntimeError("integrity refusal differs: " + json.dumps(state))
        trace = trace_at(directory)
        if any(marker in trace for marker in ("IMPORT id=", "GUEST id=", "READY role=")):
            raise RuntimeError("refused session reached guest imports or entry")
        identities = assert_dead(directory, seconds=max(.01, deadline - time.monotonic()))
        refused_in = time.monotonic() - started
        if refused_in > 25:
            raise RuntimeError("session refusal and cleanup exceeded its 25-second deadline")
        correlation(state, directory)
        self.verify_save()
        self.reports.append({"case": label, "guestEntryCount": 0, "deadNativeIdentities": identities,
                             "secondsToRefusal": refused_in, "launchRequestSeconds": self.launch_seconds[identifier],
                             "session": {k: v for k, v in state.items() if k != "preview"}})

    def session_identifiers(self):
        sessions = self.fixture.root / "state/wine-sessions"
        return sorted(set(self.identifiers) | {path.name for path in sessions.glob("*")})

    def cleanup_sessions(self):
        failures = []
        for identifier in self.session_identifiers():
            directory = self.fixture.root / "state/wine-sessions" / identifier
            deadline = time.monotonic() + 25
            try:
                self.fixture.request("session.stop", {"identifier": identifier})
                wait_for(self.fixture, identifier, lambda value: value["state"] in TERMINAL,
                         seconds=max(.01, deadline - time.monotonic()))
                assert_dead(directory, seconds=max(.01, deadline - time.monotonic()))
                if time.monotonic() > deadline:
                    raise RuntimeError("session cleanup exceeded its 25-second deadline")
            except Exception as error:
                failures.append(identifier + ": " + str(error))
        if failures:
            raise RuntimeError("proof cleanup failed: " + "; ".join(failures))

    def export_diagnostics(self):
        if not self.args.diagnostics:
            return
        target = self.args.diagnostics
        target.mkdir(parents=True, exist_ok=True, mode=0o700)
        credential = self.fixture.configuration["credential"].encode()
        # Export only service-produced session artifacts. The endpoint is never an artifact.
        for identifier in self.session_identifiers():
            source = self.fixture.root / "state/wine-sessions" / identifier
            destination = target / identifier
            destination.mkdir(exist_ok=True, mode=0o700)
            for name in ("pending.json", "request.json", "state.json", "ownership.json",
                         "bootstrap.json", "wine.log", "server.log"):
                path = source / name
                if path.exists():
                    data = path.read_bytes()
                    if credential in data:
                        raise RuntimeError("diagnostic export contains the private endpoint credential")
                    artifact = destination / name
                    artifact.write_bytes(data)
                    artifact.chmod(0o600)


def main(args):
    os.umask(0o077)
    if args.diagnostics and args.diagnostics.exists() and any(args.diagnostics.iterdir()):
        raise RuntimeError("diagnostic destination must be absent or empty")
    if any("/loader/wine" in line or "/server/wineserver" in line for line in process_table()):
        raise RuntimeError("Wine runtime is busy")
    variants = [read_json(package / "build-recipe.json")["variant"]
                for package in (args.package, args.alternate_package)]
    if variants[0] == variants[1]:
        raise RuntimeError("rollback proof requires distinct provider variants")
    binaries = build()
    payload_owner = tempfile.TemporaryDirectory(prefix="alloy-session-payload-", dir="/private/tmp")
    try:
        payload = Path(payload_owner.name) / "game"
        shutil.copytree(args.payload, payload)
        for marker in ("allow-blocked", "ignore-stop"):
            if (payload / marker).exists():
                raise RuntimeError("payload must not contain a preselected control marker")
        fixture = ServiceFixture(binaries)
        fixture.configuration["syntheticPayloadRoot"] = str(payload)
        fixture.endpoint.write_text(json.dumps(fixture.configuration))
        proof = Proof(args, fixture, payload)
        try:
            # Only the service may initialize its owned roots; arbitrary existing trees remain refused.
            fixture.__enter__()
            stopped = run(["launchctl", "bootout", fixture.target])
            if stopped.returncode:
                raise RuntimeError("private initialization service did not stop")
            fixture.loaded = False
            first = proof.activate(args.package)
            with fixture:
                try:
                    if not fixture.request("info")["gameLaunchAvailable"]:
                        raise RuntimeError("synthetic Wine driver is not available on this host")
                    proof.positive("valid-restricted", first, variants[0])
                    proof.positive("restriction-positive", first, variants[0], allowed=True)
                    proof.positive("service-crash", first, variants[0], crash=True)
                    proof.fault("wine.corrupt-snapshot")
                    proof.refusal("corrupt-policy", first, "POLICY_INTEGRITY")
                    proof.fault("wine.missing-lease")
                    proof.refusal("missing-lease", first, "GENERATION_LEASE_MISSING")
                    proof.fault()
                    with tampered_runtime(first):
                        proof.refusal("tampered-runtime", first, "RUNTIME_INTEGRITY")
                    proof.verify_runtime(first)
                    proof.positive("valid-after-faults", first, variants[0])
                    second = proof.activate(args.alternate_package)
                    if first["generationId"] == second["generationId"] or first["treeDigest"] == second["treeDigest"]:
                        raise RuntimeError("alternate package did not activate a distinct immutable runtime")
                    proof.verify_save()
                    proof.positive("alternate-runtime", second, variants[1])
                    restored = proof.activate(args.package)
                    if restored != first:
                        raise RuntimeError("rollback did not restore the exact original runtime")
                    proof.verify_save()
                    proof.positive("restored-runtime", restored, variants[0])
                    report = {"author": "Timur Isaev", "status": "pass", "clientTransport": "authenticated-XPC",
                              "runtime": first, "alternateRuntime": second, "restoredRuntime": restored,
                              "saveSHA256": proof.verify_save(), "runs": proof.reports}
                finally:
                    try:
                        proof.cleanup_sessions()
                    except BaseException:
                        fixture.preserve()
                        # Keep the payload at its existing pathname too; live
                        # guests and later recovery still refer to that G: root.
                        payload_owner._finalizer.detach()
                        raise
                    finally:
                        proof.export_diagnostics()
                        if not fixture.retained:
                            private_cleanup(fixture.root)
        finally:
            if fixture.root.exists() and not fixture.retained:
                private_cleanup(fixture.root)
            if fixture.loaded:
                fixture.__exit__(None, None, None)
            elif not fixture.retained:
                fixture.temporary.cleanup()
    finally:
        if "fixture" not in locals() or not fixture.retained:
            payload_owner.cleanup()
        else:
            payload_owner._finalizer.detach()
            print("retained unsafe-cleanup fixture: " + str(fixture.root), file=sys.stderr)
            print("retained unsafe-cleanup payload: " + str(payload), file=sys.stderr)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--alternate-package", type=Path, required=True)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--materializer", type=Path, required=True)
    parser.add_argument("--diagnostics", type=Path)
    main(parser.parse_args())
