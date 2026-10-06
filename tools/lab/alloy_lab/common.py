"""Bounded canonical data and file identity. Author: Timur Isaev."""

import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat

MAX_JSON = 4 << 20
MAX_ARTIFACT = 16 << 20


class Invalid(ValueError):
    """A stable, named refusal rather than a partially accepted record."""


def require(ok, reason):
    if not ok:
        raise Invalid(reason)


def fields(value, names, where):
    require(type(value) is dict and set(value) == set(names), f"{where}:fields")


def text(value, where, limit=4096):
    require(type(value) is str and 0 < len(value) <= limit and "\0" not in value, f"{where}:text")


def identifier(value, where="id"):
    require(type(value) is str and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}", value), f"{where}:identifier")
    require(value not in (".", ".."), f"{where}:identifier")


def digest(value, where="digest"):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value), f"{where}:sha256")


def number(value, where, low=0, high=1e18, integer=False):
    require(type(value) in ((int,) if integer else (int, float)), f"{where}:number")
    require(low <= value <= high and (type(value) is int or math.isfinite(value)), f"{where}:range")


def relative(value):
    text(value, "path", 1024)
    require("\\" not in value and not value.startswith("/"), "path:relative")
    require(all(part not in ("", ".", "..") and len(part.encode()) <= 255 for part in value.split("/")), "path:component")
    return value


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def hashed(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def decode(data):
    require(len(data) <= MAX_JSON, "json:too_large")
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "json:duplicate_field")
            result[key] = value
        return result
    def constant(_):
        raise Invalid("json:nonfinite")
    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Invalid(f"json:invalid:{error}") from error


def file_bytes(path, limit=MAX_JSON):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, "file:unsafe_or_large")
        data = bytearray()
        while True:
            block = os.read(fd, min(65536, limit + 1 - len(data)))
            if not block:
                break
            data.extend(block)
            require(len(data) <= limit, "file:too_large")
        return bytes(data)
    finally:
        os.close(fd)


def file_digest(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode), "file:not_regular")
        result = hashlib.sha256()
        size = 0
        while block := os.read(fd, 1 << 20):
            result.update(block)
            size += len(block)
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) and size == after.st_size,
                "file:changed_while_hashing")
        return {"sha256": result.hexdigest(), "bytes": size}
    finally:
        os.close(fd)


def load(path):
    return decode(file_bytes(path))


def artifact(value):
    fields(value, ("path", "sha256", "bytes"), "artifact")
    relative(value["path"])
    digest(value["sha256"])
    number(value["bytes"], "artifact.bytes", high=MAX_ARTIFACT, integer=True)


def safe_file(root, name):
    relative(name)
    current = Path(root)
    require(current.is_dir() and not current.is_symlink(), "root:unsafe")
    for component in name.split("/"):
        current = current / component
        require(not current.is_symlink(), "path:symlink")
    require(current.is_file(), "file:not_regular")
    return current
