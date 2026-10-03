#!/usr/bin/env bash
# Cold/warm shader-cache pair for the GFX-001 Deus Ex benchmark scene.
# Author: Timur Isaev

set -euo pipefail

usage() {
  cat <<'EOF'
usage: run-deus-ex-cache-pair.sh PAIR_ID DURATION_SECONDS

Required environment is the same as launch-deus-ex-mankind-divided.sh. The
pair starts with a new shader-cache directory, preserves the isolated
wineserver after cold, reuses both for warm, drives the title-owned benchmark
from its menus, and analyzes both full and verified scene streams.
Results are written beneath ALLOY_STORE_WORK/pairs/.
EOF
}

if (($# != 2)); then
  usage >&2
  exit 2
fi

pair_id=$1
duration=$2
if [[ ! $pair_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "PAIR_ID contains unsupported characters: $pair_id" >&2
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
work_root=${ALLOY_STORE_WORK:-"$store_root/work/issue-11-deus-ex"}
wine_build=${ALLOY_WINE_BUILD:?ALLOY_WINE_BUILD is required}
pair_root="$work_root/pairs/$pair_id"
cache_path="$pair_root/cache"
metrics_dir="$pair_root/metrics"
profile_name=$(id -un)
title_log="$work_root/prefix/drive_c/users/$profile_name/Documents/Deus Ex -  Mankind Divided/Deus Ex -  Mankind Divided.log"
launcher_pid=

case "$pair_root" in
  "$store_root"/work/*) ;;
  *)
    echo "pair output must stay under $store_root/work/" >&2
    exit 2
    ;;
esac
if [[ -e $pair_root ]]; then
  echo "pair output already exists; choose a new PAIR_ID: $pair_root" >&2
  exit 2
fi

stop_server() {
  env WINEPREFIX="$work_root/prefix" \
    "$wine_build/server/wineserver" -k >/dev/null 2>&1 || true
}
cleanup() {
  stop_server
  if [[ -n $launcher_pid ]]; then
    wait "$launcher_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$cache_path" "$metrics_dir"

ALLOY_DXMT_SHADER_CACHE_PATH="$cache_path" \
  ALLOY_DXMT_METRICS_PATH="$metrics_dir/prepare.tsv" \
  ALLOY_RUN_LABEL="$pair_id-prepare" \
  "$launcher" prepare

# Both runs reuse the prepared runtime. A stale DXMT install does not fail them:
# D3D11 falls back to Wine's builtin provider and the pair measures that (#35).
"$script_dir/dxmt-install.sh" check "$work_root/dxmt-install" "$wine_build"

run_scene() {
  local run_name=$1
  local preserve_server=$2
  local metrics_path="$metrics_dir/$run_name.tsv"
  local markers_path="$pair_root/$run_name-markers.json"
  local pid_path="$pair_root/$run_name.pid"
  local completion_path="$pair_root/$run_name.complete"
  local title_log_copy="$pair_root/$run_name-title.log"
  local -a launcher_options=(
    benchmark
    --reuse-runtime
    --duration "$duration"
  )
  if ((preserve_server)); then
    launcher_options+=(--preserve-server)
  fi

  rm -f "$pid_path" "$markers_path" "$completion_path" "$title_log"
  ALLOY_DXMT_SHADER_CACHE_PATH="$cache_path" \
    ALLOY_DXMT_METRICS_PATH="$metrics_path" \
    ALLOY_GAME_PID_PATH="$pid_path" \
    ALLOY_GAME_COMPLETION_PATH="$completion_path" \
    ALLOY_RUN_LABEL="$pair_id-$run_name" \
    "$launcher" "${launcher_options[@]}" &
  launcher_pid=$!

  for ((attempt = 0; attempt < 150; attempt++)); do
    if [[ -s $pid_path ]]; then
      break
    fi
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
      wait "$launcher_pid"
      echo "title exited before exposing its host PID" >&2
      exit 1
    fi
    sleep 1
  done
  if [[ ! -s $pid_path ]]; then
    echo "timed out waiting for the exact Deus Ex host process" >&2
    exit 1
  fi

  "$driver" "$(<"$pid_path")" "$title_log" "$metrics_path" \
    "$markers_path" 30 "$duration"
  cp "$title_log" "$title_log_copy"
  local game_pid command_line
  game_pid=$(<"$pid_path")
  command_line=$(ps -p "$game_pid" -o command=)
  if [[ $command_line != *"DXMD.exe -benchmark"* ]]; then
    echo "refusing to stop a PID that is not the exact Deus Ex process" >&2
    exit 1
  fi
  printf '%s\n' "verified benchmark scene complete" >"$completion_path"
  kill "$game_pid"
  wait "$launcher_pid"
  launcher_pid=

  local start_seconds end_seconds
  start_seconds=$(jq -er '.sceneStartTimestampNs / 1000000000' "$markers_path")
  end_seconds=$(jq -er '.sceneEndTimestampNs / 1000000000' "$markers_path")
  python3 -B "$analyzer" "$metrics_path" \
    --label "deus-ex-$pair_id-$run_name-full" \
    --output "$pair_root/$run_name-full.json"
  python3 -B "$analyzer" "$metrics_path" \
    --start-seconds "$start_seconds" \
    --end-seconds "$end_seconds" \
    --label "deus-ex-$pair_id-$run_name-scene" \
    --output "$pair_root/$run_name-scene.json"
}

run_scene cold 1
run_scene warm 0

echo "pair complete: $pair_root"
