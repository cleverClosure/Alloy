#!/usr/bin/env bash
# Seeded adversarial content-store stress matrix
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
STRESS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/alloy-content-store-stress.XXXXXX")"
SWIFT_CACHE="$PACKAGE_ROOT/.build/module-cache"
SEEDS=(85 740085 12648430 20260726)
STEPS=48

cleanup() {
  chmod -R u+w "$STRESS_TMP" 2>/dev/null || true
  rm -rf "$STRESS_TMP"
}
trap cleanup EXIT

export SWIFT_MODULECACHE_PATH="$SWIFT_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE"

swift build --disable-sandbox --package-path "$PACKAGE_ROOT"
HARNESS="$PACKAGE_ROOT/.build/debug/alloy-content-store-stress-harness"

for seed in "${SEEDS[@]}"; do
  "$HARNESS" run "$STRESS_TMP/seed-$seed" "$seed" "$STEPS"
done

printf 'SUMMARY seeds=%s steps_per_seed=%d total_steps=%d\n' \
  "${SEEDS[*]}" "$STEPS" "$((${#SEEDS[@]} * STEPS))"
