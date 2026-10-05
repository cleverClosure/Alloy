#!/usr/bin/env python3
"""One-command isolated build and immutable layer packaging. Author: Timur Isaev."""

import argparse
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--toolchain-archive", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.root.exists() or args.package.exists() or args.package.is_symlink():
        parser.exit(1, "FAIL: build and package destinations must not exist\n")
    try:
        subprocess.run([sys.executable, str(HERE / "build.py"), "build", "--source-repo", str(args.source_repo),
                        "--toolchain-archive", str(args.toolchain_archive), "--root", str(args.root),
                        "--jobs", str(args.jobs)], check=True)
        subprocess.run([sys.executable, str(HERE / "package.py"), "--build-root", str(args.root),
                        "--output", str(args.package)], check=True)
    except (OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"FAIL: {error}\n")
