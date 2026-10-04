#!/usr/bin/env bash
# Synthetic multi-title scanner, detector, selector and CLI proof.
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
export SWIFT_MODULECACHE_PATH="$PACKAGE_ROOT/.build/breadth-module-cache"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULECACHE_PATH"
export PYTHONDONTWRITEBYTECODE=1

exec python3 "$PACKAGE_ROOT/Tests/Breadth/proof.py" "$@"
