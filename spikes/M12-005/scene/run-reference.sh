#!/usr/bin/env bash
# Run the M12-005 reference scene through CrossOver's D3DMetal lab provider.
# Author: Timur Isaev
set -euo pipefail

scene_root="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$scene_root/../../.." && pwd)"
work_dir="$repo_root/spikes/M12-005/work"
cx_root="${CX_ROOT:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
bottle="$work_dir/crossover-d3dmetal"
setup="$cx_root/share/crossover/bottle_templates/win11_64/setup"
wine="$cx_root/bin/wine"
d3dmetal="$cx_root/lib64/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal"
cx_info="$cx_root/../../Info.plist"
backend_trace="$work_dir/backend-trace.log"
backend_env="WINED3DMETAL=1 CX_GRAPHICS_BACKEND=d3dmetal WINEDXVK=0"

if [[ ! -x "$wine" || ! -x "$setup" || ! -f "$d3dmetal" ]]; then
  printf 'CrossOver with D3DMetal is not installed at %s\n' "$cx_root" >&2
  exit 1
fi

"$scene_root/build.sh"

if [[ ! -d "$bottle/drive_c/windows/system32" ]]; then
  mkdir -p "$bottle"
  env \
    CX_ROOT="$cx_root" \
    CX_BOTTLE="crossover-d3dmetal" \
    CX_BOTTLE_PATH="$work_dir" \
    WINEPREFIX="$bottle" \
    "$setup" --create --description "Alloy M12 D3DMetal reference"
fi

{
  printf 'crossover_version: %s\n' \
    "$(plutil -extract CFBundleShortVersionString raw "$cx_info")"
  printf 'provider_product: %s\n' "$(strings "$d3dmetal" | sed -n 's/^@(#)PROGRAM:/PROGRAM:/p' | head -1)"
  printf 'provider_sha256: '
  shasum -a 256 "$d3dmetal" | awk '{print $1}'

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
} 2>&1 | tee "$work_dir/latest.log"
