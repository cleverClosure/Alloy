#!/usr/bin/env python3
"""Pinned input verification and filtered Git-object export. Author: Timur Isaev."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess


class BuildError(Exception):
    """A build input or isolation invariant failed."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_digest(path, expected):
    if not Path(path).is_file() or digest(path) != expected:
        raise BuildError(f"input digest mismatch: {path}")


def capture(argv, **kwargs):
    return subprocess.check_output(argv, stderr=subprocess.PIPE, **kwargs).decode().strip()


def tree_table(root):
    """A diagnostic input identity; package file tables have their own format."""
    root = Path(root)
    rows = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                rows.append([rel, "link", os.readlink(path)])
            elif stat.S_ISREG(info.st_mode):
                rows.append([rel, "file", stat.S_IMODE(info.st_mode) & 0o111, digest(path)])
            elif not stat.S_ISDIR(info.st_mode):
                raise BuildError(f"unsupported input: {path}")
    return sorted(rows)


def tree_digest(root):
    return hashlib.sha256(canonical(tree_table(root))).hexdigest()


def excluded(path):
    parts = PurePosixPath(path).parts
    return any(p in {"vkd3d", "vkd3d-proton"} for p in parts) or parts[:2] == ("src", "d3d12")


def git_entries(repo, revision):
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
        raise BuildError("source revision must be a full immutable SHA")
    actual = capture(["git", "-C", str(repo), "rev-parse", revision + "^{commit}"])
    if actual != revision:
        raise BuildError("source commit mismatch")
    data = subprocess.check_output(["git", "-C", str(repo), "ls-tree", "-rz", revision])
    entries = []
    for item in data.split(b"\0"):
        if not item:
            continue
        header, name = item.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        name = name.decode("utf-8")
        if not excluded(name):
            entries.append((mode, kind, oid, name))
    return entries


def export_objects(repo, revision, destination, submodules):
    """Never requests forbidden blobs; never consults checkout contents or HEAD."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    entries = git_entries(repo, revision)
    gitlinks = {name: oid for mode, kind, oid, name in entries if mode == "160000"}
    for name, oid in submodules.items():
        if gitlinks.get(name) != oid:
            raise BuildError(f"submodule pin mismatch: {name}")
    process = subprocess.Popen(["git", "-C", str(repo), "cat-file", "--batch"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for mode, kind, oid, name in entries:
            if kind != "blob":
                continue
            path = destination / name
            if path.is_absolute() and (".." in PurePosixPath(name).parts or name.startswith("/")):
                raise BuildError("unsafe Git path")
            path.parent.mkdir(parents=True, exist_ok=True)
            process.stdin.write((oid + "\n").encode())
            process.stdin.flush()
            identity, objtype, size = process.stdout.readline().split()
            if identity.decode() != oid or objtype != b"blob":
                raise BuildError("Git object read mismatch")
            content = process.stdout.read(int(size))
            if process.stdout.read(1) != b"\n":
                raise BuildError("truncated Git object")
            if mode == "120000":
                target = content.decode()
                resolved = (path.parent / target).resolve()
                if not resolved.is_relative_to(destination.resolve()):
                    raise BuildError(f"source symlink escapes export: {name}")
                path.symlink_to(target)
            else:
                path.write_bytes(content)
                path.chmod(0o755 if mode == "100755" else 0o644)
    finally:
        process.stdin.close()
        process.stdout.close()
        process.wait(timeout=10)
    for name, oid in submodules.items():
        export_objects(Path(repo) / name, oid, destination / name, {})


def verify_inputs(recipe, repo, archive, host=True):
    for name, source in recipe["sources"].items():
        entries = git_entries(Path(repo) / "third_party/src" / name, source["revision"])
        links = {row[3]: row[2] for row in entries if row[0] == "160000"}
        for path, sha in source["submodules"].items():
            if links.get(path) != sha:
                raise BuildError(f"wrong submodule: {name}/{path}")
            git_entries(Path(repo) / "third_party/src" / name / path, sha)
    check_digest(archive, recipe["toolchain"]["sha256"])
    base = Path(__file__).resolve().parents[2]
    for relative, sha in recipe["files"].items():
        check_digest(base / relative, sha)
    if host:
        metal = json.loads(capture(["/usr/bin/xcodebuild", "-showComponent", "MetalToolchain", "-json"]))
        expected = recipe["host"]["metal"]
        for key in ("buildVersion", "toolchainIdentifier"):
            if metal.get(key) != expected[key]:
                raise BuildError("Metal compiler version mismatch")
        if tree_digest(Path(metal["toolchainSearchPath"]) / "Metal.xctoolchain") != expected["treeSHA256"]:
            raise BuildError("Metal compiler tree mismatch")
        for item in recipe["host"]["files"]:
            check_digest(item["path"], item["sha256"])
        for item in recipe["host"]["trees"]:
            if tree_digest(item["path"]) != item["sha256"]:
                raise BuildError(f"host tree mismatch: {item['path']}")
        for item in recipe["host"]["commands"]:
            if capture(item["argv"]) != item["output"]:
                raise BuildError(f"host version mismatch: {item['argv']}")
