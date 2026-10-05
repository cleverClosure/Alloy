#!/usr/bin/env python3
"""Compare every shipped file with narrow cause-specific exceptions. Author: Timur Isaev."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import stat
import subprocess
import tempfile

from inputs import BuildError, canonical, digest
from layers import file_table
from package import package, stage

HERE = Path(__file__).resolve().parent


def normalize_signature(data, start, size):
    """Mask only SHA-256 code-page hashes in this pinned linker's ad-hoc profile."""
    if size < 64:
        raise BuildError("truncated signature")
    magic, length, count, slot, offset = struct.unpack_from(">5I", data, start)
    if (magic, count, slot, offset) != (0xFADE0CC0, 1, 0, 20) or not 64 <= length <= size:
        raise BuildError("unsupported signature container")
    directory = start + offset
    magic, directory_size, version, flags, hashes, identifier, special, pages, limit = struct.unpack_from(
        ">9I", data, directory)
    if ((magic, version, flags, identifier, special, limit) !=
            (0xFADE0C02, 0x20400, 0x20002, 88, 0, start)
            or data[directory + 36:directory + 40] != bytes((32, 2, 0, 12))
            or pages != (start + 4095) // 4096 or hashes != 101
            or directory_size != hashes + pages * 32 or offset + directory_size != length
            or data[directory + identifier:directory + hashes] != b"winemetal.so\0"
            or any(data[start + length:start + size])):
        raise BuildError("unsupported signature CodeDirectory")
    data[directory + hashes:directory + directory_size] = b"\0" * (pages * 32)


def normalize_metal(data, build_root):
    """Do not discard arbitrary metadata or code: only three known AIR source names."""
    data = bytearray(data)
    if len(data) < 32 or data[:4] != bytes.fromhex("cffaedfe"):
        raise BuildError("expected a thin little-endian 64-bit Mach-O")
    commands, command_bytes = struct.unpack_from("<II", data, 16)
    offset, seen = 32, set()
    if command_bytes > len(data) - 32:
        raise BuildError("invalid Mach-O command bounds")
    for _ in range(commands):
        if offset + 8 > 32 + command_bytes:
            raise BuildError("truncated Mach-O load command")
        kind, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > 32 + command_bytes:
            raise BuildError("invalid Mach-O load command")
        if kind in (0x1B, 0x1D):
            if kind in seen:
                raise BuildError("duplicate UUID/signature")
            seen.add(kind)
        if kind == 0x1B:
            if length != 24:
                raise BuildError("invalid UUID command")
            data[offset + 8:offset + 24] = b"\0" * 16
        elif kind == 0x1D:
            if length != 16:
                raise BuildError("invalid signature command")
            start, size = struct.unpack_from("<II", data, offset + 8)
            if start < 32 + command_bytes or start + size != len(data):
                raise BuildError("invalid terminal signature bounds")
            normalize_signature(data, start, size)
        offset += length
    if offset != 32 + command_bytes or seen != {0x1B, 0x1D}:
        raise BuildError("missing UUID/signature")
    for name in ("air_msad", "air_samplepos", "air_tessellation"):
        value = str(build_root).encode() + f"/sources/dxmt/src/airconv/shaders/{name}.metal".encode()
        if data.count(value) != 1:
            raise BuildError("expected exactly one known Metal source path: " + name)
        data = data.replace(value, b"@" * len(str(build_root).encode()) + value[len(str(build_root).encode()):])
    return bytes(data)


def compare_trees(first, second, build_roots, exceptions, verify_signatures=True):
    rules = {(row["role"], row["path"]): row for row in exceptions}
    if len(rules) != len(exceptions):
        raise BuildError("duplicate reproducibility exception")
    rows, files, identical = [], 0, 0
    for role in first:
        tables = [{row[0]: row for row in file_table(tree[role])} for tree in (first, second)]
        if set(tables[0]) != set(tables[1]):
            raise BuildError("shipped path sets differ: " + role)
        for path, one in tables[0].items():
            other = tables[1][path]
            if one[1] == 0:
                files += 1
            if one == other:
                identical += one[1] == 0
                continue
            rule = rules.get((role, path))
            if not rule or one[:4] != other[:4] or one[5] != other[5] or one[1] != 0:
                raise BuildError(f"unlisted file or metadata difference: {role}/{path}")
            if rule["normalizer"] != "metal-source-path-v1":
                raise BuildError("unsupported exception normalizer")
            if len(str(build_roots[0]).encode()) != len(str(build_roots[1]).encode()):
                raise BuildError("Metal exception requires equal-length independent root paths")
            normalized = []
            for index, tree in enumerate((first, second)):
                file = tree[role] / path
                if verify_signatures:
                    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(file)], check=True,
                                   capture_output=True, timeout=10)
                normalized.append(normalize_metal(file.read_bytes(), build_roots[index]))
            if normalized[0] != normalized[1]:
                raise BuildError("difference exceeds declared cause: " + path)
            rows.append({"role": role, "path": path, "cause": rule["cause"],
                         "firstDigest": one[4], "secondDigest": other[4],
                         "normalizedSHA256": hashlib.sha256(normalized[0]).hexdigest()})
    return {"files": files, "byteIdenticalFiles": identical, "explainedDifferences": rows,
            "byteIdentical": not rows, "unlistedDifferences": 0}


def verify_package_copy(expected, actual):
    if stat.S_IMODE(actual.stat().st_mode) != 0o555:
        raise BuildError("package directory is not sealed")
    names = {path.name for path in expected.iterdir()}
    if names != {path.name for path in actual.iterdir()}:
        raise BuildError("package artifact sets differ")
    hashes = {}
    for name in sorted(names):
        wanted, supplied = expected / name, actual / name
        info = supplied.lstat()
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o444
                or info.st_size != wanted.stat().st_size or digest(supplied) != digest(wanted)):
            raise BuildError("package artifact differs from rebuilt canonical output: " + name)
        hashes[name] = digest(supplied)
    return hashes


def compare_packages(roots, supplied, scratch, has_exception):
    hashes = []
    for index, root in enumerate(roots):
        expected = scratch / ("expected-package-" + str(index))
        try:
            package(root, expected)
            hashes.append(verify_package_copy(expected, supplied[index]))
        finally:
            if expected.exists():
                expected.chmod(0o700)  # Unseal only this gate's disposable private package.
    if set(hashes[0]) != set(hashes[1]):
        raise BuildError("generated package artifact sets differ")
    derived = {"graphics-provider.layer.tar.zst", "sbom.json", "provenance.json", "runtime-manifest.json"}
    rows = []
    for name, first_hash in hashes[0].items():
        second_hash = hashes[1][name]
        if first_hash != second_hash and (not has_exception or name not in derived):
            raise BuildError("unlisted package artifact difference: " + name)
        rows.append({"path": name, "firstSHA256": first_hash, "secondSHA256": second_hash,
                     "derivedFromMetalException": first_hash != second_hash})
    return rows


def compare(first, second, packages):
    if first.resolve() == second.resolve():
        raise BuildError("two independent roots are required")
    recipes = [json.loads((root / "recipe.json").read_text()) for root in (first, second)]
    if recipes[0] != recipes[1]:
        raise BuildError("build recipes differ")
    for root, recipe in zip((first, second), recipes):
        result = json.loads((root / "build-result.json").read_text())
        if result.get("status") != "built" or result.get("recipeDigest") != hashlib.sha256(canonical(recipe)).hexdigest():
            raise BuildError("build completion record mismatch")
    exceptions = json.loads((HERE / "repro-exemptions.json").read_text())["exceptions"]
    with tempfile.TemporaryDirectory(prefix="alloy-repro-") as temporary:
        trees = [stage(root, Path(temporary) / str(index)) for index, root in enumerate((first, second))]
        result = compare_trees(*trees, (first, second), exceptions)
        artifacts = compare_packages((first, second), packages, Path(temporary), bool(result["explainedDifferences"]))
    return {"author": "Timur Isaev", "roots": [str(first), str(second)],
            "recipeDigest": hashlib.sha256(canonical(recipes[0])).hexdigest(),
            "packageArtifacts": artifacts, **result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("first", type=Path)
    parser.add_argument("second", type=Path)
    parser.add_argument("--package-first", type=Path, required=True)
    parser.add_argument("--package-second", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = compare(args.first.resolve(), args.second.resolve(),
                         (args.package_first.resolve(), args.package_second.resolve()))
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    except (BuildError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"FAIL: {error}\n")
