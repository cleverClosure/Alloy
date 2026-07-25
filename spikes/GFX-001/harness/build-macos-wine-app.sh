#!/usr/bin/env bash
# Build a LaunchServices-aware Wine wrapper for GFX-001 title captures.
# Author: Timur Isaev

set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-macos-wine-app.sh OUTPUT.app BUNDLE_ID DISPLAY_NAME

OUTPUT.app must be under this repository's spikes/ work area.
EOF
}

if (($# != 3)); then
  usage >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
output=$1
bundle_id=$2
display_name=$3

case "$output" in
  "$repo_root"/spikes/*/work/*.app) ;;
  *)
    echo "output app must stay under $repo_root/spikes/*/work/" >&2
    exit 2
    ;;
esac
if [[ ! $bundle_id =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "invalid bundle identifier: $bundle_id" >&2
  exit 2
fi
if [[ -z $display_name ]]; then
  echo "display name must not be empty" >&2
  exit 2
fi

contents="$output/Contents"
executable="$contents/MacOS/AlloyWineLauncher"
plist="$contents/Info.plist"
mkdir -p "$contents/MacOS"

cc -Wall -Wextra -Werror -O2 \
  "$script_dir/macos-wine-launcher.c" \
  -o "$executable"
cp "$script_dir/macos-wine-launcher.plist" "$plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
plutil -replace CFBundleDisplayName -string "$display_name" "$plist"
plutil -replace CFBundleName -string "$display_name" "$plist"
plutil -lint "$plist" >/dev/null

echo "built: $output"
echo "bundle_id: $bundle_id"
