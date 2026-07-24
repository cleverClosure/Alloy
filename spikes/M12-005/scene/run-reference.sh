#!/usr/bin/env bash
# Run the M12-005 reference scene through CrossOver's D3DMetal lab provider.
# Author: Timur Isaev
set -euo pipefail

scene_root="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$scene_root/../../.." && pwd)"
work_dir="$repo_root/spikes/M12-005/work"
cx_root="${CX_ROOT:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
setup="$cx_root/share/crossover/bottle_templates/win11_64/setup"
wine="$cx_root/bin/wine"
cx_info="$cx_root/../../Info.plist"
provider_root="${GPTK_PROVIDER_ROOT:-$work_dir/gptk4-provider}"

if [[ -d "$provider_root/lib" ]]; then
  provider_lib="$provider_root/lib"
  provider_source="task-local GPTK package"
  bottle_name="${M12_BOTTLE_NAME:-crossover-gptk4}"
else
  provider_lib="$cx_root/lib64/apple_gptk"
  provider_source="CrossOver-bundled fallback"
  bottle_name="${M12_BOTTLE_NAME:-crossover-d3dmetal}"
fi

bottle="$work_dir/$bottle_name"
d3dmetal="$provider_lib/external/D3DMetal.framework/Versions/A/D3DMetal"
version_plist="$provider_lib/external/D3DMetal.framework/Versions/A/Resources/version.plist"
libd3dshared="$provider_lib/external/libd3dshared.dylib"
d3d12_dll="$provider_lib/wine/x86_64-windows/d3d12.dll"
provider_winedllpath="$provider_lib/wine/x86_64-windows"
backend_trace="$work_dir/$bottle_name-backend-trace.log"
latest_log="$work_dir/$bottle_name-latest.log"
backend_env="WINED3DMETAL=1 CX_GRAPHICS_BACKEND=d3dmetal WINEDXVK=0"
backend_env+=" CX_APPLEGPTK_LIBD3DSHARED_PATH=$libd3dshared"
backend_env+=" WINEDLLPATH=$provider_winedllpath:$cx_root/lib/wine/x86_64-windows:$cx_root/lib/wine"

if [[ ! -x "$wine" || ! -x "$setup" || ! -f "$cx_info" ]]; then
  printf 'CrossOver is not installed at %s\n' "$cx_root" >&2
  exit 1
fi

if [[ ! -f "$d3dmetal" || ! -f "$version_plist" || ! -f "$libd3dshared" ||
  ! -f "$d3d12_dll" ]]; then
  printf 'D3DMetal provider is incomplete at %s\n' "$provider_lib" >&2
  exit 1
fi

if [[ "$provider_lib" == *[[:space:]]* || "$cx_root" == *[[:space:]]* ]]; then
  printf 'CrossOver and GPTK provider paths may not contain whitespace.\n' >&2
  exit 1
fi

"$scene_root/build.sh"

if [[ ! -d "$bottle/drive_c/windows/system32" ]]; then
  mkdir -p "$bottle"
  env \
    CX_ROOT="$cx_root" \
    CX_BOTTLE="$bottle_name" \
    CX_BOTTLE_PATH="$work_dir" \
    WINEPREFIX="$bottle" \
    "$setup" --create --description "Alloy M12 GPTK reference"
fi

{
  printf 'crossover_version: %s\n' \
    "$(plutil -extract CFBundleShortVersionString raw "$cx_info")"
  printf 'provider_source: %s\n' "$provider_source"
  printf 'provider_version: %s\n' \
    "$(plutil -extract CFBundleShortVersionString raw "$version_plist")"
  printf 'provider_product: %s\n' "$(strings "$d3dmetal" | sed -n 's/^@(#)PROGRAM:/PROGRAM:/p' | head -1)"
  printf 'd3dmetal_sha256: '
  shasum -a 256 "$d3dmetal" | awk '{print $1}'
  printf 'libd3dshared_sha256: '
  shasum -a 256 "$libd3dshared" | awk '{print $1}'
  printf 'd3d12_dll_sha256: '
  shasum -a 256 "$d3d12_dll" | awk '{print $1}'
  if [[ -f "$provider_root/manifest.txt" ]]; then
    printf 'provider_manifest_sha256: '
    shasum -a 256 "$provider_root/manifest.txt" | awk '{print $1}'
  fi

  "$wine" \
    --bottle "$bottle" \
    --no-gui \
    --debugmsg +process \
    --env "$backend_env" \
    cmd.exe /c exit >"$backend_trace" 2>&1
  rg -m 1 'set_graphics_backend using d3dmetal as the graphics backend' "$backend_trace"

  "$wine" \
    --bottle "$bottle" \
    --no-gui \
    --env "$backend_env" \
    --workdir "$work_dir" \
    "$work_dir/d3d12_reference.exe"

  sips -s format png \
    "$work_dir/m12-gptk-reference.bmp" \
    --out "$work_dir/m12-gptk-reference.png" >/dev/null
  printf 'artifact_sha256: '
  shasum -a 256 "$work_dir/m12-gptk-reference.png" | awk '{print $1}'
} 2>&1 | tee "$latest_log"
