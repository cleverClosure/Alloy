#!/usr/bin/env python3
# Author: Timur Isaev
"""Run the host C parser and Swift CLI against the same bounded negative corpus.

Each negative is a separate process with a deadline. The C parser is the header
integrated by the Wine patch; the marker stands for its caller's import boundary.
Actual Wine rejection before guest imports is a separate runtime proof.
"""
import hashlib
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def run(argv, expected=0):
    result = subprocess.run([str(value) for value in argv], capture_output=True, timeout=30, check=False)
    if result.returncode != expected:
        raise RuntimeError(f"{argv}: exit {result.returncode}: {result.stderr.decode(errors='replace')[-4000:]}")
    return result


def seal(data):
    data = bytearray(data)
    data[32:64] = hashlib.sha256(data[96:]).digest()
    data[64:96] = bytes(32)
    data[64:96] = hashlib.sha256(data).digest()
    return data


def corpus(valid):
    cases = [("legacy", b"ALLOYP01" + valid[8:])]
    for size in [0, 1, 7, 8, 63, 64, 95, 96, len(valid) - 1]:
        cases.append((f"truncated-{size}", valid[:size]))
    cases.append(("trailing", valid + b"\0"))
    # Intact checksums deliberately bypass the integrity gate to exercise layout
    # and every semantic/presence/padding boundary in both readers.
    for offset in [8, 12, 16, 20, 24, 28, 96, 96 + 33, 96 + 95,
                   96 + 672, 96 + 676, 96 + 680, 96 + 684, 96 + 687,
                   96 + 1200 + 36 * 2, 96 + 2352 + 320 * 2]:
        changed = bytearray(valid)
        changed[offset] ^= 128
        cases.append((f"resealed-{offset}", seal(changed)))
    for offset, payload in [(96 + 160, b"C:\\..\\escape\0"), (96 + 688, b"relative\0"),
                            (96 + 2352, b"PATH\0"), (96 + 2352, b"WINEDEBUG\0"),
                            (96 + 1200, b"ntdll\0"), (96 + 1200, b"ZETA\0"),
                            (96 + 1200, b"zeta\0")]:
        changed = bytearray(valid)
        limit = 512 if offset in (96 + 160, 96 + 688) else 64 if offset == 96 + 2352 else 32
        changed[offset:offset + limit] = payload + bytes(limit - len(payload))
        cases.append((f"field-{offset}-{payload.hex()}", seal(changed)))
    # Duplicate/unsorted module and environment entries.
    changed = bytearray(valid)
    changed[96 + 1236:96 + 1272] = changed[96 + 1200:96 + 1236]
    cases.append(("duplicate-route", seal(changed)))
    changed = bytearray(valid)
    changed[96 + 2672:96 + 2992] = changed[96 + 2352:96 + 2672]
    cases.append(("duplicate-environment", seal(changed)))
    rng = random.Random(177)
    for index in range(128):
        changed = bytearray(valid)
        offset = rng.randrange(len(changed))
        changed[offset] ^= rng.randrange(1, 256)
        cases.append((f"seeded-bit-{index}", changed))
    for index in range(32):
        cases.append((f"seeded-random-{index}", rng.randbytes(rng.randrange(1, 16384))))
    return cases


def verify_embedded_parser():
    patch = (ROOT / "wine-v2.patch").read_text()
    section = patch.split("diff --git a/dlls/ntdll/alloy_snapshot_v2.h b/dlls/ntdll/alloy_snapshot_v2.h\n", 1)[1]
    section = section.split("diff --git ", 1)[0]
    embedded = "\n".join(line[1:] for line in section.splitlines()
                         if line.startswith("+") and not line.startswith("+++")) + "\n"
    if embedded != (ROOT / "native/snapshot-v2.h").read_text():
        raise RuntimeError("Wine patch parser differs from the sanitizer-tested native header")


def main():
    verify_embedded_parser()
    compiler = Path(os.environ.get("ALLOY_POLICY_COMPILER", ROOT / ".build/debug/alloy-policy-compile"))
    with tempfile.TemporaryDirectory(prefix="alloy-policy-v2-") as directory:
        scratch = Path(directory)
        parser = scratch / "validate"
        run(["xcrun", "--sdk", "macosx", "clang", "-Wall", "-Wextra", "-Werror",
             "-Wno-deprecated-declarations", "-fsanitize=undefined,address",
             "-g", ROOT / "native/validate.c", "-o", parser])
        policy = {"id": "default", "graphicsProvider": "dxmt", "providerDirectory": "C:\\providers",
                  "cpuProvider": "fex-arm64ec", "workingDirectory": "C:\\game",
                  "environment": {"LANG": "C", "TZ": "UTC"},
                  "dllRoutes": [{"module": "alpha", "loadOrder": "native"},
                                {"module": "zeta", "loadOrder": "disabled"}]}
        source = scratch / "source.json"
        source.write_text(json.dumps({"schemaVersion": 2, "defaultPolicy": policy, "processPolicies": []}))
        snapshot = scratch / "snapshot.bin"
        run([compiler, "compile-v2", source, snapshot])
        valid = snapshot.read_bytes()
        assert b"policy-import-marker" in run([parser, snapshot]).stdout
        run([compiler, "inspect-v2", snapshot, hashlib.sha256(valid).hexdigest()])
        cases = corpus(valid)
        for name, value in cases:
            candidate = scratch / f"{name}.bin"
            candidate.write_bytes(value)
            for reader, expected in [([parser, candidate], 65), ([compiler, "inspect-v2", candidate], 64)]:
                result = run(reader, expected)
                if b"policy-" not in result.stderr or b"policy-import-marker" in result.stdout:
                    raise RuntimeError(f"unnamed failure or crossed import boundary: {name}: {result}")
        print(json.dumps({"author": "Timur Isaev", "positive": 1, "negativeProcesses": len(cases) * 2,
                          "malformedCases": len(cases), "asan": True, "ubsan": True,
                          "scope": "host-parser; Wine guest controls run separately"}, sort_keys=True))


if __name__ == "__main__":
    main()
