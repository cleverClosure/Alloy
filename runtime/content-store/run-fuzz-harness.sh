#!/usr/bin/env bash
# Seeded production parser harness; randomized, not coverage-guided.
# Author: Timur Isaev
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FUZZ_WORK="$(mktemp -d "${TMPDIR:-/tmp}/alloy-parser-fuzz.XXXXXX")"
export SWIFT_MODULECACHE_PATH="$REPO_ROOT/.build/parser-fuzz-module-cache"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULECACHE_PATH"
mkdir -p "$SWIFT_MODULECACHE_PATH"
HARNESS_PID=
LAST_COMMAND_GROUP=
ITERATIONS=128
COMMAND_TIMEOUT=60
SEEDS=(1060001 1060002 1060003)
SELF_TEST=false

cleanup() {
  if [[ -n $HARNESS_PID ]]; then
    kill -TERM -- "-$HARNESS_PID" 2>/dev/null || true
    for _ in {1..50}; do
      kill -0 "$HARNESS_PID" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL -- "-$HARNESS_PID" 2>/dev/null || true
    wait "$HARNESS_PID" 2>/dev/null || true
  fi
  rm -rf "$FUZZ_WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed)
      [[ $# -ge 2 && $2 =~ ^[0-9]{1,18}$ ]] || fail 'seed must be a decimal integer of at most 18 digits'
      SEEDS=("$2")
      shift 2
      ;;
    --iterations)
      [[ $# -ge 2 && $2 =~ ^[0-9]{1,4}$ ]] || fail 'iterations must be 1..1000'
      ITERATIONS=$((10#$2))
      [[ $ITERATIONS -ge 1 && $ITERATIONS -le 1000 ]] || fail 'iterations must be 1..1000'
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 && $2 =~ ^[0-9]{1,3}$ ]] || fail 'timeout must be 1..300 seconds'
      COMMAND_TIMEOUT=$((10#$2))
      [[ $COMMAND_TIMEOUT -ge 1 && $COMMAND_TIMEOUT -le 300 ]] || fail 'timeout must be 1..300 seconds'
      shift 2
      ;;
    --self-test)
      SELF_TEST=true
      shift
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

run_bounded() {
  local limit=$1 log=$2 status=0
  shift 2
  # The supervisor tracks actual child identities, including separate PGIDs.
  set -m
  python3 "$REPO_ROOT/runtime/content-store/supervise-parser-command.py" "$limit" "$log" "$@" &
  HARNESS_PID=$!
  LAST_COMMAND_GROUP=$HARNESS_PID
  set +m
  wait "$HARNESS_PID" || status=$?
  HARNESS_PID=
  return "$status"
}

if [[ $SELF_TEST == true ]]; then
  run_bounded 5 "$FUZZ_WORK/pass.log" bash -c 'exit 0' || fail 'runner lost successful exit'
  status=0
  run_bounded 5 "$FUZZ_WORK/fail.log" bash -c 'exit 9' || status=$?
  [[ $status -eq 9 ]] || fail "runner lost failure exit: $status"
  status=0
  run_bounded 1 "$FUZZ_WORK/timeout.log" bash -c 'sleep 30 & wait' || status=$?
  [[ $status -eq 124 ]] || fail "runner lost timeout: $status"
  if kill -0 -- "-$LAST_COMMAND_GROUP" 2>/dev/null; then fail 'timed-out command group survived'; fi
  printf 'PASS runner-pass-fail-timeout-controls\nSUMMARY runner_controls=3\n'
  exit 0
fi

START_SECONDS=$SECONDS
for package in content-store store-identity; do
  package_root="$REPO_ROOT/runtime/$package"
  build_log="$FUZZ_WORK/$package-build.log"
  if ! run_bounded 180 "$build_log" swift build --disable-sandbox --build-tests --package-path "$package_root"; then
    cat "$build_log"
    fail "$package test build failed or timed out"
  fi
  printf 'PASS %s-build\n' "$package"
  if [[ $package == content-store ]]; then
    heartbeat="$FUZZ_WORK/swift-test-heartbeat"
    status=0
    run_bounded 5 "$FUZZ_WORK/swift-runner-timeout.log" \
      env ALLOY_FUZZ_CONTROL=runner-hang ALLOY_FUZZ_HEARTBEAT="$heartbeat" \
      swift test --skip-build --disable-sandbox --package-path "$package_root" \
      --filter ParserFuzzTimeoutControlTests || status=$?
    [[ $status -eq 124 ]] || fail "production Swift runner did not time out: $status"
    python3 "$REPO_ROOT/runtime/content-store/supervise-parser-command.py" --verify-heartbeat "$heartbeat"
  fi
  control_log="$FUZZ_WORK/$package-control.log"
  status=0
  run_bounded "$COMMAND_TIMEOUT" "$control_log" env ALLOY_FUZZ_CONTROL=malformation \
    swift test --skip-build --disable-sandbox --package-path "$package_root" \
    --filter 'ParserFuzzHarnessTests/validCorpusControl' || status=$?
  if [[ $status -ne 1 ]] || ! grep -q '^FUZZ_CONTROL ' "$control_log"; then
    cat "$control_log"
    fail "$package planted malformation was not detected by its executed control (exit $status)"
  fi
  printf 'PASS %s-planted-malformation expected_test_failure=%d\n' "$package" "$status"
done

for seed in "${SEEDS[@]}"; do
  for package in content-store store-identity; do
    log="$FUZZ_WORK/$package-$seed.log"
    if ! run_bounded "$COMMAND_TIMEOUT" "$log" env ALLOY_FUZZ_CONTROL= \
      ALLOY_FUZZ_SEED="$seed" ALLOY_FUZZ_ITERATIONS="$ITERATIONS" \
      swift test --skip-build --disable-sandbox --package-path "$REPO_ROOT/runtime/$package" \
      --filter ParserFuzzHarnessTests; then
      cat "$log"
      fail "$package seed=$seed failed or timed out"
    fi
    expected_targets=1
    [[ $package == content-store ]] && expected_targets=4
    [[ $(grep -c '^FUZZ_STRUCTURED ' "$log") -eq $expected_targets ]] || fail "$package structured tests did not run"
    [[ $(grep -c '^FUZZ_RANDOM ' "$log") -eq $expected_targets ]] || fail "$package random tests did not run"
    grep '^FUZZ_' "$log"
    printf 'PASS %s seed=%s iterations=%d\n' "$package" "$seed" "$ITERATIONS"
  done
done

printf 'SUMMARY parsers=5 seeds=%d structured_mutations=%d random_mutations=%d planted_controls=2 production_timeout_controls=1 elapsed_seconds=%d\n' \
  "${#SEEDS[@]}" "$((5 * ${#SEEDS[@]} * ITERATIONS))" "$((5 * ${#SEEDS[@]} * ITERATIONS))" \
  "$((SECONDS - START_SECONDS))"
