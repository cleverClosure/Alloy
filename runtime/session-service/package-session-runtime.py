#!/usr/bin/env python3
"""Build unsigned synthetic session guests and provider layers. Author: Timur Isaev."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tools/runtime-build"))
from inputs import BuildError, canonical, digest  # noqa: E402
from layers import MEDIA, write_layer  # noqa: E402

SAVE = b"Alloy session service save proof v1\n"
ROLES = (("launcher", "aarch64", 0), ("game", "x86_64", 1), ("unknown", "aarch64", 0))
FLAGS = ["-O2", "-nostdlib", "-ffreestanding", "-fno-stack-protector", "-Wl,--no-insert-timestamp"]
METADATA = ("runtime-manifest.json", "build-recipe.json", "provenance.json", "sbom.json")


def sha(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def load(path):
    data = path.read_bytes()
    value = json.loads(data)
    if canonical(value) != data:
        raise BuildError(f"noncanonical package metadata: {path.name}")
    return value


class RawLayer(io.RawIOBase):
    """Read the pinned layer writer's raw Zstandard profile without third-party codecs."""

    def __init__(self, source):
        self.source = source
        header = source.read(9)
        if len(header) != 9 or header[:5] != b"\x28\xb5\x2f\xfd\xa0":
            raise BuildError("expected raw-zstd-v1 layer")
        self.pending = b""
        self.last = False

    def readable(self):
        return True

    def readinto(self, destination):
        if not self.pending and not self.last:
            header = self.source.read(3)
            if len(header) != 3:
                raise BuildError("truncated raw Zstandard block")
            value = int.from_bytes(header, "little")
            self.last = bool(value & 1)
            size = value >> 3
            if value & 6 or size > 131072:
                raise BuildError("unsupported raw Zstandard block")
            self.pending = self.source.read(size)
            if len(self.pending) != size:
                raise BuildError("truncated raw Zstandard content")
        count = min(len(destination), len(self.pending))
        destination[:count] = self.pending[:count]
        self.pending = self.pending[count:]
        return count


def layer_metadata(path):
    with path.open("rb") as source, io.BufferedReader(RawLayer(source)) as decoded:
        with tarfile.open(fileobj=decoded, mode="r|") as archive:
            values = []
            for expected, bound in (("layer.json", 65536), ("metadata/file-table.cbor", 16 * 1024 * 1024)):
                member = archive.next()
                if member is None or member.name != expected or not member.isfile() or member.size > bound:
                    raise BuildError("unexpected canonical layer metadata")
                values.append(archive.extractfile(member).read())
            manifest = json.loads(values[0])
            if canonical(manifest) != values[0] or manifest["fileTreeDigest"] != sha(values[1]):
                raise BuildError("layer metadata digest mismatch")
            return manifest


def verify_component(package, component, recipe_digest):
    name = component["name"]
    if name not in {"wine-runtime", "cpu-provider", "graphics-provider"}:
        raise BuildError("unexpected layer role")
    path = package / (name + ".layer.tar.zst")
    if (component["digest"] != "sha256:" + digest(path) or component["size"] != path.stat().st_size
            or component["mediaType"] != MEDIA):
        raise BuildError("component archive digest mismatch")
    layer = layer_metadata(path)
    if (layer["buildRecipeDigest"] != recipe_digest or layer["sourceRevision"] != component["sourceRevision"]
            or layer["allowedCompositionRoles"] != [name] or layer["name"] != name):
        raise BuildError("layer recipe or source lineage mismatch")


def verify_metadata(package):
    values = {name: load(package / name) for name in METADATA}
    manifest = values["runtime-manifest.json"]
    provenance = values["provenance.json"]
    for field, name in (("buildRecipeDigest", "build-recipe.json"), ("attestationDigest", "provenance.json")):
        if manifest["provenance"][field] != "sha256:" + digest(package / name):
            raise BuildError("package metadata digest mismatch")
    if (manifest["activation"]["releaseRing"] != "development"
            or provenance["kind"] != "unsigned-development-build"
            or provenance["components"] != manifest["components"]
            or provenance["sourceDigest"] != manifest["provenance"]["sourceDigest"]
            or provenance["buildRecipeDigest"] != manifest["provenance"]["buildRecipeDigest"]):
        raise BuildError("expected unsigned development package with exact component lineage")
    if {row["name"] for row in manifest["components"]} != {"wine-runtime", "cpu-provider", "graphics-provider"}:
        raise BuildError("expected exactly three runtime component roles")
    if len(manifest["components"]) != 3:
        raise BuildError("duplicate component role")
    sbom = "sha256:" + digest(package / "sbom.json")
    entries = values["sbom.json"]["packages"]
    if len(entries) != len(manifest["components"]):
        raise BuildError("SBOM component count mismatch")
    for row in manifest["components"]:
        if row["sbomDigest"] != sbom:
            raise BuildError("component SBOM digest mismatch")
        matching = [entry for entry in entries if entry["name"] == row["name"]]
        if (len(matching) != 1 or matching[0]["versionInfo"] != row["sourceRevision"]
                or matching[0]["checksums"] != [{"algorithm": "SHA256", "checksumValue": row["digest"][7:]}]):
            raise BuildError("SBOM component identity mismatch")
    if manifest["generationId"] != "rtg_" + sha(canonical(manifest["components"]))[7:]:
        raise BuildError("generation identity differs from component composition")
    return values


def compile_guests(toolchain, stage, payload, variant):
    provider_root = stage / "providers"
    for role, triple, fex in ROLES:
        compiler = toolchain / (triple + "-w64-mingw32-clang")
        target = provider_root / role
        target.mkdir(parents=True)
        definitions = ['-DROLE_NAME="' + role + '"', "-DEXPECT_FEX=" + str(fex)]
        with tempfile.TemporaryDirectory(prefix="alloy-session-link-") as link_directory:
            library = Path(link_directory) / "provider.a"
            subprocess.run([str(compiler), *FLAGS, *definitions, '-DRUNTIME_VARIANT="' + variant + '"',
                            "-shared", str(HERE / "guest-session/provider.c"), "-lkernel32",
                            "-Wl,--entry,DllMainCRTStartup", "-Wl,--out-implib," + str(library),
                            "-o", str(target / "alloygraphics.dll")], check=True, timeout=60)
            extra = {"launcher": ['-DCHILD_NAME="game"'],
                     "game": ['-DCHILD_NAME="unknown"', "-DWRITE_SAVE"],
                     "unknown": ["-DPROBE_RESTRICTION"]}[role]
            subprocess.run([str(compiler), *FLAGS, *definitions, *extra,
                            str(HERE / "guest-session/guest.c"), str(library), "-lkernel32",
                            "-Wl,--entry,entry", "-Wl,--subsystem,console",
                            "-o", str(payload / (role + ".exe"))], check=True, timeout=60)
        (payload / ("cwd-" + role)).mkdir(mode=0o700)
    # This real DLL makes a successful LoadLibrary positive control possible.
    # The unknown guest's disabled route must refuse these otherwise loadable bytes.
    subprocess.run([str(toolchain / "aarch64-w64-mingw32-clang"), *FLAGS, "-shared",
                    str(HERE / "guest-session/blocked.c"), "-lkernel32", "-Wl,--entry,DllMainCRTStartup",
                    "-o", str(payload / "alloyblocked.dll")], check=True, timeout=60)


def recipe_for(base, values, toolchain, variant):
    inputs = [HERE / "package-session-runtime.py", REPO / "tools/runtime-build/layers.py",
              REPO / "tools/runtime-build/inputs.py", *sorted((HERE / "guest-session").glob("*.[ch]"))]
    files = {str(path.relative_to(REPO)): "sha256:" + digest(path) for path in inputs}
    compilers = {}
    for triple in ("aarch64", "x86_64"):
        compiler = toolchain / (triple + "-w64-mingw32-clang")
        version = subprocess.check_output([str(compiler), "--version"], text=True, timeout=10).splitlines()[0]
        compilers[triple] = {"sha256": "sha256:" + digest(compiler), "version": version}
    parent = values["runtime-manifest.json"]
    inherited = [row for row in parent["components"] if row["name"] != "graphics-provider"]
    return {"schemaVersion": "alloy-synthetic-session-package-v1", "author": "Timur Isaev",
            "syntheticOnly": True, "variant": variant, "files": files, "compilers": compilers,
            "compileFlags": FLAGS, "roles": [list(role) for role in ROLES],
            "sourceDateEpoch": values["build-recipe.json"]["sourceDateEpoch"],
            "base": {"generationId": parent["generationId"],
                     "metadata": {name: "sha256:" + digest(base / name) for name in METADATA},
                     "inheritedComponents": inherited,
                     "inheritedLayerRecipeDigest": parent["provenance"]["buildRecipeDigest"]}}


def finish_package(output, stage, base_values, recipe):
    recipe_digest = sha(canonical(recipe))
    (output / "build-recipe.json").write_bytes(canonical(recipe))
    source_digest = sha(canonical(recipe["files"]))
    components = [dict(row) for row in recipe["base"]["inheritedComponents"]]
    components.append(write_layer(stage, output / "graphics-provider.layer.tar.zst", role="graphics-provider",
                                  revision=source_digest, recipe_digest=recipe_digest))
    timestamp = base_values["runtime-manifest.json"]["createdAt"]
    sbom = {"spdxVersion": "SPDX-2.3", "SPDXID": "SPDXRef-DOCUMENT",
            "name": "Alloy synthetic session development runtime", "dataLicense": "CC0-1.0",
            "documentNamespace": "https://example.invalid/alloy/session/" + recipe_digest[7:],
            "creationInfo": {"created": timestamp, "creators": ["Person: Timur Isaev"]},
            "packages": [{"SPDXID": "SPDXRef-" + row["name"], "name": row["name"],
                          "versionInfo": row["sourceRevision"], "downloadLocation": "NOASSERTION",
                          "filesAnalyzed": False, "licenseConcluded": "NOASSERTION",
                          "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION",
                          "checksums": [{"algorithm": "SHA256", "checksumValue": row["digest"][7:]}]}
                         for row in components]}
    (output / "sbom.json").write_bytes(canonical(sbom))
    for row in components:
        row["sbomDigest"] = sha(canonical(sbom))
    provenance = {"author": "Timur Isaev", "kind": "unsigned-development-build", "sourceDigest": source_digest,
                  "buildRecipeDigest": recipe_digest, "components": components, "base": recipe["base"],
                  "scope": "Synthetic session proof only. Inherited Wine/CPU archives retain their original recipe; "
                           "graphics contains marker DLLs, not a renderer. No release or reproducibility claim."}
    (output / "provenance.json").write_bytes(canonical(provenance))
    manifest = {"schemaVersion": "1.0", "generationId": "rtg_" + sha(canonical(components))[7:],
                "createdAt": timestamp, "components": components,
                "hostRequirements": base_values["runtime-manifest.json"]["hostRequirements"],
                "provenance": {"builderId": "Timur Isaev", "sourceDigest": source_digest,
                               "buildRecipeDigest": recipe_digest, "attestationDigest": sha(canonical(provenance)),
                               "reproducible": False}, "activation": {"releaseRing": "development"}}
    (output / "runtime-manifest.json").write_bytes(canonical(manifest))
    return manifest


def audit(package):
    values = verify_metadata(package)
    recipe = values["build-recipe.json"]
    if recipe["schemaVersion"] != "alloy-synthetic-session-package-v1" or recipe["syntheticOnly"] is not True:
        raise BuildError("expected synthetic session composition recipe")
    base = verify_metadata(package / "lineage")
    parent = base["runtime-manifest.json"]
    if set(recipe["base"]["metadata"]) != set(METADATA):
        raise BuildError("base metadata inventory differs")
    if sha(canonical(recipe["files"])) != values["provenance.json"]["sourceDigest"]:
        raise BuildError("synthetic source identity differs from its recipe")
    for name, expected in recipe["base"]["metadata"].items():
        if name not in METADATA or expected != "sha256:" + digest(package / "lineage" / name):
            raise BuildError("base package metadata lineage mismatch")
    expected_inherited = [row for row in parent["components"] if row["name"] != "graphics-provider"]
    if (recipe["base"]["inheritedComponents"] != expected_inherited
            or recipe["base"]["generationId"] != parent["generationId"]
            or recipe["base"]["inheritedLayerRecipeDigest"] != parent["provenance"]["buildRecipeDigest"]
            or values["provenance.json"]["base"] != recipe["base"]):
        raise BuildError("inherited component lineage mismatch")
    for row in values["runtime-manifest.json"]["components"]:
        inherited = row["name"] != "graphics-provider"
        if inherited:
            original = next(item for item in expected_inherited if item["name"] == row["name"])
            if {key: value for key, value in row.items() if key != "sbomDigest"} != {
                    key: value for key, value in original.items() if key != "sbomDigest"}:
                raise BuildError("inherited archive descriptor changed")
        recipe_digest = (parent if inherited else values["runtime-manifest.json"])["provenance"]["buildRecipeDigest"]
        verify_component(package, row, recipe_digest)
    return values["runtime-manifest.json"]


def package(args):
    if args.output.exists() or args.payload_output.exists():
        raise BuildError("package and payload outputs must not exist")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args.variant):
        raise BuildError("variant must be a short lowercase identifier")
    base, output, payload = (path.resolve() for path in (args.base_package, args.output, args.payload_output))
    if (output.is_relative_to(base) or payload.is_relative_to(base)
            or output.is_relative_to(payload) or payload.is_relative_to(output)):
        raise BuildError("base, package and payload roots must be disjoint")
    values = verify_metadata(args.base_package)
    for component in values["runtime-manifest.json"]["components"]:
        verify_component(args.base_package, component,
                         values["runtime-manifest.json"]["provenance"]["buildRecipeDigest"])
    recipe = recipe_for(args.base_package, values, args.toolchain, args.variant)
    args.output.mkdir(mode=0o700)
    args.payload_output.mkdir(mode=0o700)
    lineage = args.output / "lineage"
    lineage.mkdir(mode=0o700)
    for name in METADATA:
        shutil.copyfile(args.base_package / name, lineage / name)
    for component in recipe["base"]["inheritedComponents"]:
        name = component["name"] + ".layer.tar.zst"
        shutil.copyfile(args.base_package / name, args.output / name)
    with tempfile.TemporaryDirectory(prefix="alloy-session-providers-") as staging:
        compile_guests(args.toolchain, Path(staging), args.payload_output, args.variant)
        manifest = finish_package(args.output, Path(staging), values, recipe)
    audit(args.output)
    for path in args.output.rglob("*"):
        path.chmod(0o555 if path.is_dir() else 0o444)
    args.output.chmod(0o555)
    return {"author": "Timur Isaev", "kind": "unsigned-synthetic-development", "variant": args.variant,
            "package": str(args.output), "payload": str(args.payload_output),
            "generationId": manifest["generationId"], "baseGenerationId": recipe["base"]["generationId"],
            "guestSHA256": {role: digest(args.payload_output / (role + ".exe")) for role, _, _ in ROLES},
            "blockedDLLSHA256": digest(args.payload_output / "alloyblocked.dll"),
            "providerDirectories": {role: "C:\\alloy\\providers\\" + role for role, _, _ in ROLES},
            "saveSHA256": hashlib.sha256(SAVE).hexdigest(), "components": manifest["components"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "This helper compiles synthetic PE guests; it does not execute Wine. Both output directories must be absent. "
        "Copy verified Wine/CPU layer archives unchanged, replace graphics with marker DLLs, and retain base metadata "
        "under lineage/. Different --variant values produce distinct immutable generations for rollback proofs. "
        "The payload's G:\\allow-blocked and G:\\ignore-stop markers select restriction-positive and stop-escalation controls."))
    parser.add_argument("--base-package", type=Path, help="verified unsigned development runtime package")
    parser.add_argument("--toolchain", type=Path, help="pinned llvm-mingw bin directory")
    parser.add_argument("--output", type=Path, help="new immutable synthetic runtime package directory")
    parser.add_argument("--payload-output", type=Path, help="new guest payload directory")
    parser.add_argument("--variant", default="one", help="provider build marker; default: one")
    parser.add_argument("--audit", type=Path, help="audit an existing synthetic package instead of building")
    args = parser.parse_args()
    try:
        if args.audit:
            print(json.dumps({"status": "pass", "manifest": audit(args.audit)}, sort_keys=True))
        else:
            if any(getattr(args, name) is None for name in ("base_package", "toolchain", "output", "payload_output")):
                parser.error("building requires --base-package, --toolchain, --output and --payload-output")
            print(json.dumps(package(args), sort_keys=True))
    except (BuildError, OSError, ValueError, KeyError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, f"FAIL: {error}\n")
