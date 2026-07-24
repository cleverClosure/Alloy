#!/usr/bin/env bash
# scene-bench.sh — cold/warm scene measurement harness (GFX-001, prep for #11)
# Author: Tim Isaev
#
# Title-agnostic: measures any command that emits the d3d11_scene metric lines
# (formats defined by testcases/d3d11_scene.c). Point it at the synthetic scene
# today; point it at a real title's scene run when one exists.
#
# Configuration (environment):
#   ALLOY_SCENE_CMD    command that runs the scene and prints metrics (run only)
#   ALLOY_WINESERVER   wineserver binary used to force cold boots (default: wineserver)
#
# Subcommands:
#   run <outdir> [n_cold] [n_warm]  orchestrate cold + warm runs (default 3 + 5)
#   parse <run.log>                 one run's stdout -> one JSON object on stdout
#   report <outdir>                 aggregate cold/*.json + warm/*.json -> markdown
#   selftest                        validate the parser against committed fixtures
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# parse_log <log> — extract the d3d11_scene metric lines into JSON on stdout.
# A run is anchor_pass only if the self-verifying depth pixel stayed red;
# commit_steps counts >64 MB single-frame pagefile jumps the guest reported.
parse_log() {
  local log="$1"
  local first frame_line mean p50 p95 p99 max fps mem_line ws0 ws1 pf0 pf1
  local commits anchor_pass exit_code

  first=$(sed -n 's/^first frame [^:]*: \([0-9.]*\) ms$/\1/p' "$log")
  frame_line=$(grep '^frame time ms:' "$log" || true)
  mean=$(sed -n 's/.*mean=\([0-9.]*\).*/\1/p' <<<"$frame_line")
  p50=$(sed -n 's/.*p50=\([0-9.]*\).*/\1/p' <<<"$frame_line")
  p95=$(sed -n 's/.*p95=\([0-9.]*\).*/\1/p' <<<"$frame_line")
  p99=$(sed -n 's/.*p99=\([0-9.]*\).*/\1/p' <<<"$frame_line")
  max=$(sed -n 's/.*max=\([0-9.]*\).*/\1/p' <<<"$frame_line")
  fps=$(sed -n 's/^throughput: \([0-9.]*\) fps mean$/\1/p' "$log")
  mem_line=$(grep '^memory MB:' "$log" || true)
  ws0=$(sed -n 's/^memory MB: working set \([0-9.]*\) -> .*/\1/p' <<<"$mem_line")
  ws1=$(sed -n 's/^memory MB: working set [0-9.]* -> \([0-9.]*\),.*/\1/p' <<<"$mem_line")
  pf0=$(sed -n 's/.*pagefile \([0-9.]*\) -> .*/\1/p' <<<"$mem_line")
  pf1=$(sed -n 's/.*pagefile [0-9.]* -> \([0-9.]*\)$/\1/p' <<<"$mem_line")
  commits=$(grep -c '^commit step at frame' "$log" || true)
  if grep -q '^anchor (.*): b=0 g=0 r=255 ' "$log"; then
    anchor_pass=true
  else
    anchor_pass=false
  fi
  exit_code=""
  [[ -f "${log%.log}.exit" ]] && exit_code=$(<"${log%.log}.exit")

  jq -n \
    --arg first "$first" --arg mean "$mean" --arg p50 "$p50" --arg p95 "$p95" \
    --arg p99 "$p99" --arg max "$max" --arg fps "$fps" \
    --arg ws0 "$ws0" --arg ws1 "$ws1" --arg pf0 "$pf0" --arg pf1 "$pf1" \
    --arg commits "$commits" --argjson anchor "$anchor_pass" --arg exit_code "$exit_code" \
    'def num(v): if v == "" then null else (v | tonumber) + 0 end;
     {
       first_frame_ms: num($first),
       frame_ms: {mean: num($mean), p50: num($p50), p95: num($p95), p99: num($p99), max: num($max)},
       fps_mean: num($fps),
       memory_mb: {
         working_set_start: num($ws0), working_set_end: num($ws1),
         pagefile_start: num($pf0), pagefile_end: num($pf1),
         pagefile_delta: (if $pf0 == "" or $pf1 == "" then null
                          else ((($pf1 | tonumber) - ($pf0 | tonumber)) * 10 | round) / 10 end)
       },
       anchor_pass: $anchor,
       commit_steps: num($commits),
       exit_code: num($exit_code)
     }'
}

# run_group <outdir> <mode> <count> — cold mode kills wineserver before each run
run_group() {
  local outdir="$1" mode="$2" count="$3" i log ec
  local wineserver="${ALLOY_WINESERVER:-wineserver}"
  mkdir -p "$outdir/$mode"
  for i in $(seq 1 "$count"); do
    if [[ "$mode" == "cold" ]]; then
      "$wineserver" -k >/dev/null 2>&1 || true
      sleep 3
    fi
    log="$outdir/$mode/run-$i.log"
    echo "[$mode $i/$count] $ALLOY_SCENE_CMD"
    ec=0
    bash -c "$ALLOY_SCENE_CMD" >"$log" 2>&1 || ec=$?
    echo "$ec" >"${log%.log}.exit"
    parse_log "$log" >"${log%.log}.json"
  done
}

# aggregate <dir> — merge a group's per-run JSONs into one summary object
aggregate() {
  jq -s '
    def med: sort | if length == 0 then null else .[(length / 2) | floor] end;
    {
      runs: length,
      clean_exits: [.[] | select(.exit_code == 0)] | length,
      anchor_passes: [.[] | select(.anchor_pass)] | length,
      commit_steps_total: ([.[].commit_steps] | add) // 0,
      first_frame_ms: {min: ([.[].first_frame_ms] | min), median: ([.[].first_frame_ms] | med), max: ([.[].first_frame_ms] | max)},
      p50_ms_median: ([.[].frame_ms.p50] | med),
      p95_ms_range: {min: ([.[].frame_ms.p95] | min), max: ([.[].frame_ms.p95] | max)},
      fps_mean_range: {min: ([.[].fps_mean] | min), max: ([.[].fps_mean] | max)},
      working_set_end_mb_max: ([.[].memory_mb.working_set_end] | max),
      pagefile_delta_mb_max: ([.[].memory_mb.pagefile_delta] | max)
    }' "$@"
}

agg_dir() { # agg_dir <dir> — aggregate a group dir, {} when empty
  local files=("$1"/*.json)
  if [[ -e "${files[0]}" ]]; then
    aggregate "${files[@]}"
  else
    echo "{}"
  fi
}

report() {
  local outdir="$1" cold_agg warm_agg summary
  cold_agg=$(agg_dir "$outdir/cold")
  warm_agg=$(agg_dir "$outdir/warm")
  echo "# Scene benchmark report"
  echo
  echo "| metric | cold | warm |"
  echo "| --- | --- | --- |"
  summary=$(jq -n --argjson cold "$cold_agg" --argjson warm "$warm_agg" '
    def cell(v): if v == null then "—" else (v | tostring) end;
    def row(name; c; w): "| \(name) | \(cell(c)) | \(cell(w)) |";
    [
      row("runs (clean exits)"; "\($cold.runs // 0) (\($cold.clean_exits // 0))"; "\($warm.runs // 0) (\($warm.clean_exits // 0))"),
      row("anchor passes"; $cold.anchor_passes; $warm.anchor_passes),
      row("first frame ms (min/med/max)"; "\($cold.first_frame_ms.min)/\($cold.first_frame_ms.median)/\($cold.first_frame_ms.max)"; "\($warm.first_frame_ms.min)/\($warm.first_frame_ms.median)/\($warm.first_frame_ms.max)"),
      row("frame p50 ms (median)"; $cold.p50_ms_median; $warm.p50_ms_median),
      row("frame p95 ms (range)"; "\($cold.p95_ms_range.min)-\($cold.p95_ms_range.max)"; "\($warm.p95_ms_range.min)-\($warm.p95_ms_range.max)"),
      row("fps mean (range)"; "\($cold.fps_mean_range.min)-\($cold.fps_mean_range.max)"; "\($warm.fps_mean_range.min)-\($warm.fps_mean_range.max)"),
      row("working set end MB (max)"; $cold.working_set_end_mb_max; $warm.working_set_end_mb_max),
      row("pagefile delta MB (max)"; $cold.pagefile_delta_mb_max; $warm.pagefile_delta_mb_max),
      row("commit steps (anomaly)"; $cold.commit_steps_total; $warm.commit_steps_total)
    ] | .[]' -r)
  echo "$summary"
}

selftest() {
  local fixture expected actual name fail=0
  for fixture in "$HERE"/fixtures/*.log; do
    name=$(basename "$fixture" .log)
    expected="$HERE/fixtures/$name.json"
    actual=$(parse_log "$fixture" | jq -S .)
    if [[ "$actual" == "$(jq -S . "$expected")" ]]; then
      echo "selftest $name: OK"
    else
      echo "selftest $name: MISMATCH"
      diff <(jq -S . "$expected") <(echo "$actual") || true
      fail=1
    fi
  done
  return "$fail"
}

case "${1:-}" in
  run)
    [[ -n "${ALLOY_SCENE_CMD:-}" ]] || {
      echo "ALLOY_SCENE_CMD is not set"
      exit 1
    }
    outdir="${2:?usage: scene-bench.sh run <outdir> [n_cold] [n_warm]}"
    run_group "$outdir" cold "${3:-3}"
    run_group "$outdir" warm "${4:-5}"
    report "$outdir"
    ;;
  parse)
    parse_log "${2:?usage: scene-bench.sh parse <run.log>}"
    ;;
  report)
    report "${2:?usage: scene-bench.sh report <outdir>}"
    ;;
  selftest)
    selftest
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
