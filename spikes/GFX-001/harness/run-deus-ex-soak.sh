#!/usr/bin/env bash
# Repeated-scene memory and pacing run for the GFX-001 Deus Ex benchmark.
# Author: Timur Isaev

set -euo pipefail

usage() {
  cat <<'EOF'
usage: run-deus-ex-soak.sh RUN_ID DURATION_SECONDS

Required environment is the same as launch-deus-ex-mankind-divided.sh. A prior
prepare or cache-pair run must have prepared ALLOY_STORE_WORK. One exact DXMD
process stays alive for DURATION_SECONDS of memory sampling while the verified
built-in benchmark scene is repeated. Each cycle is gated by title-log markers,
OCR-verified menu selection, and matching DXMT Present timestamps.

ALLOY_DXMT_SHADER_CACHE_PATH must select a warmed cache beneath ALLOY_STORE_WORK.
Results are written beneath ALLOY_STORE_WORK/soaks/.
EOF
}

if (($# != 2)); then
  usage >&2
  exit 2
fi

run_id=$1
duration=$2
if [[ ! $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "RUN_ID contains unsupported characters: $run_id" >&2
  exit 2
fi
if [[ ! $duration =~ ^[1-9][0-9]*$ ]]; then
  echo "duration must be a positive integer" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
gfx_root=$(cd "$script_dir/.." && pwd)
store_root=$(cd "$gfx_root/../STORE-001" && pwd)
launcher="$store_root/runtime-launch/launch-deus-ex-mankind-divided.sh"
analyzer="$script_dir/analyze-title-metrics.py"
driver="$script_dir/drive-deus-ex-benchmark.swift"
sampler="$script_dir/sample-process-memory.sh"
work_root=${ALLOY_STORE_WORK:-"$store_root/work/issue-11-deus-ex"}
wine_build=${ALLOY_WINE_BUILD:?ALLOY_WINE_BUILD is required}
run_root="$work_root/soaks/$run_id"
cycles_root="$run_root/cycles"
metrics_path="$run_root/metrics.tsv"
memory_path="$run_root/memory.tsv"
pid_path="$run_root/game.pid"
completion_path="$run_root/game.complete"
summary_path="$run_root/summary.json"
cache_path=${ALLOY_DXMT_SHADER_CACHE_PATH:?ALLOY_DXMT_SHADER_CACHE_PATH is required}
profile_name=$(id -un)
title_log="$work_root/prefix/drive_c/users/$profile_name/Documents/Deus Ex -  Mankind Divided/Deus Ex -  Mankind Divided.log"
watchdog_duration=$((duration + 900))
launcher_pid=
driver_pid=
sampler_pid=

case "$run_root" in
  "$store_root"/work/*) ;;
  *)
    echo "soak output must stay under $store_root/work/" >&2
    exit 2
    ;;
esac
case "$cache_path" in
  "$work_root"/*) ;;
  *)
    echo "shader cache must stay under ALLOY_STORE_WORK" >&2
    exit 2
    ;;
esac
if [[ -e $run_root ]]; then
  echo "soak output already exists; choose a new RUN_ID: $run_root" >&2
  exit 2
fi

stop_server() {
  env WINEPREFIX="$work_root/prefix" \
    "$wine_build/server/wineserver" -k >/dev/null 2>&1 || true
}
cleanup() {
  if [[ -n $driver_pid ]]; then
    kill "$driver_pid" >/dev/null 2>&1 || true
    wait "$driver_pid" 2>/dev/null || true
  fi
  if [[ -n $sampler_pid ]]; then
    kill "$sampler_pid" >/dev/null 2>&1 || true
    wait "$sampler_pid" 2>/dev/null || true
  fi
  stop_server
  if [[ -n $launcher_pid ]]; then
    wait "$launcher_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$cycles_root"
rm -f "$title_log"
ALLOY_DXMT_METRICS_PATH="$metrics_path" \
  ALLOY_DXMT_SHADER_CACHE_PATH="$cache_path" \
  ALLOY_GAME_PID_PATH="$pid_path" \
  ALLOY_GAME_COMPLETION_PATH="$completion_path" \
  ALLOY_RUN_LABEL="$run_id" \
  "$launcher" benchmark --reuse-runtime --duration "$watchdog_duration" &
launcher_pid=$!

game_pid=
for ((attempt = 0; attempt < 150; attempt++)); do
  if [[ -s $pid_path ]]; then
    game_pid=$(<"$pid_path")
    if [[ $game_pid =~ ^[1-9][0-9]*$ ]] &&
      ps -p "$game_pid" -o command= | grep -Fq "DXMD.exe -benchmark"; then
      break
    fi
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    wait "$launcher_pid"
    echo "title exited before exposing its host PID" >&2
    exit 1
  fi
  sleep 1
done
if [[ -z $game_pid ]] ||
  ! ps -p "$game_pid" -o command= | grep -Fq "DXMD.exe -benchmark"; then
  echo "timed out waiting for the exact Deus Ex host process" >&2
  exit 1
fi

analyze_cycle() {
  local cycle_id=$1
  local markers_path="$cycles_root/$cycle_id-markers.json"
  local start_seconds end_seconds
  start_seconds=$(jq -er '.sceneStartTimestampNs / 1000000000' "$markers_path")
  end_seconds=$(jq -er '.sceneEndTimestampNs / 1000000000' "$markers_path")
  python3 -B "$analyzer" "$metrics_path" \
    --start-seconds "$start_seconds" \
    --end-seconds "$end_seconds" \
    --label "deus-ex-$run_id-$cycle_id" \
    --output "$cycles_root/$cycle_id-summary.json"
}

cycle_number=1
cycle_id=$(printf 'cycle-%02d' "$cycle_number")
first_markers="$cycles_root/$cycle_id-markers.json"
"$driver" "$game_pid" "$title_log" "$metrics_path" \
  "$first_markers" 30 "$watchdog_duration" &
driver_pid=$!

for ((attempt = 0; attempt < 300; attempt++)); do
  if [[ -s $first_markers ]] &&
    jq -e '.sceneStartTimestampNs | numbers' "$first_markers" >/dev/null; then
    break
  fi
  if ! kill -0 "$driver_pid" 2>/dev/null; then
    wait "$driver_pid"
    echo "first benchmark cycle exited before its scene marker" >&2
    exit 1
  fi
  sleep 1
done
if [[ ! -s $first_markers ]] ||
  ! jq -e '.sceneStartTimestampNs | numbers' "$first_markers" >/dev/null; then
  echo "timed out waiting for the first verified benchmark scene" >&2
  exit 1
fi

"$sampler" "$game_pid" "$duration" "$memory_path" "DXMD.exe -benchmark" &
sampler_pid=$!

wait "$driver_pid"
driver_pid=
analyze_cycle "$cycle_id"

while kill -0 "$sampler_pid" 2>/dev/null; do
  cycle_number=$((cycle_number + 1))
  cycle_id=$(printf 'cycle-%02d' "$cycle_number")
  "$driver" "$game_pid" "$title_log" "$metrics_path" \
    "$cycles_root/$cycle_id-markers.json" 1 "$watchdog_duration" &
  driver_pid=$!
  wait "$driver_pid"
  driver_pid=
  analyze_cycle "$cycle_id"
done

wait "$sampler_pid"
sampler_pid=
cp "$title_log" "$run_root/title.log"

command_line=$(ps -p "$game_pid" -o command=)
if [[ $command_line != *"DXMD.exe -benchmark"* ]]; then
  echo "refusing to stop a PID that is not the exact Deus Ex process" >&2
  exit 1
fi
printf '%s\n' "verified repeated-scene soak complete" >"$completion_path"
kill "$game_pid"
wait "$launcher_pid"
launcher_pid=

python3 -B "$analyzer" "$metrics_path" \
  --memory "$memory_path" \
  --label "deus-ex-$run_id-full-session" \
  --output "$summary_path"

jq -n \
  --argjson cycle_count "$cycle_number" \
  --argjson requested_duration_seconds "$duration" \
  --arg metrics_sha256 "$(shasum -a 256 "$metrics_path" | awk '{print $1}')" \
  --arg memory_sha256 "$(shasum -a 256 "$memory_path" | awk '{print $1}')" \
  '{
    schemaVersion: 1,
    author: "Timur Isaev",
    cycleCount: $cycle_count,
    requestedMemoryDurationSeconds: $requested_duration_seconds,
    metricsSHA256: $metrics_sha256,
    memorySHA256: $memory_sha256
  }' >"$run_root/session.json"

echo "soak complete: $run_root"
