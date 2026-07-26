#!/usr/bin/env bash
# Run the promoted M12-001, M12-002, and M12-004 proof thresholds.
# Author: Timur Isaev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN_PRESSURE=0

if [[ ${1:-} == --include-residency-pressure ]]; then
  RUN_PRESSURE=1
elif (($#)); then
  printf 'usage: %s [--include-residency-pressure]\n' "$0" >&2
  exit 2
fi

"$ROOT/build.sh"

printf '== descriptor heap proof\n'
"$ROOT/build/descriptor_heap_test"

printf '== barrier tracker proof\n'
"$ROOT/build/barrier_tracker_test"

if ((RUN_PRESSURE == 0)); then
  printf '%s\n' \
    '== residency proof: NOT RUN' \
    'This proof deliberately allocates through Metal'\''s advisory budget and up to 1 GiB beyond it.' \
    'Re-run with --include-residency-pressure only after explicit host-risk approval.' >&2
  exit 3
fi

printf '== residency proof (explicit hardware-pressure gate)\n'
"$ROOT/build/residency_test"

printf 'model proofs: PASS\n'
