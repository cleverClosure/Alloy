#!/usr/bin/env bash
# Author: Timur Isaev
set -euo pipefail
PACKAGE="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$PACKAGE" --jobs 2 --product alloy-client
BIN="$(swift build --package-path "$PACKAGE" --show-bin-path)"
APP="$PACKAGE/.build/Alloy.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/alloy-client" "$APP/Contents/MacOS/alloy-client"
cp "$PACKAGE/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
