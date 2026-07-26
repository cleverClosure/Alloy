#!/usr/bin/env bash
# Deterministic content-store multi-process coordination matrix
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
MATRIX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/alloy-content-store-concurrency.XXXXXX")"
SWIFT_CACHE="$PACKAGE_ROOT/.build/module-cache"

cleanup() {
  chmod -R u+w "$MATRIX_TMP" 2>/dev/null || true
  rm -rf "$MATRIX_TMP"
}
trap cleanup EXIT

export SWIFT_MODULECACHE_PATH="$SWIFT_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE"

swift build --disable-sandbox --package-path "$PACKAGE_ROOT"
PROBE="$PACKAGE_ROOT/.build/debug/alloy-content-store-fault-probe"

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

printf 'SUMMARY cases=4\n'
