#!/bin/bash -p
# Build fresh reference shaders, then prove live/capture/replay/presentation.
# Author: Timur Isaev
[[ $- == *p* ]] || {
  printf 'reference trace: execute this script directly; Bash privileged mode is required\n' >&2
  exit 2
}
set -euo pipefail
umask 077
unset BASH_ENV CDPATH ENV GLOBIGNORE
shopt -u dotglob extglob failglob nocaseglob nullglob
LC_ALL=C
LANG=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
TMPDIR=/tmp
export LANG LC_ALL PATH TMPDIR

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$ROOT/../.." && pwd -P)"
BUILD="$ROOT/build"
PUBLISHED_WORK="$BUILD/reference"
PUBLISHED_RUN_MANIFEST="$PUBLISHED_WORK/RUN-MANIFEST.txt"
HLSL_REPO_PATH=runtime/metal12/Tests/Fixtures/reference_scene.hlsl
COMPARATOR_REPO_PATH=spikes/M12-006/prototype/compare_reference.py
ANSWER_KEY_REPO_PATH=spikes/M12-005/results/2026-07-25-gptk4-reference.png
PRESENT=0
RUN_WORK=
PRIVATE_WINE_PREFIX=
PRIVATE_WINE_USED=0
FROZEN_RUN_MANIFEST_SHA256=
METALLIB_FRONTEND_PATH=
METALLIB_FRONTEND_LINK_TARGET=

# shellcheck source=runtime/metal12/evidence-paths.sh
source "$ROOT/evidence-paths.sh"
# shellcheck disable=SC2119 # The sanitizer rejects forwarded arguments.
am12_evidence_sanitize_git_environment

sha256_file() {
  am12_evidence_sha256_file "$1"
}

GIT_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v git)" Git
)"

if [[ ${1:-} == --present ]]; then
  PRESENT=1
elif (($#)); then
  printf 'usage: %s [--present]\n' "$0" >&2
  exit 2
fi

COMMON_GIT_DIR="$(
  "$GIT_PATH" -C "$REPO" rev-parse \
    --path-format=absolute --git-common-dir
)"
SHARED_ROOT="${ALLOY_SHARED_ROOT:-$(dirname "$COMMON_GIT_DIR")}"
ALLOY_WINE=${ALLOY_WINE:-"$SHARED_ROOT/spikes/WINE-001/work/build-2/wine"}
ALLOY_FEX_PREFIX=${ALLOY_FEX_PREFIX:-"$SHARED_ROOT/spikes/CPU-001/work/fex-runtime-probe"}
ALLOY_DXC=${ALLOY_DXC:-"$SHARED_ROOT/tools/toolchains/dxc-v1.9.2602.24/bin/x64/dxc.exe"}
DXC=$ALLOY_DXC
export ALLOY_WINE ALLOY_FEX_PREFIX ALLOY_DXC DXC

# shellcheck source=runtime/metal12/evidence-lock.sh
source "$ROOT/evidence-lock.sh"
# shellcheck source=runtime/metal12/compiler-runtime-identity.sh
source "$ROOT/compiler-runtime-identity.sh"
am12_evidence_lock_acquire "$ROOT" "$BUILD"
am12_evidence_lock_install_traps

run_private_wine_command() {
  /usr/bin/env -i \
    PATH="$AM12_COMPILER_RUNTIME_PATH_POLICY" \
    LC_ALL="$AM12_COMPILER_RUNTIME_LC_ALL_POLICY" \
    LANG="$AM12_COMPILER_RUNTIME_LANG_POLICY" \
    TMPDIR="$AM12_COMPILER_RUNTIME_TMPDIR_POLICY" \
    WINEPREFIX="$PRIVATE_WINE_PREFIX" \
    WINEDLLOVERRIDES="$AM12_WINE_DLL_OVERRIDES" \
    "$@"
}

run_clean_native_tool() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    TMPDIR=/tmp \
    "$@"
}

stop_private_wine_server() {
  local current_wineserver_sha256

  ((PRIVATE_WINE_USED)) || return 0
  if [[ -z ${AM12_WINESERVER_PATH:-} ||
    -z ${AM12_WINESERVER_SHA256:-} ||
    ! -f $AM12_WINESERVER_PATH ||
    -L $AM12_WINESERVER_PATH ]]; then
    printf 'cannot terminate the private Wine server with the frozen binary\n' >&2
    return 1
  fi
  current_wineserver_sha256="$(
    sha256_file "$AM12_WINESERVER_PATH"
  )"
  if [[ $current_wineserver_sha256 != "$AM12_WINESERVER_SHA256" ]]; then
    printf 'frozen wineserver changed before private-prefix cleanup\n' >&2
    return 1
  fi
  if ! run_private_wine_command "$AM12_WINESERVER_PATH" -k; then
    printf 'could not kill the private-prefix wineserver\n' >&2
    return 1
  fi
  if ! run_private_wine_command "$AM12_WINESERVER_PATH" -w; then
    printf 'could not wait for the private-prefix wineserver\n' >&2
    return 1
  fi
  am12_compiler_runtime_recheck || return 1
  PRIVATE_WINE_USED=0
}

reference_stage_cleanup() {
  local cleanup_status=0

  [[ -n $RUN_WORK ]] || return 0
  case $RUN_WORK in
    "$BUILD"/.reference-run.*) ;;
    *)
      printf 'refusing to clean unexpected reference staging path: %s\n' \
        "$RUN_WORK" >&2
      return 1
      ;;
  esac
  if [[ -L $RUN_WORK ]]; then
    printf 'refusing to clean symlinked reference staging path: %s\n' \
      "$RUN_WORK" >&2
    return 1
  fi
  if ((PRIVATE_WINE_USED)) && ! stop_private_wine_server; then
    cleanup_status=1
  fi
  if [[ -d $RUN_WORK ]]; then
    if ((cleanup_status)); then
      printf 'private reference staging retained after cleanup failure: %s\n' \
        "$RUN_WORK" >&2
    else
      find "$RUN_WORK" -depth -delete || cleanup_status=1
    fi
  fi
  return "$cleanup_status"
}

reference_exit() {
  local exit_status=$1

  trap - EXIT
  if ! reference_stage_cleanup; then
    exit_status=1
  fi
  am12_evidence_lock_exit "$exit_status"
}

trap 'reference_exit "$?"' EXIT

[[ -d $BUILD && ! -L $BUILD &&
  $(cd "$BUILD" && pwd -P) == "$BUILD" ]] ||
  {
    printf 'invalid fixed build directory: %s\n' "$BUILD" >&2
    exit 1
  }
mkdir -p "$PUBLISHED_WORK"
[[ -d $PUBLISHED_WORK && ! -L $PUBLISHED_WORK &&
  $(cd "$PUBLISHED_WORK" && pwd -P) == "$PUBLISHED_WORK" ]] ||
  {
    printf 'invalid fixed reference directory: %s\n' "$PUBLISHED_WORK" >&2
    exit 1
  }
am12_evidence_require_output_leaf \
  "$PUBLISHED_RUN_MANIFEST" "$PUBLISHED_WORK" "reference run manifest"

HEAD_COMMIT="$("$GIT_PATH" -C "$REPO" rev-parse HEAD)"
RUNTIME_TREE="$(
  "$GIT_PATH" -C "$REPO" rev-parse "$HEAD_COMMIT:runtime/metal12"
)"
RELEVANT_PATHS=(
  runtime/metal12
  "$COMPARATOR_REPO_PATH"
  "$ANSWER_KEY_REPO_PATH"
)
if [[ -n $(
  "$GIT_PATH" -C "$REPO" status \
    --porcelain=v1 --untracked-files=normal -- "${RELEVANT_PATHS[@]}"
) ]]; then
  printf 'reference inputs must match the frozen HEAD before execution\n' >&2
  exit 1
fi

TEMPORARY_RUN_MANIFEST="$(
  mktemp "$PUBLISHED_WORK/.RUN-MANIFEST.txt.XXXXXX"
)"
{
  printf 'schema: com.alloy.metal12.reference-trace.v2\n'
  printf 'author: Timur Isaev\n'
  printf 'status: in-progress\n'
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
} >"$TEMPORARY_RUN_MANIFEST"
mv -f "$TEMPORARY_RUN_MANIFEST" "$PUBLISHED_RUN_MANIFEST"

RUN_WORK="$(mktemp -d "$BUILD/.reference-run.XXXXXX")"
[[ -d $RUN_WORK && ! -L $RUN_WORK &&
  $(cd "$RUN_WORK" && pwd -P) == "$RUN_WORK" ]] ||
  {
    printf 'invalid reference staging directory: %s\n' "$RUN_WORK" >&2
    exit 1
  }
mkdir -p "$RUN_WORK/inputs"
mkdir "$RUN_WORK/module-cache"

git_blob_to_file() {
  local repo_path=$1
  local destination=$2
  local tree_mode

  tree_mode="$(
    "$GIT_PATH" -C "$REPO" ls-tree "$HEAD_COMMIT" -- "$repo_path" |
      awk 'NR == 1 { print $1 }'
  )"
  [[ $tree_mode == 100644 || $tree_mode == 100755 ]] ||
    {
      printf 'reference input is not a regular Git blob: %s\n' \
        "$repo_path" >&2
      return 1
    }
  "$GIT_PATH" -C "$REPO" cat-file blob \
    "$HEAD_COMMIT:$repo_path" >"$destination"
  [[ -s $destination && ! -L $destination ]]
}

HLSL="$RUN_WORK/inputs/reference_scene.hlsl"
COMPARATOR="$RUN_WORK/inputs/compare_reference.py"
ANSWER_KEY="$RUN_WORK/inputs/gptk4-reference.png"
git_blob_to_file "$HLSL_REPO_PATH" "$HLSL"
git_blob_to_file "$COMPARATOR_REPO_PATH" "$COMPARATOR"
git_blob_to_file "$ANSWER_KEY_REPO_PATH" "$ANSWER_KEY"
HLSL_SHA256="$(sha256_file "$HLSL")"
COMPARATOR_SHA256="$(sha256_file "$COMPARATOR")"
ANSWER_KEY_SHA256="$(sha256_file "$ANSWER_KEY")"

for required_tool in awk cmp grep mktemp python3 readlink xcrun; do
  if ! command -v "$required_tool" >/dev/null; then
    printf 'missing tool: %s\n' "$required_tool" >&2
    exit 2
  fi
done
XCRUN_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v xcrun)" xcrun
)"
PYTHON_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v python3)" Python
)"
READLINK_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v readlink)" readlink
)"

build_manifest_field() {
  local field=$1
  local result

  result="$(
    awk -v field="$field" \
      'index($0, field ": ") == 1 {
        value = substr($0, length(field) + 3)
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
      "$BUILD_MANIFEST"
  )" || {
    printf 'build manifest omits or duplicates field: %s\n' "$field" >&2
    return 1
  }
  printf '%s\n' "$result"
}

build_manifest_artifact_hash() {
  local artifact=$1
  local result

  result="$(
    awk -v artifact="$artifact" \
      '$1 == "artifact_sha256:" && NF == 3 && $3 == artifact {
        value = $2
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
      "$BUILD_MANIFEST"
  )" || {
    printf 'build manifest omits or duplicates artifact: %s\n' \
      "$artifact" >&2
    return 1
  }
  printf '%s\n' "$result"
}

am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12

"$ROOT/build.sh"
BUILD_MANIFEST="$BUILD/BUILD-MANIFEST.txt"
[[ -s $BUILD_MANIFEST && ! -L $BUILD_MANIFEST ]] ||
  {
    printf 'build did not publish a regular manifest\n' >&2
    exit 1
  }
FROZEN_BUILD_MANIFEST_SHA256="$(
  sha256_file "$BUILD_MANIFEST"
)"
if [[ $(build_manifest_field schema) != com.alloy.metal12.build-manifest.v1 ||
$(build_manifest_field author) != "Timur Isaev" ||
$(build_manifest_field status) != complete ||
$(build_manifest_field head_commit) != "$HEAD_COMMIT" ||
$(build_manifest_field runtime_tree) != "$RUNTIME_TREE" ||
$(build_manifest_field runtime_worktree_clean) != yes ||
$(build_manifest_field source_materialization) != git-cat-file-frozen-head-v1 ||
$(build_manifest_field native_execution_environment) != env-i-fixed-path-locale-tmp-v1 ||
$(build_manifest_field module_cache_policy) != unique-ephemeral-not-published ||
$(build_manifest_field native_toolchain_identity_scope) != selected-executables-and-sdk-metadata-not-full-sdk-closure-v1 ]]; then
  printf 'build manifest is not a clean build of the frozen runtime source\n' >&2
  exit 1
fi

INVOKED_BINARIES=(
  lowering_api_test
  metal12_lower
  command_validation_test
  vertical_slice
  trace_validation_test
  metal12_replay
)
INVOKED_BINARY_SHA256=()
for invoked_binary in "${INVOKED_BINARIES[@]}"; do
  [[ -x $BUILD/$invoked_binary && ! -L $BUILD/$invoked_binary ]] ||
    {
      printf 'missing invoked build binary: %s\n' "$invoked_binary" >&2
      exit 1
    }
  invoked_binary_sha256="$(
    sha256_file "$BUILD/$invoked_binary"
  )"
  INVOKED_BINARY_SHA256+=("$invoked_binary_sha256")
  [[ $(build_manifest_artifact_hash "$invoked_binary") == "$invoked_binary_sha256" ]] ||
    {
      printf 'build manifest has the wrong hash for invoked binary: %s\n' \
        "$invoked_binary" >&2
      exit 1
    }
done
[[ $(sha256_file "$BUILD_MANIFEST") == "$FROZEN_BUILD_MANIFEST_SHA256" ]] ||
  {
    printf 'build manifest changed while reference inputs were frozen\n' >&2
    exit 1
  }
PRODUCER_SHA256="$(
  sha256_file "$ROOT/run-reference-trace.sh"
)"

am12_compiler_runtime_freeze
am12_compiler_runtime_materialize_private_dxc_bundle \
  "$RUN_WORK/dxc-bundle"
METAL_PATH="$(
  am12_evidence_resolve_canonical_executable \
    "$(run_clean_native_tool "$XCRUN_PATH" --sdk macosx --find metal)" \
    "Metal compiler"
)"
METALLIB_FRONTEND_PATH="$(
  run_clean_native_tool "$XCRUN_PATH" --sdk macosx --find metallib
)"
METALLIB_FRONTEND_DIRECTORY="$(
  cd "$(dirname "$METALLIB_FRONTEND_PATH")" && pwd -P
)"
[[ $METALLIB_FRONTEND_PATH == /* &&
  $(basename "$METALLIB_FRONTEND_PATH") == metallib &&
  -L $METALLIB_FRONTEND_PATH ]] ||
  {
    printf 'metallib frontend is not the expected absolute symlink: %s\n' \
      "$METALLIB_FRONTEND_PATH" >&2
    exit 1
  }
case $METALLIB_FRONTEND_PATH in
  /private/var/run/com.apple.security.cryptexd/mnt/*/Metal.xctoolchain/usr/bin/metallib | \
    /var/run/com.apple.security.cryptexd/mnt/*/Metal.xctoolchain/usr/bin/metallib)
    ;;
  *)
    printf 'metallib frontend is outside the read-only Metal cryptex: %s\n' \
      "$METALLIB_FRONTEND_PATH" >&2
    exit 1
    ;;
esac
case $METALLIB_FRONTEND_DIRECTORY in
  /private/var/run/com.apple.security.cryptexd/mnt/*/Metal.xctoolchain/usr/bin | \
    /var/run/com.apple.security.cryptexd/mnt/*/Metal.xctoolchain/usr/bin)
    ;;
  *)
    printf 'metallib frontend parent is outside the read-only Metal cryptex: %s\n' \
      "$METALLIB_FRONTEND_DIRECTORY" >&2
    exit 1
    ;;
esac
METALLIB_FRONTEND_LINK_TARGET="$(
  "$READLINK_PATH" "$METALLIB_FRONTEND_PATH"
)"
[[ -n $METALLIB_FRONTEND_LINK_TARGET &&
  $METALLIB_FRONTEND_LINK_TARGET != *$'\n'* &&
  $METALLIB_FRONTEND_LINK_TARGET != *$'\r'* ]] ||
  {
    printf 'metallib frontend has an invalid symlink target\n' >&2
    exit 1
  }
METALLIB_PATH="$(
  am12_evidence_resolve_canonical_executable \
    "$METALLIB_FRONTEND_PATH" "metallib target"
)"
PYTHON_SHA256="$(sha256_file "$PYTHON_PATH")"
METAL_SHA256="$(sha256_file "$METAL_PATH")"
METALLIB_SHA256="$(sha256_file "$METALLIB_PATH")"
XCRUN_SHA256="$(sha256_file "$XCRUN_PATH")"
READLINK_SHA256="$(sha256_file "$READLINK_PATH")"

verify_metallib_dispatch() {
  local discovered_frontend
  local current_link_target
  local current_target
  local current_target_sha256
  local current_xcrun_sha256
  local current_readlink_sha256

  current_xcrun_sha256="$(sha256_file "$XCRUN_PATH")"
  [[ $current_xcrun_sha256 == "$XCRUN_SHA256" ]] ||
    {
      printf 'xcrun changed during reference-trace execution\n' >&2
      return 1
    }
  current_readlink_sha256="$(sha256_file "$READLINK_PATH")"
  [[ $current_readlink_sha256 == "$READLINK_SHA256" ]] ||
    {
      printf 'readlink changed during reference-trace execution\n' >&2
      return 1
    }
  discovered_frontend="$(
    run_clean_native_tool "$XCRUN_PATH" --sdk macosx --find metallib
  )"
  [[ $discovered_frontend == "$METALLIB_FRONTEND_PATH" &&
    -L $METALLIB_FRONTEND_PATH ]] ||
    {
      printf 'xcrun metallib dispatch changed during execution\n' >&2
      return 1
    }
  current_link_target="$("$READLINK_PATH" "$METALLIB_FRONTEND_PATH")"
  [[ $current_link_target == "$METALLIB_FRONTEND_LINK_TARGET" ]] ||
    {
      printf 'metallib frontend symlink target changed during execution\n' >&2
      return 1
    }
  current_target="$(
    am12_evidence_resolve_canonical_executable \
      "$METALLIB_FRONTEND_PATH" "metallib target"
  )"
  [[ $current_target == "$METALLIB_PATH" ]] ||
    {
      printf 'metallib canonical target changed during execution\n' >&2
      return 1
    }
  current_target_sha256="$(
    sha256_file "$current_target"
  )"
  [[ $current_target_sha256 == "$METALLIB_SHA256" ]] ||
    {
      printf 'metallib target bytes changed during execution\n' >&2
      return 1
    }
}

if [[ $AM12_COMPILER_RUNTIME_ENVIRONMENT_POLICY != env-i-fixed-allowlist-v1 ||
  $AM12_COMPILER_RUNTIME_PREFIX_POLICY != unique-run-copy-with-selected-leaf-validation-v1 ||
  $AM12_COMPILER_RUNTIME_DYLD_FALLBACK_LIBRARY_POLICY != unset ||
  $AM12_COMPILER_RUNTIME_LC_ALL_POLICY != C ||
  $AM12_COMPILER_RUNTIME_LANG_POLICY != C ||
  $AM12_COMPILER_RUNTIME_TMPDIR_POLICY != /tmp ||
  $AM12_COMPILER_RUNTIME_PATH_POLICY != /usr/bin:/bin:/usr/sbin:/sbin ]]; then
  printf 'unsupported compiler-runtime execution policy\n' >&2
  exit 2
fi
am12_evidence_require_canonical_directory \
  "$AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH" \
  "frozen Wine-prefix template"
PRIVATE_WINE_PREFIX="$RUN_WORK/wine-prefix"
if [[ -e $PRIVATE_WINE_PREFIX || -L $PRIVATE_WINE_PREFIX ]]; then
  printf 'private Wine-prefix destination already exists\n' >&2
  exit 1
fi
/bin/cp -cR \
  "$AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH" \
  "$PRIVATE_WINE_PREFIX"
am12_evidence_require_canonical_directory \
  "$PRIVATE_WINE_PREFIX" "private Wine prefix"

verify_private_prefix_file() {
  local relative_path=$1
  local expected_sha256=$2
  local label=$3
  local private_path="$PRIVATE_WINE_PREFIX/$relative_path"
  local actual_sha256

  am12_evidence_require_canonical_directory \
    "${private_path%/*}" "private Wine-prefix $label parent" ||
    return 1
  if [[ ! -f $private_path || -L $private_path ]]; then
    printf 'private Wine prefix omits a regular %s: %s\n' \
      "$label" "$relative_path" >&2
    return 1
  fi
  actual_sha256="$(sha256_file "$private_path")"
  if [[ $actual_sha256 != "$expected_sha256" ]]; then
    printf 'private Wine-prefix %s differs from the frozen identity\n' \
      "$label" >&2
    return 1
  fi
}

verify_private_prefix_file \
  system.reg "$AM12_FEX_SYSTEM_REG_SHA256" system.reg
verify_private_prefix_file \
  user.reg "$AM12_FEX_USER_REG_SHA256" user.reg
verify_private_prefix_file \
  userdef.reg "$AM12_FEX_USERDEF_REG_SHA256" userdef.reg
PRIVATE_C_DRIVE_LINK="$PRIVATE_WINE_PREFIX/dosdevices/c:"
PRIVATE_Z_DRIVE_LINK="$PRIVATE_WINE_PREFIX/dosdevices/z:"

verify_private_prefix_selected_files() {
  local private_c_drive_candidate
  local private_c_drive_link_target
  local private_c_drive_path
  local private_z_drive_candidate
  local private_z_drive_link_target
  local private_z_drive_path

  verify_private_prefix_file \
    drive_c/windows/system32/ntdll.dll \
    "$AM12_WINE_PREFIX_NTDLL_PE_SHA256" ntdll.dll
  verify_private_prefix_file \
    drive_c/windows/system32/wow64.dll \
    "$AM12_WINE_PREFIX_WOW64_PE_SHA256" wow64.dll
  verify_private_prefix_file \
    drive_c/windows/system32/libarm64ecfex.dll \
    "$AM12_WINE_PREFIX_LIBARM64ECFEX_PE_SHA256" libarm64ecfex.dll
  verify_private_prefix_file \
    drive_c/windows/system32/xtajit64.dll \
    "$AM12_WINE_PREFIX_XTAJIT64_PE_SHA256" xtajit64.dll
  verify_private_prefix_file \
    drive_c/windows/system32/advapi32.dll \
    "$AM12_WINE_PREFIX_ADVAPI32_PE_SHA256" advapi32.dll
  verify_private_prefix_file \
    drive_c/windows/system32/kernel32.dll \
    "$AM12_WINE_PREFIX_KERNEL32_PE_SHA256" kernel32.dll
  verify_private_prefix_file \
    drive_c/windows/system32/kernelbase.dll \
    "$AM12_WINE_PREFIX_KERNELBASE_PE_SHA256" kernelbase.dll
  verify_private_prefix_file \
    drive_c/windows/system32/oleaut32.dll \
    "$AM12_WINE_PREFIX_OLEAUT32_PE_SHA256" oleaut32.dll
  verify_private_prefix_file \
    drive_c/windows/system32/ole32.dll \
    "$AM12_WINE_PREFIX_OLE32_PE_SHA256" ole32.dll
  verify_private_prefix_file \
    drive_c/windows/system32/version.dll \
    "$AM12_WINE_PREFIX_VERSION_PE_SHA256" version.dll
  verify_private_prefix_file \
    drive_c/windows/system32/ucrtbase.dll \
    "$AM12_WINE_PREFIX_UCRTBASE_PE_SHA256" ucrtbase.dll

  am12_evidence_require_canonical_directory \
    "$PRIVATE_WINE_PREFIX/dosdevices" "private Wine-prefix dosdevices" ||
    return 1
  [[ -L $PRIVATE_C_DRIVE_LINK && -L $PRIVATE_Z_DRIVE_LINK ]] ||
    {
      printf 'private Wine-prefix drive mappings are not symlinks\n' >&2
      return 1
    }
  private_c_drive_link_target="$(
    "$READLINK_PATH" "$PRIVATE_C_DRIVE_LINK"
  )"
  private_z_drive_link_target="$(
    "$READLINK_PATH" "$PRIVATE_Z_DRIVE_LINK"
  )"
  [[ $private_c_drive_link_target == "$AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET" &&
    $private_z_drive_link_target == "$AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET" ]] ||
    {
      printf 'private Wine-prefix drive targets differ from the frozen identity\n' >&2
      return 1
    }
  case "$private_c_drive_link_target" in
    /*) private_c_drive_candidate=$private_c_drive_link_target ;;
    *)
      private_c_drive_candidate="$(
        dirname "$PRIVATE_C_DRIVE_LINK"
      )/$private_c_drive_link_target"
      ;;
  esac
  case "$private_z_drive_link_target" in
    /*) private_z_drive_candidate=$private_z_drive_link_target ;;
    *)
      private_z_drive_candidate="$(
        dirname "$PRIVATE_Z_DRIVE_LINK"
      )/$private_z_drive_link_target"
      ;;
  esac
  private_c_drive_path="$(
    cd "$private_c_drive_candidate" &&
      pwd -P
  )"
  private_z_drive_path="$(
    cd "$private_z_drive_candidate" &&
      pwd -P
  )"
  [[ $private_c_drive_path == "$PRIVATE_WINE_PREFIX/drive_c" &&
    $private_z_drive_path == "$AM12_WINE_PREFIX_Z_DRIVE_PATH" ]] ||
    {
      printf 'private Wine-prefix drive mappings resolve unexpectedly\n' >&2
      return 1
    }
}

verify_private_prefix_selected_files
am12_compiler_runtime_recheck

run_dxc() {
  local dxc_status=0
  local postcheck_status=0

  am12_compiler_runtime_recheck || return 1
  am12_compiler_runtime_verify_private_dxc_bundle || return 1
  verify_private_prefix_selected_files || return 1
  PRIVATE_WINE_USED=1
  (
    cd "$AM12_FEX_RUNTIME_ROOT_PATH"
    run_private_wine_command \
      "$AM12_WINE_FRONTEND_PATH" "$AM12_PRIVATE_DXC_EXE_PATH" "$@"
  ) 2>>"$RUN_WORK/dxc-stderr.log" || dxc_status=$?
  verify_private_prefix_selected_files || postcheck_status=1
  am12_compiler_runtime_verify_private_dxc_bundle ||
    postcheck_status=1
  am12_compiler_runtime_recheck || postcheck_status=1
  ((postcheck_status == 0)) || return 1
  return "$dxc_status"
}

run_clean_native_tool "$BUILD/lowering_api_test"

VS_DXIL_ARGS=(-T vs_6_0 -E vs_main -Fo "$RUN_WORK/vs.dxil" "$HLSL")
VS_LL_ARGS=(-T vs_6_0 -E vs_main -Fc "$RUN_WORK/vs.ll" "$HLSL")
PS_DXIL_ARGS=(-T ps_6_0 -E ps_main -Fo "$RUN_WORK/ps.dxil" "$HLSL")
PS_LL_ARGS=(-T ps_6_0 -E ps_main -Fc "$RUN_WORK/ps.ll" "$HLSL")
# shellcheck disable=SC2119 # The stream has no positional arguments.
REFERENCE_COMPILE_KEY="$(
  {
    printf '%s\0' \
      'alloy-metal12-reference-fresh-compile.v2' \
      'hlsl-sha256' "$HLSL_SHA256" \
      'compiler-runtime-identity-sha256' \
      "$AM12_COMPILER_RUNTIME_IDENTITY_SHA256"
    printf '%s\0' \
      'vs-dxil-args' -T vs_6_0 -E vs_main -Fo reference/vs.dxil \
      inputs/reference_scene.hlsl
    printf '%s\0' \
      'vs-ll-args' -T vs_6_0 -E vs_main -Fc reference/vs.ll \
      inputs/reference_scene.hlsl
    printf '%s\0' \
      'ps-dxil-args' -T ps_6_0 -E ps_main -Fo reference/ps.dxil \
      inputs/reference_scene.hlsl
    printf '%s\0' \
      'ps-ll-args' -T ps_6_0 -E ps_main -Fc reference/ps.ll \
      inputs/reference_scene.hlsl
  } | am12_evidence_sha256_stream
)"

printf 'compile_mode: fresh\n' >"$RUN_WORK/dxc-stderr.log"
printf '== HLSL -> DXIL (four fresh compiler invocations)\n'
run_dxc "${VS_DXIL_ARGS[@]}"
run_dxc "${VS_LL_ARGS[@]}"
run_dxc "${PS_DXIL_ARGS[@]}"
run_dxc "${PS_LL_ARGS[@]}"
for compiler_artifact in vs.dxil vs.ll ps.dxil ps.ll; do
  [[ -s $RUN_WORK/$compiler_artifact && ! -L $RUN_WORK/$compiler_artifact ]] ||
    {
      printf 'DXC did not freshly produce: %s\n' "$compiler_artifact" >&2
      exit 1
    }
done
printf '%s\n' "$REFERENCE_COMPILE_KEY" \
  >"$RUN_WORK/reference-shaders.compile-key"

printf '== DXIL -> MSL -> metallib\n'
for stage in vs ps; do
  run_clean_native_tool "$BUILD/metal12_lower" \
    "$RUN_WORK/$stage.dxil" "$RUN_WORK/$stage.ll" "$RUN_WORK"
  run_clean_native_tool \
    "$METAL_PATH" -fmodules-cache-path="$RUN_WORK/module-cache" \
    -O2 -c "$RUN_WORK/$stage.metal" \
    -o "$RUN_WORK/$stage.air"
done
PS_METAL_TEXT=$(<"$RUN_WORK/ps.metal")
if [[ $PS_METAL_TEXT != *'device const ulong *am12_descriptor_page [[buffer(0)]]'* ||
  $PS_METAL_TEXT != *'am12_descriptor_page[0]'* ||
  $PS_METAL_TEXT == *'constant float4 *cb0 [[buffer(0)]]'* ]]; then
  printf 'fragment MSL did not preserve the descriptor-page ABI\n' >&2
  exit 1
fi
verify_metallib_dispatch
run_clean_native_tool "$XCRUN_PATH" --sdk macosx metallib \
  "$RUN_WORK/vs.air" "$RUN_WORK/ps.air" \
  -o "$RUN_WORK/scene.metallib"
verify_metallib_dispatch

printf '== public command rejection matrix\n'
run_clean_native_tool \
  "$BUILD/command_validation_test" "$RUN_WORK/scene.metallib" |
  tee "$RUN_WORK/command-validation.log"

printf '== live path\n'
run_clean_native_tool "$BUILD/vertical_slice" "$RUN_WORK/scene.metallib" \
  --output "$RUN_WORK/live.bmp" | tee "$RUN_WORK/live.log"

printf '== capture path A\n'
run_clean_native_tool "$BUILD/vertical_slice" "$RUN_WORK/scene.metallib" \
  --output "$RUN_WORK/capture-a.bmp" --capture "$RUN_WORK/reference-a.am12" |
  tee "$RUN_WORK/capture-a.log"

printf '== capture path B\n'
run_clean_native_tool "$BUILD/vertical_slice" "$RUN_WORK/scene.metallib" \
  --output "$RUN_WORK/capture-b.bmp" --capture "$RUN_WORK/reference-b.am12" |
  tee "$RUN_WORK/capture-b.log"

cmp "$RUN_WORK/live.bmp" "$RUN_WORK/capture-a.bmp"
cmp "$RUN_WORK/live.bmp" "$RUN_WORK/capture-b.bmp"
cmp "$RUN_WORK/reference-a.am12" "$RUN_WORK/reference-b.am12"

printf '== trace preflight mutation matrix\n'
run_clean_native_tool \
  "$BUILD/trace_validation_test" "$RUN_WORK/reference-a.am12" |
  tee "$RUN_WORK/trace-validation.log"

printf '== generic replay (10 fresh runtimes)\n'
run_clean_native_tool "$BUILD/metal12_replay" \
  "$RUN_WORK/reference-a.am12" "$RUN_WORK/replay.bmp" 10 |
  tee "$RUN_WORK/replay.log"
cmp "$RUN_WORK/live.bmp" "$RUN_WORK/replay.bmp"

printf '== GPTK answer-key comparison\n'
run_clean_native_tool \
  "$PYTHON_PATH" -I "$COMPARATOR" "$ANSWER_KEY" "$RUN_WORK/live.bmp" |
  tee "$RUN_WORK/gptk-compare.log"
grep -Fqx 'size: 640x360 (230400 pixels)' "$RUN_WORK/gptk-compare.log"
grep -Fqx 'baseline fnv1a64: 825861ee12085256' \
  "$RUN_WORK/gptk-compare.log"
grep -Fqx 'slice    fnv1a64: 44709706809f28e9' \
  "$RUN_WORK/gptk-compare.log"
grep -Fqx 'identical pixels: 228971/230400 (99.380%)' \
  "$RUN_WORK/gptk-compare.log"
grep -Fqx 'maximum channel delta: 1' "$RUN_WORK/gptk-compare.log"
grep -Fqx 'comparison gate: PASS' "$RUN_WORK/gptk-compare.log"

if ((PRESENT)); then
  printf '== CAMetalLayer presentation\n'
  run_clean_native_tool "$BUILD/vertical_slice" "$RUN_WORK/scene.metallib" \
    --output "$RUN_WORK/presented.bmp" --present |
    tee "$RUN_WORK/presented.log"
  cmp "$RUN_WORK/live.bmp" "$RUN_WORK/presented.bmp"
fi

am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12
CURRENT_HEAD_COMMIT="$("$GIT_PATH" -C "$REPO" rev-parse HEAD)"
CURRENT_RUNTIME_TREE="$(
  "$GIT_PATH" -C "$REPO" rev-parse \
    "$CURRENT_HEAD_COMMIT:runtime/metal12"
)"
CURRENT_RELEVANT_STATUS="$(
  "$GIT_PATH" -C "$REPO" status --porcelain=v1 --untracked-files=normal -- \
    "${RELEVANT_PATHS[@]}"
)"
if [[ $CURRENT_HEAD_COMMIT != "$HEAD_COMMIT" ||
  $CURRENT_RUNTIME_TREE != "$RUNTIME_TREE" ||
  -n $CURRENT_RELEVANT_STATUS ]]; then
  printf 'source changed during reference-trace execution\n' >&2
  exit 1
fi

[[ $(sha256_file "$BUILD_MANIFEST") == "$FROZEN_BUILD_MANIFEST_SHA256" ]] ||
  {
    printf 'build manifest changed during reference-trace execution\n' >&2
    exit 1
  }
for ((binary_index = 0;  \
binary_index < ${#INVOKED_BINARIES[@]};  \
binary_index++)); do
  [[ $(sha256_file "$BUILD/${INVOKED_BINARIES[$binary_index]}") == "${INVOKED_BINARY_SHA256[$binary_index]}" ]] ||
    {
      printf 'invoked binary changed during run: %s\n' \
        "${INVOKED_BINARIES[$binary_index]}" >&2
      exit 1
    }
done
[[ $(sha256_file "$ROOT/run-reference-trace.sh") == "$PRODUCER_SHA256" ]]
am12_compiler_runtime_recheck
am12_compiler_runtime_verify_private_dxc_bundle
[[ $(sha256_file "$PYTHON_PATH") == "$PYTHON_SHA256" ]]
[[ $(sha256_file "$METAL_PATH") == "$METAL_SHA256" ]]
verify_metallib_dispatch
[[ $(sha256_file "$HLSL") == "$HLSL_SHA256" ]]
[[ $(sha256_file "$COMPARATOR") == "$COMPARATOR_SHA256" ]]
[[ $(sha256_file "$ANSWER_KEY") == "$ANSWER_KEY_SHA256" ]]

REFERENCE_ARTIFACTS=(
  capture-a.bmp
  capture-a.log
  capture-b.bmp
  capture-b.log
  command-validation.log
  dxc-stderr.log
  gptk-compare.log
  inputs/compare_reference.py
  inputs/gptk4-reference.png
  inputs/reference_scene.hlsl
  live.bmp
  live.log
  ps.air
  ps.dxil
  ps.ll
  ps.metal
  ps.provenance.json
  reference-a.am12
  reference-b.am12
  reference-shaders.compile-key
  replay.bmp
  replay.log
  scene.metallib
  trace-validation.log
  vs.air
  vs.dxil
  vs.ll
  vs.metal
  vs.provenance.json
)
RUN_STATUS=complete-offscreen
if ((PRESENT)); then
  REFERENCE_ARTIFACTS+=(presented.bmp presented.log)
  RUN_STATUS=complete-presented
fi

for reference_artifact in "${REFERENCE_ARTIFACTS[@]}"; do
  [[ -s $RUN_WORK/$reference_artifact &&
    ! -L $RUN_WORK/$reference_artifact ]] ||
    {
      printf 'fresh reference artifact is missing: %s\n' \
        "$reference_artifact" >&2
      exit 1
    }
done

TEMPORARY_RUN_MANIFEST="$RUN_WORK/RUN-MANIFEST.txt"
{
  printf 'schema: com.alloy.metal12.reference-trace.v2\n'
  printf 'author: Timur Isaev\n'
  printf 'status: %s\n' "$RUN_STATUS"
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
  printf 'build_manifest_sha256: %s\n' \
    "$FROZEN_BUILD_MANIFEST_SHA256"
  printf 'producer_sha256: %s\n' "$PRODUCER_SHA256"
  printf 'dxc_compile_mode: fresh\n'
  printf 'dxc_compile_invocations: 4\n'
  printf 'dxc_cache_hits: 0\n'
  printf '%s\n' \
    'dxc_execution_materialization: private-validated-copy-of-frozen-bundle-v1'
  printf '%s\n' \
    'compiler_runtime_selected_file_recheck: immediately-before-and-after-each-dxc-v1'
  printf 'source_materialization: git-cat-file-frozen-head-v1\n'
  printf 'native_execution_environment: env-i-fixed-path-locale-tmp-v1\n'
  printf 'python_isolation: isolated-mode-minus-I\n'
  printf 'module_cache_policy: unique-ephemeral-not-published\n'
  printf 'reference_compile_key: %s\n' "$REFERENCE_COMPILE_KEY"
  printf 'hlsl_git_path: %s\n' "$HLSL_REPO_PATH"
  printf 'hlsl_sha256: %s\n' "$HLSL_SHA256"
  printf 'comparator_git_path: %s\n' "$COMPARATOR_REPO_PATH"
  printf 'comparator_sha256: %s\n' "$COMPARATOR_SHA256"
  printf 'answer_key_git_path: %s\n' "$ANSWER_KEY_REPO_PATH"
  printf 'answer_key_sha256: %s\n' "$ANSWER_KEY_SHA256"
  printf 'python_path: %s\n' "$PYTHON_PATH"
  printf 'python_sha256: %s\n' "$PYTHON_SHA256"
  printf 'metal_path: %s\n' "$METAL_PATH"
  printf 'metal_sha256: %s\n' "$METAL_SHA256"
  printf 'xcrun_path: %s\n' "$XCRUN_PATH"
  printf 'xcrun_sha256: %s\n' "$XCRUN_SHA256"
  printf 'readlink_path: %s\n' "$READLINK_PATH"
  printf 'readlink_sha256: %s\n' "$READLINK_SHA256"
  printf 'metallib_path: %s\n' "$METALLIB_PATH"
  printf 'metallib_sha256: %s\n' "$METALLIB_SHA256"
  printf 'metallib_frontend_path: %s\n' "$METALLIB_FRONTEND_PATH"
  printf 'metallib_frontend_link_target: %s\n' \
    "$METALLIB_FRONTEND_LINK_TARGET"
  printf '%s\n' \
    'metallib_invocation_policy: frozen-xcrun-sdk-dispatch-read-only-cryptex-symlink-v1'
  printf 'wine_prefix_materialization: apfs-clone-of-frozen-template\n'
  printf 'wine_prefix_system_reg_initial_sha256: %s\n' \
    "$AM12_FEX_SYSTEM_REG_SHA256"
  printf '%s\n' \
    'wine_prefix_selected_file_validation: initial-registries-and-selected-dlls-plus-mappings-v1'
  printf 'wine_server_cleanup_policy: frozen-wineserver-kill-wait-before-stage-delete\n'
  for ((binary_index = 0;  \
  binary_index < ${#INVOKED_BINARIES[@]};  \
  binary_index++)); do
    printf 'invoked_binary_sha256: %s  %s\n' \
      "${INVOKED_BINARY_SHA256[$binary_index]}" \
      "${INVOKED_BINARIES[$binary_index]}"
  done
} >"$TEMPORARY_RUN_MANIFEST"
am12_compiler_runtime_append_manifest "$TEMPORARY_RUN_MANIFEST"
REFERENCE_ARTIFACT_SHA256=()
for reference_artifact in "${REFERENCE_ARTIFACTS[@]}"; do
  reference_artifact_sha256="$(
    sha256_file "$RUN_WORK/$reference_artifact"
  )"
  REFERENCE_ARTIFACT_SHA256+=("$reference_artifact_sha256")
  printf 'artifact_sha256: %s  reference/%s\n' \
    "$reference_artifact_sha256" "$reference_artifact" \
    >>"$TEMPORARY_RUN_MANIFEST"
done
FROZEN_RUN_MANIFEST_SHA256="$(
  sha256_file "$TEMPORARY_RUN_MANIFEST"
)"
[[ ${#FROZEN_RUN_MANIFEST_SHA256} == 64 &&
  $FROZEN_RUN_MANIFEST_SHA256 != *[!0-9a-f]* ]] ||
  {
    printf 'reference run manifest has an invalid frozen SHA-256\n' >&2
    exit 1
  }

publish_file() {
  local source=$1
  local destination=$2
  local expected_sha256=${3:-}
  local destination_directory
  local temporary_destination
  local source_sha256

  [[ -s $source && ! -L $source ]] || return 1
  destination_directory="$(dirname "$destination")"
  mkdir -p "$destination_directory"
  am12_evidence_require_canonical_directory \
    "$destination_directory" "reference publication directory"
  am12_evidence_require_output_leaf \
    "$destination" "$destination_directory" "reference publication"
  source_sha256="$(sha256_file "$source")"
  if [[ -n $expected_sha256 && $source_sha256 != "$expected_sha256" ]]; then
    printf 'reference publication source differs from its frozen hash: %s\n' \
      "$source" >&2
    return 1
  fi
  temporary_destination="$(
    mktemp "$destination_directory/.$(basename "$destination").XXXXXX"
  )"
  COPYFILE_DISABLE=1 cp -p "$source" "$temporary_destination"
  [[ $(sha256_file "$temporary_destination") == "$source_sha256" ]] ||
    return 1
  mv -f "$temporary_destination" "$destination"
  [[ ! -L $destination &&
    $(sha256_file "$destination") == "$source_sha256" ]]
}

verify_published_reference_artifacts() {
  local reference_index
  local reference_artifact
  local published_artifact
  local published_sha256

  for ((reference_index = 0;  \
  reference_index < ${#REFERENCE_ARTIFACTS[@]};  \
  reference_index++)); do
    reference_artifact=${REFERENCE_ARTIFACTS[$reference_index]}
    published_artifact="$PUBLISHED_WORK/$reference_artifact"
    if [[ ! -s $published_artifact || -L $published_artifact ]]; then
      printf 'published reference artifact is missing or nonregular: %s\n' \
        "$reference_artifact" >&2
      return 1
    fi
    published_sha256="$(
      sha256_file "$published_artifact"
    )"
    if [[ $published_sha256 != "${REFERENCE_ARTIFACT_SHA256[$reference_index]}" ]]; then
      printf 'published reference artifact changed: %s\n' \
        "$reference_artifact" >&2
      return 1
    fi
  done
}

for ((reference_index = 0;  \
reference_index < ${#REFERENCE_ARTIFACTS[@]};  \
reference_index++)); do
  reference_artifact=${REFERENCE_ARTIFACTS[$reference_index]}
  publish_file "$RUN_WORK/$reference_artifact" \
    "$PUBLISHED_WORK/$reference_artifact" \
    "${REFERENCE_ARTIFACT_SHA256[$reference_index]}"
done
verify_published_reference_artifacts
am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12
am12_compiler_runtime_recheck
am12_compiler_runtime_verify_private_dxc_bundle
verify_metallib_dispatch
stop_private_wine_server
verify_private_prefix_selected_files
[[ $(sha256_file "$BUILD_MANIFEST") == "$FROZEN_BUILD_MANIFEST_SHA256" ]] ||
  {
    printf 'build manifest changed before reference publication\n' >&2
    exit 1
  }
for ((binary_index = 0;  \
binary_index < ${#INVOKED_BINARIES[@]};  \
binary_index++)); do
  [[ $(sha256_file "$BUILD/${INVOKED_BINARIES[$binary_index]}") == "${INVOKED_BINARY_SHA256[$binary_index]}" ]] ||
    {
      printf 'invoked binary changed before publication: %s\n' \
        "${INVOKED_BINARIES[$binary_index]}" >&2
      exit 1
    }
done
verify_published_reference_artifacts
[[ $(sha256_file "$TEMPORARY_RUN_MANIFEST") == "$FROZEN_RUN_MANIFEST_SHA256" ]] ||
  {
    printf 'reference run manifest changed immediately before publication\n' >&2
    exit 1
  }
publish_file "$TEMPORARY_RUN_MANIFEST" "$PUBLISHED_RUN_MANIFEST" \
  "$FROZEN_RUN_MANIFEST_SHA256"
[[ $(sha256_file "$PUBLISHED_RUN_MANIFEST") == "$FROZEN_RUN_MANIFEST_SHA256" ]] ||
  {
    printf 'published reference run manifest differs from its frozen hash\n' >&2
    exit 1
  }
verify_published_reference_artifacts
am12_compiler_runtime_recheck
am12_compiler_runtime_verify_private_dxc_bundle
verify_private_prefix_selected_files
verify_metallib_dispatch
[[ $(sha256_file "$BUILD_MANIFEST") == "$FROZEN_BUILD_MANIFEST_SHA256" ]] ||
  {
    printf 'build manifest changed after reference publication\n' >&2
    exit 1
  }
for ((binary_index = 0;  \
binary_index < ${#INVOKED_BINARIES[@]};  \
binary_index++)); do
  [[ $(sha256_file "$BUILD/${INVOKED_BINARIES[$binary_index]}") == "${INVOKED_BINARY_SHA256[$binary_index]}" ]] ||
    {
      printf 'invoked binary changed after publication: %s\n' \
        "${INVOKED_BINARIES[$binary_index]}" >&2
      exit 1
    }
done
[[ $(sha256_file "$PUBLISHED_RUN_MANIFEST") == "$FROZEN_RUN_MANIFEST_SHA256" ]] ||
  {
    printf 'reference run manifest changed after publication checks\n' >&2
    exit 1
  }
printf 'reference trace gates: PASS\n'
