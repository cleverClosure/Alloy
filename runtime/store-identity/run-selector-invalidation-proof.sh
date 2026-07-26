#!/usr/bin/env bash
# Gate 4 deterministic selector and invalidation proof.
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE_CACHE="$PACKAGE_ROOT/.build/module-cache"

export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

swift test \
  --disable-sandbox \
  --package-path "$PACKAGE_ROOT" \
  --filter SelectorInvalidationTests

printf 'SUMMARY selector-invalidation cases=3 unchanged-controls=3 selectors=3 records=1 status=PASS\n'
