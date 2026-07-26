#!/bin/bash
# Metal12 shader corpus: HLSL -> DXIL -> MSL -> GPU -> CPU reference.
# Author: Timur Isaev
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

RUNTIME="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$RUNTIME/../.." && pwd)"
CORPUS="$RUNTIME/Tests/ShaderCorpus"
SHADER_TOOLS="$RUNTIME/ShaderTools"
BUILD="$RUNTIME/build"
SHADER_BUILD="$BUILD/shaders"
MODULE_CACHE="$BUILD/module-cache"
MANIFEST="$CORPUS/cases.json"
RUN_MANIFEST="$SHADER_BUILD/RUN-MANIFEST.txt"

COMMON_GIT_DIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
SHARED_ROOT="${ALLOY_SHARED_ROOT:-$(dirname "$COMMON_GIT_DIR")}"
ALLOY_WINE="${ALLOY_WINE:-$SHARED_ROOT/spikes/WINE-001/work/build-2/wine}"
ALLOY_FEX_PREFIX="${ALLOY_FEX_PREFIX:-$SHARED_ROOT/spikes/CPU-001/work/fex-runtime-probe}"
DXC="${ALLOY_DXC:-$SHARED_ROOT/tools/toolchains/dxc-v1.9.2602.24/bin/x64/dxc.exe}"
TOOLCHAIN_BIN="$SHARED_ROOT/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin"
export PATH="$TOOLCHAIN_BIN:$PATH"

mkdir -p "$SHADER_BUILD" "$MODULE_CACHE"
HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
RUNTIME_TREE="$(git -C "$ROOT" rev-parse HEAD:runtime/metal12)"
TEMPORARY_RUN_MANIFEST="$(mktemp "$SHADER_BUILD/.RUN-MANIFEST.txt.XXXXXX")"
{
  printf 'schema: com.alloy.metal12.shader-corpus.v1\n'
  printf 'author: Timur Isaev\n'
  printf 'status: in-progress\n'
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
} >"$TEMPORARY_RUN_MANIFEST"
mv -f "$TEMPORARY_RUN_MANIFEST" "$RUN_MANIFEST"

if [[ ! -x $ALLOY_WINE ]]; then
  echo "missing Wine loader: $ALLOY_WINE" >&2
  exit 2
fi
if [[ ! -d $ALLOY_FEX_PREFIX/prefix-gui ]]; then
  echo "missing FEX probe prefix: $ALLOY_FEX_PREFIX/prefix-gui" >&2
  exit 2
fi
if [[ ! -f $DXC ]]; then
  echo "missing dxc: $DXC" >&2
  exit 2
fi
for required_tool in clang jq python3 rg shasum xcrun; do
  if ! command -v "$required_tool" >/dev/null; then
    echo "missing tool: $required_tool" >&2
    exit 2
  fi
done
all_processes=
if ! all_processes="$(ps aux 2>/dev/null)"; then
  echo "could not inspect the shared Wine/FEX loader" >&2
  exit 2
fi
shared_processes="$(
  printf '%s\n' "$all_processes" |
    rg '[A]lloy/spikes/WINE-001/work/build-2' || true
)"
busy_processes="$(printf '%s\n' "$shared_processes" | rg -v '/server/wineserver$' || true)"
if [[ -n $busy_processes ]]; then
  echo "shared Wine/FEX loader is busy; wait before starting the dxc batch:" >&2
  printf '%s\n' "$busy_processes" >&2
  exit 2
fi

run_dxc() {
  (
    cd "$ALLOY_FEX_PREFIX"
    WINEPREFIX="$ALLOY_FEX_PREFIX/prefix-gui" \
      DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
      WINEDLLOVERRIDES="xtajit64=n" \
      "$ALLOY_WINE" "$DXC" "$@"
  )
}

echo "== build shader runner"
"$RUNTIME/build.sh"
"$BUILD/lowering_api_test"

texture_width="$(jq -r '.texture.width' "$MANIFEST")"
texture_height="$(jq -r '.texture.height' "$MANIFEST")"
texture_mip_levels="$(jq -r '.texture.mip_levels' "$MANIFEST")"
threads="$(jq -r '.threads' "$MANIFEST")"
texture_fixture="$SHADER_BUILD/texture-rgba32f.bin"
python3 "$SHADER_TOOLS/verify_shader_output.py" prepare-texture \
  "$MANIFEST" "$texture_fixture"

dxc_hash="$(shasum -a 256 "$DXC" | awk '{print $1}')"
pass=0
reject=0
fail=0
passed_names=" "

echo "== compile, lower, and execute corpus"
while IFS= read -r shader_name; do
  hlsl="$CORPUS/$shader_name.hlsl"
  dxil="$SHADER_BUILD/$shader_name.dxil"
  disassembly="$SHADER_BUILD/$shader_name.ll"
  compile_key_path="$SHADER_BUILD/$shader_name.compile-key"
  dxc_log="$SHADER_BUILD/$shader_name.dxc.log"
  lower_log="$SHADER_BUILD/$shader_name.lower.log"
  expect="$(jq -r --arg name "$shader_name" \
    '.cases[] | select(.name == $name) | .expect' "$MANIFEST")"

  if [[ ! -f $hlsl ]]; then
    echo "$shader_name: missing HLSL fixture" >&2
    fail=$((fail + 1))
    continue
  fi

  source_hash="$(shasum -a 256 "$hlsl" | awk '{print $1}')"
  compile_key="$source_hash:$dxc_hash:cs_6_0:main"
  if [[ -s $dxil && -s $disassembly && -f $compile_key_path ]] &&
    [[ $(<"$compile_key_path") == "$compile_key" ]]; then
    echo "$shader_name: cached DXIL"
  else
    if run_dxc -T cs_6_0 -E main -Fo "$dxil" -Fc "$disassembly" "$hlsl" \
      >"$dxc_log" 2>&1; then
      printf '%s\n' "$compile_key" >"$compile_key_path"
      echo "$shader_name: dxc compiled once"
    else
      echo "$shader_name: dxc failed (see $dxc_log)" >&2
      fail=$((fail + 1))
      continue
    fi
  fi

  if "$BUILD/metal12_lower" "$dxil" "$disassembly" "$SHADER_BUILD" \
    >"$lower_log" 2>&1; then
    if [[ $expect == reject ]]; then
      echo "$shader_name: unexpectedly lowered; rejection was required" >&2
      fail=$((fail + 1))
      continue
    fi
  else
    if [[ $expect != reject ]]; then
      echo "$shader_name: lowering failed" >&2
      sed 's/^/  /' "$lower_log" >&2
      fail=$((fail + 1))
      continue
    fi
    diagnostic="$(jq -r --arg name "$shader_name" \
      '.cases[] | select(.name == $name) | .diagnostic' "$MANIFEST")"
    if rg -Fq "$diagnostic" "$lower_log"; then
      echo "$shader_name: rejected with named diagnostic ($diagnostic)"
      reject=$((reject + 1))
    else
      echo "$shader_name: rejected without required diagnostic $diagnostic" >&2
      sed 's/^/  /' "$lower_log" >&2
      fail=$((fail + 1))
    fi
    continue
  fi

  if ! xcrun -sdk macosx metal -fmodules-cache-path="$MODULE_CACHE" -O2 \
    "$SHADER_BUILD/$shader_name.metal" \
    -o "$SHADER_BUILD/$shader_name.metallib"; then
    echo "$shader_name: Metal compilation failed" >&2
    fail=$((fail + 1))
    continue
  fi

  inputs=("$SHADER_BUILD/$shader_name".u*.in.bin)
  if [[ ! -f ${inputs[0]} ]]; then
    echo "$shader_name: lowerer generated no buffer fixture" >&2
    fail=$((fail + 1))
    continue
  fi

  width_path="$SHADER_BUILD/$shader_name.width"
  runner_args=(
    "$SHADER_BUILD/$shader_name.metallib"
    "$shader_name"
    "$threads"
  )
  kind="$(jq -r --arg name "$shader_name" \
    '.cases[] | select(.name == $name) | .kind' "$MANIFEST")"
  if [[ $kind == texture ]]; then
    sampler="$(jq -r --arg name "$shader_name" \
      '.cases[] | select(.name == $name) | .sampler' "$MANIFEST")"
    runner_args+=(
      --texture "$sampler" "$texture_width" "$texture_height" "$texture_mip_levels"
      "$texture_fixture"
    )
  fi
  runner_args+=(--thread-width-out "$width_path")
  runner_args+=("${inputs[@]}")

  if ! "$BUILD/ShaderRunner" "${runner_args[@]}"; then
    echo "$shader_name: GPU execution failed" >&2
    fail=$((fail + 1))
    continue
  fi
  if python3 "$SHADER_TOOLS/verify_shader_output.py" verify \
    "$MANIFEST" "$shader_name" "$SHADER_BUILD" "$width_path"; then
    pass=$((pass + 1))
    passed_names+="$shader_name "
  else
    fail=$((fail + 1))
  fi
done < <(jq -r '.cases[].name' "$MANIFEST")

required_passes=(
  add_cs
  clamp_cs
  intops_cs
  select_cs
  twobuf_cs
  texture_point_cs
  texture_bilinear_cs
  wave_cs
  wave_lane_index_cs
  wave_prefix_sum_cs
)
for shader_name in "${required_passes[@]}"; do
  if [[ $passed_names != *" $shader_name "* ]]; then
    echo "required supported case did not pass: $shader_name" >&2
    fail=$((fail + 1))
  fi
done

echo "corpus: $pass pass, $reject rejected-with-diagnostic, $fail fail"
if ((fail == 0 && pass >= 10 && reject >= 1)); then
  CURRENT_HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
  CURRENT_RUNTIME_TREE="$(git -C "$ROOT" rev-parse HEAD:runtime/metal12)"
  CURRENT_RUNTIME_STATUS="$(
    git -C "$ROOT" status --porcelain=v1 --untracked-files=normal -- runtime/metal12
  )"
  if [[ $CURRENT_HEAD_COMMIT != "$HEAD_COMMIT" ||
    $CURRENT_RUNTIME_TREE != "$RUNTIME_TREE" ||
    -n $CURRENT_RUNTIME_STATUS ]]; then
    echo "runtime source changed during shader-corpus execution" >&2
    exit 1
  fi
  BUILD_MANIFEST_SHA256="$(
    shasum -a 256 "$BUILD/BUILD-MANIFEST.txt" | awk '{print $1}'
  )"
  WINE_SHA256="$(shasum -a 256 "$ALLOY_WINE" | awk '{print $1}')"
  SHADER_ARTIFACTS="$(
    find "$SHADER_BUILD" -maxdepth 1 -type f \
      ! -name 'RUN-MANIFEST.txt' \
      ! -name '.RUN-MANIFEST.txt.*' \
      ! -name '.am12-publish-*.lock' |
      LC_ALL=C sort
  )"
  TEMPORARY_RUN_MANIFEST="$(mktemp "$SHADER_BUILD/.RUN-MANIFEST.txt.XXXXXX")"
  {
    printf 'schema: com.alloy.metal12.shader-corpus.v1\n'
    printf 'author: Timur Isaev\n'
    printf 'status: complete\n'
    printf 'supported_passes: %s\n' "$pass"
    printf 'named_rejections: %s\n' "$reject"
    printf 'failures: %s\n' "$fail"
    printf 'head_commit: %s\n' "$HEAD_COMMIT"
    printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
    printf 'build_manifest_sha256: %s\n' "$BUILD_MANIFEST_SHA256"
    printf 'producer_sha256: %s\n' \
      "$(shasum -a 256 "$RUNTIME/run-shader-corpus.sh" | awk '{print $1}')"
    printf 'dxc_sha256: %s\n' "$dxc_hash"
    printf 'wine_sha256: %s\n' "$WINE_SHA256"
    while IFS= read -r shader_artifact; do
      [[ -n $shader_artifact ]] || continue
      shader_artifact_sha256="$(
        shasum -a 256 "$shader_artifact" | awk '{print $1}'
      )"
      printf 'artifact_sha256: %s  shaders/%s\n' \
        "$shader_artifact_sha256" "$(basename "$shader_artifact")"
    done <<<"$SHADER_ARTIFACTS"
  } >"$TEMPORARY_RUN_MANIFEST"
  mv -f "$TEMPORARY_RUN_MANIFEST" "$RUN_MANIFEST"
  echo "m12-003 shader path ok"
  echo "metal12 shader corpus ok"
else
  exit 1
fi
