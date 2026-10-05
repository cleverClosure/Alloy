#!/usr/bin/env python3
# Author: Timur Isaev
"""Exercise the development export boundary; never authorizes a session launch."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    executable = Path(sys.argv[1]).resolve()
    resolved = {"ruleIds": [], "cpuProvider": "native-arm64ec", "graphicsProvider": "dxmt",
                "syncProvider": "conservative", "dllOverrides": {}, "environment": {"LANG": "C"},
                "networkPolicy": "allow", "debugPolicy": "off", "services": {}}
    request = {"schemaVersion": "alloy-resolved-policy-v2-development", "processes": [],
               "defaultPolicy": {"id": "test", "providerDirectory": "C:\\providers", "resolved": resolved}}
    with tempfile.TemporaryDirectory(prefix="alloy-export-controls-") as temporary:
        root = Path(temporary)

        def invoke(label, value, code=0):
            source, output = root / (label + ".json"), root / label
            source.write_text(value if isinstance(value, str) else json.dumps(value))
            result = subprocess.run([str(executable), str(source), str(output)], capture_output=True, timeout=30)
            assert result.returncode == code, (label, result)
            if code:
                assert b"snapshot-export:" in result.stderr and not output.exists(), label
                return None
            report = json.loads(result.stdout)
            snapshot = (output / "policy.snapshot").read_bytes()
            assert snapshot[:8] == b"ALLOYP02"
            assert report["digest"] == "sha256:" + hashlib.sha256(snapshot).hexdigest()
            assert not report["productionEligible"]
            assert (output / "policy.snapshot").stat().st_mode & 0o777 == 0o400
            assert json.loads((output / "report.json").read_text()) == report
            return report

        ready = invoke("ready", request)
        assert ready["runtimeReady"] and not ready["notYetLowered"]
        unsupported = copy.deepcopy(request)
        unsupported["defaultPolicy"]["resolved"]["networkPolicy"] = "deny"
        gap = invoke("gap", unsupported)
        assert not gap["runtimeReady"] and [item["field"] for item in gap["notYetLowered"]] == ["networkPolicy"]
        unknown = dict(request, unexpected=True)
        invoke("unknown", unknown, 64)
        invoke("duplicate", '{"processes":[],"processes":[]}', 64)
        invoke("oversized", " " * (4 * 1024 * 1024 + 1), 64)
        source = root / "ready.json"
        result = subprocess.run([str(executable), str(source), str(root / "ready")], capture_output=True, timeout=30)
        assert result.returncode == 64 and b"output directory must be new" in result.stderr
        assert (root / "ready/policy.snapshot").read_bytes()[:8] == b"ALLOYP02"
    print("development export: 2 positive and 4 rejection controls passed")


if __name__ == "__main__":
    main()
