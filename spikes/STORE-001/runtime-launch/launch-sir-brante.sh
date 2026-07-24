#!/usr/bin/env bash
# Sir Brante entitled-build launch harness (STORE-001 / WINE-001)
# Author: Timur Isaev

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
store_root=$(cd "$script_dir/.." && pwd)
repo_root=$(cd "$store_root/../.." && pwd)
fingerprint="$store_root/results/fingerprint-1272160-first.json"

usage() {
  cat <<'EOF'
usage: launch-sir-brante.sh prepare|headless|graphical [options]

Required environment:
  ALLOY_WINE_BUILD          configured Alloy Wine build directory
  ALLOY_FEX_DLL             libarm64ecfex.dll to install in the prefix
  ALLOY_DXMT_PROVIDER_DIR   directory containing d3d11.dll and dxgi.dll
  ALLOY_DXMT_PE_DLL         ARM64EC winemetal.dll
  ALLOY_DXMT_UNIXLIB        path to DXMT's winemetal.so
  ALLOY_GAME_EXE            entitled Sir Brante executable, build 24280929

Optional environment:
  ALLOY_POLICY_COMPILER     alloy-policy-compile executable
  ALLOY_STORE_WORK          isolated work directory under spikes/STORE-001/work/
  ALLOY_WINE_SOURCE         Wine source checkout, recorded in run metadata
  ALLOY_WINEDEBUG           Wine debug channels (default: -all,+alloy,+loaddll)
  DYLD_FALLBACK_LIBRARY_PATH

Options:
  --duration SECONDS        stop only this isolated Wine prefix after SECONDS
  --census                  enable the Wine virtual-memory census channel
  --width PIXELS            graphical width (default: 1280)
  --height PIXELS           graphical height (default: 720)
EOF
}

mode=${1:-}
case "$mode" in
  prepare | headless | graphical) shift ;;
  -h | --help | "")
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

duration=
census=0
width=1280
height=720
while (($#)); do
  case "$1" in
    --duration)
      duration=${2:?--duration requires seconds}
      shift 2
      ;;
    --census)
      census=1
      shift
      ;;
    --width)
      width=${2:?--width requires pixels}
      shift 2
      ;;
    --height)
      height=${2:?--height requires pixels}
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for value in ${duration:+"$duration"} "$width" "$height"; do
  if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
    echo "duration, width, and height must be positive integers" >&2
    exit 2
  fi
done

wine_build=${ALLOY_WINE_BUILD:?ALLOY_WINE_BUILD is required}
fex_dll=${ALLOY_FEX_DLL:?ALLOY_FEX_DLL is required}
provider_source=${ALLOY_DXMT_PROVIDER_DIR:?ALLOY_DXMT_PROVIDER_DIR is required}
winemetal_pe=${ALLOY_DXMT_PE_DLL:?ALLOY_DXMT_PE_DLL is required}
winemetal_source=${ALLOY_DXMT_UNIXLIB:?ALLOY_DXMT_UNIXLIB is required}
game_exe=${ALLOY_GAME_EXE:?ALLOY_GAME_EXE is required}
policy_compiler=${ALLOY_POLICY_COMPILER:-"$repo_root/spikes/WINE-001/policy-probe/.build/release/alloy-policy-compile"}
work_root=${ALLOY_STORE_WORK:-"$store_root/work/runtime-launch"}
wine_dyld_path=${DYLD_FALLBACK_LIBRARY_PATH:-/opt/homebrew/lib}

case "$work_root" in
  "$store_root"/work/*)
    if [[ $work_root == *"/../"* || $work_root == *"/./"* ]]; then
      echo "ALLOY_STORE_WORK may not contain dot-path traversal" >&2
      exit 2
    fi
    ;;
  *)
    echo "ALLOY_STORE_WORK must stay under $store_root/work/" >&2
    exit 2
    ;;
esac

wine="$wine_build/wine"
wineserver="$wine_build/server/wineserver"
winemac="$wine_build/dlls/winemac.drv/winemac.so"
win32u="$wine_build/dlls/win32u/win32u.so"
ntdll="$wine_build/dlls/ntdll/ntdll.so"
provider_d3d11="$provider_source/d3d11.dll"
provider_dxgi="$provider_source/dxgi.dll"

for command in jq shasum; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 2
  }
done
for file in "$wine" "$wineserver" "$winemac" "$win32u" "$ntdll" "$fex_dll" \
  "$provider_d3d11" "$provider_dxgi" "$winemetal_pe" "$winemetal_source" "$game_exe" \
  "$policy_compiler" "$fingerprint"; do
  [[ -f $file ]] || {
    echo "missing required file: $file" >&2
    exit 2
  }
done
for executable in "$wine" "$wineserver" "$policy_compiler"; do
  [[ -x $executable ]] || {
    echo "required executable is not executable: $executable" >&2
    exit 2
  }
done

expected_game_sha=$(jq -er '
  .files[]
  | select(.path == "The Life and Suffering of Sir Brante.exe")
  | .sha256
' "$fingerprint")
actual_game_sha=$(shasum -a 256 "$game_exe" | awk '{print $1}')
build_id=$(jq -er '.buildid' "$fingerprint")
if [[ $build_id != 24280929 || $actual_game_sha != "$expected_game_sha" ]]; then
  echo "entitled executable does not match Sir Brante build 24280929" >&2
  echo "expected: $expected_game_sha" >&2
  echo "actual:   $actual_game_sha" >&2
  exit 1
fi

prefix="$work_root/prefix"
provider_dir="$work_root/providers/dxmt"
restricted_dir="$work_root/providers/restricted"
unix_dir="$work_root/dxmt-install/aarch64-unix"
arm64_windows_dir="$work_root/dxmt-install/aarch64-windows"
x64_windows_dir="$work_root/dxmt-install/x86_64-windows"
log_dir="$work_root/logs"
policy_source="$work_root/policy-source.json"
policy_snapshot="$work_root/policy.snapshot"
run_metadata="$work_root/run-inputs.json"

windows_path() {
  local converted=${1//\//\\}
  printf 'Z:%s' "$converted"
}

stop_isolated_server() {
  env WINEPREFIX="$prefix" "$wineserver" -k >/dev/null 2>&1 || true
}

prepare_runtime() {
  local provider_windows restricted_windows wine_commit=""

  mkdir -p "$provider_dir" "$restricted_dir" "$unix_dir" "$arm64_windows_dir" \
    "$x64_windows_dir" "$log_dir" "$prefix"
  stop_isolated_server

  if [[ ! -f $prefix/system.reg ]]; then
    env WINEPREFIX="$prefix" WINEDEBUG=-all \
      DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" \
      "$wine" wineboot -u
    stop_isolated_server
  fi

  mkdir -p "$prefix/drive_c/windows/system32"
  cp -f "$fex_dll" "$prefix/drive_c/windows/system32/libarm64ecfex.dll"
  cp -f "$winemetal_pe" "$prefix/drive_c/windows/system32/winemetal.dll"
  cp -f "$provider_d3d11" "$prefix/drive_c/windows/system32/d3d11.dll"
  cp -f "$provider_dxgi" "$prefix/drive_c/windows/system32/dxgi.dll"
  printf '%s\n' \
    'REGEDIT4' \
    '' \
    '[HKEY_LOCAL_MACHINE\Software\Microsoft\Wow64\amd64]' \
    '@="libarm64ecfex.dll"' \
    >"$work_root/select-fex.reg"
  env WINEPREFIX="$prefix" WINEDEBUG=-all \
    DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" \
    "$wine" regedit "$work_root/select-fex.reg"
  stop_isolated_server
  cp -f "$provider_d3d11" "$provider_dir/d3d11.dll"
  cp -f "$provider_dxgi" "$provider_dir/dxgi.dll"
  cp -f "$winemetal_source" "$unix_dir/winemetal.so"
  cp -f "$winemetal_pe" "$arm64_windows_dir/winemetal.dll"
  cp -f "$winemetal_pe" "$x64_windows_dir/winemetal.dll"
  ln -sfn ../aarch64-unix/winemetal.so "$x64_windows_dir/winemetal.so"
  ln -sfn "$ntdll" "$unix_dir/ntdll.so"
  ln -sfn "$winemac" "$unix_dir/winemac.so"
  ln -sfn "$win32u" "$unix_dir/win32u.so"

  provider_windows=$(windows_path "$provider_dir")
  restricted_windows=$(windows_path "$restricted_dir")
  jq -n \
    --arg image_sha "$actual_game_sha" \
    --arg provider "$provider_windows" \
    --arg restricted "$restricted_windows" \
    '{
      schemaVersion: 1,
      defaultPolicy: {
        id: "unknown-restricted",
        graphicsProvider: "restricted",
        providerDirectory: $restricted,
        dllRoutes: [
          {module: "d3d11.dll", loadOrder: "builtin"},
          {module: "dxgi.dll", loadOrder: "builtin"}
        ]
      },
      processPolicies: [{
        imageSHA256: $image_sha,
        policy: {
          id: "sir-brante-24280929",
          graphicsProvider: "dxmt",
          providerDirectory: $provider,
          dllRoutes: [
            {module: "d3d11.dll", loadOrder: "native"},
            {module: "dxgi.dll", loadOrder: "native"}
          ]
        }
      }]
    }' >"$policy_source"
  "$policy_compiler" compile "$policy_source" "$policy_snapshot"

  if [[ -n ${ALLOY_WINE_SOURCE:-} && -e ${ALLOY_WINE_SOURCE}/.git ]]; then
    wine_commit=$(git -C "$ALLOY_WINE_SOURCE" rev-parse HEAD)
  fi
  jq -n \
    --arg build_id "$build_id" \
    --arg game_sha256 "$actual_game_sha" \
    --arg fex_sha256 "$(shasum -a 256 "$fex_dll" | awk '{print $1}')" \
    --arg d3d11_sha256 "$(shasum -a 256 "$provider_d3d11" | awk '{print $1}')" \
    --arg dxgi_sha256 "$(shasum -a 256 "$provider_dxgi" | awk '{print $1}')" \
    --arg winemetal_pe_sha256 "$(shasum -a 256 "$winemetal_pe" | awk '{print $1}')" \
    --arg winemetal_unix_sha256 "$(shasum -a 256 "$winemetal_source" | awk '{print $1}')" \
    --arg ntdll_sha256 "$(shasum -a 256 "$ntdll" | awk '{print $1}')" \
    --arg policy_snapshot_sha256 "$(shasum -a 256 "$policy_snapshot" | awk '{print $1}')" \
    --arg wine_commit "$wine_commit" \
    '{
      appid: "1272160",
      buildID: $build_id,
      executableSHA256: $game_sha256,
      fexSHA256: $fex_sha256,
      d3d11SHA256: $d3d11_sha256,
      dxgiSHA256: $dxgi_sha256,
      winemetalPESHA256: $winemetal_pe_sha256,
      winemetalUnixSHA256: $winemetal_unix_sha256,
      ntdllSHA256: $ntdll_sha256,
      policySnapshotSHA256: $policy_snapshot_sha256,
      wineCommit: (if $wine_commit == "" then null else $wine_commit end)
    }' >"$run_metadata"

  echo "prepared: $work_root"
  echo "policy: sir-brante-24280929"
  echo "game_sha256: $actual_game_sha"
}

prepare_runtime
if [[ $mode == prepare ]]; then
  exit 0
fi

wine_debug=${ALLOY_WINEDEBUG:--all,+alloy,+loaddll}
if ((census)); then
  wine_debug+=",err+virtual"
fi

player_log="$log_dir/sir-brante-$mode-player.log"
runtime_log="$log_dir/sir-brante-$mode-runtime.log"
player_log_windows=$(windows_path "$player_log")
launch_args=(-logFile "$player_log_windows")
if [[ $mode == headless ]]; then
  launch_args=(-batchmode -nographics "${launch_args[@]}")
else
  launch_args=(-screen-fullscreen 0 -screen-width "$width" -screen-height "$height"
    -force-d3d11 "${launch_args[@]}")
fi

watchdog_pid=
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup_watchdog() {
  if [[ -n $watchdog_pid ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
}
trap cleanup_watchdog EXIT

if [[ -n $duration ]]; then
  (
    sleep "$duration"
    stop_isolated_server
    sleep 2
    stop_isolated_server
  ) &
  watchdog_pid=$!
fi

set +e
(
  exec 9<"$policy_snapshot"
  env \
    ALLOY_POLICY_SNAPSHOT_FD=9 \
    WINEPREFIX="$prefix" \
    WINEDLLPATH="$work_root/dxmt-install" \
    WINEDLLOVERRIDES=xtajit64=n \
    WINEDEBUG="$wine_debug" \
    DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" \
    "$wine" "$game_exe" "${launch_args[@]}"
) 2>&1 | tee "$runtime_log"
status=${PIPESTATUS[0]}
set -e

printf '%s\n' "$status" >"$log_dir/sir-brante-$mode.exit"
echo "runtime_log: $runtime_log"
echo "player_log: $player_log"
echo "exit: $status"
exit "$status"
