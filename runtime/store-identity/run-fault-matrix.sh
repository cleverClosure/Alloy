#!/usr/bin/env bash
# Gate 5 deterministic detector self-test and crash-convergence proof.
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$PACKAGE_ROOT/../.." && pwd)"
MODULE_CACHE="$PACKAGE_ROOT/.build/module-cache"
FIXTURE_SOURCE="$PACKAGE_ROOT/Tests/Fixtures/SyntheticSteamLibrary"
ANCHOR_SOURCE="$REPOSITORY_ROOT/spikes/STORE-001/results/fingerprint-1272160-first.json"
REGISTRY_SOURCE="$PACKAGE_ROOT/Registry/selectors.v1.json"

export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

require_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$label: expected '$expected', got '$actual'"
}

matching_file_count() {
  local directory="$1"
  local pattern="$2"
  find "$directory" -maxdepth 1 -type f -name "$pattern" -print |
    awk 'END { print NR + 0 }'
}

require_matching_file_count() {
  local directory="$1"
  local pattern="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(matching_file_count "$directory" "$pattern")"
  require_equal "$actual" "$expected" "$label"
}

single_matching_file() {
  local directory="$1"
  local pattern="$2"
  find "$directory" -maxdepth 1 -type f -name "$pattern" -print
}

require_empty_directory() {
  local directory="$1"
  local label="$2"
  [[ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail "$label: residual entry found"
}

snapshot_inputs() {
  find "$SYNTHETIC_LIBRARY" -type f -exec shasum -a 256 {} \;
  shasum -a 256 "$ANCHOR_SOURCE" "$REGISTRY_SOURCE"
}

run_expected_kill() {
  local point="$1"
  local marker="$2"
  local expected_context="$3"
  local stdout_path="$4"
  local stderr_path="$5"
  shift 5

  rm -f -- "$marker" "$stdout_path" "$stderr_path"
  set +e
  ALLOY_STORE_IDENTITY_FAULT_POINT="$point" \
    ALLOY_STORE_IDENTITY_FAULT_MARKER="$marker" \
    "$PROBE" "$@" >"$stdout_path" 2>"$stderr_path"
  local status=$?
  set -e

  require_equal "$status" "97" "$point exit status"
  [[ -f "$marker" ]] || fail "$point did not write its reachability marker"
  local marker_value
  marker_value="$(tr -d '\n' <"$marker")"
  require_equal \
    "$marker_value" \
    "$point"$'\t'"$expected_context" \
    "$point marker"
}

assert_one_final_and_no_temps() {
  local output_root="$1"
  local baseline_final="$2"
  local label="$3"
  local directory="$output_root/invalidations"
  local final

  require_matching_file_count "$directory" '*.json' 1 "$label final JSON count"
  require_matching_file_count \
    "$directory" \
    '.*.tmp-*' \
    0 \
    "$label generated temporary count"
  final="$(single_matching_file "$directory" '*.json')"
  cmp -s "$baseline_final" "$final" ||
    fail "$label final JSON differs from the clean baseline"
}

swift build \
  --disable-sandbox \
  --package-path "$PACKAGE_ROOT" \
  --product AlloyStoreIdentityFaultProbe

PROBE="$PACKAGE_ROOT/.build/debug/AlloyStoreIdentityFaultProbe"
[[ -x "$PROBE" ]] || fail "fault probe executable was not produced"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/alloy-store-fault-matrix.XXXXXX")"
cleanup() {
  if [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" ]]; then
    rm -rf -- "$WORK_ROOT"
  fi
}
trap cleanup EXIT

SYNTHETIC_LIBRARY="$WORK_ROOT/synthetic-library"
cp -R "$FIXTURE_SOURCE" "$SYNTHETIC_LIBRARY"
SYNTHETIC_MANIFEST="$SYNTHETIC_LIBRARY/steamapps/appmanifest_900000.acf"
SYNTHETIC_INSTALL="$SYNTHETIC_LIBRARY/steamapps/common/Synthetic Game"

snapshot_inputs | LC_ALL=C sort >"$WORK_ROOT/inputs-before.sha256"

SCAN_BASELINE="$WORK_ROOT/scan-baseline.json"
SCAN_RECOVERED="$WORK_ROOT/scan-recovered.json"
SCAN_REPEATED="$WORK_ROOT/scan-repeated.json"
"$PROBE" \
  scan \
  "$SYNTHETIC_MANIFEST" \
  "$SYNTHETIC_INSTALL" \
  "$SCAN_BASELINE" >"$WORK_ROOT/scan-baseline.log"

WATCH_SCRATCH="$WORK_ROOT/watch-scratch"
mkdir -p "$WATCH_SCRATCH"
run_expected_kill \
  afterFingerprintCandidate \
  "$WORK_ROOT/scan.marker" \
  ".hidden-settings" \
  "$WORK_ROOT/scan-killed.stdout" \
  "$WORK_ROOT/scan-killed.stderr" \
  watch-unchanged \
  "$SYNTHETIC_MANIFEST" \
  "$SYNTHETIC_INSTALL" \
  "$SCAN_BASELINE" \
  "$WATCH_SCRATCH"

[[ ! -s "$WORK_ROOT/scan-killed.stdout" ]] ||
  fail "mid-scan kill exposed a watcher result"
require_empty_directory "$WATCH_SCRATCH" "mid-scan watcher scratch"
snapshot_inputs | LC_ALL=C sort >"$WORK_ROOT/inputs-after-scan-kill.sha256"
cmp -s \
  "$WORK_ROOT/inputs-before.sha256" \
  "$WORK_ROOT/inputs-after-scan-kill.sha256" ||
  fail "mid-scan kill changed an input byte"

"$PROBE" \
  scan \
  "$SYNTHETIC_MANIFEST" \
  "$SYNTHETIC_INSTALL" \
  "$SCAN_RECOVERED" >"$WORK_ROOT/scan-recovered.log"
cmp -s "$SCAN_BASELINE" "$SCAN_RECOVERED" ||
  fail "mid-scan recovery fingerprint differs from baseline"

"$PROBE" \
  watch-unchanged \
  "$SYNTHETIC_MANIFEST" \
  "$SYNTHETIC_INSTALL" \
  "$SCAN_RECOVERED" \
  "$WATCH_SCRATCH" >"$WORK_ROOT/watch-recovered.log"
require_equal \
  "$(tr -d '\n' <"$WORK_ROOT/watch-recovered.log")" \
  "WATCH self_test=passed detection=unchanged" \
  "recovered unchanged watcher result"

"$PROBE" \
  scan \
  "$SYNTHETIC_MANIFEST" \
  "$SYNTHETIC_INSTALL" \
  "$SCAN_REPEATED" >"$WORK_ROOT/scan-repeated.log"
cmp -s "$SCAN_BASELINE" "$SCAN_REPEATED" ||
  fail "repeated recovery fingerprint is not stable"

EMIT_BASELINE_ROOT="$WORK_ROOT/emit-baseline"
EMIT_BASELINE_SCRATCH="$WORK_ROOT/emit-baseline-scratch"
mkdir -p "$EMIT_BASELINE_ROOT" "$EMIT_BASELINE_SCRATCH"
"$PROBE" \
  emit \
  "$ANCHOR_SOURCE" \
  "$REGISTRY_SOURCE" \
  "$EMIT_BASELINE_ROOT" \
  "$EMIT_BASELINE_SCRATCH" >"$WORK_ROOT/emit-baseline.log"

require_matching_file_count \
  "$EMIT_BASELINE_ROOT/invalidations" \
  '*.json' \
  1 \
  "clean baseline final JSON count"
require_matching_file_count \
  "$EMIT_BASELINE_ROOT/invalidations" \
  '.*.tmp-*' \
  0 \
  "clean baseline generated temporary count"
BASELINE_FINAL="$(
  single_matching_file "$EMIT_BASELINE_ROOT/invalidations" '*.json'
)"
BASELINE_FILE="$(basename "$BASELINE_FINAL")"
BASELINE_ID="sha256:${BASELINE_FILE%.json}"
require_equal \
  "$(tr -d '\n' <"$WORK_ROOT/emit-baseline.log")" \
  "EMIT created=true id=$BASELINE_ID file=$BASELINE_FILE proof=passed" \
  "clean baseline emission"

emit_points=(
  afterTemporaryFileSync
  afterFinalLink
  afterDirectorySync
)

for point in "${emit_points[@]}"; do
  case_root="$WORK_ROOT/emit-$point"
  scratch_root="$WORK_ROOT/scratch-$point"
  marker="$WORK_ROOT/$point.marker"
  mkdir -p "$case_root" "$scratch_root"

  run_expected_kill \
    "$point" \
    "$marker" \
    "$BASELINE_ID" \
    "$WORK_ROOT/$point.stdout" \
    "$WORK_ROOT/$point.stderr" \
    emit \
    "$ANCHOR_SOURCE" \
    "$REGISTRY_SOURCE" \
    "$case_root" \
    "$scratch_root"

  require_empty_directory "$scratch_root" "$point self-test scratch"
  require_matching_file_count \
    "$case_root/invalidations" \
    '.*.tmp-*' \
    1 \
    "$point hidden canonical temporary count"

  expected_created=false
  if [[ "$point" == "afterTemporaryFileSync" ]]; then
    require_matching_file_count \
      "$case_root/invalidations" \
      '*.json' \
      0 \
      "$point visible final JSON count"
    expected_created=true
  else
    require_matching_file_count \
      "$case_root/invalidations" \
      '*.json' \
      1 \
      "$point visible final JSON count"
    killed_final="$(
      single_matching_file "$case_root/invalidations" '*.json'
    )"
    cmp -s "$BASELINE_FINAL" "$killed_final" ||
      fail "$point exposed a noncanonical final JSON"
  fi

  "$PROBE" \
    emit \
    "$ANCHOR_SOURCE" \
    "$REGISTRY_SOURCE" \
    "$case_root" \
    "$scratch_root" >"$WORK_ROOT/$point-recovered.log"
  require_equal \
    "$(tr -d '\n' <"$WORK_ROOT/$point-recovered.log")" \
    "EMIT created=$expected_created id=$BASELINE_ID file=$BASELINE_FILE proof=passed" \
    "$point recovery emission"
  assert_one_final_and_no_temps \
    "$case_root" \
    "$BASELINE_FINAL" \
    "$point recovery"

  recovered_final="$(
    single_matching_file "$case_root/invalidations" '*.json'
  )"
  shasum -a 256 "$recovered_final" >"$WORK_ROOT/$point-before-retry.sha256"
  "$PROBE" \
    emit \
    "$ANCHOR_SOURCE" \
    "$REGISTRY_SOURCE" \
    "$case_root" \
    "$scratch_root" >"$WORK_ROOT/$point-retry.log"
  require_equal \
    "$(tr -d '\n' <"$WORK_ROOT/$point-retry.log")" \
    "EMIT created=false id=$BASELINE_ID file=$BASELINE_FILE proof=passed" \
    "$point second retry"
  assert_one_final_and_no_temps \
    "$case_root" \
    "$BASELINE_FINAL" \
    "$point second retry"
  shasum -a 256 "$recovered_final" >"$WORK_ROOT/$point-after-retry.sha256"
  cmp -s \
    "$WORK_ROOT/$point-before-retry.sha256" \
    "$WORK_ROOT/$point-after-retry.sha256" ||
    fail "$point second retry changed final invalidation bytes"
done

snapshot_inputs | LC_ALL=C sort >"$WORK_ROOT/inputs-after.sha256"
cmp -s "$WORK_ROOT/inputs-before.sha256" "$WORK_ROOT/inputs-after.sha256" ||
  fail "fault matrix changed an input byte"

printf '%s\n' \
  'SUMMARY fault-matrix scan-points=1 emit-points=3 self-test=PASS inputs=UNCHANGED recovery=CONVERGED status=PASS'
