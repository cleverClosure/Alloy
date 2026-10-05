#!/usr/bin/env python3
"""Stage runtime-only artifacts and emit immutable layers. Author: Timur Isaev."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from inputs import BuildError, canonical, digest
from layers import write_layer

HERE = Path(__file__).resolve().parent
CODEC_EXCLUSIONS = {"winedmo.so", "winegstreamer.so"}


def copy(source, destination):
    if not source.is_file():
        raise BuildError(f"missing build product: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)


def stage(root, work):
    wine = work / "wine-runtime"
    wine.mkdir(parents=True)
    build = root / "build/wine"
    selected = {"loader/wine", "server/wineserver", "loader/wine.inf"}
    for path in sorted(build.rglob("*")):
        relative = path.relative_to(build).as_posix()
        if not path.is_file() or "tests" in path.parts or path.name in CODEC_EXCLUSIONS:
            continue
        if relative in selected or path.suffix.lower() in {".dll", ".exe", ".so", ".ttf", ".fon", ".winmd"}:
            if not path.resolve().is_relative_to(root.resolve()):
                raise BuildError("build product links outside isolated root")
            copy(path, wine / relative)
    # Wine keeps immutable locale data in its source tree, not its build outputs.
    for path in sorted((root / "sources/wine/nls").iterdir()):
        if path.suffix in {".nls", ".dat"}:
            copy(path, wine / "nls" / path.name)
    for name in selected:
        if not (wine / name).is_file():
            raise BuildError(f"missing staged Wine runtime file: {name}")
    (wine / "CODEC-EXCLUSIONS.txt").write_text(
        "Author: Timur Isaev\nDevelopment generation.\n"
        "Omitted winedmo.so and winegstreamer.so, matching codec-clean/stage-runtime.sh.\n")
    cpu = work / "cpu-provider"
    copy(root / "build/fex/Bin/libarm64ecfex.dll",
         cpu / "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll")
    copy(root / "build/fex/Bin/libarm64ecfex.so", cpu / "dlls/libarm64ecfex/libarm64ecfex.so")
    gfx = work / "graphics-provider"
    for path in sorted((root / "build/dxmt/src").rglob("*.dll")):
        copy(path, gfx / "providers/x86_64-windows" / path.name)
    copy(root / "build/dxmt/src/winemetal/unix/winemetal.so", gfx / "providers/aarch64-unix/winemetal.so")
    for module, name in (("ntdll", "ntdll"), ("winemac.drv", "winemac"), ("win32u", "win32u")):
        (gfx / "providers/aarch64-unix" / (name + ".so")).symlink_to(f"../../dlls/{module}/{name}.so")
    for name in ("d3d11.dll", "dxgi.dll", "winemetal.dll"):
        if not (gfx / "providers/x86_64-windows" / name).is_file():
            raise BuildError("missing DXMT runtime component")
    return {"wine-runtime": wine, "cpu-provider": cpu, "graphics-provider": gfx}


def package(root, output):
    if output.exists():
        raise BuildError("package output must not exist")
    if not (root / "build-result.json").is_file():
        raise BuildError("build has no successful completion record")
    recipe = json.loads((root / "recipe.json").read_text())
    result = json.loads((root / "build-result.json").read_text())
    if result.get("status") != "built" or result.get("recipeDigest") != hashlib.sha256(canonical(recipe)).hexdigest():
        raise BuildError("build completion record does not match recipe")
    output.mkdir(mode=0o700)
    stages = stage(root, output / ".staging")
    packaged_recipe = {**recipe, "packagingFiles": {
        name: digest(HERE / name) for name in ("package.py", "layers.py", "build-generation.py")}}
    recipe_bytes = canonical(packaged_recipe)
    recipe_digest = "sha256:" + hashlib.sha256(recipe_bytes).hexdigest()
    (output / "build-recipe.json").write_bytes(recipe_bytes)
    components = []
    sources = {"wine-runtime": "wine", "cpu-provider": "fex", "graphics-provider": "dxmt"}
    for role, tree in stages.items():
        components.append(write_layer(tree, output / (role + ".layer.tar.zst"), role=role,
                                      revision=recipe["sources"][sources[role]]["revision"],
                                      recipe_digest=recipe_digest))
    timestamp = datetime.fromtimestamp(recipe["sourceDateEpoch"], timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sbom = {"spdxVersion": "SPDX-2.3", "SPDXID": "SPDXRef-DOCUMENT", "name": "Alloy development runtime",
            "dataLicense": "CC0-1.0", "documentNamespace": "https://example.invalid/alloy/" + recipe_digest[7:],
            "creationInfo": {"created": timestamp, "creators": ["Person: Timur Isaev"]},
            "packages": [{"SPDXID": "SPDXRef-" + c["name"], "name": c["name"],
                          "versionInfo": c["sourceRevision"], "downloadLocation": "NOASSERTION",
                          "filesAnalyzed": False, "licenseConcluded": "NOASSERTION",
                          "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION",
                          "checksums": [{"algorithm": "SHA256", "checksumValue": c["digest"][7:]}]}
                         for c in components]}
    (output / "sbom.json").write_bytes(canonical(sbom))
    sbom_digest = "sha256:" + digest(output / "sbom.json")
    for component in components:
        component["sbomDigest"] = sbom_digest
    source_digest = "sha256:" + hashlib.sha256(canonical(recipe["sources"])).hexdigest()
    provenance = {"author": "Timur Isaev", "kind": "unsigned-development-build",
                  "sourceDigest": source_digest, "buildRecipeDigest": recipe_digest,
                  "components": components, "scope": "Local development; no release attestation or signing identity."}
    (output / "provenance.json").write_bytes(canonical(provenance))
    generation = "rtg_" + hashlib.sha256(canonical(components)).hexdigest()
    manifest = {"schemaVersion": "1.0", "generationId": generation, "createdAt": timestamp,
                "components": components, "hostRequirements": {"architecture": "arm64", "minimumMacOS": "27.0"},
                "provenance": {"builderId": "Timur Isaev", "sourceDigest": source_digest,
                               "buildRecipeDigest": recipe_digest,
                               "attestationDigest": "sha256:" + digest(output / "provenance.json"),
                               "reproducible": False}, "activation": {"releaseRing": "development"}}
    (output / "runtime-manifest.json").write_bytes(canonical(manifest))
    shutil.rmtree(output / ".staging")
    for file in output.iterdir():
        file.chmod(0o444)
    output.chmod(0o555)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(package(args.build_root.resolve(), args.output.absolute()), indent=2))
    except (BuildError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"FAIL: {error}\n")
