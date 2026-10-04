#!/usr/bin/env python3
"""Deterministic synthetic bytes and an independent FINGERPRINT_V1 §5 oracle.

Author: Timur Isaev
"""

import hashlib
import json
from pathlib import Path


RECIPE_PATH = Path(__file__).parent.parent / "Fixtures/Breadth/recipe.v1.json"


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":")) + "\n").encode("utf-8")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def payloads(title):
    """Yield exact relative UTF-8 paths/bytes; no filesystem or scanner input."""
    special = [
        title["image"],
        ".settings/hidden.bin",
        "locales/日本語/挨拶.txt",
        "locales/Казакша/сәлем.txt",
        "unicode/nfc/caf\u00e9.txt",
        "unicode/nfd/cafe\u0301.txt",
        "DLC/expansion-" + title["dlc_appid"] + "/chapter.bin",
        "/".join(["long"] + ["segment-%02d-" % index + "x" * 60
                               for index in range(8)] + ["終点.bin"]),
        "empty.bin",
    ]
    for index in range(title["file_count"]):
        path = (special[index] if index < len(special) else
                "assets/%03d/chunk-%05d.bin" % (index // 100, index))
        data = (b"" if path == "empty.bin" else
                ("alloy-breadth-v1\0%s\0%05d\0%s\n" %
                 (title["appid"], index, path)).encode("utf-8"))
        yield path, data


def fingerprint(title, entries=None, depots=None):
    """Compute from recipe bytes, never from a Swift scan or directory listing."""
    source = payloads(title) if entries is None else entries
    files = sorted(({"path": path, "size": len(data), "sha256": sha256(data)}
                    for path, data in source), key=lambda item: item["path"].encode("utf-8"))
    digest = hashlib.sha256()
    for item in files:
        digest.update(item["path"].encode("utf-8") + b"\0" +
                      str(item["size"]).encode("ascii") + b"\0" +
                      item["sha256"].encode("ascii") + b"\n")
    if depots is None:
        sizes = [0] * len(title["depots"])
        for index, (path, data) in enumerate(payloads(title)):
            depot_index = len(sizes) - 1 if path.startswith("DLC/") else index % (len(sizes) - 1)
            sizes[depot_index] += len(data)
        depots = {depot: {"manifest": str(7000000000000000000 + int(depot)),
                          "size": str(sizes[index])}
                  for index, depot in enumerate(title["depots"])}
    return {"record": "alloy-store-001-fingerprint", "version": 1,
            "appid": title["appid"], "name": title["name"], "buildid": title["buildid"],
            "depots": depots, "files": files, "file_count": len(files),
            "total_bytes": sum(item["size"] for item in files),
            "aggregate_sha256": digest.hexdigest()}


def manifest(title, record):
    lines = ['"AppState"', '{']
    for key, value in (("appid", title["appid"]), ("name", title["name"]),
                       ("installdir", title["name"]), ("buildid", title["buildid"]),
                       ("SizeOnDisk", str(record["total_bytes"]))):
        lines.append('  "%s" "%s"' % (key, value))
    lines.extend(['  "InstalledDepots"', '  {'])
    for depot, value in sorted(record["depots"].items()):
        lines.extend(['    "%s"' % depot, '    {',
                      '      "manifest" "%s"' % value["manifest"],
                      '      "size" "%s"' % value["size"]])
        if depot == title["depots"][-1]:
            lines.append('      "dlcappid" "%s"' % title["dlc_appid"])
        lines.append('    }')
    lines.extend(['  }', '}'])
    return ("\n".join(lines) + "\n").encode("utf-8")


def generate(root, titles=None):
    """Materialize only beneath a new caller-owned scratch root."""
    root.mkdir(parents=True, exist_ok=False)
    titles = json.loads(RECIPE_PATH.read_bytes())["titles"] if titles is None else titles
    generated = []
    selectors = []
    for title in titles:
        install = root / "library/steamapps/common" / title["name"]
        for path, data in payloads(title):
            target = install / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        expected = fingerprint(title)
        appmanifest = root / "library/steamapps" / ("appmanifest_%s.acf" % title["appid"])
        appmanifest.write_bytes(manifest(title, expected))
        anchor = root / ("anchor-%s.json" % title["appid"])
        anchor.write_bytes(canonical(expected))
        selector_id = "synthetic.breadth." + title["appid"]
        selectors.append({
            "selector_id": selector_id, "storefront": "steam", "game_id": title["appid"],
            "store_build_id": title["buildid"], "aggregate_sha256": expected["aggregate_sha256"],
            "manifest_ids": {key: value["manifest"] for key, value in expected["depots"].items()},
            "image_hashes": {title["image"]: next(item["sha256"] for item in expected["files"]
                                                  if item["path"] == title["image"])},
            "artifact": {"kind": "fingerprint", "path": anchor.name,
                         "sha256": sha256(anchor.read_bytes())},
        })
        generated.append({"title": title, "install": install, "manifest": appmanifest,
                          "anchor": anchor, "expected": expected, "selector_id": selector_id})
    registry = root / "selectors.json"
    registry.write_bytes(canonical({"record": "alloy-store-identity-selector-registry",
                                    "version": 1, "author": "Timur Isaev",
                                    "selectors": selectors}))
    return generated, registry
