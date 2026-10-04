#!/usr/bin/env python3
"""Independent Decimal arithmetic audit of raw variance samples. Author: Timur Isaev."""

from decimal import Decimal, localcontext
import json
import math
from pathlib import Path
import sys


def check(path):
    path = Path(path)
    batch = json.loads(path.read_text())
    if any(Path(name).is_absolute() or ".." in Path(name).parts for name in batch["samples"]):
        raise ValueError("samples:unsafe_path")
    samples = [json.loads((path.parent / name).read_text()) for name in batch["samples"]]
    if len(samples) < 3 or len(set(batch["samples"])) != len(samples) or len({sample["run_id"] for sample in samples}) != len(samples):
        raise ValueError("samples:too_few")
    units = {**{f"timing.{key}": "seconds" for key in ("setup_seconds", "run_wall_seconds", "teardown_seconds", "wall_seconds", "child_user_seconds", "child_system_seconds", "child_cpu_seconds")}, "subject.frame_count": "frames", "subject.pixel_count": "pixels", "subject.pixel_sum": "channel-value-sum"}
    if set(batch["stats"]) != set(units):
        raise ValueError("stats:missing_or_extra_metric")
    for key, expected in batch["stats"].items():
        if expected["unit"] != units[key]:
            raise ValueError("stats:wrong_unit")
        section, name = key.split(".", 1)
        section = "timing" if section == "timing" else "subject_metrics"
        vector = [Decimal(str(raw[section][name])) for raw in samples]
        with localcontext() as context:
            context.prec = 50
            mean = sum(vector) / len(vector)
            variance = sum((item - mean) ** 2 for item in vector) / len(vector)
            actual = {"count": len(vector), "mean": mean, "population_variance": variance, "standard_deviation": variance.sqrt(), "min": min(vector), "max": max(vector), "range": max(vector) - min(vector)}
        for field, value in actual.items():
            if type(expected[field]) not in (int, float) or not math.isfinite(expected[field]):
                raise ValueError(f"{key}.{field}:invalid_number")
            if not math.isclose(float(value), expected[field], rel_tol=1e-12, abs_tol=1e-15):
                raise ValueError(f"{key}.{field}:independent_mismatch")
    return {"metrics": len(batch["stats"]), "samples": len(samples), "status": "PASS"}


if __name__ == "__main__":
    try:
        print(json.dumps(check(sys.argv[1]), sort_keys=True))
    except (OSError, ValueError, KeyError, IndexError) as error:
        raise SystemExit(f"FAIL: {error}")
