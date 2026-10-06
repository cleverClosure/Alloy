#!/usr/bin/env python3
"""Local lab CLI. Author: Timur Isaev."""

import argparse
import json
from pathlib import Path

from alloy_lab.common import Invalid, load
from alloy_lab.evidence import validate as validate_evidence
from alloy_lab.scenario import read


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate-scenario", "migrate-v1"):
        command = commands.add_parser(name)
        command.add_argument("path", type=Path)
    evidence = commands.add_parser("validate-evidence")
    evidence.add_argument("path", type=Path)
    evidence.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "validate-evidence":
            value = validate_evidence(load(args.path), args.artifacts)
            print(json.dumps({"valid": True, "run_id": value["run_id"]}))
        else:
            value, source = read(args.path)
            print(json.dumps(value if args.command == "migrate-v1" else
                             {"valid": True, "id": value["id"], "source_sha256": source}, sort_keys=True, indent=2))
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(2, f"INVALID {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
