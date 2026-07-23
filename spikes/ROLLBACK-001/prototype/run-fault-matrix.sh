#!/usr/bin/env bash
# ROLLBACK-001 real process-death fault matrix
# Author: Timur Isaev
set -euo pipefail

PROTOTYPE_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/alloy-rollback-matrix.XXXXXX")"
SWIFT_CACHE="$PROTOTYPE_ROOT/.build/module-cache"

cleanup() {
  chmod -R u+w "$PROBE_TMP" 2>/dev/null || true
  rm -rf "$PROBE_TMP"
}
trap cleanup EXIT

export SWIFT_MODULECACHE_PATH="$SWIFT_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE"

swift build --disable-sandbox --package-path "$PROTOTYPE_ROOT"
PROBE="$PROTOTYPE_ROOT/.build/debug/alloy-rollback-probe"

FAULT_POINTS=(
  after-download-action
  after-download
  after-verify-action
  after-verify
  after-publish-cas-action
  after-publish-cas
  after-materialize-action
  after-materialize
  after-prepare-candidate-action
  after-prepare-candidate
  after-record-rollback-action
  after-record-rollback
  after-switch-active-action
  after-switch-active
  after-health-window-action
  after-health-window
  after-retain-collect-action
  after-retain-collect
)

START_SECONDS=$SECONDS
for fault_point in "${FAULT_POINTS[@]}"; do
  case_root="$PROBE_TMP/$fault_point"
  "$PROBE" bootstrap "$case_root" game generation-a payload-a save-v1

  set +e
  ALLOY_FAULT_AFTER="$fault_point" \
    "$PROBE" update "$case_root" game generation-b payload-b pass
  status=$?
  set -e

  if [[ $status -ne 97 ]]; then
    printf 'FAIL %-38s expected exit 97, got %d\n' "$fault_point" "$status" >&2
    exit 1
  fi

  "$PROBE" recover "$case_root"
  "$PROBE" recover "$case_root"
  "$PROBE" verify "$case_root" game generation-b save-v1
  printf 'PASS %s\n' "$fault_point"
done

failed_health_root="$PROBE_TMP/failed-health"
"$PROBE" bootstrap "$failed_health_root" game generation-a payload-a save-v1
"$PROBE" update "$failed_health_root" game generation-b payload-b fail
"$PROBE" verify "$failed_health_root" game generation-a save-v1
printf 'PASS failed-health-rollback\n'

printf 'SUMMARY cases=%d elapsed_seconds=%d\n' \
  "$((${#FAULT_POINTS[@]} + 1))" "$((SECONDS - START_SECONDS))"
