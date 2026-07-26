#!/bin/bash -p
# Metal12 shader corpus: HLSL -> DXIL -> MSL -> GPU -> CPU reference.
# Author: Timur Isaev
# shellcheck disable=SC2016 # jq programs intentionally contain jq variables.
[[ $- == *p* ]] || {
  printf 'shader corpus: execute this script directly; Bash privileged mode is required\n' >&2
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

RUNTIME="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$RUNTIME/../.." && pwd)"
CORPUS="$RUNTIME/Tests/ShaderCorpus"
SHADER_TOOLS="$RUNTIME/ShaderTools"
BUILD="$RUNTIME/build"
SHADER_BUILD="$BUILD/shaders"
MANIFEST="$CORPUS/cases.json"
RUN_MANIFEST="$SHADER_BUILD/RUN-MANIFEST.txt"
RUN_STAGING=
PRIVATE_WINE_PREFIX=
PRIVATE_WINE_USED=0
TEMPORARY_RUN_MANIFEST=
FROZEN_RUN_MANIFEST_SHA256=

# shellcheck source=runtime/metal12/evidence-paths.sh
source "$RUNTIME/evidence-paths.sh"
# shellcheck disable=SC2119 # The sanitizer rejects forwarded arguments.
am12_evidence_sanitize_git_environment
GIT_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v git)" Git
)"
COMMON_GIT_DIR="$(
  "$GIT_PATH" -C "$ROOT" rev-parse \
    --path-format=absolute --git-common-dir
)"
SHARED_ROOT="${ALLOY_SHARED_ROOT:-$(dirname "$COMMON_GIT_DIR")}"
ALLOY_WINE="${ALLOY_WINE:-$SHARED_ROOT/spikes/WINE-001/work/build-2/wine}"
ALLOY_FEX_PREFIX="${ALLOY_FEX_PREFIX:-$SHARED_ROOT/spikes/CPU-001/work/fex-runtime-probe}"
DXC="${ALLOY_DXC:-$SHARED_ROOT/tools/toolchains/dxc-v1.9.2602.24/bin/x64/dxc.exe}"
ALLOY_DXC=$DXC
export ALLOY_DXC ALLOY_FEX_PREFIX ALLOY_WINE

# The evidence lock covers the build, compilation, validation, file-by-file
# publication, and final manifest publication. The nested build inherits it.
# shellcheck source=runtime/metal12/evidence-lock.sh
source "$RUNTIME/evidence-lock.sh"
# shellcheck source=runtime/metal12/compiler-runtime-identity.sh
source "$RUNTIME/compiler-runtime-identity.sh"
am12_evidence_lock_acquire "$RUNTIME" "$BUILD"
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
    echo "cannot terminate the private Wine server with the frozen binary" >&2
    return 1
  fi
  current_wineserver_sha256="$(
    am12_evidence_sha256_file "$AM12_WINESERVER_PATH"
  )"
  if [[ $current_wineserver_sha256 != "$AM12_WINESERVER_SHA256" ]]; then
    echo "frozen wineserver changed before private-prefix cleanup" >&2
    return 1
  fi
  if ! run_private_wine_command "$AM12_WINESERVER_PATH" -k; then
    echo "could not kill the private-prefix wineserver" >&2
    return 1
  fi
  if ! run_private_wine_command "$AM12_WINESERVER_PATH" -w; then
    echo "could not wait for the private-prefix wineserver" >&2
    return 1
  fi
  am12_compiler_runtime_recheck || return 1
  PRIVATE_WINE_USED=0
}

shader_stage_cleanup() {
  local cleanup_status=0

  if ((PRIVATE_WINE_USED)) && ! stop_private_wine_server; then
    cleanup_status=1
  fi

  if [[ -n $TEMPORARY_RUN_MANIFEST &&
    (-e $TEMPORARY_RUN_MANIFEST || -L $TEMPORARY_RUN_MANIFEST) ]]; then
    case $TEMPORARY_RUN_MANIFEST in
      "$SHADER_BUILD"/.RUN-MANIFEST.txt.*)
        if [[ -f $TEMPORARY_RUN_MANIFEST && ! -L $TEMPORARY_RUN_MANIFEST ]]; then
          rm -f -- "$TEMPORARY_RUN_MANIFEST" || cleanup_status=1
        else
          echo "refusing to remove a nonregular temporary shader manifest" >&2
          cleanup_status=1
        fi
        ;;
      *)
        echo "refusing to remove an unexpected temporary shader manifest" >&2
        cleanup_status=1
        ;;
    esac
  fi

  if [[ -n $RUN_STAGING ]]; then
    case $RUN_STAGING in
      "$BUILD"/.shader-corpus-run.*) ;;
      *)
        echo "refusing to clean an unexpected shader staging path" >&2
        return 1
        ;;
    esac
    if [[ -L $RUN_STAGING ]]; then
      echo "refusing to clean a symlinked shader staging path" >&2
      return 1
    fi
    if [[ -d $RUN_STAGING ]]; then
      if ((cleanup_status)); then
        echo "private shader staging retained after cleanup failure: $RUN_STAGING" >&2
      elif ! find "$RUN_STAGING" -depth -delete; then
        cleanup_status=1
      fi
    fi
  fi

  return "$cleanup_status"
}

shader_exit() {
  local exit_status=$1

  trap - EXIT
  if ! shader_stage_cleanup; then
    exit_status=1
  fi
  am12_evidence_lock_exit "$exit_status"
}

trap 'shader_exit "$?"' EXIT

if [[ -L $SHADER_BUILD ]]; then
  echo "shader build directory must not be a symlink: $SHADER_BUILD" >&2
  exit 2
fi
mkdir -p "$SHADER_BUILD"
if [[ ! -d $SHADER_BUILD || -L $SHADER_BUILD ||
  $(cd "$SHADER_BUILD" && pwd -P) != "$SHADER_BUILD" ]]; then
  echo "shader build directory is not its fixed canonical directory" >&2
  exit 2
fi
if [[ -n $(
  find "$SHADER_BUILD" -mindepth 1 -maxdepth 1 ! -type f -print -quit
) ]]; then
  echo "shader build directory contains a nonregular output leaf" >&2
  exit 2
fi
if [[ (-e $RUN_MANIFEST || -L $RUN_MANIFEST) &&
  (! -f $RUN_MANIFEST || -L $RUN_MANIFEST) ]]; then
  echo "shader run manifest is not a replaceable regular file" >&2
  exit 2
fi
am12_evidence_require_output_leaf \
  "$RUN_MANIFEST" "$SHADER_BUILD" "shader run manifest"
HEAD_COMMIT="$("$GIT_PATH" -C "$ROOT" rev-parse HEAD)"
RUNTIME_TREE="$(
  "$GIT_PATH" -C "$ROOT" rev-parse "$HEAD_COMMIT:runtime/metal12"
)"
TEMPORARY_RUN_MANIFEST="$(mktemp "$SHADER_BUILD/.RUN-MANIFEST.txt.XXXXXX")"
{
  printf 'schema: com.alloy.metal12.shader-corpus.v2\n'
  printf 'author: Timur Isaev\n'
  printf 'status: in-progress\n'
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
} >"$TEMPORARY_RUN_MANIFEST"
mv -f "$TEMPORARY_RUN_MANIFEST" "$RUN_MANIFEST"

for required_tool in \
  awk basename cmp find jq mktemp mv python3 readlink sed sort xcrun; do
  if ! command -v "$required_tool" >/dev/null; then
    echo "missing tool: $required_tool" >&2
    exit 2
  fi
done
XCRUN_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v xcrun)" xcrun
)"
PYTHON3_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v python3)" Python
)"
JQ_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v jq)" jq
)"
READLINK_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v readlink)" readlink
)"
METAL_PATH="$(
  am12_evidence_resolve_canonical_executable \
    "$(run_clean_native_tool "$XCRUN_PATH" -sdk macosx --find metal)" \
    "Metal compiler"
)"
am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$ROOT" "$HEAD_COMMIT" runtime/metal12
if [[ -n $(
  "$GIT_PATH" -C "$ROOT" status \
    --porcelain=v1 --untracked-files=normal -- runtime/metal12
) ]]; then
  echo "runtime source must match the frozen HEAD before shader execution" >&2
  exit 1
fi
FROZEN_PRODUCER_SHA256="$(
  am12_evidence_sha256_file "$RUNTIME/run-shader-corpus.sh"
)"

sha256_file() {
  local path=$1

  am12_evidence_sha256_file "$path"
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
      "$BUILD/BUILD-MANIFEST.txt"
  )" || {
    echo "build manifest omits or duplicates artifact: $artifact" >&2
    return 1
  }
  printf '%s\n' "$result"
}

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
      "$BUILD/BUILD-MANIFEST.txt"
  )" || {
    echo "build manifest omits or duplicates field: $field" >&2
    return 1
  }
  printf '%s\n' "$result"
}

verify_frozen_file() {
  local label=$1
  local path=$2
  local expected_sha256=$3
  local actual_sha256

  if [[ ! -f $path || -L $path ]]; then
    echo "$label changed type or disappeared during shader-corpus execution" >&2
    return 1
  fi
  actual_sha256="$(sha256_file "$path")"
  if [[ $actual_sha256 != "$expected_sha256" ]]; then
    echo "$label changed during shader-corpus execution" >&2
    return 1
  fi
}

verify_build_artifact_binding() {
  local artifact=$1
  local frozen_sha256=$2
  local recorded_sha256

  recorded_sha256="$(build_manifest_artifact_hash "$artifact")"
  if [[ $recorded_sha256 != "$frozen_sha256" ]]; then
    echo "build manifest has the wrong hash for $artifact" >&2
    return 1
  fi
}

echo "== build shader runner"
"$RUNTIME/build.sh"

# Freeze the manifest and every build product this script invokes immediately
# after the nested build, before executing any of them.
FROZEN_BUILD_MANIFEST_SHA256="$(sha256_file "$BUILD/BUILD-MANIFEST.txt")"
FROZEN_LOWERING_API_TEST_SHA256="$(sha256_file "$BUILD/lowering_api_test")"
FROZEN_METAL12_LOWER_SHA256="$(sha256_file "$BUILD/metal12_lower")"
FROZEN_SHADER_RUNNER_SHA256="$(sha256_file "$BUILD/ShaderRunner")"
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
  echo "build manifest is not a clean build of the frozen runtime source" >&2
  exit 1
fi
verify_build_artifact_binding lowering_api_test "$FROZEN_LOWERING_API_TEST_SHA256"
verify_build_artifact_binding metal12_lower "$FROZEN_METAL12_LOWER_SHA256"
verify_build_artifact_binding ShaderRunner "$FROZEN_SHADER_RUNNER_SHA256"

am12_compiler_runtime_freeze

FROZEN_METAL_SHA256="$(sha256_file "$METAL_PATH")"
FROZEN_XCRUN_SHA256="$(sha256_file "$XCRUN_PATH")"
FROZEN_PYTHON3_SHA256="$(sha256_file "$PYTHON3_PATH")"
FROZEN_JQ_SHA256="$(sha256_file "$JQ_PATH")"
FROZEN_READLINK_SHA256="$(sha256_file "$READLINK_PATH")"
if [[ $AM12_COMPILER_RUNTIME_ENVIRONMENT_POLICY != env-i-fixed-allowlist-v1 ||
  $AM12_COMPILER_RUNTIME_PREFIX_POLICY != unique-run-copy-with-selected-leaf-validation-v1 ||
  $AM12_COMPILER_RUNTIME_DYLD_FALLBACK_LIBRARY_POLICY != unset ||
  $AM12_COMPILER_RUNTIME_LC_ALL_POLICY != C ||
  $AM12_COMPILER_RUNTIME_LANG_POLICY != C ||
  $AM12_COMPILER_RUNTIME_TMPDIR_POLICY != /tmp ||
  $AM12_COMPILER_RUNTIME_PATH_POLICY != /usr/bin:/bin:/usr/sbin:/sbin ]]; then
  echo "unsupported compiler-runtime execution policy" >&2
  exit 2
fi
am12_evidence_require_canonical_directory \
  "$AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH" \
  "frozen Wine-prefix template"

RUN_STAGING="$(mktemp -d "$BUILD/.shader-corpus-run.XXXXXX")"
am12_evidence_require_canonical_directory "$RUN_STAGING" "shader staging"
am12_compiler_runtime_materialize_private_dxc_bundle \
  "$RUN_STAGING/dxc-bundle"
RUN_SOURCE_STAGING="$RUN_STAGING/source-snapshot"
mkdir "$RUN_SOURCE_STAGING"
am12_evidence_require_canonical_directory \
  "$RUN_SOURCE_STAGING" "shader source snapshot"
am12_evidence_materialize_tracked_tree \
  "$GIT_PATH" "$ROOT" "$HEAD_COMMIT" runtime/metal12 \
  "$RUN_SOURCE_STAGING"
RUN_SOURCE_ROOT="$RUN_SOURCE_STAGING/runtime/metal12"
CORPUS="$RUN_SOURCE_ROOT/Tests/ShaderCorpus"
SHADER_TOOLS="$RUN_SOURCE_ROOT/ShaderTools"
MANIFEST="$CORPUS/cases.json"
FROZEN_CASES_MANIFEST_SHA256="$(sha256_file "$MANIFEST")"
FROZEN_VERIFIER_SHA256="$(
  sha256_file "$SHADER_TOOLS/verify_shader_output.py"
)"
PRIVATE_WINE_PREFIX="$RUN_STAGING/wine-prefix"
if [[ -e $PRIVATE_WINE_PREFIX || -L $PRIVATE_WINE_PREFIX ]]; then
  echo "private Wine-prefix destination already exists" >&2
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
    echo "private Wine prefix omits a regular $label: $relative_path" >&2
    return 1
  fi
  actual_sha256="$(sha256_file "$private_path")"
  if [[ $actual_sha256 != "$expected_sha256" ]]; then
    echo "private Wine-prefix $label differs from the frozen identity" >&2
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
      echo "private Wine-prefix drive mappings are not symlinks" >&2
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
      echo "private Wine-prefix drive targets differ from the frozen identity" >&2
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
      echo "private Wine-prefix drive mappings resolve unexpectedly" >&2
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
  ) || dxc_status=$?
  verify_private_prefix_selected_files || postcheck_status=1
  am12_compiler_runtime_verify_private_dxc_bundle ||
    postcheck_status=1
  am12_compiler_runtime_recheck || postcheck_status=1
  ((postcheck_status == 0)) || return 1
  return "$dxc_status"
}

run_clean_native_tool "$BUILD/lowering_api_test"

STAGED_SHADERS="$RUN_STAGING/artifacts"
STAGED_MODULE_CACHE="$RUN_STAGING/module-cache"
CASE_INPUT_RECORDS="$RUN_STAGING/case-inputs.txt"
EXPECTED_ARTIFACTS_FILE="$RUN_STAGING/expected-artifacts.txt"
ACTUAL_ARTIFACTS_FILE="$RUN_STAGING/actual-artifacts.txt"
STAGED_ARTIFACT_HASHES="$RUN_STAGING/artifact-hashes.txt"
CASE_NAMES_FILE="$RUN_STAGING/case-names.txt"
EXPECTED_CASE_NAMES_FILE="$RUN_STAGING/expected-case-names.txt"
SORTED_CASE_NAMES_FILE="$RUN_STAGING/sorted-case-names.txt"
STATE_INPUT_RECORDS_FILE="$RUN_STAGING/state-input-records.txt"
mkdir -p "$STAGED_SHADERS" "$STAGED_MODULE_CACHE"
: >"$CASE_INPUT_RECORDS"

if ! run_clean_native_tool "$JQ_PATH" -er '
  .cases |
  if (type == "array" and
      length == 11 and
      all(.[]; ((.name | type) == "string" and (.name | length) > 0)))
  then .[].name
  else error("invalid shader case inventory")
  end
' "$MANIFEST" >"$CASE_NAMES_FILE"; then
  echo "could not extract the exact shader case inventory" >&2
  exit 1
fi
printf '%s\n' \
  add_cs \
  clamp_cs \
  intops_cs \
  select_cs \
  texture_bilinear_cs \
  texture_point_cs \
  twobuf_cs \
  wave_cs \
  wave_lane_index_cs \
  wave_prefix_sum_cs \
  wave_read_lane_unsupported_cs |
  LC_ALL=C sort >"$EXPECTED_CASE_NAMES_FILE"
LC_ALL=C sort "$CASE_NAMES_FILE" >"$SORTED_CASE_NAMES_FILE"
if ! cmp -s "$EXPECTED_CASE_NAMES_FILE" "$SORTED_CASE_NAMES_FILE"; then
  echo "shader manifest case inventory differs from the evidence allowlist" >&2
  exit 1
fi

texture_width="$("$JQ_PATH" -r '.texture.width' "$MANIFEST")"
texture_height="$("$JQ_PATH" -r '.texture.height' "$MANIFEST")"
texture_mip_levels="$("$JQ_PATH" -r '.texture.mip_levels' "$MANIFEST")"
threads="$("$JQ_PATH" -r '.threads' "$MANIFEST")"
texture_fixture="$STAGED_SHADERS/texture-rgba32f.bin"
run_clean_native_tool \
  "$PYTHON3_PATH" -I "$SHADER_TOOLS/verify_shader_output.py" prepare-texture \
  "$MANIFEST" "$texture_fixture"

pass=0
reject=0
fail=0
fresh_compiles=0
cache_hits=0
passed_names=" "

echo "== compile, lower, and execute fresh corpus"
while IFS= read -r shader_name; do
  hlsl="$CORPUS/$shader_name.hlsl"
  dxil="$STAGED_SHADERS/$shader_name.dxil"
  disassembly="$STAGED_SHADERS/$shader_name.ll"
  compile_key_path="$STAGED_SHADERS/$shader_name.compile-key"
  dxc_log="$STAGED_SHADERS/$shader_name.dxc.log"
  lower_log="$STAGED_SHADERS/$shader_name.lower.log"
  expect="$(
    "$JQ_PATH" -r --arg name "$shader_name" \
      '.cases[] | select(.name == $name) | .expect' "$MANIFEST"
  )"

  if [[ ! -f $hlsl || -L $hlsl ]]; then
    echo "$shader_name: missing or symlinked HLSL fixture" >&2
    fail=$((fail + 1))
    continue
  fi

  source_hash="$(sha256_file "$hlsl")"
  logical_dxc_arguments="$(
    printf -- '-T cs_6_0 -E main -Fo shaders/%s.dxil ' "$shader_name"
    printf -- '-Fc shaders/%s.ll Tests/ShaderCorpus/%s.hlsl' \
      "$shader_name" "$shader_name"
  )"
  {
    printf 'case_input_sha256: %s  Tests/ShaderCorpus/%s.hlsl\n' \
      "$source_hash" "$shader_name"
    printf 'case_dxc_arguments: %s  %s\n' \
      "$shader_name" "$logical_dxc_arguments"
  } >>"$CASE_INPUT_RECORDS"

  # Evidence runs never consult prior DXIL or compile-key files. All eleven
  # corpus cases are compiled into this run's unique staging directory.
  printf 'compile_mode: fresh\n' >"$dxc_log"
  if run_dxc -T cs_6_0 -E main -Fo "$dxil" -Fc "$disassembly" "$hlsl" \
    >>"$dxc_log" 2>&1; then
    fresh_compiles=$((fresh_compiles + 1))
    {
      printf 'schema: com.alloy.metal12.shader-compile-key.v1\n'
      printf 'source_sha256: %s\n' "$source_hash"
      printf 'compiler_runtime_identity_sha256: %s\n' \
        "$AM12_COMPILER_RUNTIME_IDENTITY_SHA256"
      printf 'dxc_arguments: %s\n' "$logical_dxc_arguments"
    } >"$compile_key_path"
    compile_key_sha256="$(sha256_file "$compile_key_path")"
    printf 'key_sha256: %s\n' "$compile_key_sha256" >>"$compile_key_path"
    printf 'case_compile_key_sha256: %s  %s\n' \
      "$compile_key_sha256" "$shader_name" >>"$CASE_INPUT_RECORDS"
    echo "$shader_name: dxc compiled fresh"
  else
    echo "$shader_name: dxc failed (see $dxc_log)" >&2
    fail=$((fail + 1))
    continue
  fi

  printf 'lower_mode: fresh-staging\n' >"$lower_log"
  if run_clean_native_tool \
    "$BUILD/metal12_lower" "$dxil" "$disassembly" "$STAGED_SHADERS" \
    >>"$lower_log" 2>&1; then
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
    diagnostic="$(
      "$JQ_PATH" -r --arg name "$shader_name" \
        '.cases[] | select(.name == $name) | .diagnostic' "$MANIFEST"
    )"
    lower_log_text=$(<"$lower_log")
    if [[ $lower_log_text == *"$diagnostic"* ]]; then
      echo "$shader_name: rejected with named diagnostic ($diagnostic)"
      reject=$((reject + 1))
    else
      echo "$shader_name: rejected without required diagnostic $diagnostic" >&2
      sed 's/^/  /' "$lower_log" >&2
      fail=$((fail + 1))
    fi
    continue
  fi

  if ! run_clean_native_tool \
    "$METAL_PATH" -fmodules-cache-path="$STAGED_MODULE_CACHE" -O2 \
    "$STAGED_SHADERS/$shader_name.metal" \
    -o "$STAGED_SHADERS/$shader_name.metallib"; then
    echo "$shader_name: Metal compilation failed" >&2
    fail=$((fail + 1))
    continue
  fi

  inputs=("$STAGED_SHADERS/$shader_name".u*.in.bin)
  if [[ ! -f ${inputs[0]} ]]; then
    echo "$shader_name: lowerer generated no buffer fixture" >&2
    fail=$((fail + 1))
    continue
  fi

  width_path="$STAGED_SHADERS/$shader_name.width"
  runner_args=(
    "$STAGED_SHADERS/$shader_name.metallib"
    "$shader_name"
    "$threads"
  )
  kind="$(
    "$JQ_PATH" -r --arg name "$shader_name" \
      '.cases[] | select(.name == $name) | .kind' "$MANIFEST"
  )"
  if [[ $kind == texture ]]; then
    sampler="$(
      "$JQ_PATH" -r --arg name "$shader_name" \
        '.cases[] | select(.name == $name) | .sampler' "$MANIFEST"
    )"
    runner_args+=(
      --texture "$sampler" "$texture_width" "$texture_height"
      "$texture_mip_levels" "$texture_fixture"
    )
  fi
  runner_args+=(--thread-width-out "$width_path")
  runner_args+=("${inputs[@]}")

  if ! run_clean_native_tool "$BUILD/ShaderRunner" "${runner_args[@]}"; then
    echo "$shader_name: GPU execution failed" >&2
    fail=$((fail + 1))
    continue
  fi
  if run_clean_native_tool \
    "$PYTHON3_PATH" -I "$SHADER_TOOLS/verify_shader_output.py" verify \
    "$MANIFEST" "$shader_name" "$STAGED_SHADERS" "$width_path"; then
    pass=$((pass + 1))
    passed_names+="$shader_name "
  else
    fail=$((fail + 1))
  fi
done <"$CASE_NAMES_FILE"

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
if ((fail != 0 || pass != 10 || reject != 1 || \
  fresh_compiles != 11 || cache_hits != 0)); then
  exit 1
fi

EXPECTED_ARTIFACTS=(texture-rgba32f.bin)
for shader_name in "${required_passes[@]}"; do
  for shader_suffix in \
    compile-key dxc.log dxil ll lower.log metal metallib provenance.json width; do
    EXPECTED_ARTIFACTS+=("$shader_name.$shader_suffix")
  done
  case "$shader_name" in
    add_cs | clamp_cs | intops_cs | select_cs)
      EXPECTED_ARTIFACTS+=(
        "$shader_name.u0.in.bin"
        "$shader_name.u0.in.bin.out"
        "$shader_name.u0.ref.bin"
      )
      ;;
    texture_bilinear_cs | texture_point_cs | wave_cs | \
      wave_lane_index_cs | wave_prefix_sum_cs)
      EXPECTED_ARTIFACTS+=(
        "$shader_name.u0.in.bin"
        "$shader_name.u0.in.bin.out"
        "$shader_name.u0.runtime.ref.bin"
      )
      ;;
    twobuf_cs)
      EXPECTED_ARTIFACTS+=(
        "$shader_name.u0.in.bin"
        "$shader_name.u0.in.bin.out"
        "$shader_name.u0.ref.bin"
        "$shader_name.u1.in.bin"
        "$shader_name.u1.in.bin.out"
        "$shader_name.u1.ref.bin"
      )
      ;;
  esac
done
for shader_suffix in compile-key dxc.log dxil ll lower.log; do
  EXPECTED_ARTIFACTS+=("wave_read_lane_unsupported_cs.$shader_suffix")
done
printf '%s\n' "${EXPECTED_ARTIFACTS[@]}" |
  LC_ALL=C sort -u >"$EXPECTED_ARTIFACTS_FILE"

if [[ -n $(
  find "$STAGED_SHADERS" -mindepth 1 -maxdepth 1 ! -type f -print -quit
) ]]; then
  echo "shader staging contains an unexpected nonregular artifact" >&2
  exit 1
fi
find "$STAGED_SHADERS" -mindepth 1 -maxdepth 1 -type f \
  ! -name '.am12-publish-*.lock' -exec basename {} \; |
  LC_ALL=C sort -u >"$ACTUAL_ARTIFACTS_FILE"
if ! cmp -s "$EXPECTED_ARTIFACTS_FILE" "$ACTUAL_ARTIFACTS_FILE"; then
  echo "fresh shader artifact set does not match the evidence allowlist" >&2
  echo "expected:" >&2
  sed 's/^/  /' "$EXPECTED_ARTIFACTS_FILE" >&2
  echo "actual:" >&2
  sed 's/^/  /' "$ACTUAL_ARTIFACTS_FILE" >&2
  exit 1
fi
while IFS= read -r shader_artifact; do
  if [[ ! -s $STAGED_SHADERS/$shader_artifact ||
    -L $STAGED_SHADERS/$shader_artifact ]]; then
    echo "fresh shader artifact is empty, missing, or symlinked: $shader_artifact" >&2
    exit 1
  fi
done <"$EXPECTED_ARTIFACTS_FILE"
while IFS= read -r shader_artifact; do
  printf '%s  %s\n' \
    "$(sha256_file "$STAGED_SHADERS/$shader_artifact")" "$shader_artifact"
done <"$EXPECTED_ARTIFACTS_FILE" >"$STAGED_ARTIFACT_HASHES"

verify_execution_state() {
  local current_head_commit
  local current_runtime_tree
  local current_runtime_status
  local expected_input_sha256
  local shader_name
  local actual_input_sha256
  local parsed_input_count=0

  am12_evidence_verify_tracked_tree \
    "$GIT_PATH" "$ROOT" "$HEAD_COMMIT" runtime/metal12
  current_head_commit="$("$GIT_PATH" -C "$ROOT" rev-parse HEAD)"
  current_runtime_tree="$(
    "$GIT_PATH" -C "$ROOT" rev-parse \
      "$current_head_commit:runtime/metal12"
  )"
  current_runtime_status="$(
    "$GIT_PATH" -C "$ROOT" status --porcelain=v1 --untracked-files=normal -- \
      runtime/metal12
  )"
  if [[ $current_head_commit != "$HEAD_COMMIT" ||
    $current_runtime_tree != "$RUNTIME_TREE" ||
    -n $current_runtime_status ]]; then
    echo "runtime source changed or is dirty during shader-corpus execution" >&2
    return 1
  fi

  verify_frozen_file producer "$RUNTIME/run-shader-corpus.sh" \
    "$FROZEN_PRODUCER_SHA256"
  verify_frozen_file build-manifest "$BUILD/BUILD-MANIFEST.txt" \
    "$FROZEN_BUILD_MANIFEST_SHA256"
  verify_frozen_file lowering-api-test "$BUILD/lowering_api_test" \
    "$FROZEN_LOWERING_API_TEST_SHA256"
  verify_frozen_file metal12-lower "$BUILD/metal12_lower" \
    "$FROZEN_METAL12_LOWER_SHA256"
  verify_frozen_file shader-runner "$BUILD/ShaderRunner" \
    "$FROZEN_SHADER_RUNNER_SHA256"
  verify_frozen_file metal-compiler "$METAL_PATH" "$FROZEN_METAL_SHA256"
  verify_frozen_file xcrun "$XCRUN_PATH" "$FROZEN_XCRUN_SHA256"
  verify_frozen_file python3 "$PYTHON3_PATH" "$FROZEN_PYTHON3_SHA256"
  verify_frozen_file jq "$JQ_PATH" "$FROZEN_JQ_SHA256"
  verify_frozen_file readlink "$READLINK_PATH" "$FROZEN_READLINK_SHA256"
  verify_frozen_file cases-manifest "$MANIFEST" \
    "$FROZEN_CASES_MANIFEST_SHA256"
  verify_frozen_file shader-verifier \
    "$SHADER_TOOLS/verify_shader_output.py" "$FROZEN_VERIFIER_SHA256"
  am12_compiler_runtime_verify_private_dxc_bundle

  if ! awk '
    $1 == "case_input_sha256:" {
      if (NF != 3 ||
          length($2) != 64 ||
          $2 ~ /[^0-9a-f]/ ||
          $3 !~ /^Tests\/ShaderCorpus\/[A-Za-z0-9_]+\.hlsl$/) {
        exit 2
      }
      name = $3
      sub(/^Tests\/ShaderCorpus\//, "", name)
      sub(/\.hlsl$/, "", name)
      print $2, name
      count += 1
    }
    END {
      if (count != 11) exit 3
    }
  ' "$CASE_INPUT_RECORDS" >"$STATE_INPUT_RECORDS_FILE"; then
    echo "could not parse the complete frozen HLSL input inventory" >&2
    return 1
  fi

  while read -r expected_input_sha256 shader_name; do
    parsed_input_count=$((parsed_input_count + 1))
    actual_input_sha256="$(sha256_file "$CORPUS/$shader_name.hlsl")"
    if [[ $actual_input_sha256 != "$expected_input_sha256" ]]; then
      echo "HLSL input changed during execution: $shader_name" >&2
      return 1
    fi
  done <"$STATE_INPUT_RECORDS_FILE"
  if ((parsed_input_count != 11 || \
    fresh_compiles != 11 || \
    parsed_input_count != fresh_compiles)); then
    echo "frozen HLSL input inventory does not match fresh compilations" >&2
    return 1
  fi
}

verify_execution_state
am12_compiler_runtime_recheck

# Publish each complete artifact with a same-filesystem rename. The fixed
# RUN-MANIFEST remains in-progress until every artifact is installed and
# revalidated, so a partial publication cannot be accepted as evidence.
while IFS= read -r shader_artifact; do
  am12_evidence_require_output_leaf \
    "$SHADER_BUILD/$shader_artifact" "$SHADER_BUILD" \
    "published shader artifact $shader_artifact"
  mv -f "$STAGED_SHADERS/$shader_artifact" \
    "$SHADER_BUILD/$shader_artifact"
done <"$EXPECTED_ARTIFACTS_FILE"

verify_published_artifacts() {
  local expected_sha256
  local shader_artifact
  local actual_sha256

  while read -r expected_sha256 shader_artifact; do
    if [[ ! -s $SHADER_BUILD/$shader_artifact ||
      -L $SHADER_BUILD/$shader_artifact ]]; then
      echo "published shader artifact is empty, missing, or symlinked: $shader_artifact" >&2
      return 1
    fi
    actual_sha256="$(sha256_file "$SHADER_BUILD/$shader_artifact")"
    if [[ $actual_sha256 != "$expected_sha256" ]]; then
      echo "published shader artifact changed: $shader_artifact" >&2
      return 1
    fi
  done <"$STAGED_ARTIFACT_HASHES"
}

verify_published_artifacts
if [[ ! -d $SHADER_BUILD || -L $SHADER_BUILD ||
  $(cd "$SHADER_BUILD" && pwd -P) != "$SHADER_BUILD" ]]; then
  echo "shader build directory changed before manifest publication" >&2
  exit 1
fi
while IFS= read -r shader_artifact; do
  if [[ ! -s $SHADER_BUILD/$shader_artifact ||
    -L $SHADER_BUILD/$shader_artifact ]]; then
    echo "published shader artifact is empty, missing, or symlinked: $shader_artifact" >&2
    exit 1
  fi
done <"$EXPECTED_ARTIFACTS_FILE"

verify_execution_state
am12_compiler_runtime_recheck

TEMPORARY_RUN_MANIFEST="$(mktemp "$SHADER_BUILD/.RUN-MANIFEST.txt.XXXXXX")"
{
  printf 'schema: com.alloy.metal12.shader-corpus.v2\n'
  printf 'author: Timur Isaev\n'
  printf 'status: complete\n'
  printf 'supported_passes: %s\n' "$pass"
  printf 'named_rejections: %s\n' "$reject"
  printf 'failures: %s\n' "$fail"
  printf 'fresh_compiles: %s\n' "$fresh_compiles"
  printf 'cache_hits: %s\n' "$cache_hits"
  printf 'compilation_policy: fresh-only-no-cache-read\n'
  printf '%s\n' \
    'dxc_execution_materialization: private-validated-copy-of-frozen-bundle-v1'
  printf '%s\n' \
    'compiler_runtime_selected_file_recheck: immediately-before-and-after-each-dxc-v1'
  printf 'source_materialization: git-cat-file-frozen-head-v1\n'
  printf 'native_execution_environment: env-i-fixed-path-locale-tmp-v1\n'
  printf 'python_isolation: isolated-mode-minus-I\n'
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
  printf 'build_manifest_sha256: %s\n' "$FROZEN_BUILD_MANIFEST_SHA256"
  printf 'producer_sha256: %s\n' "$FROZEN_PRODUCER_SHA256"
  printf 'lowering_api_test_sha256: %s\n' \
    "$FROZEN_LOWERING_API_TEST_SHA256"
  printf 'metal12_lower_sha256: %s\n' "$FROZEN_METAL12_LOWER_SHA256"
  printf 'shader_runner_sha256: %s\n' "$FROZEN_SHADER_RUNNER_SHA256"
  printf 'cases_manifest_sha256: %s\n' "$FROZEN_CASES_MANIFEST_SHA256"
  printf 'shader_verifier_sha256: %s\n' "$FROZEN_VERIFIER_SHA256"
  printf 'dxc_profile: cs_6_0\n'
  printf 'dxc_entry_point: main\n'
  printf 'compile_key_schema: com.alloy.metal12.shader-compile-key.v1\n'
  printf 'compile_key_digest_scope: preceding-compile-key-lines\n'
  printf 'metal_path: %s\n' "$METAL_PATH"
  printf 'metal_sha256: %s\n' "$FROZEN_METAL_SHA256"
  printf 'xcrun_path: %s\n' "$XCRUN_PATH"
  printf 'xcrun_sha256: %s\n' "$FROZEN_XCRUN_SHA256"
  printf 'python3_path: %s\n' "$PYTHON3_PATH"
  printf 'python3_sha256: %s\n' "$FROZEN_PYTHON3_SHA256"
  printf 'jq_path: %s\n' "$JQ_PATH"
  printf 'jq_sha256: %s\n' "$FROZEN_JQ_SHA256"
  printf 'readlink_path: %s\n' "$READLINK_PATH"
  printf 'readlink_sha256: %s\n' "$FROZEN_READLINK_SHA256"
  printf 'module_cache_policy: unique-ephemeral-not-published\n'
  printf 'wine_prefix_materialization: apfs-clone-of-frozen-template\n'
  printf 'wine_prefix_system_reg_initial_sha256: %s\n' \
    "$AM12_FEX_SYSTEM_REG_SHA256"
  printf '%s\n' \
    'wine_prefix_selected_file_validation: initial-registries-and-selected-dlls-plus-mappings-v1'
  printf 'wine_server_cleanup_policy: frozen-wineserver-kill-wait-before-stage-delete\n'
} >"$TEMPORARY_RUN_MANIFEST"
am12_compiler_runtime_append_manifest "$TEMPORARY_RUN_MANIFEST"
while IFS= read -r case_input_record; do
  printf '%s\n' "$case_input_record" >>"$TEMPORARY_RUN_MANIFEST"
done <"$CASE_INPUT_RECORDS"
while read -r shader_artifact_sha256 shader_artifact; do
  printf 'artifact_sha256: %s  shaders/%s\n' \
    "$shader_artifact_sha256" "$shader_artifact" \
    >>"$TEMPORARY_RUN_MANIFEST"
done <"$STAGED_ARTIFACT_HASHES"
FROZEN_RUN_MANIFEST_SHA256="$(
  sha256_file "$TEMPORARY_RUN_MANIFEST"
)"

verify_execution_state
am12_compiler_runtime_recheck
verify_published_artifacts
stop_private_wine_server
verify_private_prefix_selected_files
if [[ ! -f $RUN_MANIFEST || -L $RUN_MANIFEST ]]; then
  echo "in-progress shader manifest changed type before final publication" >&2
  exit 1
fi
am12_evidence_require_output_leaf \
  "$RUN_MANIFEST" "$SHADER_BUILD" "shader run manifest"
[[ $(sha256_file "$TEMPORARY_RUN_MANIFEST") == "$FROZEN_RUN_MANIFEST_SHA256" ]] ||
  {
    echo "temporary shader run manifest changed before publication" >&2
    exit 1
  }
mv -f "$TEMPORARY_RUN_MANIFEST" "$RUN_MANIFEST"
[[ $(sha256_file "$RUN_MANIFEST") == "$FROZEN_RUN_MANIFEST_SHA256" ]] ||
  {
    echo "published shader run manifest differs from staging" >&2
    exit 1
  }
verify_published_artifacts
verify_execution_state
am12_compiler_runtime_recheck
verify_private_prefix_selected_files
[[ $(sha256_file "$RUN_MANIFEST") == "$FROZEN_RUN_MANIFEST_SHA256" ]] ||
  {
    echo "shader run manifest changed after publication checks" >&2
    exit 1
  }

echo "m12-003 shader path ok"
echo "metal12 shader corpus ok"
