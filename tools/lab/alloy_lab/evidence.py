"""Evidence v2: provenance, observations and honest failures. Author: Timur Isaev."""

import copy
from datetime import datetime
import hashlib

from .common import artifact, canonical, decode, digest, fields, file_bytes, file_digest, hashed, identifier, number, require, safe_file, text
from .scenario import validate as validate_scenario

STATES = ("COMPLETED", "FAILED", "INCOMPARABLE", "CANCELLED", "DEADLINE", "INTERRUPTED")
SCOPE = "local-engineering-not-certification"


def seal(record):
    result = copy.deepcopy(record)
    result.pop("integrity", None)
    result["integrity"] = {"algorithm": "sha256", "claim": "accidental-edit-detection-only", "sha256": hashed(result)}
    return result


def timestamp(value):
    text(value, "timestamp", 64)
    try:
        require(value.endswith("Z") and datetime.fromisoformat(value[:-1] + "+00:00").tzinfo is not None, "timestamp:utc")
    except ValueError as error:
        from .common import Invalid
        raise Invalid("timestamp:invalid") from error


def identity(value):
    fields(value, ("expected", "before", "after"), "identity")
    digest(value["expected"])
    for name in ("before", "after"):
        if value[name] is not None:
            digest(value[name])


def validate(record, artifact_root=None):
    fields(record, ("version", "scope", "run_id", "job_id", "attempt", "created_at", "finished_at", "scenario",
                    "source_scenario_sha256", "provenance", "control", "state", "events", "steps", "observed",
                    "artifacts", "failures", "duration_seconds", "integrity"), "evidence")
    require(type(record["version"]) is int and record["version"] == 2, "evidence:version")
    require(record["scope"] == SCOPE, "evidence:scope")
    for key in ("run_id", "job_id"):
        identifier(record[key], key)
    number(record["attempt"], "attempt", 1, 4, integer=True)
    for key in ("created_at", "finished_at"):
        timestamp(record[key])
    require(datetime.fromisoformat(record["finished_at"].replace("Z", "+00:00")) >=
            datetime.fromisoformat(record["created_at"].replace("Z", "+00:00")), "evidence:time_order")
    scenario = validate_scenario(record["scenario"])
    require(record["attempt"] <= scenario["retry_limit"] + 1, "evidence:attempt_limit")
    digest(record["source_scenario_sha256"])
    provenance = record["provenance"]
    fields(provenance, ("runner", "scheduler", "host", "host_class_sha256", "scenario_sha256", "runtime",
                        "subject", "inputs", "environment_health"), "provenance")
    for name in ("runner", "scheduler"):
        fields(provenance[name], ("id", "sha256"), name)
        identifier(provenance[name]["id"])
        digest(provenance[name]["sha256"])
    host = provenance["host"]
    fields(host, ("os", "os_release", "os_build", "architecture", "hardware_class", "firmware", "memory_bytes",
                  "cpu_count", "capabilities"), "host")
    for key in ("os", "os_release", "os_build", "architecture", "hardware_class", "firmware"):
        text(host[key], f"host.{key}", 1024)
    number(host["memory_bytes"], "host.memory", 1, 1 << 50, integer=True)
    number(host["cpu_count"], "host.cpus", 1, 100000, integer=True)
    require(type(host["capabilities"]) is dict and len(host["capabilities"]) <= 32, "host:capabilities")
    for key, value in host["capabilities"].items():
        identifier(key)
        text(value, "capability")
    require(provenance["host_class_sha256"] == hashed(host), "provenance:host_mismatch")
    require(provenance["scenario_sha256"] == hashed(scenario), "provenance:scenario_mismatch")
    for name, expected in (("runtime", scenario["runtime"]["sha256"]), ("subject", scenario["subject"]["sha256"])):
        identity(provenance[name])
        require(provenance[name]["expected"] == expected, f"provenance:{name}_mismatch")
    fields(provenance["inputs"], scenario["inputs"], "provenance.inputs")
    for name, expected in scenario["inputs"].items():
        identity(provenance["inputs"][name])
        require(provenance["inputs"][name]["expected"] == expected["sha256"], "provenance:input_mismatch")
    health = provenance["environment_health"]
    fields(health, ("resource_lock", "requirements_met", "notes"), "health")
    require(health["resource_lock"] in ("exclusive", "shared", "not-acquired"), "health:lock")
    require(type(health["requirements_met"]) is bool, "health:requirements")
    require(type(health["notes"]) is list and len(health["notes"]) <= 32, "health:notes")
    for note in health["notes"]:
        text(note, "health.note")
    require(record["control"] in ("clean", "seeded", "hang", "error", "flaky"), "control:unsupported")
    require(record["state"] in STATES, "evidence:state")
    number(record["duration_seconds"], "duration", high=14400)
    require(type(record["events"]) is list and 1 <= len(record["events"]) <= 128, "events:shape")
    previous = 0
    for event in record["events"]:
        fields(event, ("state", "elapsed_seconds"), "event")
        require(event["state"] in ("SETUP", "RUN", "TEARDOWN", *STATES), "event:state")
        number(event["elapsed_seconds"], "event.elapsed", previous, record["duration_seconds"])
        previous = event["elapsed_seconds"]
    require(record["events"][-1]["state"] == record["state"], "events:terminal_mismatch")
    require(type(record["failures"]) is list and len(record["failures"]) <= 64, "failures:shape")
    for failure in record["failures"]:
        fields(failure, ("code", "detail"), "failure")
        identifier(failure["code"])
        text(failure["detail"], "failure.detail")
    require(type(record["steps"]) is list and len(record["steps"]) <= len(scenario["steps"]), "steps:shape")
    expected_steps = {step["id"]: step for step in scenario["steps"]}
    ids = []
    for step in record["steps"]:
        fields(step, ("id", "argv", "exit_code", "elapsed_seconds"), "step.result")
        require(step["id"] in expected_steps and step["id"] not in ids, "step:identity")
        ids.append(step["id"])
        require(type(step["argv"]) is list and 1 <= len(step["argv"]) <= 128, "step.argv:shape")
        for arg in step["argv"]:
            text(arg, "step.argv")
        require(step["exit_code"] is None or type(step["exit_code"]) is int, "step:exit")
        number(step["elapsed_seconds"], "step.elapsed", high=record["duration_seconds"])
    require(type(record["observed"]) is dict, "observed:shape")
    require(set(record["observed"]) <= {item["id"] for item in scenario["observables"]}, "observed:unknown")
    require(len(canonical(record["observed"])) <= 65536, "observed:too_large")
    require(type(record["artifacts"]) is list and len(record["artifacts"]) <= 512, "artifacts:shape")
    paths = []
    total = 0
    for entry in record["artifacts"]:
        artifact(entry)
        paths.append(entry["path"].casefold())
        total += entry["bytes"]
        if artifact_root is not None:
            observed = file_digest(safe_file(artifact_root, entry["path"]))
            require(observed == {key: entry[key] for key in ("sha256", "bytes")}, "artifact:corrupt")
    require(len(set(paths)) == len(paths) and total <= 64 << 20, "artifacts:duplicate_or_large")
    source_entries = {entry['path'][8:]: {key: entry[key] for key in ('sha256', 'bytes')}
                      for entry in record['artifacts'] if entry['path'].startswith('sources/')}
    if source_entries:
        require(hashed(source_entries) == provenance['runner']['sha256'], 'provenance:source_archive_mismatch')
        require(source_entries.get('scheduler.py', {}).get('sha256') == provenance['scheduler']['sha256'],
                'provenance:scheduler_archive_mismatch')
    if artifact_root is not None:
        from .scenario import runtime_digest
        for which in ('before', 'after'):
            name = f'provenance/runtime-{which}.json'
            if name in {entry['path'] for entry in record['artifacts']}:
                manifest = decode(file_bytes(safe_file(artifact_root, name)))
                require(runtime_digest(manifest) == provenance['runtime'][which], 'provenance:runtime_archive_mismatch')
    if record["state"] == "COMPLETED":
        require(not record["failures"] and ids == list(expected_steps), "completed:steps_or_failures")
        require(all(step["exit_code"] == expected_steps[step["id"]]["expected_exit"] for step in record["steps"]), "completed:exit")
        require(set(record["observed"]) == {item["id"] for item in scenario["observables"]}, "completed:missing_observation")
        artifacts = {entry["path"]: entry for entry in record["artifacts"]}
        results = {step["id"]: step for step in record["steps"]}
        for step in ids:
            require({f"steps/{step}.stdout.log", f"steps/{step}.stderr.log"} <= artifacts.keys(), "completed:missing_log")
        for item in scenario["observables"]:
            source, observed = item["source"], record["observed"][item["id"]]
            kind = source["kind"]
            path = source["path"] if kind in ("file-sha256", "json-file") else f"steps/{source['step']}.stdout.log"
            if kind in ("file-sha256", "json-file", "stdout-json"):
                require(path in artifacts, "observed:missing_artifact")
                if kind == "file-sha256":
                    require(observed == artifacts[path]["sha256"], "observed:digest_mismatch")
                elif artifact_root is not None:
                    actual = decode(file_bytes(safe_file(artifact_root, path)))
                    for key in source["key"]:
                        require(type(actual) is dict and key in actual, "observed:missing_key")
                        actual = actual[key]
                    require(type(observed) is type(actual) and observed == actual, "observed:artifact_mismatch")
            elif kind == "exit-code":
                require(observed == results[source["step"]]["exit_code"], "observed:exit_mismatch")
            else:
                require(observed == results[source["step"]]["elapsed_seconds"], "observed:time_mismatch")
            if item["comparison"]["class"] in ("numeric", "performance"):
                number(observed, "observed.numeric", -1e18, 1e18)
        require(health["requirements_met"] and health["resource_lock"] ==
                ("exclusive" if scenario["timing_sensitive"] else "shared"), "completed:environment")
        for observed in (provenance["runtime"], provenance["subject"], *provenance["inputs"].values()):
            require(observed["expected"] == observed["before"] == observed["after"], "completed:identity_drift")
    else:
        require(bool(record["failures"]), "failed:missing_reason")
    integrity = record["integrity"]
    fields(integrity, ("algorithm", "claim", "sha256"), "integrity")
    require(integrity["algorithm"] == "sha256" and integrity["claim"] == "accidental-edit-detection-only", "integrity:claim")
    require(integrity["sha256"] == hashed({key: value for key, value in record.items() if key != "integrity"}), "integrity:mismatch")
    return record
