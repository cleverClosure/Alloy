#!/usr/bin/env bash
# Production content-store process-death fault matrix
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/alloy-content-store-matrix.XXXXXX")"
SWIFT_CACHE="$PACKAGE_ROOT/.build/module-cache"
TRANSPORT_SERVER_PID=

cleanup() {
  if [[ -n $TRANSPORT_SERVER_PID ]]; then
    kill "$TRANSPORT_SERVER_PID" 2>/dev/null || true
    wait "$TRANSPORT_SERVER_PID" 2>/dev/null || true
  fi
  chmod -R u+w "$PROBE_TMP" 2>/dev/null || true
  rm -rf "$PROBE_TMP"
}
trap cleanup EXIT

export SWIFT_MODULECACHE_PATH="$SWIFT_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE"

swift build --disable-sandbox --package-path "$PACKAGE_ROOT"
PROBE="$PACKAGE_ROOT/.build/debug/alloy-content-store-fault-probe"

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
  after-gc-mark
  after-gc-generation-sweep-item
  after-gc-generation-sweep
  after-gc-object-sweep-item
  after-gc-object-sweep
  after-gc-download-sweep-item
  after-gc-download-sweep
  after-gc-quarantine-sweep-item
  after-gc-quarantine-sweep
  after-transport-stream-chunk
  before-transport-verification
  after-transport-verification
  before-transport-publication
  after-transport-publication
  before-catalog-maintenance
  after-catalog-reconcile
  after-catalog-commit
)

transport_server_url_file="$PROBE_TMP/transport-server.url"
python3 "$PACKAGE_ROOT/Tests/Fixtures/transport_range_server.py" \
  >"$transport_server_url_file" &
TRANSPORT_SERVER_PID=$!
# Up to 10 seconds, the same bound the other two matrices use. The fixture
# starts in milliseconds now that it no longer resolves its own host name; see
# TransportServer.server_bind in transport_range_server.py for what made it
# take 35 seconds on a hosted runner. A fixture that dies is caught at once by
# the liveness check below.
for _ in {1..1000}; do
  if [[ -s $transport_server_url_file ]]; then
    break
  fi
  if ! kill -0 "$TRANSPORT_SERVER_PID" 2>/dev/null; then
    printf 'FAIL transport fixture exited during startup\n' >&2
    exit 1
  fi
  sleep 0.01
done
if [[ ! -s $transport_server_url_file ]]; then
  printf 'FAIL transport fixture did not publish its address\n' >&2
  exit 1
fi
read -r transport_server_url <"$transport_server_url_file"

START_SECONDS=$SECONDS
for fault_point in "${FAULT_POINTS[@]}"; do
  case_root="$PROBE_TMP/$fault_point"

  if [[ $fault_point == *transport* ]]; then
    set +e
    ALLOY_FAULT_AFTER="$fault_point" \
      "$PROBE" transport "$case_root" "$transport_server_url" matrix-fetch
    status=$?
    set -e

    if [[ $status -ne 97 ]]; then
      printf 'FAIL %-38s expected exit 97, got %d\n' "$fault_point" "$status" >&2
      exit 1
    fi

    "$PROBE" transport "$case_root" "$transport_server_url" matrix-fetch
    "$PROBE" verify-transport \
      "$case_root" "$transport_server_url" matrix-fetch
    printf 'PASS %s\n' "$fault_point"
    continue
  fi

  "$PROBE" bootstrap "$case_root" game generation-a payload-a save-v1

  if [[ $fault_point == after-gc-* ]]; then
    "$PROBE" update "$case_root" game generation-b payload-b pass
    "$PROBE" update "$case_root" game generation-c payload-c pass
    "$PROBE" seed-gc-leftovers "$case_root"

    set +e
    ALLOY_FAULT_AFTER="$fault_point" "$PROBE" collect "$case_root"
    status=$?
    set -e

    if [[ $status -ne 97 ]]; then
      printf 'FAIL %-38s expected exit 97, got %d\n' "$fault_point" "$status" >&2
      exit 1
    fi

    "$PROBE" recover "$case_root"
    "$PROBE" collect "$case_root"
    "$PROBE" verify-gc \
      "$case_root" game generation-c save-v1 2 generation-a
    printf 'PASS %s\n' "$fault_point"
    continue
  fi

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

restart_root="$PROBE_TMP/ignored-range-restart"
ignored_range_url="$transport_server_url/ignore-range"
for _ in 1 2; do
  set +e
  ALLOY_FAULT_AFTER=after-transport-stream-chunk \
    "$PROBE" transport "$restart_root" "$ignored_range_url" matrix-restart
  status=$?
  set -e
  if [[ $status -ne 97 ]]; then
    printf 'FAIL %-38s expected exit 97, got %d\n' \
      ignored-range-restart-death "$status" >&2
    exit 1
  fi
done
"$PROBE" transport "$restart_root" "$ignored_range_url" matrix-restart
"$PROBE" verify-transport \
  "$restart_root" "$ignored_range_url" matrix-restart
printf 'PASS ignored-range-restart-death\n'

failed_health_root="$PROBE_TMP/failed-health"
"$PROBE" bootstrap "$failed_health_root" game generation-a payload-a save-v1
"$PROBE" update "$failed_health_root" game generation-b payload-b fail
"$PROBE" verify "$failed_health_root" game generation-a save-v1
printf 'PASS failed-health-rollback\n'

printf 'SUMMARY cases=%d elapsed_seconds=%d\n' \
  "$((${#FAULT_POINTS[@]} + 2))" "$((SECONDS - START_SECONDS))"
