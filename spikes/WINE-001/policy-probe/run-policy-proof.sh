#!/usr/bin/env bash
# WINE-001 per-process policy proof
# Author: Timur Isaev

set -euo pipefail

spike_root=$(cd "$(dirname "$0")/.." && pwd)
repo_root=$(cd "$spike_root/../.." && pwd)
probe_root="$spike_root/policy-probe"
probe_work="$spike_root/work/policy-probe"
wine_build="$spike_root/work/build-2"
wine_binary="$wine_build/wine"
wine_server="$wine_build/server/wineserver"
toolchain="$repo_root/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin"
cross_cc="$toolchain/aarch64-w64-mingw32-clang"
swift_cache=/tmp/alloy-policy-swift-cache
clang_cache=/tmp/alloy-policy-clang-cache

[[ "$probe_work" == "$spike_root/work/policy-probe" ]] || {
  printf 'refusing unexpected work path: %s\n' "$probe_work" >&2
  exit 2
}
[[ -x "$wine_binary" && -x "$wine_server" && -x "$cross_cc" ]] || {
  printf 'missing Wine build or llvm-mingw toolchain\n' >&2
  exit 2
}
command -v jq >/dev/null

rm -rf "$probe_work"
mkdir -p \
  "$probe_work/guest" \
  "$probe_work/providers/dxmt" \
  "$probe_work/providers/metal12" \
  "$probe_work/providers/restricted"

env \
  SWIFT_MODULECACHE_PATH="$swift_cache" \
  CLANG_MODULE_CACHE_PATH="$clang_cache" \
  swift build --disable-sandbox -c release --package-path "$probe_root"
compiler="$probe_root/.build/release/alloy-policy-compile"

build_provider() {
  local name=$1
  local identifier=$2
  local output_directory="$probe_work/providers/$name"

  "$cross_cc" -O2 -shared -nostdlib -ffreestanding -fno-stack-protector \
    -DPROVIDER_ID="$identifier" \
    -DPROVIDER_NAME="\"$name\"" \
    "$probe_root/guest/alloygraphics.c" \
    -Wl,--entry,DllMainCRTStartup \
    -Wl,--out-implib,"$output_directory/liballoygraphics.a" \
    -o "$output_directory/alloygraphics.dll"
}

build_guest() {
  local role=$1
  local identifier=$2
  shift 2

  "$cross_cc" -O2 -nostdlib -ffreestanding -fno-stack-protector \
    -DROLE_NAME="\"$role\"" \
    -DEXPECTED_PROVIDER_ID="$identifier" \
    -DEXPECTED_PROVIDER_TEXT="\"$identifier\"" \
    "$@" \
    "$probe_root/guest/probe.c" \
    -L"$probe_work/providers/dxmt" \
    -lalloygraphics \
    -lkernel32 \
    -Wl,--entry,entry \
    -o "$probe_work/guest/$role.exe"
}

windows_path() {
  local converted=${1//\//\\}
  printf 'Z:%s' "$converted"
}

build_provider dxmt 11
build_provider metal12 12
build_provider restricted 0
build_guest launcher 11 -DLAUNCH_CHILDREN
build_guest game 12
build_guest unknown 0

launcher_digest=$("$compiler" sha256 "$probe_work/guest/launcher.exe")
game_digest=$("$compiler" sha256 "$probe_work/guest/game.exe")
dxmt_path=$(windows_path "$probe_work/providers/dxmt")
metal12_path=$(windows_path "$probe_work/providers/metal12")
restricted_path=$(windows_path "$probe_work/providers/restricted")
source_json="$probe_work/policy-source.json"
snapshot="$probe_work/policy.snapshot"
snapshot_repeat="$probe_work/policy-repeat.snapshot"

jq -n \
  --arg launcher_digest "$launcher_digest" \
  --arg game_digest "$game_digest" \
  --arg dxmt_path "$dxmt_path" \
  --arg metal12_path "$metal12_path" \
  --arg restricted_path "$restricted_path" \
  '{
    schemaVersion: 1,
    defaultPolicy: {
      id: "unknown-restricted",
      graphicsProvider: "restricted",
      providerDirectory: $restricted_path,
      dllRoutes: [{module: "alloygraphics.dll", loadOrder: "native"}]
    },
    processPolicies: [
      {
        imageSHA256: $launcher_digest,
        policy: {
          id: "launcher",
          graphicsProvider: "dxmt",
          providerDirectory: $dxmt_path,
          dllRoutes: [{module: "alloygraphics.dll", loadOrder: "native"}]
        }
      },
      {
        imageSHA256: $game_digest,
        policy: {
          id: "game",
          graphicsProvider: "metal12",
          providerDirectory: $metal12_path,
          dllRoutes: [{module: "alloygraphics.dll", loadOrder: "native"}]
        }
      }
    ]
  }' >"$source_json"

"$compiler" compile "$source_json" "$snapshot"
"$compiler" compile "$source_json" "$snapshot_repeat"
cmp "$snapshot" "$snapshot_repeat"
"$compiler" inspect "$snapshot" >"$probe_work/policy-inspection.json"

for executable in launcher game unknown; do
  "$toolchain/llvm-readobj" --coff-imports "$probe_work/guest/$executable.exe" |
    grep -qi 'alloygraphics.dll'
done

prefix="$probe_work/prefix"
mkdir -p "$prefix"
env \
  PATH="$toolchain:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  WINEPREFIX="$prefix" \
  WINEDEBUG=-all \
  "$wine_binary" wineboot -u >"$probe_work/wineboot.log" 2>&1
env WINEPREFIX="$prefix" "$wine_server" -k >/dev/null 2>&1 || true

run_log="$probe_work/policy-run.log"
(
  exec 9<"$snapshot"
  rm -f "$snapshot"
  cd "$probe_work/guest"
  env -u WINEDLLOVERRIDES \
    ALLOY_POLICY_SNAPSHOT_FD=9 \
    PATH="$toolchain:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WINEPREFIX="$prefix" \
    WINEDEBUG=+alloy,+loaddll \
    "$wine_binary" launcher.exe
) 2>&1 | tee "$run_log"

grep -Fq 'selected policy launcher graphics dxmt default 0' "$run_log"
grep -Fq 'selected policy game graphics metal12 default 0' "$run_log"
grep -Fq 'selected policy unknown-restricted graphics restricted default 1' "$run_log"
grep -Fq 'PROBE role=launcher provider=dxmt id=11' "$run_log"
grep -Fq 'PROBE role=game provider=metal12 id=12' "$run_log"
grep -Fq 'PROBE role=unknown provider=restricted id=0' "$run_log"
grep -Fq 'SESSION game=0 unknown=0' "$run_log"
grep -Fqi 'providers\\dxmt\\alloygraphics.dll' "$run_log"
grep -Fqi 'providers\\metal12\\alloygraphics.dll' "$run_log"
grep -Fqi 'providers\\restricted\\alloygraphics.dll' "$run_log"

jq -e '
  .entries | length == 3 and
  .[0].defaultPolicy == true and
  .[0].policyID == "unknown-restricted" and
  .[1, 2].defaultPolicy == false
' "$probe_work/policy-inspection.json" >/dev/null

expect_bootstrap_failure() {
  local label=$1
  local descriptor_mode=$2
  local snapshot_path=$3
  local expected_status=$4
  local failure_log="$probe_work/$label.log"

  if (
    if [[ "$descriptor_mode" == read-write ]]; then
      exec 8<>"$snapshot_path"
    else
      exec 8<"$snapshot_path"
    fi
    rm -f "$snapshot_path"
    cd "$probe_work/guest"
    env -u WINEDLLOVERRIDES \
      ALLOY_POLICY_SNAPSHOT_FD=8 \
      PATH="$toolchain:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      WINEPREFIX="$prefix" \
      WINEDEBUG=-all \
      "$wine_binary" unknown.exe
  ) >"$failure_log" 2>&1; then
    printf '%s unexpectedly succeeded\n' "$label" >&2
    return 1
  fi
  grep -Fq "status $expected_status" "$failure_log"
}

writable_snapshot="$probe_work/policy-writable.snapshot"
cp "$snapshot_repeat" "$writable_snapshot"
chmod 600 "$writable_snapshot"
expect_bootstrap_failure writable-fd read-write "$writable_snapshot" c0000022

unsupported_snapshot="$probe_work/policy-unsupported.snapshot"
cp "$snapshot_repeat" "$unsupported_snapshot"
chmod 600 "$unsupported_snapshot"
printf '\002\000\000\000' |
  dd of="$unsupported_snapshot" bs=1 seek=8 conv=notrunc status=none
chmod 400 "$unsupported_snapshot"
expect_bootstrap_failure unsupported-version read-only "$unsupported_snapshot" c0000059

snapshot_digest=$("$compiler" sha256 "$snapshot_repeat")
printf 'PASS WINE-001 policy hook\n'
printf 'fail_closed=writable-fd,unsupported-version\n'
printf 'snapshot_sha256=%s\n' "$snapshot_digest"
printf 'launcher_sha256=%s\n' "$launcher_digest"
printf 'game_sha256=%s\n' "$game_digest"
printf 'log=%s\n' "$run_log"
