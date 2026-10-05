#!/usr/bin/env python3
"""Build an isolated development runtime from reviewed pins. Author: Timur Isaev."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import time

from inputs import BuildError, canonical, digest, export_objects, tree_digest, verify_inputs

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def run(argv, cwd, env, log, timeout=7200):
    print("RUN", " ".join(map(str, argv)), flush=True)
    with log.open("ab") as stream:
        stream.write(("\nRUN " + " ".join(map(str, argv)) + "\n").encode())
        child = subprocess.Popen(list(map(str, argv)), cwd=cwd, env=env, stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
            if code:
                raise subprocess.CalledProcessError(code, argv)
        except BaseException:
            # Every build process belongs to this private process group.
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
            raise


def prepare(recipe, source_repo, archive, root):
    verify_inputs(recipe, source_repo, archive)
    if root.exists() or root.is_symlink():
        raise BuildError("build root must not exist; resuming partial builds is not supported")
    if shutil.disk_usage(root.parent).free < 14 * 1024**3:
        raise BuildError("at least 14 GiB free required")
    root.mkdir(mode=0o700)
    for name in ("sources", "build", "logs", "home", "tmp", "overlay", "bin"):
        (root / name).mkdir()
    (root / "recipe.json").write_bytes(canonical(recipe) + b"\n")
    with tarfile.open(archive) as bundle:
        bundle.extractall(root / "toolchain", filter="data")
    toolchain = root / "toolchain" / recipe["toolchain"]["directory"]
    for name, path in recipe["host"]["tools"].items():
        (root / "bin" / name).symlink_to(path)
    env = environment(recipe, root)
    for name, source in recipe["sources"].items():
        export_objects(source_repo / "third_party/src" / name, source["revision"],
                       root / "sources" / name, source["submodules"])
        for patch in source["patches"]:
            run(["git", "apply", "--check", REPO / patch], root / "sources" / name, env,
                root / "logs" / "prepare.log")
            run(["git", "apply", REPO / patch], root / "sources" / name, env,
                root / "logs" / "prepare.log")
    shutil.copyfile(toolchain / "generic-w64-mingw32/include/winnt.h", root / "overlay/winnt.h")
    run(["patch", "--batch", "--fuzz=0", "-p1", "-i", HERE / "overlays/winnt.patch"],
        root / "overlay", env, root / "logs/prepare.log")
    (root / "source-identities.json").write_bytes(canonical({
        name: tree_digest(root / "sources" / name) for name in recipe["sources"]
    }) + b"\n")
    return env, toolchain


def environment(recipe, root):
    toolchain = root / "toolchain" / recipe["toolchain"]["directory"]
    return {
        "PATH": f"{toolchain / 'bin'}:{root / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"),
        "LC_ALL": "C", "LANG": "C", "TZ": "UTC", "ZERO_AR_DATE": "1",
        "SOURCE_DATE_EPOCH": str(recipe["sourceDateEpoch"]), "PYTHONNOUSERSITE": "1",
        "DEVELOPER_DIR": recipe["host"]["developerDirectory"],
        "SDKROOT": recipe["host"]["sdk"], "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "PKG_CONFIG_LIBDIR": str(root / "empty-pkgconfig"),
        "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
    }


def build_wine(recipe, root, env, jobs):
    source = root / "sources/wine"
    build = root / "build/wine"
    build.mkdir(exist_ok=True)
    log = root / "logs/wine.log"
    run(["autoreconf", "-f"], source, env, log)
    flags = "-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -ffile-prefix-map=" + str(root) + "=/alloy-build"
    wine_env = dict(env, CFLAGS=flags, CXXFLAGS=flags, CROSSCFLAGS=flags)
    run([source / "configure", *recipe["wineArguments"],
         "--prefix=/alloy-runtime"], build, wine_env, log)
    run(["make", f"-j{jobs}"], build, wine_env, log)
    return build


def build_fex(recipe, root, env, jobs):
    source = root / "sources/fex"
    build = root / "build/fex"
    log = root / "logs/fex.log"
    flags = f"-O3 -DNDEBUG -I{root / 'overlay'} -DFEX_HOST_GUARD_PAGE_SIZE=16384 -ffile-prefix-map={root}=/alloy-build"
    run(["cmake", "-S", source, "-B", build, "-G", "Ninja",
         "-DCMAKE_TOOLCHAIN_FILE=" + str(source / "Data/CMake/toolchain_mingw.cmake"),
         *recipe["fexArguments"], "-DCMAKE_C_FLAGS=-ffixed-x18", "-DCMAKE_CXX_FLAGS=-ffixed-x18",
         "-DCMAKE_C_FLAGS_RELEASE=" + flags, "-DCMAKE_CXX_FLAGS_RELEASE=" + flags,
         "-DOVERRIDE_HASH=" + recipe["sources"]["fex"]["revision"],
         "-DOVERRIDE_VERSION=alloy-development"], root, env, log)
    run(["cmake", "--build", build, "--target", "arm64ecfex", "-j", str(jobs)], root, env, log)
    run(["/usr/bin/clang++", "-std=c++17", "-O2", "-dynamiclib",
         "-Wl,-install_name,@rpath/libarm64ecfex.so", HERE / "overlays/fex_unixlib_darwin.cpp",
         "-o", build / "Bin/libarm64ecfex.so"], root, env, log)


def build_dxmt(recipe, root, env, jobs):
    source = root / "sources/dxmt"
    build = root / "build/dxmt"
    flags = ["-ffixed-x18", "-I" + str(root / "overlay"), f"-ffile-prefix-map={root}=/alloy-build"]
    cross = root / "dxmt-cross.ini"
    cross.write_text("[binaries]\n" + "\n".join(
        f"{key} = 'arm64ec-w64-mingw32-{value}'" for key, value in
        {"c": "clang", "cpp": "clang++", "ar": "ar", "strip": "strip", "windres": "windres"}.items()) +
        "\n[built-in options]\nc_args = " + repr(flags) + "\ncpp_args = " + repr(flags) +
        "\n[properties]\nneeds_exe_wrapper = true\n[host_machine]\nsystem = 'windows'\n"
        "cpu_family = 'aarch64'\ncpu = 'aarch64'\nendian = 'little'\n")
    log = root / "logs/dxmt.log"
    run(["meson", "setup", build, source, "--cross-file", cross, *recipe["dxmtArguments"],
         "-Dwine_build_path=" + str(root / "build/wine"),
         "-Dnative_llvm_path=" + recipe["host"]["nativeLLVM"]], root, env, log)
    run(["meson", "compile", "-C", build, "-j", str(jobs)], root, env, log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify-inputs", "build"))
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--toolchain-archive", type=Path, required=True)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    recipe = json.loads((HERE / "pins.json").read_text())
    if args.command == "verify-inputs":
        verify_inputs(recipe, args.source_repo.resolve(), args.toolchain_archive.resolve())
        print("PASS: all pinned inputs verified")
        return
    if args.root is None or not 1 <= args.jobs <= 8:
        raise BuildError("build requires --root and --jobs between 1 and 8")
    root = args.root.absolute()
    if root != root.resolve() or root.is_relative_to(args.source_repo.resolve() / "third_party"):
        raise BuildError("build root must be a canonical isolated path")
    start = time.monotonic()
    env, toolchain = prepare(recipe, args.source_repo.resolve(), args.toolchain_archive.resolve(), root)
    build_wine(recipe, root, env, args.jobs)
    build_fex(recipe, root, env, args.jobs)
    build_dxmt(recipe, root, env, args.jobs)
    report = {"schemaVersion": 1, "author": "Timur Isaev", "status": "built",
              "recipeDigest": hashlib.sha256(canonical(recipe)).hexdigest(),
              "seconds": round(time.monotonic() - start, 3), "root": str(root)}
    (root / "build-result.json").write_bytes(canonical(report) + b"\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (BuildError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
