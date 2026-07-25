#!/usr/bin/env bash
# Process memory sampler for GFX-001 title measurements.
# Author: Timur Isaev

set -euo pipefail

usage() {
  cat <<'EOF'
usage: sample-process-memory.sh PID DURATION_SECONDS OUTPUT_TSV EXPECTED_COMMAND_FRAGMENT

Samples RSS and virtual size once per second. The sampler exits if PID no longer
identifies a process whose command contains EXPECTED_COMMAND_FRAGMENT.
EOF
}

if (($# != 4)); then
  usage >&2
  exit 2
fi

pid=$1
duration=$2
output=$3
expected_fragment=$4

if [[ ! $pid =~ ^[1-9][0-9]*$ || ! $duration =~ ^[1-9][0-9]*$ ]]; then
  echo "PID and duration must be positive integers" >&2
  exit 2
fi
if [[ -z $expected_fragment ]]; then
  echo "expected command fragment must not be empty" >&2
  exit 2
fi

mkdir -p "$(dirname "$output")"
printf 'elapsed_s\tpid\trss_kb\tvsz_kb\tpercent_mem\n' >"$output"

for ((elapsed = 0; elapsed <= duration; elapsed++)); do
  command_line=$(ps -p "$pid" -o command=)
  if [[ $command_line != *"$expected_fragment"* ]]; then
    echo "PID $pid no longer matches the expected command" >&2
    exit 1
  fi

  read -r rss_kb vsz_kb percent_mem < <(
    ps -p "$pid" -o rss= -o vsz= -o %mem=
  )
  printf '%d\t%d\t%s\t%s\t%s\n' \
    "$elapsed" "$pid" "$rss_kb" "$vsz_kb" "$percent_mem" >>"$output"

  if ((elapsed < duration)); then
    sleep 1
  fi
done
