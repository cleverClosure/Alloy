#!/usr/bin/env bash
# Run the promoted M12-001, M12-002, and M12-004 proof thresholds.
# Author: Timur Isaev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RESIDENCY_MODE=none

if [[ ${1:-} == --include-residency-pressure ]]; then
  RESIDENCY_MODE=pressure
elif [[ ${1:-} == --include-residency-safe ]]; then
  RESIDENCY_MODE=safe
elif (($#)); then
  printf 'usage: %s [--include-residency-safe|--include-residency-pressure]\n' "$0" >&2
  exit 2
fi

"$ROOT/build.sh"

printf '== descriptor heap proof\n'
"$ROOT/build/descriptor_heap_test"

printf '== barrier tracker proof\n'
"$ROOT/build/barrier_tracker_test"

if [[ $RESIDENCY_MODE == none ]]; then
  printf '%s\n' \
    '== residency proofs: NOT RUN' \
    'The safe path can still peak around 820 MiB; use --include-residency-safe deliberately.' \
    'The full proof allocates through Metal'\''s advisory budget and up to 1 GiB beyond it.' \
    'Use --include-residency-pressure only after explicit host-risk approval.' >&2
  exit 3
fi

if [[ $RESIDENCY_MODE == safe ]]; then
  printf '== residency proof (non-oversubscribing checks)\n'
  "$ROOT/build/residency_safe_test"
  printf '%s\n' \
    '== residency pressure proof: NOT RUN' \
    'Re-run with --include-residency-pressure only after explicit host-risk approval.' >&2
  exit 3
fi

printf '== residency proof (explicit hardware-pressure gate)\n'
"$ROOT/build/residency_test"

printf 'model proofs: PASS\n'
