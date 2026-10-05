#!/usr/bin/env python3
"""Plant real source and toolchain mutations in private scratch. Author: Timur Isaev."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from build import environment
from inputs import BuildError, canonical, digest
from layers import write_layer
from reproduce import compare_trees

HERE = Path(__file__).resolve().parent


def prove(args):
    recipe = json.loads((HERE / "pins.json").read_text())
    env = environment(recipe, args.build_root)
    with tempfile.TemporaryDirectory(prefix="alloy-mutations-") as temporary:
        scratch = Path(temporary).resolve()
        original = (HERE / "overlays/fex_unixlib_darwin.cpp").read_bytes()
        changed = original.replace(b"0xc00000bbU", b"0xc00000baU")
        if len(original) != len(changed) or sum(a != b for a, b in zip(original, changed)) != 1:
            raise BuildError("source mutation is not exactly one byte")
        trees, products = [], []
        for name, source in (("original", original), ("mutation", changed)):
            root = scratch / name
            root.mkdir()
            cpp = root / "bridge.cpp"
            cpp.write_bytes(source)
            tree = root / "cpu"
            tree.mkdir()
            binary = tree / "libarm64ecfex.so"
            subprocess.run(["/usr/bin/clang++", "-std=c++17", "-O2", "-dynamiclib",
                            "-Wl,-install_name,@rpath/libarm64ecfex.so", str(cpp), "-o", str(binary)],
                           env=env, check=True, timeout=120)
            archive = root / "cpu.layer.tar.zst"
            layer = write_layer(tree, archive, role="cpu-provider", revision=recipe["sources"]["fex"]["revision"],
                                recipe_digest="sha256:" + hashlib.sha256(canonical(recipe)).hexdigest())
            products.append({"sourceSHA256": hashlib.sha256(source).hexdigest(),
                             "binarySHA256": digest(binary), "layerDigest": layer["digest"]})
            trees.append({"cpu-provider": tree})
        if any(products[0][key] == products[1][key] for key in products[0]):
            raise BuildError("source mutation did not change all required identities")
        try:
            compare_trees(*trees, (scratch / "original", scratch / "mutation"), [])
        except BuildError as error:
            if "unlisted" not in str(error):
                raise
        else:
            raise BuildError("reproducibility gate accepted a changed runtime")
        bad_archive = scratch / "unpinned.tar.xz"
        shutil.copyfile(args.toolchain_archive, bad_archive)
        with bad_archive.open("r+b") as file:
            byte = file.read(1)
            file.seek(0)
            file.write(bytes([byte[0] ^ 1]))
        refused = subprocess.run([recipe["host"]["tools"]["python3"], str(HERE / "build.py"), "build",
                                  "--source-repo", str(args.source_repo), "--toolchain-archive", str(bad_archive),
                                  "--root", str(scratch / "must-not-exist")],
                                 env=env, text=True, capture_output=True, timeout=120)
        if (refused.returncode == 0 or "input digest mismatch" not in refused.stderr
                or (scratch / "must-not-exist").exists()):
            raise BuildError("unpinned toolchain control failed: " + refused.stderr[-1000:])
        return {"author": "Timur Isaev", "oneByteSourceChange": products,
                "sourceDifferenceRejected": True, "unpinnedToolchainRejectedBeforeBuild": True,
                "toolchainExit": refused.returncode}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--toolchain-archive", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prove(args)
        args.report.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    except (BuildError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"FAIL: {error}\n")
