#!/usr/bin/env bash
# Deus Ex: Mankind Divided GOG launch harness (STORE-001 / GFX-001).
# Author: Timur Isaev

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
store_root=$(cd "$script_dir/.." && pwd)
repo_root=$(cd "$store_root/../.." && pwd)

usage() {
  cat <<'EOF'
usage: launch-deus-ex-mankind-divided.sh prepare|benchmark [options]

Required environment:
  ALLOY_WINE_BUILD          configured Alloy Wine build directory
  ALLOY_FEX_DLL             libarm64ecfex.dll to install in the prefix
  ALLOY_DXMT_PROVIDER_DIR   directory containing d3d11.dll and dxgi.dll
  ALLOY_DXMT_PE_DLL         ARM64EC winemetal.dll
  ALLOY_DXMT_UNIXLIB        path to DXMT's winemetal.so
  ALLOY_GAME_EXE            entitled GOG DXMD.exe from build 53307442018838439

Optional environment:
  ALLOY_WINE_LOADER         alternate Wine loader (for a macOS test app bundle)
  ALLOY_POLICY_COMPILER     alloy-policy-compile executable
  ALLOY_STORE_WORK          isolated work directory under spikes/STORE-001/work/
  ALLOY_WINE_SOURCE         Wine source checkout, recorded in run metadata
  ALLOY_WINEDEBUG           Wine debug channels (default: -all,+alloy,+loaddll)
  ALLOY_TZ                  deterministic host time zone (default: UTC)
  ALLOY_DXMT_METRICS_PATH   telemetry TSV under ALLOY_STORE_WORK
  ALLOY_DXMT_SHADER_CACHE_PATH
                            shader-cache directory under ALLOY_STORE_WORK
  ALLOY_RUN_LABEL           safe suffix for logs and exit-status files
  DYLD_FALLBACK_LIBRARY_PATH

Options:
  --duration SECONDS        watchdog timeout for the benchmark
  --reuse-runtime           reuse the prepared prefix and running wineserver
  --preserve-server         stop only the game at timeout; keep wineserver warm
  --width PIXELS            graphical width (default: 1280)
  --height PIXELS           graphical height (default: 720)
EOF
}

mode=${1:-}
case "$mode" in
  prepare | benchmark) shift ;;
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
reuse_runtime=0
preserve_server=0
width=1280
height=720
while (($#)); do
  case "$1" in
    --duration)
      duration=${2:?--duration requires seconds}
      shift 2
      ;;
    --reuse-runtime)
      reuse_runtime=1
      shift
      ;;
    --preserve-server)
      preserve_server=1
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
work_root=${ALLOY_STORE_WORK:-"$store_root/work/issue-11-deus-ex"}
wine_dyld_path=${DYLD_FALLBACK_LIBRARY_PATH:-/opt/homebrew/lib}
runtime_tz=${ALLOY_TZ:-UTC}
metrics_path=${ALLOY_DXMT_METRICS_PATH:-"$work_root/metrics/$mode.tsv"}
shader_cache_path=${ALLOY_DXMT_SHADER_CACHE_PATH:-"$work_root/cache/dxmt"}
run_label=${ALLOY_RUN_LABEL:-$mode}

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
for scoped_path in "$metrics_path" "$shader_cache_path"; do
  if [[ $scoped_path == *"/../"* || $scoped_path == *"/./"* ]]; then
    echo "DXMT metric and cache paths may not contain dot-path traversal" >&2
    exit 2
  fi
  case "$scoped_path" in
    "$work_root"/*) ;;
    *)
      echo "DXMT metric and cache paths must stay under ALLOY_STORE_WORK" >&2
      exit 2
      ;;
  esac
done
if [[ ! $run_label =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ALLOY_RUN_LABEL contains unsupported characters: $run_label" >&2
  exit 2
fi

wine="$wine_build/wine"
game_wine=${ALLOY_WINE_LOADER:-"$wine"}
wineserver="$wine_build/server/wineserver"
winemac="$wine_build/dlls/winemac.drv/winemac.so"
win32u="$wine_build/dlls/win32u/win32u.so"
ntdll="$wine_build/dlls/ntdll/ntdll.so"
provider_d3d11="$provider_source/d3d11.dll"
provider_dxgi="$provider_source/dxgi.dll"
game_root=$(cd "$(dirname "$game_exe")/.." && pwd)
game_manifest="$game_root/goggame-1296690054.info"

for command in jq shasum; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 2
  }
done
for file in "$wine" "$wineserver" "$winemac" "$win32u" "$ntdll" "$fex_dll" \
  "$provider_d3d11" "$provider_dxgi" "$winemetal_pe" "$winemetal_source" "$game_exe" \
  "$game_manifest" "$game_wine" "$policy_compiler"; do
  [[ -f $file ]] || {
    echo "missing required file: $file" >&2
    exit 2
  }
done
for executable in "$wine" "$game_wine" "$wineserver" "$policy_compiler"; do
  [[ -x $executable ]] || {
    echo "required executable is not executable: $executable" >&2
    exit 2
  }
done
for game_dir in "$game_root/retail" "$game_root/runtime"; do
  [[ -d $game_dir ]] || {
    echo "installed game directory is incomplete: $game_dir" >&2
    exit 1
  }
done

expected_game_id=1296690054
expected_build_id=53307442018838439
expected_game_sha=cf4805608f9cc7129a8f04ade8eeefdf1f0cd849a1f702dfe8f0cd06f2f53ee8
expected_manifest_sha=9f277c156af56d0ba48ba1745423f315e7e3cc1e32b79023d26d47f60722d75c
actual_game_id=$(jq -er '.gameId' "$game_manifest")
actual_build_id=$(jq -er '.buildId' "$game_manifest")
actual_play_path=$(jq -er '.playTasks[] | select(.isPrimary == true) | .path' "$game_manifest")
actual_game_sha=$(shasum -a 256 "$game_exe" | awk '{print $1}')
actual_manifest_sha=$(shasum -a 256 "$game_manifest" | awk '{print $1}')
if [[ $actual_game_id != "$expected_game_id" ||
  $actual_build_id != "$expected_build_id" ||
  $actual_play_path != "retail/DXMD.exe" ||
  $actual_game_sha != "$expected_game_sha" ||
  $actual_manifest_sha != "$expected_manifest_sha" ]]; then
  echo "entitled executable does not match the recorded Deus Ex GOG build" >&2
  echo "game id:       $actual_game_id" >&2
  echo "build id:      $actual_build_id" >&2
  echo "play path:     $actual_play_path" >&2
  echo "game sha256:   $actual_game_sha" >&2
  echo "manifest hash: $actual_manifest_sha" >&2
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
graphics_seed="$work_root/dxmd-graphics.reg"

windows_path() {
  local converted=${1//\//\\}
  printf 'Z:%s' "$converted"
}

stop_isolated_server() {
  env WINEPREFIX="$prefix" "$wineserver" -k >/dev/null 2>&1 || true
}

run_wine_policy() {
  (
    exec 9<"$policy_snapshot"
    env ALLOY_POLICY_SNAPSHOT_FD=9 \
      WINEPREFIX="$prefix" \
      WINEDEBUG=-all \
      TZ="$runtime_tz" \
      DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" \
      "$wine" "$@"
  )
}

ensure_wine_builtin() {
  local relative_path=$1
  local source_file="$wine_build/prefix/drive_c/windows/$relative_path"
  local target_file="$prefix/drive_c/windows/$relative_path"

  if [[ -s $target_file ]]; then
    return
  fi
  if [[ ! -s $source_file ]]; then
    echo "Wine build is missing a usable builtin: $source_file" >&2
    exit 1
  fi
  cp -f "$source_file" "$target_file"
  if [[ ! -s $target_file ]]; then
    echo "failed to restore Wine builtin: $target_file" >&2
    exit 1
  fi
  echo "restored Wine builtin: $target_file"
}

write_graphics_seed() {
  local width_hex height_hex
  printf -v width_hex '%08x' "$width"
  printf -v height_hex '%08x' "$height"
  cat >"$graphics_seed" <<EOF
REGEDIT4

[HKEY_CURRENT_USER\\Software\\Eidos Montreal\\Deus Ex: MD]
"FirstRun"=dword:00000000

[HKEY_CURRENT_USER\\Software\\Eidos Montreal\\Deus Ex: MD\\Graphics]
"AmbientOcclusionQuality"=dword:00000001
"Bloom"=dword:00000001
"ChromaticAberration"=dword:00000001
"CHSQuality"=dword:00000000
"ClothPhysics"=dword:00000001
"DisableDX12BufferPooling"=dword:00000000
"DisableDXGISwapChain1"=dword:00000000
"DOFQuality"=dword:00000001
"EnableDX12"=dword:00000000
"ExclusiveFullscreen"=dword:00000000
"Fullscreen"=dword:00000000
"FullscreenHeight"=dword:$height_hex
"FullscreenWidth"=dword:$width_hex
"LevelOfDetail"=dword:00000002
"MotionBlur"=dword:00000000
"MultiSamplingQuality"=dword:00000000
"POMQuality"=dword:00000001
"RefreshRate"=dword:0000003c
"ScreenSpaceReflectionQuality"=dword:00000001
"ShadowQuality"=dword:00000001
"TAA"=dword:00000001
"TesselationQuality"=dword:00000000
"TextureFiltering"=dword:00000002
"TextureQuality"=dword:00000002
"TripleBuffering"=dword:00000000
"UserWindowHeight"=dword:$height_hex
"UserWindowWidth"=dword:$width_hex
"VSync"=dword:00000000
"WindowHeight"=dword:$height_hex
"WindowLeft"=dword:00000040
"WindowMaximized"=dword:00000000
"WindowTop"=dword:00000040
"WindowWidth"=dword:$width_hex

[HKEY_CURRENT_USER\\Software\\Eidos Montreal\\Deus Ex: MD\\Language]
"TextLanguage"="en"
EOF
}

prepare_runtime() {
  local provider_windows restricted_windows wine_commit=""
  local new_prefix=0
  local timezone_catalog_key='[Software\\Microsoft\\Windows NT\\CurrentVersion\\Time Zones\\UTC]'

  mkdir -p "$provider_dir" "$restricted_dir" "$unix_dir" "$arm64_windows_dir" \
    "$x64_windows_dir" "$log_dir" "$prefix"
  stop_isolated_server

  if [[ ! -f $prefix/system.reg ]]; then
    new_prefix=1
    cp -cR "$wine_build/prefix/." "$prefix/"
  fi
  mkdir -p "$prefix/drive_c/windows/system32"
  cp -f "$fex_dll" "$prefix/drive_c/windows/system32/libarm64ecfex.dll"

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
          id: "dxmd-gog-53307442018838439",
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

  if ((new_prefix)); then
    run_wine_policy wineboot -u
    stop_isolated_server
  fi
  ensure_wine_builtin system32/windowscodecs.dll

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
  run_wine_policy regedit "$work_root/select-fex.reg"
  if ! grep -Fq "$timezone_catalog_key" "$prefix/system.reg"; then
    run_wine_policy wineboot -u
    stop_isolated_server
  fi
  ensure_wine_builtin system32/windowscodecs.dll
  write_graphics_seed
  run_wine_policy regedit "$graphics_seed"

  cp -f "$provider_d3d11" "$provider_dir/d3d11.dll"
  cp -f "$provider_dxgi" "$provider_dir/dxgi.dll"
  cp -f "$winemetal_source" "$unix_dir/winemetal.so"
  cp -f "$winemetal_pe" "$arm64_windows_dir/winemetal.dll"
  cp -f "$winemetal_pe" "$x64_windows_dir/winemetal.dll"
  ln -sfn ../aarch64-unix/winemetal.so "$x64_windows_dir/winemetal.so"
  ln -sfn "$ntdll" "$unix_dir/ntdll.so"
  ln -sfn "$winemac" "$unix_dir/winemac.so"
  ln -sfn "$win32u" "$unix_dir/win32u.so"

  if [[ -n ${ALLOY_WINE_SOURCE:-} && -e ${ALLOY_WINE_SOURCE}/.git ]]; then
    wine_commit=$(git -C "$ALLOY_WINE_SOURCE" rev-parse HEAD)
  fi
  jq -n \
    --arg game_id "$actual_game_id" \
    --arg build_id "$actual_build_id" \
    --arg game_sha256 "$actual_game_sha" \
    --arg manifest_sha256 "$actual_manifest_sha" \
    --arg fex_sha256 "$(shasum -a 256 "$fex_dll" | awk '{print $1}')" \
    --arg d3d11_sha256 "$(shasum -a 256 "$provider_d3d11" | awk '{print $1}')" \
    --arg dxgi_sha256 "$(shasum -a 256 "$provider_dxgi" | awk '{print $1}')" \
    --arg windows_codecs_sha256 "$(shasum -a 256 "$prefix/drive_c/windows/system32/windowscodecs.dll" | awk '{print $1}')" \
    --arg winemetal_pe_sha256 "$(shasum -a 256 "$winemetal_pe" | awk '{print $1}')" \
    --arg winemetal_unix_sha256 "$(shasum -a 256 "$winemetal_source" | awk '{print $1}')" \
    --arg ntdll_sha256 "$(shasum -a 256 "$ntdll" | awk '{print $1}')" \
    --arg policy_snapshot_sha256 "$(shasum -a 256 "$policy_snapshot" | awk '{print $1}')" \
    --arg wine_commit "$wine_commit" \
    --arg timezone "$runtime_tz" \
    --arg dxmt_metrics_path "$metrics_path" \
    --arg dxmt_shader_cache_path "$shader_cache_path" \
    --argjson width "$width" \
    --argjson height "$height" \
    '{
      gogGameID: $game_id,
      gogBuildID: $build_id,
      executableSHA256: $game_sha256,
      gogManifestSHA256: $manifest_sha256,
      fexSHA256: $fex_sha256,
      d3d11SHA256: $d3d11_sha256,
      dxgiSHA256: $dxgi_sha256,
      windowsCodecsSHA256: $windows_codecs_sha256,
      winemetalPESHA256: $winemetal_pe_sha256,
      winemetalUnixSHA256: $winemetal_unix_sha256,
      ntdllSHA256: $ntdll_sha256,
      policySnapshotSHA256: $policy_snapshot_sha256,
      timezone: $timezone,
      dxmtMetricsPath: $dxmt_metrics_path,
      dxmtShaderCachePath: $dxmt_shader_cache_path,
      scene: {
        commandLine: ["-benchmark"],
        enableDX12: false,
        fullscreen: false,
        width: $width,
        height: $height
      },
      wineCommit: (if $wine_commit == "" then null else $wine_commit end)
    }' >"$run_metadata"
  stop_isolated_server

  echo "prepared: $work_root"
  echo "policy: dxmd-gog-53307442018838439"
  echo "game_sha256: $actual_game_sha"
}

if ((reuse_runtime)); then
  for prepared_file in "$policy_snapshot" "$run_metadata" "$prefix/system.reg"; do
    [[ -f $prepared_file ]] || {
      echo "--reuse-runtime requires a prior prepare: $prepared_file" >&2
      exit 2
    }
  done
else
  prepare_runtime
fi
if [[ $mode == prepare ]]; then
  exit 0
fi

wine_debug=${ALLOY_WINEDEBUG:--all,+alloy,+loaddll}
mkdir -p "$(dirname "$metrics_path")" "$shader_cache_path"
if ((preserve_server)); then
  env WINEPREFIX="$prefix" \
    DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" \
    "$wineserver" -p
fi

runtime_log="$log_dir/dxmd-$run_label-runtime.log"
watchdog_pid=
watchdog_marker="$log_dir/dxmd-$run_label.watchdog"
rm -f "$watchdog_marker"

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup_watchdog() {
  if [[ -n $watchdog_pid ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
}
trap cleanup_watchdog EXIT

if [[ -n $duration ]]; then
  if ((preserve_server)); then
    (
      sleep "$duration"
      printf '%s\n' "planned game stop after $duration seconds" >"$watchdog_marker"
      run_wine_policy taskkill /f /im "${game_exe##*/}" >/dev/null 2>&1 || true
      sleep 2
      run_wine_policy taskkill /f /im "${game_exe##*/}" >/dev/null 2>&1 || true
    ) &
  else
    (
      sleep "$duration"
      stop_isolated_server
      sleep 2
      stop_isolated_server
    ) &
  fi
  watchdog_pid=$!
fi

set +e
(
  exec 9<"$policy_snapshot"
  cd "$game_root"
  env \
    ALLOY_POLICY_SNAPSHOT_FD=9 \
    WINEPREFIX="$prefix" \
    WINEDLLPATH="$work_root/dxmt-install" \
    WINEDLLOVERRIDES=xtajit64=n \
    WINEDEBUG="$wine_debug" \
    TZ="$runtime_tz" \
    DXMT_METRICS_PATH="$metrics_path" \
    DXMT_SHADER_CACHE_PATH="$shader_cache_path" \
    DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" \
    "$game_wine" "$game_exe" -benchmark
) >"$runtime_log" 2>&1
status=$?
set -e

printf '%s\n' "$status" >"$log_dir/dxmd-$run_label.raw-exit"
if [[ -f $watchdog_marker ]]; then
  status=0
fi
printf '%s\n' "$status" >"$log_dir/dxmd-$run_label.exit"
echo "runtime_log: $runtime_log"
echo "exit: $status"
exit "$status"
