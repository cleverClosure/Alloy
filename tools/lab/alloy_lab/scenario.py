"""Scenario v2 validation and lossless LAB-001 migration. Author: Timur Isaev."""

import copy
import importlib.util
from pathlib import Path
import re
import sys

from .common import Invalid, decode, digest, fields, file_bytes, file_digest, hashed, identifier, number, relative, require, text

REPO = Path(__file__).resolve().parents[3]
LEGACY = REPO / "spikes/LAB-001"
CLASSES = ("exact", "numeric", "visual", "behavioral", "performance", "informational")
TOKENS = re.compile(r"\{(runtime|subject|work|control|attempt|input:[a-zA-Z0-9_.-]+|runtime_file:[a-zA-Z0-9_.-]+)\}")


def template(value, inputs, runtime_files):
    text(value, "template")
    for match in TOKENS.finditer(value):
        token = match[1]
        if token.startswith("input:"):
            require(token[6:] in inputs, "template:unknown_input")
        if token.startswith("runtime_file:"):
            require(token[13:] in runtime_files, "template:unknown_runtime_file")
    remaining = TOKENS.sub("", value)
    require("{" not in remaining and "}" not in remaining, "template:unknown_token")


def validate(value):
    fields(value, ("version", "id", "revision", "subject", "runtime", "host", "inputs", "steps", "observables",
                   "timing_sensitive", "timeout_seconds", "retry_limit", "context", "legacy"), "scenario")
    require(type(value["version"]) is int and value["version"] == 2, "scenario:version")
    identifier(value["id"])
    number(value["revision"], "revision", 1, 1000000, integer=True)
    fields(value["subject"], ("kind", "path", "sha256"), "subject")
    subject = value["subject"]
    require(subject["kind"] in ("lab001", "native", "wine", "windows-reference"), "subject:kind")
    relative(subject["path"])
    digest(subject["sha256"])
    fields(value["runtime"], ("kind", "sha256", "executable", "files"), "runtime")
    runtime = value["runtime"]
    require(runtime["kind"] in ("native", "wine", "windows-reference"), "runtime:kind")
    require(runtime["kind"] == ("native" if subject["kind"] in ("native", "lab001") else subject["kind"]), "runtime:kind_mismatch")
    digest(runtime["sha256"])
    relative(runtime["executable"])
    require(type(runtime["files"]) is dict and 1 <= len(runtime["files"]) <= 8192, "runtime:files")
    paths = []
    for name, entry in runtime["files"].items():
        identifier(name)
        fields(entry, ("path", "sha256", "bytes"), "runtime.file")
        paths.append(relative(entry["path"]))
        digest(entry["sha256"])
        number(entry["bytes"], "runtime.bytes", high=1 << 40, integer=True)
    require(len(set(paths)) == len(paths) and runtime["executable"] in paths, "runtime:inventory")
    require(runtime["sha256"] == runtime_digest(runtime), "runtime:digest_mismatch")
    fields(value["host"], ("os", "architectures", "minimum_memory_bytes", "requirements"), "host")
    host = value["host"]
    require(host["os"] in ("Darwin", "Windows"), "host:os")
    require(type(host["architectures"]) is list and 1 <= len(host["architectures"]) <= 4, "host:architectures")
    require(all(item in ("arm64", "aarch64", "x86_64", "AMD64") for item in host["architectures"]), "host:architecture")
    number(host["minimum_memory_bytes"], "host.memory", high=1 << 50, integer=True)
    require(type(host["requirements"]) is dict and len(host["requirements"]) <= 32, "host:requirements")
    for key, setting in host["requirements"].items():
        identifier(key)
        text(setting, "host.requirement")
    require(type(value["inputs"]) is dict and len(value["inputs"]) <= 64, "inputs:shape")
    for name, entry in value["inputs"].items():
        identifier(name)
        fields(entry, ("path", "sha256"), "input")
        relative(entry["path"])
        digest(entry["sha256"])
    require(type(value["timing_sensitive"]) is bool, "timing_sensitive:bool")
    number(value["timeout_seconds"], "timeout", 0.01, 7200)
    number(value["retry_limit"], "retry_limit", 0, 3, integer=True)
    require(type(value["steps"]) is list and 1 <= len(value["steps"]) <= 32, "steps:shape")
    ids, phases = [], []
    for step in value["steps"]:
        fields(step, ("id", "phase", "argv", "environment", "timeout_seconds", "expected_exit"), "step")
        identifier(step["id"])
        ids.append(step["id"])
        require(step["phase"] in ("setup", "run", "teardown"), "step:phase")
        phases.append(("setup", "run", "teardown").index(step["phase"]))
        require(type(step["argv"]) is list and 1 <= len(step["argv"]) <= 128, "step:argv")
        require(step["argv"][0] == "{runtime}" or re.fullmatch(r"\{runtime_file:[a-zA-Z0-9_.-]+\}", step["argv"][0]), "step:executable")
        for arg in step["argv"]:
            template(arg, value["inputs"], runtime["files"])
        require(type(step["environment"]) is dict and len(step["environment"]) <= 32, "step:environment")
        for key, setting in step["environment"].items():
            require(re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", key), "environment:key")
            require(key not in ("PYTHONPATH", "PYTHONHOME", "DYLD_INSERT_LIBRARIES"), "environment:reserved")
            template(setting, value["inputs"], runtime["files"])
        number(step["timeout_seconds"], "step.timeout", 0.01, value["timeout_seconds"])
        number(step["expected_exit"], "step.exit", 0, 255, integer=True)
    require(len(set(ids)) == len(ids) and phases == sorted(phases) and 1 in phases, "steps:order_or_duplicate")
    require(type(value["observables"]) is list and 1 <= len(value["observables"]) <= 128, "observables:shape")
    names = []
    for item in value["observables"]:
        fields(item, ("id", "source", "comparison", "unit"), "observable")
        identifier(item["id"])
        names.append(item["id"])
        text(item["unit"], "observable.unit", 64)
        source = item["source"]
        fields(source, ("kind", "step", "path", "key"), "source")
        require(source["kind"] in ("file-sha256", "json-file", "stdout-json", "elapsed", "exit-code"), "source:kind")
        require(source["step"] in ids, "source:unknown_step")
        if source["kind"] in ("file-sha256", "json-file"):
            relative(source["path"])
        else:
            require(source["path"] is None, "source:unexpected_path")
        require(type(source["key"]) is list and len(source["key"]) <= 16, "source:key")
        for key in source["key"]:
            text(key, "source.key", 128)
        require(source["kind"] in ("json-file", "stdout-json") or not source["key"], "source:unexpected_key")
        rule = item["comparison"]
        fields(rule, ("class", "absolute", "relative", "direction"), "comparison")
        require(rule["class"] in CLASSES and rule["direction"] in ("any", "higher", "lower"), "comparison:class")
        number(rule["absolute"], "comparison.absolute")
        number(rule["relative"], "comparison.relative", high=100)
        if rule["class"] not in ("numeric", "performance"):
            require(rule["absolute"] == rule["relative"] == 0 and rule["direction"] == "any", "comparison:unused_tolerance")
        if rule["class"] == "performance" or source["kind"] == "elapsed":
            require(value["timing_sensitive"], "scenario:timing_lock_required")
    require(len(set(names)) == len(names), "observable:duplicate")
    fields(value["context"], ("game_build", "profile", "cache_state", "automation", "privacy"), "context")
    for key in ("game_build", "profile", "automation"):
        digest(value["context"][key])
    text(value["context"]["cache_state"], "context.cache", 256)
    require(value["context"]["privacy"] == "local-only-no-accounts", "context:privacy")
    if value["legacy"] is not None:
        fields(value["legacy"], ("source_sha256", "definition"), "legacy")
        digest(value["legacy"]["source_sha256"])
        require(subject["kind"] == "lab001", "legacy:adapter")
        validate_v1(value["legacy"]["definition"])
        require(value["id"] == value["legacy"]["definition"]["id"], "legacy:id")
    return value


def runtime_digest(runtime):
    return hashed({key: runtime[key] for key in ("kind", "executable", "files")})


def validate_v1(value):
    # Load only the spike's dependency-free validator under a private module name.
    spec = importlib.util.spec_from_file_location("alloy_lab._scenario_v1", LEGACY / "scenario.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    from tempfile import TemporaryDirectory
    import json
    try:
        with TemporaryDirectory(prefix="alloy-lab-v1-") as directory:
            path = Path(directory) / "scenario.json"
            path.write_text(json.dumps(value))
            module.Scenario.load(path)
    except ValueError as error:
        raise Invalid(f"legacy:{error}") from error
    return value


def migrate(value, source_sha256, subject_root=LEGACY):
    validate_v1(value)
    interpreter = Path(sys.executable).resolve()
    runtime = {"kind": "native", "executable": interpreter.name,
               "files": {"python": {"path": interpreter.name, **file_digest(interpreter)}}}
    runtime["sha256"] = runtime_digest(runtime)
    subject_hash = file_digest(Path(subject_root) / "subject.py")["sha256"]
    result = {
        "version": 2, "id": value["id"], "revision": 1,
        "subject": {"kind": "lab001", "path": "subject.py", "sha256": subject_hash},
        "runtime": runtime, "host": {"os": "Darwin", "architectures": ["arm64", "x86_64"],
                                      "minimum_memory_bytes": 0, "requirements": {}},
        "inputs": {}, "steps": [{"id": "render", "phase": "run",
            "argv": ["{runtime}", "{subject}", "--output", "{work}", "--mode", "{control}"],
            "environment": {}, "timeout_seconds": value["timeout_seconds"], "expected_exit": 0}],
        "observables": [], "timing_sensitive": True, "timeout_seconds": value["timeout_seconds"], "retry_limit": 0,
        "context": {"game_build": subject_hash, "profile": hashed({"profile": "lab001"}), "cache_state": "fresh",
                    "automation": subject_hash, "privacy": "local-only-no-accounts"},
        "legacy": {"source_sha256": source_sha256, "definition": copy.deepcopy(value)},
    }
    def observable(name, kind, path=None, key=None, unit="sha256"):
        return {"id": name, "source": {"kind": kind, "step": "render", "path": path, "key": key or []},
                "comparison": {"class": "exact", "absolute": 0, "relative": 0, "direction": "any"}, "unit": unit}
    result["observables"] = [observable(f"frame-{index}", "file-sha256", f"frame-{index:03d}.ppm") for index in range(4)]
    result["observables"] += [observable(name, "stdout-json", key=[name], unit=unit) for name, unit in
                              (("frame_count", "frames"), ("pixel_count", "pixels"), ("pixel_sum", "channel-value-sum"))]
    return validate(result)


def read(path, subject_root=None):
    data = file_bytes(path)
    value = decode(data)
    import hashlib
    source = hashlib.sha256(data).hexdigest()
    if type(value) is dict and type(value.get("version")) is int and value["version"] == 1:
        value = migrate(value, source, subject_root or Path(path).parent)
    return validate(value), source
