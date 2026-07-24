#!/usr/bin/env bash
# Install Apple's GPTK evaluation libraries into the isolated M12 lab.
# Author: Timur Isaev
set -euo pipefail

scene_root="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$scene_root/../../.." && pwd)"
work_dir="$repo_root/spikes/M12-005/work"
provider_dir="$work_dir/gptk4-provider"
gptk_dmg="${GPTK_DMG:-${1:-}}"
cx_root="${CX_ROOT:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
cx_info="$cx_root/../../Info.plist"

if [[ -z "$gptk_dmg" ]]; then
  printf 'usage: %s /path/to/Evaluation_environment_for_Windows_games.dmg\n' "$0" >&2
  exit 2
fi

if [[ ! -t 0 ]]; then
  printf 'The founder must run this installer interactively and accept Apple'\''s license personally.\n' >&2
  exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  printf 'GPTK requires an Apple silicon Mac.\n' >&2
  exit 1
fi

macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
if ((macos_major < 15)); then
  printf 'GPTK requires macOS 15 or newer; found %s.\n' "$macos_version" >&2
  exit 1
fi

if [[ ! -f "$gptk_dmg" ]]; then
  printf 'GPTK disk image not found: %s\n' "$gptk_dmg" >&2
  exit 1
fi

if [[ ! -x "$cx_root/bin/wine" || ! -f "$cx_info" ]]; then
  printf 'CrossOver is not installed at %s\n' "$cx_root" >&2
  exit 1
fi

mkdir -p "$work_dir"
install_tmp="$(mktemp -d "$work_dir/gptk-install.XXXXXX")"
mount_dir="$install_tmp/mount"
stage_dir="$install_tmp/provider"
mounted=0

cleanup() {
  if ((mounted)); then
    hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -f "$install_tmp/License.txt" ]]; then
    unlink "$install_tmp/License.txt"
  fi
  rmdir "$stage_dir" >/dev/null 2>&1 || true
  rmdir "$mount_dir" "$install_tmp" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$mount_dir" "$stage_dir"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$gptk_dmg" >/dev/null
mounted=1

license_file="$(find "$mount_dir" -maxdepth 3 -type f -name 'License.rtf' -print -quit)"
readme_file="$(find "$mount_dir" -maxdepth 3 -type f -name 'Read Me.rtf' -print -quit)"
redist_lib="$(find "$mount_dir" -maxdepth 4 -type d -path '*/redist/lib' -print -quit)"

if [[ -z "$license_file" || -z "$readme_file" || -z "$redist_lib" ]]; then
  printf 'The disk image does not contain the expected GPTK license, README, and redist/lib tree.\n' >&2
  exit 1
fi

textutil -convert txt -output "$install_tmp/License.txt" "$license_file"
less "$install_tmp/License.txt"

printf '\nType I ACCEPT to confirm that you personally accept Apple'\''s GPTK license\n'
printf 'and install this package for internal, non-commercial evaluation on this Mac: '
IFS= read -r acceptance
if [[ "$acceptance" != "I ACCEPT" ]]; then
  printf 'License not accepted; nothing was installed.\n' >&2
  exit 1
fi

ditto "$redist_lib" "$stage_dir/lib"
ditto "$license_file" "$stage_dir/License.rtf"
ditto "$readme_file" "$stage_dir/Read Me.rtf"

d3dmetal="$stage_dir/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
libd3dshared="$stage_dir/lib/external/libd3dshared.dylib"
d3d12_dll="$stage_dir/lib/wine/x86_64-windows/d3d12.dll"
d3d12_unix="$stage_dir/lib/wine/x86_64-unix/d3d12.so"
version_plist="$stage_dir/lib/external/D3DMetal.framework/Versions/A/Resources/version.plist"

if [[ ! -f "$d3dmetal" || ! -f "$libd3dshared" || ! -f "$d3d12_dll" ||
  ! -L "$d3d12_unix" || ! -f "$version_plist" ]]; then
  printf 'The staged GPTK provider is incomplete.\n' >&2
  exit 1
fi

package_name="$(basename "$gptk_dmg" .dmg)"
package_name="${package_name//_/ }"
dmg_sha256="$(shasum -a 256 "$gptk_dmg" | awk '{print $1}')"
provider_product="$(strings "$d3dmetal" | sed -n 's/^@(#)PROGRAM:/PROGRAM:/p' | head -1)"
provider_version="$(plutil -extract CFBundleShortVersionString raw "$version_plist")"
installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
backup_stamp="$(date -u +%Y%m%dT%H%M%SZ)"

{
  printf 'author: Timur Isaev\n'
  printf 'installed_at: %s\n' "$installed_at"
  printf 'package: %s\n' "$package_name"
  printf 'source_dmg_sha256: %s\n' "$dmg_sha256"
  printf 'crossover_version: %s\n' "$(plutil -extract CFBundleShortVersionString raw "$cx_info")"
  printf 'provider_product: %s\n' "$provider_product"
  printf 'provider_version: %s\n' "$provider_version"
  printf 'd3dmetal_sha256: %s\n' "$(shasum -a 256 "$d3dmetal" | awk '{print $1}')"
  printf 'libd3dshared_sha256: %s\n' "$(shasum -a 256 "$libd3dshared" | awk '{print $1}')"
  printf 'd3d12_dll_sha256: %s\n' "$(shasum -a 256 "$d3d12_dll" | awk '{print $1}')"
} >"$stage_dir/manifest.txt"

if [[ -e "$provider_dir" ]]; then
  backup_dir="$work_dir/gptk4-provider.previous-$backup_stamp"
  mv "$provider_dir" "$backup_dir"
  printf 'Previous provider preserved at %s\n' "$backup_dir"
fi

mv "$stage_dir" "$provider_dir"

printf 'GPTK lab provider installed at %s\n' "$provider_dir"
cat "$provider_dir/manifest.txt"
