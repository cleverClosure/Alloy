#!/usr/bin/env python3
"""Two cold prefix caches and isolated real wineservers. Author: Timur Isaev."""

import argparse
from contextlib import nullcontext
import json
import os
from pathlib import Path
import subprocess
import tempfile

from proof_support import PACKAGE, build


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output:
        args.output.mkdir(mode=0o700)
    store = Path(os.environ["ALLOY_SESSION_CONTENT_STORE"]).resolve()
    game = os.environ.get("ALLOY_SESSION_GAME", "policy177")
    binary = build() / "alloy-environment-proof"
    scratch = nullcontext(args.output) if args.output else tempfile.TemporaryDirectory(
        prefix="alloy-environment-", dir="/private/tmp")
    with scratch as temporary:
        reports = []
        for number in (1, 2):
            processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True, timeout=5)
            if any("/loader/wine" in row or "/server/wineserver" in row for row in processes.splitlines()):
                raise RuntimeError("Wine runtime is busy")
            output = Path(temporary) / str(number)
            result = subprocess.run([
                "python3", str(PACKAGE.parents[1] / "tools/lab/lab.py"), "lock-run",
                "--mode", "exclusive", "--timeout", "180", "--", str(binary), str(store), game, str(output)
            ], capture_output=True, text=True, timeout=200)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            report = json.loads((output / "proof.json").read_text())
            if report["status"] != "pass" or report["runtimeUnchanged"] != "true":
                raise RuntimeError("environment proof did not complete")
            reports.append(report)
        for field in ("runtimeTreeDigest", "templateDigest", "prefixDigest"):
            if reports[0][field] != reports[1][field]:
                raise RuntimeError("cold templates differ: " + field)
        print(json.dumps({"author": "Timur Isaev", "status": "pass", "coldCacheRuns": reports}))


if __name__ == "__main__":
    main()
