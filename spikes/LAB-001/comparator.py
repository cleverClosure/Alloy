"""Evidence comparison and compulsory comparator controls. Author: Timur Isaev."""

import copy

from evidence import hash_value, seal, validate
from scenario import require
from variance import validate_calibration


def compare(baseline, candidate, calibration):
    validate(baseline)
    validate(candidate)
    frozen = validate_calibration(calibration, host=baseline["host"])
    for key in ("runner", "interpreter", "host", "subject", "scenario"):
        if baseline[key] != candidate[key]:
            return {"verdict": "INCOMPARABLE", "reasons": [f"identity:{key}"]}
    before, after = baseline["raw"], candidate["raw"]
    if before["state"] != "COMPLETED" or after["state"] != "COMPLETED":
        return {"verdict": "INCOMPARABLE", "reasons": ["failed_lifecycle"]}
    require(before["scenario_sha256"] == frozen["binding"]["scenario_sha256"] and before["inputs_before"] == frozen["binding"]["execution_inputs"], "comparator:calibration_identity_mismatch")
    reasons = []
    for first, second in zip(before["frames"], after["frames"]):
        if first["sha256"] != second["sha256"]:
            reasons.append(f"frame:{first['path']}")
    for name, value in before["subject_metrics"].items():
        if after["subject_metrics"][name] != value:
            reasons.append(f"counter:{name}")
    for name, value in before["timing"].items():
        if abs(after["timing"][name] - value) > frozen["limits"][f"timing.{name}"]["max_mean_shift"]:
            reasons.append(f"timing:{name}")
    # Mode labels and expected verdicts never decide observed classification.
    return {"verdict": "REGRESSION" if reasons else "CLEAN", "reasons": reasons}


def selftest(baseline, calibration, classifier=compare):
    """Known-number evidence pairs, constructed fixtures rather than new runs."""
    cases = []
    cases.append(("identical", copy.deepcopy(baseline), "CLEAN"))
    label_only = copy.deepcopy(baseline)
    label_only["raw"]["mode"] = "seeded"
    label_only["raw"]["argv"][-1] = "seeded"
    cases.append(("changed_label_only", seal(label_only), "CLEAN"))
    frame = copy.deepcopy(baseline)
    frame["raw"]["frames"][0]["sha256"] = "f" * 64
    for entry in frame["artifacts"]:
        if entry["path"] == "frame-000.ppm":
            entry["sha256"] = "f" * 64
    cases.append(("changed_frame_clean_label", seal(frame), "REGRESSION"))
    counter = copy.deepcopy(baseline)
    counter["raw"]["subject_metrics"]["pixel_sum"] += 1
    cases.append(("changed_counter", seal(counter), "REGRESSION"))
    slow = copy.deepcopy(baseline)
    slow["raw"]["timing"]["wall_seconds"] += 1 + 10 * calibration["limits"]["timing.wall_seconds"]["max_mean_shift"]
    cases.append(("changed_wall_cost", seal(slow), "REGRESSION"))
    different_host = copy.deepcopy(baseline)
    different_host["host"]["cpu_count"] += 1
    different_host["correlation"]["host_class_id"] = hash_value(different_host["host"])
    cases.append(("different_host", seal(different_host), "INCOMPARABLE"))
    results = []
    for name, candidate, expected in cases:
        actual = classifier(baseline, candidate, calibration)["verdict"]
        require(actual == expected, f"comparator_selftest:{name}:expected_{expected}:got_{actual}")
        results.append({"name": name, "expected": expected, "actual": actual})
    return results
