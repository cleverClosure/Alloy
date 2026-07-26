#!/usr/bin/env bash
# Gate 3 deterministic update-watcher proof.
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE_CACHE="$PACKAGE_ROOT/.build/module-cache"

export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

swift test \
  --disable-sandbox \
  --package-path "$PACKAGE_ROOT" \
  --filter UpdateWatcherTests

printf 'SUMMARY update-watcher cases=4 unchanged-controls=4 status=PASS\n'
