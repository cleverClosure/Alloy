#!/usr/bin/env bash
# Deterministic content-store multi-process coordination matrix
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
MATRIX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/alloy-content-store-concurrency.XXXXXX")"
SWIFT_CACHE="$PACKAGE_ROOT/.build/module-cache"
TRANSPORT_SERVER_PID=

cleanup() {
  if [[ -n $TRANSPORT_SERVER_PID ]]; then
    kill "$TRANSPORT_SERVER_PID" 2>/dev/null || true
    wait "$TRANSPORT_SERVER_PID" 2>/dev/null || true
  fi
  chmod -R u+w "$MATRIX_TMP" 2>/dev/null || true
  rm -rf "$MATRIX_TMP"
}
trap cleanup EXIT

export SWIFT_MODULECACHE_PATH="$SWIFT_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE"

swift build --disable-sandbox --package-path "$PACKAGE_ROOT"
PROBE="$PACKAGE_ROOT/.build/debug/alloy-content-store-fault-probe"

transport_server_fifo="$MATRIX_TMP/transport-server.url"
mkfifo "$transport_server_fifo"
python3 "$PACKAGE_ROOT/Tests/Fixtures/transport_range_server.py" \
  >"$transport_server_fifo" &
TRANSPORT_SERVER_PID=$!
if ! IFS= read -r -t 10 transport_server_url <"$transport_server_fifo"; then
  printf 'FAIL transport fixture did not publish its address\n' >&2
  exit 1
fi
if [[ $transport_server_url != http://127.0.0.1:* ]]; then
  printf 'FAIL transport fixture published invalid URL: %s\n' \
    "$transport_server_url" >&2
  exit 1
fi

wait_marker() {
  "$PROBE" wait-marker "$1"
}

write_marker() {
  "$PROBE" write-marker "$1"
}

bootstrap_three() {
  local root=$1
  "$PROBE" bootstrap "$root" game generation-a payload-a save-v1
  "$PROBE" update "$root" game generation-b payload-b pass
  "$PROBE" update "$root" game generation-c payload-c pass
}

# Lease is acquired and remains held through the complete sweep.
case_root="$MATRIX_TMP/lease-before-sweep"
markers="$case_root-markers"
"$PROBE" bootstrap "$case_root" game generation-a payload-a save-v1
"$PROBE" lease-hold \
  "$case_root" game "$markers/ready" "$markers/release" \
  "$markers/release-attempted" "$markers/done" &
lease_pid=$!
wait_marker "$markers/ready"
"$PROBE" update "$case_root" game generation-b payload-b pass
"$PROBE" update "$case_root" game generation-c payload-c pass
"$PROBE" collect "$case_root"
"$PROBE" verify-generation "$case_root" game generation-a present
write_marker "$markers/release"
wait "$lease_pid"
"$PROBE" collect "$case_root"
"$PROBE" verify-generation "$case_root" game generation-a absent
printf 'PASS lease-before-sweep\n'

# Release is requested after GC marks the live lease. The collector owns the
# lock, so release waits; its mark snapshot still protects the generation.
case_root="$MATRIX_TMP/release-after-mark"
markers="$case_root-markers"
"$PROBE" bootstrap "$case_root" game generation-a payload-a save-v1
"$PROBE" lease-hold-contended \
  "$case_root" game "$markers/lease-ready" "$markers/release" \
  "$markers/release-attempted" "$markers/lease-done" &
lease_pid=$!
wait_marker "$markers/lease-ready"
"$PROBE" update "$case_root" game generation-b payload-b pass
"$PROBE" update "$case_root" game generation-c payload-c pass
"$PROBE" collect-handshake \
  "$case_root" after-gc-mark "$markers/gc-marked" "$markers/gc-continue" &
gc_pid=$!
wait_marker "$markers/gc-marked"
write_marker "$markers/release"
wait_marker "$markers/release-attempted"
write_marker "$markers/gc-continue"
wait "$gc_pid"
wait "$lease_pid"
"$PROBE" verify-generation "$case_root" game generation-a present
"$PROBE" collect "$case_root"
"$PROBE" verify-generation "$case_root" game generation-a absent
printf 'PASS release-after-mark\n'

# GC holds the lock after mark while a writer has announced its activation.
# The writer proceeds only after the sweep releases the lock.
case_root="$MATRIX_TMP/gc-before-writer"
markers="$case_root-markers"
bootstrap_three "$case_root"
"$PROBE" collect-handshake \
  "$case_root" after-gc-mark "$markers/gc-marked" "$markers/gc-continue" &
gc_pid=$!
wait_marker "$markers/gc-marked"
"$PROBE" update-announced \
  "$case_root" game generation-d payload-d pass \
  "$markers/writer-entered" "$markers/writer-done" &
writer_pid=$!
wait_marker "$markers/writer-entered"
write_marker "$markers/gc-continue"
wait "$gc_pid"
wait_marker "$markers/writer-done"
wait "$writer_pid"
"$PROBE" recover "$case_root"
"$PROBE" recover "$case_root"
"$PROBE" verify "$case_root" game generation-d save-v1
printf 'PASS gc-before-writer\n'

# The writer holds the lock after publishing its CAS action while a collector
# has announced its sweep. The completed journal becomes visible before mark.
case_root="$MATRIX_TMP/writer-before-gc"
markers="$case_root-markers"
bootstrap_three "$case_root"
"$PROBE" update-handshake \
  "$case_root" game generation-d payload-d pass after-publish-cas-action \
  "$markers/writer-published" "$markers/writer-continue" &
writer_pid=$!
wait_marker "$markers/writer-published"
"$PROBE" collect-announced \
  "$case_root" "$markers/gc-entered" "$markers/gc-done" &
gc_pid=$!
wait_marker "$markers/gc-entered"
write_marker "$markers/writer-continue"
wait "$writer_pid"
wait_marker "$markers/gc-done"
wait "$gc_pid"
"$PROBE" recover "$case_root"
"$PROBE" recover "$case_root"
"$PROBE" verify "$case_root" game generation-d save-v1
printf 'PASS writer-before-gc\n'

# A downloader owns a durable partial operation while GC runs. A lease roots
# generation A while active C and rollback B cover the remaining generations.
case_root="$MATRIX_TMP/downloader-before-gc"
markers="$case_root-markers"
"$PROBE" bootstrap "$case_root" game generation-a payload-a save-v1
"$PROBE" lease-hold \
  "$case_root" game "$markers/lease-ready" "$markers/release" \
  "$markers/release-attempted" "$markers/lease-done" &
lease_pid=$!
wait_marker "$markers/lease-ready"
"$PROBE" update "$case_root" game generation-b payload-b pass
"$PROBE" update "$case_root" game generation-c payload-c pass
"$PROBE" transport-handshake \
  "$case_root" "$transport_server_url" live-download \
  after-transport-stream-chunk \
  "$markers/download-checkpoint" "$markers/download-continue" &
downloader_pid=$!
wait_marker "$markers/download-checkpoint"
"$PROBE" verify-transport-staging \
  "$case_root" live-download downloading
"$PROBE" collect "$case_root"
"$PROBE" verify-transport-staging \
  "$case_root" live-download downloading
"$PROBE" verify-generation "$case_root" game generation-a present
write_marker "$markers/download-continue"
wait "$downloader_pid"
"$PROBE" verify-transport \
  "$case_root" "$transport_server_url" live-download 4
"$PROBE" verify "$case_root" game generation-c save-v1
write_marker "$markers/release"
wait "$lease_pid"
"$PROBE" collect "$case_root"
"$PROBE" verify-gc \
  "$case_root" game generation-c save-v1 2 generation-a

# A process death after CAS publication leaves a published sidecar. GC must
# root that digest until retry reuses the object and removes the sidecar.
set +e
ALLOY_FAULT_AFTER=after-transport-publication \
  "$PROBE" transport \
  "$case_root" "$transport_server_url" published-download
status=$?
set -e
if [[ $status -ne 97 ]]; then
  printf 'FAIL %-38s expected exit 97, got %d\n' \
    published-download-before-gc "$status" >&2
  exit 1
fi
"$PROBE" collect "$case_root"
"$PROBE" verify-transport-staging \
  "$case_root" published-download published
"$PROBE" verify-transport \
  "$case_root" "$transport_server_url" published-download 3
"$PROBE" collect "$case_root"
"$PROBE" verify-gc \
  "$case_root" game generation-c save-v1 2 generation-a
printf 'PASS downloader-before-gc\n'

# GC owns the store lock first. The downloader announces contention before
# constructing ContentStore, then proceeds only after GC has swept abandoned
# staging and released the lock.
case_root="$MATRIX_TMP/gc-before-downloader"
markers="$case_root-markers"
bootstrap_three "$case_root"
"$PROBE" seed-gc-leftovers "$case_root"
"$PROBE" collect-handshake \
  "$case_root" after-gc-mark "$markers/gc-marked" "$markers/gc-continue" &
gc_pid=$!
wait_marker "$markers/gc-marked"
"$PROBE" transport-announced \
  "$case_root" "$transport_server_url" gc-after-download \
  "$markers/downloader-entered" "$markers/downloader-done" &
downloader_pid=$!
wait_marker "$markers/downloader-entered"
write_marker "$markers/gc-continue"
wait "$gc_pid"
"$PROBE" verify-transport-staging "$case_root" abandoned absent
wait_marker "$markers/downloader-done"
wait "$downloader_pid"
"$PROBE" verify-transport \
  "$case_root" "$transport_server_url" gc-after-download 3
"$PROBE" verify "$case_root" game generation-c save-v1
"$PROBE" collect "$case_root"
"$PROBE" verify-gc \
  "$case_root" game generation-c save-v1 2 generation-a
printf 'PASS gc-before-downloader\n'

printf 'SUMMARY cases=6\n'
