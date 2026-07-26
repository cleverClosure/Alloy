#!/usr/bin/env bash
# Build the reference shaders once, then prove live/capture/replay/presentation.
# Author: Timur Isaev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
WORK="$ROOT/build/reference"
HLSL="$ROOT/Tests/Fixtures/reference_scene.hlsl"
LOWERER="$ROOT/ShaderTools/dxil_to_msl.py"
COMPILE_KEY_PATH="$WORK/reference-shaders.compile-key"
PRESENT=0
COMMON_GIT_DIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)"
SHARED_ROOT="${ALLOY_SHARED_ROOT:-$(dirname "$COMMON_GIT_DIR")}"

if [[ ${1:-} == --present ]]; then
  PRESENT=1
elif (($#)); then
  printf 'usage: %s [--present]\n' "$0" >&2
  exit 2
fi

ALLOY_WINE=${ALLOY_WINE:-"$SHARED_ROOT/spikes/WINE-001/work/build-2/wine"}
ALLOY_FEX_PREFIX=${ALLOY_FEX_PREFIX:-"$SHARED_ROOT/spikes/CPU-001/work/fex-runtime-probe"}
ALLOY_DXC=${ALLOY_DXC:-"$SHARED_ROOT/tools/toolchains/dxc-v1.9.2602.24/bin/x64/dxc.exe"}
export PATH="$SHARED_ROOT/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin:$PATH"

if [[ ! -x $ALLOY_WINE || ! -d $ALLOY_FEX_PREFIX/prefix-gui || ! -f $ALLOY_DXC ]]; then
  cat >&2 <<EOF
missing shared compiler runtime. Set:
  ALLOY_WINE=<checkout>/spikes/WINE-001/work/build-2/wine
  ALLOY_FEX_PREFIX=<checkout>/spikes/CPU-001/work/fex-runtime-probe
  ALLOY_DXC=<checkout>/tools/toolchains/dxc-v1.9.2602.24/bin/x64/dxc.exe
EOF
  exit 2
fi
if [[ ! -f $LOWERER ]]; then
  printf 'missing canonical lowerer: %s\n' "$LOWERER" >&2
  exit 2
fi

mkdir -p "$WORK"
"$ROOT/build.sh"
"$ROOT/build/lowering_api_test"

run_dxc() {
  (
    cd "$ALLOY_FEX_PREFIX"
    WINEPREFIX="$ALLOY_FEX_PREFIX/prefix-gui" \
      DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
      WINEDLLOVERRIDES="xtajit64=n" \
      "$ALLOY_WINE" "$ALLOY_DXC" "$@"
  ) 2>>"$WORK/dxc-stderr.log"
}

VS_DXIL_ARGS=(-T vs_6_0 -E vs_main -Fo "$WORK/vs.dxil" "$HLSL")
VS_LL_ARGS=(-T vs_6_0 -E vs_main -Fc "$WORK/vs.ll" "$HLSL")
PS_DXIL_ARGS=(-T ps_6_0 -E ps_main -Fo "$WORK/ps.dxil" "$HLSL")
PS_LL_ARGS=(-T ps_6_0 -E ps_main -Fc "$WORK/ps.ll" "$HLSL")

DXC_DIRECTORY="$(cd "$(dirname "$ALLOY_DXC")" && pwd -P)"
DXC_RESOLVED_PATH="$DXC_DIRECTORY/$(basename "$ALLOY_DXC")"
HLSL_SHA256="$(shasum -a 256 "$HLSL" | awk '{print $1}')"
DXC_SHA256="$(shasum -a 256 "$ALLOY_DXC" | awk '{print $1}')"
REFERENCE_COMPILE_KEY="$(
  {
    printf '%s\0' \
      'alloy-metal12-reference-shader-cache-v1' \
      'hlsl-path' "$HLSL" \
      'hlsl-sha256' "$HLSL_SHA256" \
      'dxc-configured-path' "$ALLOY_DXC" \
      'dxc-resolved-path' "$DXC_RESOLVED_PATH" \
      'dxc-sha256' "$DXC_SHA256" \
      'wine-path' "$ALLOY_WINE" \
      'fex-prefix' "$ALLOY_FEX_PREFIX"
    printf '%s\0' 'vs-dxil-args' "${VS_DXIL_ARGS[@]}"
    printf '%s\0' 'vs-ll-args' "${VS_LL_ARGS[@]}"
    printf '%s\0' 'ps-dxil-args' "${PS_DXIL_ARGS[@]}"
    printf '%s\0' 'ps-ll-args' "${PS_LL_ARGS[@]}"
  } | shasum -a 256 | awk '{print $1}'
)"

CACHED_COMPILE_KEY=
if [[ -f $COMPILE_KEY_PATH ]]; then
  CACHED_COMPILE_KEY="$(<"$COMPILE_KEY_PATH")"
fi

if [[ ! -s $WORK/vs.dxil || ! -s $WORK/vs.ll ||
  ! -s $WORK/ps.dxil || ! -s $WORK/ps.ll ||
  $CACHED_COMPILE_KEY != "$REFERENCE_COMPILE_KEY" ]]; then
  if ps aux | rg '[A]lloy/spikes/WINE-001/work/build-2' | rg -qv '/server/wineserver$'; then
    printf 'shared Wine/FEX runtime is busy; wait before compiling shaders\n' >&2
    exit 3
  fi
  rm -f "$COMPILE_KEY_PATH" \
    "$WORK/vs.dxil" "$WORK/vs.ll" "$WORK/ps.dxil" "$WORK/ps.ll"
  : >"$WORK/dxc-stderr.log"
  printf '== HLSL -> DXIL (one cached batch)\n'
  run_dxc "${VS_DXIL_ARGS[@]}"
  run_dxc "${VS_LL_ARGS[@]}"
  run_dxc "${PS_DXIL_ARGS[@]}"
  run_dxc "${PS_LL_ARGS[@]}"
  if [[ ! -s $WORK/vs.dxil || ! -s $WORK/vs.ll ||
    ! -s $WORK/ps.dxil || ! -s $WORK/ps.ll ]]; then
    printf 'dxc reported success without producing all reference shader artifacts\n' >&2
    exit 1
  fi
  TEMPORARY_COMPILE_KEY="$(mktemp "$WORK/.reference-shaders.compile-key.XXXXXX")"
  printf '%s\n' "$REFERENCE_COMPILE_KEY" >"$TEMPORARY_COMPILE_KEY"
  mv -f "$TEMPORARY_COMPILE_KEY" "$COMPILE_KEY_PATH"
else
  printf '== HLSL -> DXIL (using cached batch)\n'
fi

printf '== DXIL -> MSL -> metallib\n'
for stage in vs ps; do
  "$ROOT/build/metal12_lower" "$WORK/$stage.dxil" "$WORK/$stage.ll" "$WORK"
  xcrun -sdk macosx metal -O2 -c "$WORK/$stage.metal" -o "$WORK/$stage.air"
done
if ! rg -Fq 'device const ulong *am12_descriptor_page [[buffer(0)]]' "$WORK/ps.metal" ||
  ! rg -Fq 'am12_descriptor_page[0]' "$WORK/ps.metal" ||
  rg -Fq 'constant float4 *cb0 [[buffer(0)]]' "$WORK/ps.metal"; then
  printf 'fragment MSL did not preserve the descriptor-page ABI\n' >&2
  exit 1
fi
xcrun -sdk macosx metallib "$WORK/vs.air" "$WORK/ps.air" -o "$WORK/scene.metallib"

printf '== public command rejection matrix\n'
"$ROOT/build/command_validation_test" "$WORK/scene.metallib" |
  tee "$WORK/command-validation.log"

printf '== live path\n'
"$ROOT/build/vertical_slice" "$WORK/scene.metallib" \
  --output "$WORK/live.bmp" | tee "$WORK/live.log"

printf '== capture path A\n'
"$ROOT/build/vertical_slice" "$WORK/scene.metallib" \
  --output "$WORK/capture-a.bmp" --capture "$WORK/reference-a.am12" |
  tee "$WORK/capture-a.log"

printf '== capture path B\n'
"$ROOT/build/vertical_slice" "$WORK/scene.metallib" \
  --output "$WORK/capture-b.bmp" --capture "$WORK/reference-b.am12" |
  tee "$WORK/capture-b.log"

cmp "$WORK/live.bmp" "$WORK/capture-a.bmp"
cmp "$WORK/live.bmp" "$WORK/capture-b.bmp"
cmp "$WORK/reference-a.am12" "$WORK/reference-b.am12"

printf '== trace preflight mutation matrix\n'
"$ROOT/build/trace_validation_test" "$WORK/reference-a.am12" |
  tee "$WORK/trace-validation.log"

printf '== generic replay (10 fresh runtimes)\n'
"$ROOT/build/metal12_replay" "$WORK/reference-a.am12" "$WORK/replay.bmp" 10 |
  tee "$WORK/replay.log"
cmp "$WORK/live.bmp" "$WORK/replay.bmp"

printf '== GPTK answer-key comparison\n'
python3 "$REPO/spikes/M12-006/prototype/compare_reference.py" \
  "$REPO/spikes/M12-005/results/2026-07-25-gptk4-reference.png" \
  "$WORK/live.bmp" | tee "$WORK/gptk-compare.log"

if ((PRESENT)); then
  printf '== CAMetalLayer presentation\n'
  "$ROOT/build/vertical_slice" "$WORK/scene.metallib" \
    --output "$WORK/presented.bmp" --present | tee "$WORK/presented.log"
  cmp "$WORK/live.bmp" "$WORK/presented.bmp"
fi

printf 'reference trace gates: PASS\n'
