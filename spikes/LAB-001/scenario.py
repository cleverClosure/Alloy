"""Strict, dependency-free scenario format. Author: Timur Isaev."""

from dataclasses import dataclass
import json
import math
from pathlib import Path
import re
import sys


class Invalid(ValueError):
    """A stable named validation failure."""


def require(condition, reason):
    if not condition:
        raise Invalid(reason)


def fields(value, expected, path):
    require(type(value) is dict, f"{path}:wrong_type")
    require(not (set(expected) - set(value)), f"{path}:missing_field")
    require(not (set(value) - set(expected)), f"{path}:unexpected_field")


def number(value, path, minimum=0):
    require(type(value) in (int, float), f"{path}:wrong_type")
    require(type(value) is int or math.isfinite(value), f"{path}:wrong_type")
    require(value >= minimum, f"{path}:out_of_range")


def digest(value, path):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value), f"{path}:invalid_digest")


def strict_json(text):
    def pairs(items):
        out = {}
        for key, value in items:
            require(key not in out, f"{key}:duplicate_field")
            out[key] = value
        return out

    def constant(value):
        raise Invalid(f"json:nonfinite:{value}")

    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


@dataclass(frozen=True)
class Scenario:
    path: Path
    definition: dict

    @classmethod
    def load(cls, path):
        path = Path(path).resolve()
        value = strict_json(path.read_text())
        fields(value, ("version", "id", "command", "timeout_seconds", "capture", "expected"), "scenario")
        require(type(value["version"]) is int and value["version"] == 1, "scenario:unsupported_version")
        require(type(value["id"]) is str and re.fullmatch(r"[a-z0-9-]+", value["id"]), "scenario:invalid_id")
        command = value["command"]
        require(type(command) is list and len(command) >= 2, "command:wrong_type")
        require(command[0] == "{python}", "command:interpreter_required")
        require(command[1] == "{root}/subject.py", "command:subject_required")
        require(command == ["{python}", "{root}/subject.py", "--output", "{output}", "--mode", "{mode}"], "command:unsupported_template")
        number(value["timeout_seconds"], "timeout_seconds", 0.01)
        require(value["timeout_seconds"] <= 60, "timeout_seconds:out_of_range")
        fields(value["capture"], ("format", "width", "height", "count"), "capture")
        require(value["capture"] == {"format": "ppm-p6", "width": 16, "height": 16, "count": 4}, "capture:unsupported_shape")
        for key in ("width", "height", "count"):
            require(type(value["capture"][key]) is int, f"capture.{key}:wrong_type")
        fields(value["expected"], ("clean", "seeded"), "expected")
        for mode in ("clean", "seeded"):
            expected = value["expected"][mode]
            fields(expected, ("frames", "metrics"), f"expected.{mode}")
            require(type(expected["frames"]) is list and len(expected["frames"]) == 4, f"expected.{mode}.frames:wrong_shape")
            for entry in expected["frames"]:
                digest(entry, f"expected.{mode}.frames")
            fields(expected["metrics"], ("frame_count", "pixel_count", "pixel_sum"), f"expected.{mode}.metrics")
            for metric, result in expected["metrics"].items():
                require(type(result) is int and result >= 0, f"expected.{mode}.{metric}:wrong_type")
        return cls(path, value)

    def argv(self, output, mode):
        require(mode in ("clean", "seeded", "hang", "error"), "command:invalid_mode")
        values = {"python": sys.executable, "root": str(self.path.parent), "output": str(output), "mode": mode}
        return [arg.format(**values) for arg in self.definition["command"]]
