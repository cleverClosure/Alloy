#!/usr/bin/env python3
# STORE-001 Steam install fingerprint tool.
# Author: Timur Isaev
# Gate 6: superseded by runtime/store-identity/ for production observation;
# retained as the working historical fingerprint and parity reference.
#
# Produces the exact-build identity record the Phase-0 storefront proof needs:
# discovers installs via libraryfolders.vdf / appmanifest ACFs (the D-019
# identity inputs), records buildid + per-depot manifest ids, hashes every
# installed file, and emits a deterministic JSON fingerprint.  --verify
# recomputes against a stored fingerprint for the rerun-evidence leg.
#
# Works against any Steam library directory (native, CrossOver, or an Alloy
# prefix); no Steam credentials are touched.

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def parse_vdf(text):
    """Minimal parser for Valve's text KeyValues format."""
    tokens = re.findall(r'"((?:[^"\\]|\\.)*)"|([{}])', text)
    pos = 0

    def parse_object():
        nonlocal pos
        obj = {}
        while pos < len(tokens):
            string, brace = tokens[pos]
            pos += 1
            if brace == "}":
                return obj
            key = string
            nstring, nbrace = tokens[pos]
            pos += 1
            if nbrace == "{":
                obj[key] = parse_object()
            else:
                obj[key] = nstring
        return obj

    root = {}
    while pos < len(tokens):
        string, brace = tokens[pos]
        pos += 1
        if brace:
            continue
        nstring, nbrace = tokens[pos]
        pos += 1
        if nbrace == "{":
            root[string] = parse_object()
        else:
            root[string] = nstring
    return root


def discover_libraries(steam_root):
    vdf_path = steam_root / "steamapps" / "libraryfolders.vdf"
    libraries = [steam_root]
    if vdf_path.exists():
        data = parse_vdf(vdf_path.read_text(errors="replace"))
        folders = data.get("libraryfolders", {})
        for key, entry in folders.items():
            if not key.isdigit() or not isinstance(entry, dict):
                continue
            path = entry.get("path")
            if path:
                libraries.append(Path(path.replace("\\\\", "/")))
    seen, unique = set(), []
    for lib in libraries:
        if lib.resolve() not in seen and (lib / "steamapps").is_dir():
            seen.add(lib.resolve())
            unique.append(lib)
    return unique


def read_manifests(library):
    apps = []
    for acf in sorted((library / "steamapps").glob("appmanifest_*.acf")):
        data = parse_vdf(acf.read_text(errors="replace")).get("AppState", {})
        depots = {
            depot: {"manifest": info.get("manifest"), "size": info.get("size")}
            for depot, info in data.get("InstalledDepots", {}).items()
            if isinstance(info, dict)
        }
        apps.append(
            {
                "appid": data.get("appid"),
                "name": data.get("name"),
                "buildid": data.get("buildid"),
                "installdir": data.get("installdir"),
                "acf": acf.name,
                "library": str(library),
                "depots": depots,
            }
        )
    return apps


def fingerprint_files(install_root):
    records = []
    aggregate = hashlib.sha256()
    for path in sorted(install_root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for block in iter(lambda: handle.read(1 << 20), b""):
                digest.update(block)
        rel = str(path.relative_to(install_root))
        entry = {"path": rel, "size": path.stat().st_size, "sha256": digest.hexdigest()}
        records.append(entry)
        aggregate.update(f"{rel}\0{entry['size']}\0{entry['sha256']}\n".encode())
    return records, aggregate.hexdigest()


def build_fingerprint(app):
    install_root = Path(app["library"]) / "steamapps" / "common" / app["installdir"]
    if not install_root.is_dir():
        sys.exit(f"install dir missing: {install_root}")
    files, aggregate = fingerprint_files(install_root)
    return {
        "record": "alloy-store-001-fingerprint",
        "version": 1,
        "appid": app["appid"],
        "name": app["name"],
        "buildid": app["buildid"],
        "depots": app["depots"],
        "file_count": len(files),
        "total_bytes": sum(f["size"] for f in files),
        "aggregate_sha256": aggregate,
        "files": files,
    }


def main():
    parser = argparse.ArgumentParser(description="STORE-001 Steam build fingerprint")
    parser.add_argument("steam_root", type=Path, help="Steam root (contains steamapps/)")
    parser.add_argument("--app", help="appid to fingerprint")
    parser.add_argument("--out", type=Path, help="write fingerprint JSON here")
    parser.add_argument("--verify", type=Path, help="verify against stored fingerprint")
    args = parser.parse_args()

    libraries = discover_libraries(args.steam_root)
    if not libraries:
        sys.exit("no steamapps library found under the given root")
    apps = [app for lib in libraries for app in read_manifests(lib)]

    if not args.app:
        print(f"{len(libraries)} library folder(s), {len(apps)} installed app(s):")
        for app in apps:
            print(
                f"  {app['appid']:>8}  build {app['buildid']:>10}  "
                f"{len(app['depots'])} depot(s)  {app['name']}"
            )
        return

    matches = [a for a in apps if a["appid"] == args.app]
    if not matches:
        sys.exit(f"appid {args.app} not installed in any discovered library")
    fingerprint = build_fingerprint(matches[0])

    if args.verify:
        stored = json.loads(args.verify.read_text())
        same_build = stored["buildid"] == fingerprint["buildid"]
        same_depots = stored["depots"] == fingerprint["depots"]
        same_content = stored["aggregate_sha256"] == fingerprint["aggregate_sha256"]
        print(f"buildid: {stored['buildid']} -> {fingerprint['buildid']}"
              f" {'==' if same_build else 'DIFFERS'}")
        print(f"depot manifests: {'identical' if same_depots else 'DIFFER'}")
        print(f"content aggregate: {'identical' if same_content else 'DIFFERS'}")
        if same_build and same_depots and same_content:
            print("rerun evidence: EXACT MATCH")
            return
        sys.exit("rerun evidence: MISMATCH")

    out = args.out or Path(f"fingerprint-{args.app}-{fingerprint['buildid']}.json")
    out.write_text(json.dumps(fingerprint, indent=1))
    print(
        f"{fingerprint['name']}: build {fingerprint['buildid']}, "
        f"{fingerprint['file_count']} files, {fingerprint['total_bytes']} bytes\n"
        f"aggregate {fingerprint['aggregate_sha256']}\nwritten to {out}"
    )


if __name__ == "__main__":
    main()
