#!/usr/bin/env python3
"""Independent schema and digest audit (requires jsonschema). Author: Timur Isaev."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile

from jsonschema import Draft202012Validator, FormatChecker

from inputs import BuildError, digest
from test_layers import decode_raw


def require(condition):
    if not condition:
        raise BuildError("package digest linkage mismatch")


def validate(package):
    repo = Path(__file__).resolve().parents[2]
    manifest = json.loads((package / "runtime-manifest.json").read_text())
    schema = json.loads((repo / "docs/schemas/runtime-manifest.schema.json").read_text())
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(manifest)
    layer_schema = json.loads((repo / "runtime/content-store/Specs/layer-manifest.v1.schema.json").read_text())
    for component in manifest["components"]:
        path = package / (component["name"] + ".layer.tar.zst")
        require(component["size"] == path.stat().st_size)
        require(component["digest"] == "sha256:" + digest(path))
        require(component["sbomDigest"] == "sha256:" + digest(package / "sbom.json"))
        with tarfile.open(fileobj=io.BytesIO(decode_raw(path.read_bytes()))) as archive:
            layer = json.load(archive.extractfile("layer.json"))
            Draft202012Validator(layer_schema).validate(layer)
            table = archive.extractfile("metadata/file-table.cbor").read()
            require(layer["fileTreeDigest"] == "sha256:" + hashlib.sha256(table).hexdigest())
            require(layer["sourceRevision"] == component["sourceRevision"])
            require(layer["buildRecipeDigest"] == manifest["provenance"]["buildRecipeDigest"])
    for field, file in (("buildRecipeDigest", "build-recipe.json"), ("attestationDigest", "provenance.json")):
        require(manifest["provenance"][field] == "sha256:" + digest(package / file))
    print("PASS runtime/layer schemas and package digest links")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    validate(parser.parse_args().package)
