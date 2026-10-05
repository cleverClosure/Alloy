#!/usr/bin/env python3
"""Canonical development layer writer. Author: Timur Isaev."""

import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import tarfile
import unicodedata

from inputs import BuildError, canonical, digest

MEDIA = "application/vnd.alloy.layer.v1+tar+zstd"
FEATURES = ["canonical-table-v1", "raw-zstd-v1", "development-adhoc-v1"]


def cbor(value):
    def head(kind, size):
        if size < 24:
            return bytes([kind << 5 | size])
        for code, width in ((24, 1), (25, 2), (26, 4), (27, 8)):
            if size < 1 << (8 * width):
                return bytes([kind << 5 | code]) + size.to_bytes(width, "big")
        raise BuildError("CBOR integer exceeds uint64")
    if type(value) is int and value >= 0:
        return head(0, value)
    if isinstance(value, str):
        data = value.encode("utf-8")
        return head(3, len(data)) + data
    if isinstance(value, list):
        return head(4, len(value)) + b"".join(cbor(item) for item in value)
    raise BuildError("unsupported canonical CBOR type")


def safe_path(path):
    parts = path.split("/")
    if (not path or len(path.encode()) > 240 or path != unicodedata.normalize("NFC", path)
            or any(part in ("", ".", "..") for part in parts) or "\\" in path
            or ":" in path or any(ord(ch) < 32 or ord(ch) == 127 for ch in path)):
        raise BuildError(f"unsafe layer path: {path!r}")
    return path


def safe_link(path, target):
    if not target or target.startswith("/") or "\\" in target or ":" in target:
        raise BuildError("unsafe layer symlink")
    parts = list(PurePosixPath(path).parent.parts)
    for item in target.split("/"):
        if item == "..":
            if not parts:
                raise BuildError("layer symlink escapes files")
            parts.pop()
        elif item not in ("", "."):
            parts.append(item)
    if not parts:
        raise BuildError("layer symlink names root")
    safe_path("/".join(parts))


def file_table(root):
    rows, seen = [], set()
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(directory) / name
            relative = safe_path(path.relative_to(root).as_posix())
            folded = relative.casefold()
            if folded in seen:
                raise BuildError("case-fold path collision")
            seen.add(folded)
            info = path.lstat()
            if stat.S_ISREG(info.st_mode):
                if info.st_mode & 0o6000 or info.st_nlink != 1:
                    raise BuildError("set-id or hard-linked layer file")
                rows.append([relative, 0, 0o555 if info.st_mode & 0o111 else 0o444,
                             info.st_size, "sha256:" + digest(path), ""])
            elif stat.S_ISDIR(info.st_mode):
                rows.append([relative, 1, 0o555, 0, "", ""])
            elif stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                safe_link(relative, target)
                data = target.encode()
                rows.append([relative, 2, 0o777, len(data),
                             "sha256:" + hashlib.sha256(data).hexdigest(), target])
            else:
                raise BuildError("special layer file")
    return sorted(rows, key=lambda row: row[0].encode())


def raw_zstd(source, destination):
    """RFC 8878 single segment, four-byte size, raw blocks, no dictionary/checksum."""
    size = source.stat().st_size
    if size > 1024**3:
        raise BuildError("development layer exceeds 1 GiB expanded bound")
    with source.open("rb") as reader, destination.open("xb") as writer:
        writer.write(b"\x28\xb5\x2f\xfd\xa0" + struct.pack("<I", size))
        remaining = size
        while remaining:
            chunk = reader.read(min(remaining, 128 * 1024))
            remaining -= len(chunk)
            writer.write(((len(chunk) << 3) | int(remaining == 0)).to_bytes(3, "little"))
            writer.write(chunk)
        if not size:
            writer.write(b"\x01\0\0")


def add_bytes(archive, name, data):
    info = tarfile.TarInfo(name)
    info.mode = 0o444
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))


def write_layer(root, output, *, role, revision, recipe_digest):
    table = file_table(root)
    table_data = cbor(table)
    manifest = {
        "schemaVersion": "1.0", "name": role, "version": "development-1",
        "mediaType": MEDIA, "targetArchitecture": "arm64", "minimumHostCapability": "macOS-27-arm64",
        "fileTreeDigest": "sha256:" + hashlib.sha256(table_data).hexdigest(),
        "sourceRevision": revision, "buildRecipeDigest": recipe_digest,
        "allowedCompositionRoles": [role], "requiredFeatures": FEATURES,
    }
    tar_path = output.with_suffix(".tar.tmp")
    with tar_path.open("xb") as stream, tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        add_bytes(archive, "layer.json", canonical(manifest))
        add_bytes(archive, "metadata/file-table.cbor", table_data)
        for path, kind, mode, size, sha, target in table:
            entry = tarfile.TarInfo("files/" + path)
            entry.mode = mode
            if kind == 1:
                entry.type = tarfile.DIRTYPE
                archive.addfile(entry)
            elif kind == 2:
                entry.type = tarfile.SYMTYPE
                entry.linkname = target
                archive.addfile(entry)
            else:
                entry.size = size
                with (root / path).open("rb") as reader:
                    archive.addfile(entry, reader)
    try:
        raw_zstd(tar_path, output)
    finally:
        tar_path.unlink()
    return {"name": role, "version": manifest["version"], "digest": "sha256:" + digest(output),
            "mediaType": MEDIA, "size": output.stat().st_size, "sourceRevision": revision}
