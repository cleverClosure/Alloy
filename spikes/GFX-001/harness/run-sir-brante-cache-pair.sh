#!/usr/bin/env bash
# Cold/warm shader-cache pair for the GFX-001 Sir Brante title scene.
# Author: Timur Isaev

set -euo pipefail

usage() {
  cat <<'EOF'
usage: run-sir-brante-cache-pair.sh PAIR_ID DURATION_SECONDS

Required environment is the same as launch-sir-brante.sh. The pair uses one
previously absent cache directory: cold starts with it empty, warm reuses it and
the running wineserver. Results are written beneath ALLOY_STORE_WORK/pairs/.
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
launcher="$store_root/runtime-launch/launch-sir-brante.sh"
analyzer="$script_dir/analyze-title-metrics.py"
work_root=${ALLOY_STORE_WORK:-"$store_root/work/runtime-launch"}
wine_build=${ALLOY_WINE_BUILD:?ALLOY_WINE_BUILD is required}
pair_root="$work_root/pairs/$pair_id"
cache_path="$pair_root/cache"
metrics_dir="$pair_root/metrics"

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
trap stop_server EXIT

mkdir -p "$cache_path" "$metrics_dir"

ALLOY_DXMT_SHADER_CACHE_PATH="$cache_path" \
  ALLOY_DXMT_METRICS_PATH="$metrics_dir/prepare.tsv" \
  ALLOY_RUN_LABEL="$pair_id-prepare" \
  "$launcher" prepare

# Both runs reuse the prepared runtime. A stale DXMT install does not fail them:
# D3D11 falls back to Wine's builtin provider and the pair measures that (#35).
"$script_dir/dxmt-install.sh" check "$work_root/dxmt-install" "$wine_build"

ALLOY_DXMT_SHADER_CACHE_PATH="$cache_path" \
  ALLOY_DXMT_METRICS_PATH="$metrics_dir/cold.tsv" \
  ALLOY_RUN_LABEL="$pair_id-cold" \
  "$launcher" graphical --reuse-runtime --duration "$duration" --preserve-server

ALLOY_DXMT_SHADER_CACHE_PATH="$cache_path" \
  ALLOY_DXMT_METRICS_PATH="$metrics_dir/warm.tsv" \
  ALLOY_RUN_LABEL="$pair_id-warm" \
  "$launcher" graphical --reuse-runtime --duration "$duration"

python3 -B "$analyzer" "$metrics_dir/cold.tsv" \
  --label "sir-brante-$pair_id-cold" \
  --output "$pair_root/cold.json"
python3 -B "$analyzer" "$metrics_dir/warm.tsv" \
  --label "sir-brante-$pair_id-warm" \
  --output "$pair_root/warm.json"

echo "pair complete: $pair_root"
