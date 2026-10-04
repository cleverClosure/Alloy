#!/usr/bin/env python3
"""Reproduce the vector oracle proofs without running Wine. Author: Timur Isaev."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
MANIFEST = json.loads((ROOT / "isa-corpus-vectors.json").read_text())
FLAGS = [
    "-std=c11", "-Wall", "-Wextra", "-Werror", "-fno-fast-math",
    "-ffp-contract=off", "-fno-vectorize", "-fno-slp-vectorize",
]


def validate(text, rc, family, mutated, instruction=False):
    """Exit code, named diagnostics, coverage, seed and checksum must agree."""
    spec = MANIFEST["families"][family]
    lines = text.splitlines()
    tag = spec["mutation"] if mutated else "none"
    mode = "instruction-parity" if instruction else "reference-only"
    header = (f"cpu-001 isa-corpus {family} mode={mode} "
              f"seed={MANIFEST['seed']} mutate={tag}")
    if lines.count(header) != 1 or lines[0] != header:
        raise ValueError("missing, duplicate or incorrect seed/mode header")
    prefix = f"cpu-001 isa-corpus {family}:"
    summaries = [line for line in lines if line.startswith(prefix)]
    pattern = re.escape(prefix) + r" cases=(\d+) failures=(\d+) checksum=([0-9a-f]{16}) mutate=(\S+)"
    summary = re.fullmatch(pattern, summaries[0]) if len(summaries) == 1 else None
    if summary is None or lines[-1] != summaries[0]:
        raise ValueError("missing, duplicate or incomplete summary")
    cases, failures, checksum, actual_tag = summary.groups()
    expected_hash = spec["mutation_checksum"] if mutated else spec["checksum"]
    if int(cases) != spec["cases"] or checksum != expected_hash or actual_tag != tag:
        raise ValueError("case count, checksum or mutation tag disagrees with recorded oracle")
    rows = []
    for line in lines:
        if line.startswith("op="):
            row = re.fullmatch(r"op=(\S+) cases=(\d+) checksum=([0-9a-f]{16})", line)
            if row is None:
                raise ValueError("malformed operation record")
            rows.append({"name": row[1], "cases": int(row[2])})
    if rows != spec["operations"] or sum(row["cases"] for row in rows) != int(cases):
        raise ValueError("operation inventory is missing, duplicated or reordered")
    fail_lines = [line for line in lines if line.startswith("FAIL")]
    if not mutated:
        if rc != 0 or int(failures) != 0 or fail_lines:
            raise ValueError("clean run must exit zero with no failure counter or diagnostics")
    else:
        named = f"FAIL {tag} "
        if (rc != 1 or int(failures) == 0 or not fail_lines
                or not all(line.startswith(named) for line in fail_lines)
                or not any(line.startswith(named + "hand-vector ") for line in fail_lines)):
            raise ValueError("mutation was not caught by its named hand vector with exit 1")
        if instruction and not any(line.startswith(named + "parity ") for line in fail_lines):
            raise ValueError("instruction comparison did not observe the mutation")
        if instruction and int(failures) != spec["mutation_instruction_failures"]:
            raise ValueError("instruction failure count includes missing or unexpected mismatches")
        if not instruction and int(failures) != 1:
            raise ValueError("native mutation must fail exactly its one literal hand vector")
    return checksum


def selftest():
    """Synthetic corrupt outputs prove the reader, without pretending to run ISA."""
    family = "sse"
    spec = MANIFEST["families"][family]
    rows = [f"op={op['name']} cases={op['cases']} checksum=0000000000000000"
            for op in spec["operations"]]
    clean = "\n".join([
        f"cpu-001 isa-corpus sse mode=reference-only seed={MANIFEST['seed']} mutate=none",
        *rows,
        f"cpu-001 isa-corpus sse: cases={spec['cases']} failures=0 "
        f"checksum={spec['checksum']} mutate=none",
    ])
    mutation = clean.replace("mutate=none", "mutate=addps").replace(
        "failures=0", "failures=1").replace(spec["checksum"], spec["mutation_checksum"])
    mutation = mutation.replace(rows[0], "FAIL addps hand-vector expected=00 actual=01\n" + rows[0])
    validate(clean, 0, family, False)
    validate(mutation, 1, family, True)
    validate(clean.replace("mode=reference-only", "mode=instruction-parity"),
             0, family, False, instruction=True)
    instruction_mutation = mutation.replace("mode=reference-only", "mode=instruction-parity").replace(
        "failures=1", f"failures={spec['mutation_instruction_failures']}").replace(
        rows[0], "FAIL addps parity expected=00 actual=01\n" + rows[0])
    validate(instruction_mutation, 1, family, True, instruction=True)
    checks = [
        ("timeout", mutation, 142, True),
        ("crash", mutation, 139, True),
        ("zero-exit mutation", mutation, 0, True),
        ("silent failure counter", clean.replace(rows[0], "FAIL addps parity mismatch\n" + rows[0]), 0, False),
        ("missing operation", clean.replace(rows[0] + "\n", ""), 0, False),
        ("duplicate operation", clean.replace(rows[0], rows[0] + "\n" + rows[0]), 0, False),
        ("missing summary", "\n".join(clean.splitlines()[:-1]), 0, False),
        ("duplicate summary", clean + "\n" + clean.splitlines()[-1], 0, False),
        ("wrong checksum", clean.replace(spec["checksum"], "ffffffffffffffff"), 0, False),
        ("wrong cases", clean.replace(f"cases={spec['cases']}", "cases=1"), 0, False),
        ("wrong seed", clean.replace(MANIFEST["seed"], "0000000000000001"), 0, False),
        ("wrong mutation name", mutation.replace("FAIL addps", "FAIL subps"), 1, True),
        ("missing hand vector", mutation.replace("hand-vector", "parity"), 1, True),
        ("unknown failure", mutation.replace("failures=1", "failures=2"), 1, True),
    ]
    for name, output, rc, mutated in checks:
        try:
            validate(output, rc, family, mutated)
        except ValueError:
            continue
        raise RuntimeError(f"reader accepted its {name} negative control")
    try:
        validate(mutation.replace("mode=reference-only", "mode=instruction-parity"),
                 1, family, True, instruction=True)
    except ValueError:
        pass
    else:
        raise RuntimeError("reader accepted instruction mutation without a parity mismatch")
    try:
        validate(instruction_mutation.replace(f"failures={spec['mutation_instruction_failures']}",
                                             "failures=999999"), 1, family, True, instruction=True)
    except ValueError:
        pass
    else:
        raise RuntimeError("reader accepted unexpected instruction failure counts")
    print(f"PASS reader controls: 4 positive, {len(checks) + 2} negative", flush=True)


def run(binary, log):
    try:
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"timeout running {binary}; this is not a mutation pass") from error
    text = result.stdout + result.stderr
    log.write_text(text)
    return text, result.returncode


def inspect_instructions(binary, toolchain, spec):
    disassembly = subprocess.check_output([
        str(toolchain / "llvm-objdump"), "-d", "--disassemble-symbols=instruction",
        "--no-show-raw-insn", str(binary),
    ], text=True)
    (binary.parent / (binary.name + ".asm")).write_text(disassembly)
    present = set(re.findall(r"^\s*[0-9a-f]+:\s+([a-z][a-z0-9]*)", disassembly, re.MULTILINE))
    aliases = {"blendps5": "blendps", "palignr13": "palignr", "crc32d": "crc32l",
               "pcmpestrm-any": "pcmpestrm", "pcmpestrm-each": "pcmpestrm"}
    required = {aliases.get(op["name"], op["name"]) for op in spec["operations"]}
    missing = required - present
    if missing:
        raise RuntimeError(f"{binary.name} does not execute its named instructions: {sorted(missing)}")


def build_and_run(args):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("this proof requires native arm64 macOS; do not label emulated references native")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    cross = args.toolchain / "x86_64-w64-mingw32-clang"
    if not cross.is_file():
        raise RuntimeError(f"missing cross compiler {cross}")
    report = {
        "author": "Timur Isaev", "host": platform.platform(), "seed": MANIFEST["seed"],
        "fex": "NOT RUN: runtime issue #111", "rosetta": args.rosetta,
        "clang": subprocess.check_output(["/usr/bin/clang", "--version"], text=True).splitlines()[0],
        "families": {},
    }
    for family, spec in MANIFEST["families"].items():
        source = ROOT / f"isa_corpus_{family}.c"
        results = {}
        for mutated in (False, True):
            tag = "mutation" if mutated else "clean"
            extra = ["-DALLOY_CORPUS_MUTATE"] if mutated else []
            baseline = None
            for opt in (0, 1, 2, 3):
                name = f"{family}-{tag}-arm64-O{opt}"
                binary = out / name
                subprocess.run(["/usr/bin/clang", *FLAGS, f"-O{opt}", *extra,
                                str(source), "-o", str(binary)], check=True)
                text, rc = run(binary, out / f"{name}.log")
                validate(text, rc, family, mutated)
                if baseline is not None and text != baseline:
                    raise RuntimeError(f"{family} {tag} output changed with optimization")
                baseline = text
            binary = out / f"{family}-{tag}-arm64-O2"
            for repeat in range(3):
                text, rc = run(binary, out / f"{family}-{tag}-repeat-{repeat}.log")
                validate(text, rc, family, mutated)
                if text != baseline:
                    raise RuntimeError(f"{family} {tag} separate invocation changed output")
            pe = out / f"isa_corpus_{family}-{tag}.exe"
            subprocess.run([str(cross), *FLAGS, "-O2", spec["flag"], *extra,
                            str(source), "-o", str(pe)], check=True)
            inspect_instructions(pe, args.toolchain, spec)
            results[tag] = {"native": "PASS", "pe": "BUILT, NOT EXECUTED",
                            "pe_sha256": hashlib.sha256(pe.read_bytes()).hexdigest()}
            if args.rosetta:
                binary = out / f"{family}-{tag}-rosetta"
                subprocess.run(["/usr/bin/clang", *FLAGS, "-O2", "-arch", "x86_64", spec["flag"],
                                *extra, str(source), "-o", str(binary)], check=True)
                text, rc = run(binary, out / f"{family}-{tag}-rosetta.log")
                validate(text, rc, family, mutated, instruction=True)
                results[tag]["rosetta"] = "PASS (independent translator, not FEX)"
            print(f"PASS {family} {tag}: O0/O1/O2/O3, three repeats, PE build"
                  + (", Rosetta instruction parity" if args.rosetta else ""), flush=True)
        report["families"][family] = results
    (out / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Native vector proof complete. FEX NOT RUN. Report: {out / 'verification.json'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--rosetta", action="store_true", help="also require independent x86 Mach-O instruction parity")
    parser.add_argument("--selftest", action="store_true", help="only check the output reader's controls")
    parser.add_argument("--toolchain", type=Path, default=Path(os.environ.get(
        "ALLOY_TOOLCHAIN_BIN", "/Users/cleverclosure/Developer/Alloy/tools/toolchains/"
        "llvm-mingw-20260616-ucrt-macos-universal/bin")))
    args = parser.parse_args()
    selftest()
    if not args.selftest:
        if args.output is None:
            parser.error("output directory required unless --selftest")
        build_and_run(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
