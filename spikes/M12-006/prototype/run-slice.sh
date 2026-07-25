#!/bin/bash
# M12-006 vertical-slice driver: the reference scene's HLSL -> (dxc under
# Wine/FEX) -> DXIL -> lowered MSL -> metallib -> rendered on Metal through the
# M12-001/002/004 models -> digest and timings compared against M12-005.
# Author: Tim Isaev
set -u

SPIKE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SPIKE/../.." && pwd)"
WORK="$SPIKE/work"
PROTO="$SPIKE/prototype"

# The Wine build and FEX probe prefix are gitignored machine state; a worktree
# that has never built them has to borrow another checkout's.
ALLOY_WINE=${ALLOY_WINE:-"$ROOT/spikes/WINE-001/work/build-2/wine"}
ALLOY_FEX_PREFIX=${ALLOY_FEX_PREFIX:-"$ROOT/spikes/CPU-001/work/fex-runtime-probe"}
DXC=${ALLOY_DXC:-"$ROOT/tools/toolchains/dxc-v1.9.2602.24/bin/x64/dxc.exe"}

if [ ! -x "$ALLOY_WINE" ]; then
  echo "missing Wine loader: $ALLOY_WINE" >&2
  exit 2
fi
if [ ! -f "$DXC" ]; then
  echo "missing dxc: $DXC — run tools/fetch-deps.sh" >&2
  exit 2
fi
mkdir -p "$WORK"

run_dxc() {
  (cd "$ALLOY_FEX_PREFIX" && WINEPREFIX="$ALLOY_FEX_PREFIX/prefix-gui" \
    DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
    WINEDLLOVERRIDES="xtajit64=n" \
    "$ALLOY_WINE" "$DXC" "$@") 2>>"$WORK/dxc-stderr.log"
}

HLSL="$PROTO/reference_scene.hlsl"
echo "== HLSL -> DXIL"
run_dxc -T vs_6_0 -E vs_main -Fo "$WORK/vs.dxil" "$HLSL"
run_dxc -T vs_6_0 -E vs_main -Fc "$WORK/vs.ll" "$HLSL"
run_dxc -T ps_6_0 -E ps_main -Fo "$WORK/ps.dxil" "$HLSL"
run_dxc -T ps_6_0 -E ps_main -Fc "$WORK/ps.ll" "$HLSL"
for stage in vs ps; do
  if [ ! -s "$WORK/$stage.dxil" ] || [ ! -s "$WORK/$stage.ll" ]; then
    echo "dxc produced no $stage output; see $WORK/dxc-stderr.log" >&2
    exit 1
  fi
done

echo "== DXIL -> MSL"
for stage in vs ps; do
  python3 "$ROOT/spikes/M12-003/prototype/dxil_to_msl.py" \
    "$WORK/$stage.dxil" "$WORK/$stage.ll" "$WORK" || exit 1
done

echo "== MSL -> metallib"
for stage in vs ps; do
  xcrun -sdk macosx metal -O2 -c "$WORK/$stage.metal" -o "$WORK/$stage.air" || exit 1
done
xcrun -sdk macosx metallib "$WORK/vs.air" "$WORK/ps.air" -o "$WORK/scene.metallib" || exit 1

echo "== build slice"
clang -fobjc-arc -O2 -o "$WORK/vertical_slice" "$PROTO/vertical_slice.m" \
  -framework Metal -framework Foundation || exit 1

echo "== render"
(cd "$WORK" && ./vertical_slice scene.metallib) || exit 1

echo "== compare against the M12-005 baseline"
python3 "$PROTO/compare_reference.py" \
  "$ROOT/spikes/M12-005/results/2026-07-25-gptk4-reference.png" \
  "$WORK/m12-metal12-slice.bmp"
