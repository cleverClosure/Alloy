#!/bin/bash -p
# Build the Alloy Metal12 library and linked proof executables.
# Author: Timur Isaev
[[ $- == *p* ]] || {
  printf 'build: execute this script directly; Bash privileged mode is required\n' >&2
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
SOURCE_STAGING=
NATIVE_STAGING=
# shellcheck source=runtime/metal12/evidence-paths.sh
source "$ROOT/evidence-paths.sh"
# shellcheck source=runtime/metal12/evidence-lock.sh
source "$ROOT/evidence-lock.sh"

# This API rejects arguments; do not forward build-script arguments.
# shellcheck disable=SC2119
am12_evidence_sanitize_git_environment

run_clean_native_tool() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    TMPDIR=/tmp \
    "$@"
}

BUILD_PRODUCER_PATH="$(
  am12_evidence_resolve_canonical_executable "$ROOT/build.sh" 'build producer'
)"
GIT_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v git)" git
)"
SHASUM_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v shasum)" shasum
)"
XCRUN_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v xcrun)" xcrun
)"
LIBTOOL_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v libtool)" libtool
)"
XXD_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v xxd)" xxd
)"
SED_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v sed)" sed
)"

sha256_file() {
  local path=$1

  am12_evidence_sha256_file "$path"
}

verify_frozen_file() {
  local label=$1
  local path=$2
  local expected_sha256=$3
  local actual_sha256

  [[ -f $path && ! -L $path ]] || {
    printf 'build: frozen %s changed type or disappeared: %s\n' \
      "$label" "$path" >&2
    return 1
  }
  actual_sha256="$(sha256_file "$path")"
  [[ $actual_sha256 == "$expected_sha256" ]] || {
    printf 'build: frozen %s changed during the build: %s\n' \
      "$label" "$path" >&2
    return 1
  }
}

require_built_output() {
  local path=$1
  local parent=$2
  local label=$3

  am12_evidence_require_output_leaf "$path" "$parent" "$label"
  [[ -f $path && ! -L $path ]] || {
    printf 'build: expected output is missing or nonregular: %s\n' \
      "$path" >&2
    return 1
  }
}

FROZEN_BUILD_PRODUCER_SHA256="$(sha256_file "$BUILD_PRODUCER_PATH")"
FROZEN_GIT_SHA256="$(sha256_file "$GIT_PATH")"
FROZEN_SHASUM_SHA256="$(sha256_file "$SHASUM_PATH")"
FROZEN_XCRUN_SHA256="$(sha256_file "$XCRUN_PATH")"
FROZEN_LIBTOOL_SHA256="$(sha256_file "$LIBTOOL_PATH")"
FROZEN_XXD_SHA256="$(sha256_file "$XXD_PATH")"
FROZEN_SED_SHA256="$(sha256_file "$SED_PATH")"

CLANG_PATH="$(
  am12_evidence_resolve_canonical_executable \
    "$(run_clean_native_tool "$XCRUN_PATH" --sdk macosx --find clang)" clang
)"
LD_PATH="$(
  am12_evidence_resolve_canonical_executable \
    "$(run_clean_native_tool "$XCRUN_PATH" --sdk macosx --find ld)" linker
)"
SDK_CANDIDATE="$(
  run_clean_native_tool "$XCRUN_PATH" --sdk macosx --show-sdk-path
)"
SDK_PATH="$(cd "$SDK_CANDIDATE" && pwd -P)"
am12_evidence_require_canonical_directory "$SDK_PATH" 'macOS SDK'
SDK_SETTINGS_PATH="$SDK_PATH/SDKSettings.json"
SDK_VERSION="$(
  run_clean_native_tool "$XCRUN_PATH" --sdk macosx --show-sdk-version
)"
SDK_BUILD_VERSION="$(
  run_clean_native_tool "$XCRUN_PATH" --sdk macosx --show-sdk-build-version
)"
am12_evidence_path_require_single_line 'macOS SDK version' "$SDK_VERSION"
am12_evidence_path_require_single_line \
  'macOS SDK build version' "$SDK_BUILD_VERSION"
NATIVE_TOOLCHAIN_IDENTITY_SCOPE='selected-executables-and-sdk-metadata-not-full-sdk-closure-v1'
FROZEN_CLANG_SHA256="$(sha256_file "$CLANG_PATH")"
FROZEN_LD_SHA256="$(sha256_file "$LD_PATH")"
FROZEN_SDK_SETTINGS_SHA256="$(sha256_file "$SDK_SETTINGS_PATH")"

verify_native_toolchain_selection() {
  local current_clang_path
  local current_ld_path
  local current_sdk_path
  local current_sdk_version
  local current_sdk_build_version

  verify_frozen_file xcrun "$XCRUN_PATH" "$FROZEN_XCRUN_SHA256"
  verify_frozen_file clang "$CLANG_PATH" "$FROZEN_CLANG_SHA256"
  verify_frozen_file linker "$LD_PATH" "$FROZEN_LD_SHA256"
  verify_frozen_file \
    sdk-settings "$SDK_SETTINGS_PATH" "$FROZEN_SDK_SETTINGS_SHA256"
  current_clang_path="$(
    am12_evidence_resolve_canonical_executable \
      "$(run_clean_native_tool "$XCRUN_PATH" --sdk macosx --find clang)" \
      clang
  )"
  current_ld_path="$(
    am12_evidence_resolve_canonical_executable \
      "$(run_clean_native_tool "$XCRUN_PATH" --sdk macosx --find ld)" linker
  )"
  current_sdk_path="$(
    cd "$(
      run_clean_native_tool \
        "$XCRUN_PATH" --sdk macosx --show-sdk-path
    )" &&
      pwd -P
  )"
  current_sdk_version="$(
    run_clean_native_tool "$XCRUN_PATH" --sdk macosx --show-sdk-version
  )"
  current_sdk_build_version="$(
    run_clean_native_tool \
      "$XCRUN_PATH" --sdk macosx --show-sdk-build-version
  )"
  [[ $current_clang_path == "$CLANG_PATH" &&
    $current_ld_path == "$LD_PATH" &&
    $current_sdk_path == "$SDK_PATH" &&
    $current_sdk_version == "$SDK_VERSION" &&
    $current_sdk_build_version == "$SDK_BUILD_VERSION" ]] || {
    printf 'build: selected native toolchain changed during the build\n' >&2
    return 1
  }
}

verify_native_toolchain_selection

am12_evidence_lock_acquire "$ROOT" "$BUILD"
am12_evidence_lock_install_traps
verify_native_toolchain_selection

build_staging_cleanup() {
  local cleanup_status=0
  local staging_path

  for staging_path in "$SOURCE_STAGING" "$NATIVE_STAGING"; do
    [[ -n $staging_path ]] || continue
    case $staging_path in
      "$BUILD"/.source-snapshot.* | "$BUILD"/.native-build.*) ;;
      *)
        printf 'build: refusing to clean unexpected staging path: %s\n' \
          "$staging_path" >&2
        cleanup_status=1
        continue
        ;;
    esac
    if [[ -L $staging_path ]]; then
      printf 'build: refusing to clean symlinked staging path: %s\n' \
        "$staging_path" >&2
      cleanup_status=1
    elif [[ -d $staging_path ]]; then
      /bin/chmod -R u+w "$staging_path" || cleanup_status=1
      find "$staging_path" -depth -delete || cleanup_status=1
    fi
  done
  return "$cleanup_status"
}

build_exit() {
  local exit_status=$1

  trap - EXIT
  if ! build_staging_cleanup; then
    exit_status=1
  fi
  am12_evidence_lock_exit "$exit_status"
}

trap 'build_exit "$?"' EXIT

OBJECTS="$BUILD/objects"
GENERATED="$BUILD/generated"
BUILD_MANIFEST="$BUILD/BUILD-MANIFEST.txt"
HEAD_COMMIT="$("$GIT_PATH" -C "$REPO" rev-parse HEAD)"
RUNTIME_TREE="$(
  "$GIT_PATH" -C "$REPO" rev-parse "$HEAD_COMMIT:runtime/metal12"
)"
am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12
am12_evidence_verify_tracked_file \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12/build.sh \
  "$BUILD_PRODUCER_PATH"
am12_evidence_require_canonical_directory "$BUILD" 'Metal12 build directory'
am12_evidence_prepare_fixed_directory \
  "$OBJECTS" "$BUILD" 'Metal12 object directory'
am12_evidence_prepare_fixed_directory \
  "$GENERATED" "$BUILD" 'Metal12 generated directory'

SOURCE_STAGING="$(mktemp -d "$BUILD/.source-snapshot.XXXXXX")"
NATIVE_STAGING="$(mktemp -d "$BUILD/.native-build.XXXXXX")"
am12_evidence_require_canonical_directory \
  "$SOURCE_STAGING" "build source snapshot"
am12_evidence_require_canonical_directory \
  "$NATIVE_STAGING" "native build staging"
am12_evidence_materialize_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12 "$SOURCE_STAGING"
SOURCE_ROOT="$SOURCE_STAGING/runtime/metal12"
am12_evidence_require_canonical_directory \
  "$SOURCE_ROOT" "materialized runtime source"
LOWERER="$SOURCE_ROOT/ShaderTools/dxil_to_msl.py"
[[ -f $LOWERER && ! -L $LOWERER ]] || {
  printf 'build: staged lowerer must be a regular file: %s\n' "$LOWERER" >&2
  exit 1
}
LOWERER_SHA256="$(sha256_file "$LOWERER")"
/bin/chmod -R a-w "$SOURCE_STAGING"
STAGED_OBJECTS="$NATIVE_STAGING/objects"
STAGED_GENERATED="$NATIVE_STAGING/generated"
STAGED_MODULE_CACHE="$NATIVE_STAGING/module-cache"
mkdir "$STAGED_OBJECTS" "$STAGED_GENERATED" "$STAGED_MODULE_CACHE"
am12_evidence_require_canonical_directory \
  "$STAGED_OBJECTS" "staged object directory"
am12_evidence_require_canonical_directory \
  "$STAGED_GENERATED" "staged generated directory"
STAGED_EMBEDDED_LOWERER="$STAGED_GENERATED/AM12EmbeddedLowerer.inc"

OBJECT_OUTPUTS=(
  AlloyMetal12.o
  AM12DescriptorHeap.o
  AM12BarrierTracker.o
  AM12ResidencyManager.o
  ShaderLowering.o
  ShaderProofSupport.o
  DescriptorHeapProof.o
  BarrierTrackerProof.o
  ResidencyProof.o
)
BUILD_OUTPUTS=(
  BUILD-MANIFEST.txt
  ShaderRunner
  barrier_tracker_test
  command_validation_test
  descriptor_heap_test
  libAlloyMetal12.a
  lowering_api_test
  metal12_lower
  metal12_replay
  residency_safe_test
  residency_test
  trace_validation_test
  vertical_slice
)
GENERATED_OUTPUTS=(AM12EmbeddedLowerer.inc)
for output_leaf in "${OBJECT_OUTPUTS[@]}"; do
  am12_evidence_require_output_leaf \
    "$OBJECTS/$output_leaf" "$OBJECTS" "object output $output_leaf"
done
for output_leaf in "${BUILD_OUTPUTS[@]}"; do
  am12_evidence_require_output_leaf \
    "$BUILD/$output_leaf" "$BUILD" "build output $output_leaf"
done
for output_leaf in "${GENERATED_OUTPUTS[@]}"; do
  am12_evidence_require_output_leaf \
    "$GENERATED/$output_leaf" "$GENERATED" "generated output $output_leaf"
done

IN_PROGRESS_BUILD_MANIFEST="$NATIVE_STAGING/BUILD-MANIFEST.in-progress"
{
  printf 'schema: com.alloy.metal12.build-manifest.v1\n'
  printf 'author: Timur Isaev\n'
  printf 'status: in-progress\n'
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
} >"$IN_PROGRESS_BUILD_MANIFEST"
mv -f "$IN_PROGRESS_BUILD_MANIFEST" "$BUILD_MANIFEST"

{
  printf '/* Generated from the canonical lowerer. Author: Timur Isaev */\n'
  run_clean_native_tool \
    "$XXD_PATH" -i -n AM12CanonicalLowererBytes "$LOWERER" |
    run_clean_native_tool "$SED_PATH" \
      -e 's/^unsigned char /static const unsigned char /' \
      -e 's/^unsigned int /static const unsigned int /'
  printf 'static const char AM12CanonicalLowererSHA256[] = "%s";\n' "$LOWERER_SHA256"
} >"$STAGED_EMBEDDED_LOWERER"
[[ -s $STAGED_EMBEDDED_LOWERER && ! -L $STAGED_EMBEDDED_LOWERER ]] ||
  {
    printf 'build: failed to stage the embedded lowerer\n' >&2
    exit 1
  }

CFLAGS=(
  -fobjc-arc
  -O2
  "-fmodules-cache-path=$STAGED_MODULE_CACHE"
  -isysroot
  "$SDK_PATH"
  -I"$SOURCE_ROOT/include"
  -I"$STAGED_GENERATED"
)
FRAMEWORKS=(
  -framework Metal
  -framework Foundation
  -framework QuartzCore
  -framework AppKit
)

compile_object() {
  local source=$1
  local object=$2
  [[ $object == "$STAGED_OBJECTS/"* ]] || {
    printf 'build: unexpected staged object path: %s\n' "$object" >&2
    return 1
  }
  run_clean_native_tool \
    "$CLANG_PATH" "${CFLAGS[@]}" -c "$source" -o "$object"
}

compile_object "$SOURCE_ROOT/Sources/AlloyMetal12.m" "$STAGED_OBJECTS/AlloyMetal12.o"
compile_object "$SOURCE_ROOT/Sources/Models/AM12DescriptorHeap.m" "$STAGED_OBJECTS/AM12DescriptorHeap.o"
compile_object "$SOURCE_ROOT/Sources/Models/AM12BarrierTracker.m" "$STAGED_OBJECTS/AM12BarrierTracker.o"
compile_object "$SOURCE_ROOT/Sources/Models/AM12ResidencyManager.m" "$STAGED_OBJECTS/AM12ResidencyManager.o"
compile_object "$SOURCE_ROOT/Sources/ShaderLowering.m" "$STAGED_OBJECTS/ShaderLowering.o"
compile_object "$SOURCE_ROOT/Sources/ShaderProofSupport.m" "$STAGED_OBJECTS/ShaderProofSupport.o"
compile_object "$SOURCE_ROOT/Sources/Proofs/DescriptorHeapProof.m" "$STAGED_OBJECTS/DescriptorHeapProof.o"
compile_object "$SOURCE_ROOT/Sources/Proofs/BarrierTrackerProof.m" "$STAGED_OBJECTS/BarrierTrackerProof.o"
compile_object "$SOURCE_ROOT/Sources/Proofs/ResidencyProof.m" "$STAGED_OBJECTS/ResidencyProof.o"

STAGED_LIBRARY="$NATIVE_STAGING/libAlloyMetal12.a"
run_clean_native_tool "$LIBTOOL_PATH" -static -o "$STAGED_LIBRARY" \
  "$STAGED_OBJECTS/AlloyMetal12.o" \
  "$STAGED_OBJECTS/AM12DescriptorHeap.o" \
  "$STAGED_OBJECTS/AM12BarrierTracker.o" \
  "$STAGED_OBJECTS/AM12ResidencyManager.o" \
  "$STAGED_OBJECTS/ShaderLowering.o" \
  "$STAGED_OBJECTS/ShaderProofSupport.o" \
  "$STAGED_OBJECTS/DescriptorHeapProof.o" \
  "$STAGED_OBJECTS/BarrierTrackerProof.o" \
  "$STAGED_OBJECTS/ResidencyProof.o"

link_executable() {
  local source=$1
  local output=$2
  [[ $output == "$NATIVE_STAGING/"* ]] || {
    printf 'build: unexpected staged executable path: %s\n' "$output" >&2
    return 1
  }
  run_clean_native_tool \
    "$CLANG_PATH" "${CFLAGS[@]}" "$source" "$STAGED_LIBRARY" \
    "-fuse-ld=$LD_PATH" "${FRAMEWORKS[@]}" -o "$output"
}

link_executable "$SOURCE_ROOT/Tests/descriptor_heap_test.m" "$NATIVE_STAGING/descriptor_heap_test"
link_executable "$SOURCE_ROOT/Tests/barrier_tracker_test.m" "$NATIVE_STAGING/barrier_tracker_test"
link_executable "$SOURCE_ROOT/Tests/residency_test.m" "$NATIVE_STAGING/residency_test"
link_executable "$SOURCE_ROOT/Tests/residency_safe_test.m" "$NATIVE_STAGING/residency_safe_test"
link_executable "$SOURCE_ROOT/Tests/lowering_api_test.m" "$NATIVE_STAGING/lowering_api_test"
link_executable "$SOURCE_ROOT/Tests/command_validation_test.m" "$NATIVE_STAGING/command_validation_test"
link_executable "$SOURCE_ROOT/Tests/trace_validation_test.m" "$NATIVE_STAGING/trace_validation_test"
link_executable "$SOURCE_ROOT/Tests/vertical_slice.m" "$NATIVE_STAGING/vertical_slice"
link_executable "$SOURCE_ROOT/Tests/ShaderRunner.m" "$NATIVE_STAGING/ShaderRunner"
link_executable "$SOURCE_ROOT/Tools/metal12_replay.m" "$NATIVE_STAGING/metal12_replay"
link_executable "$SOURCE_ROOT/Tools/metal12_lower.m" "$NATIVE_STAGING/metal12_lower"

BUILT_ARTIFACTS=(
  ShaderRunner
  barrier_tracker_test
  command_validation_test
  descriptor_heap_test
  generated/AM12EmbeddedLowerer.inc
  libAlloyMetal12.a
  lowering_api_test
  metal12_lower
  metal12_replay
  residency_safe_test
  residency_test
  trace_validation_test
  vertical_slice
)

BUILT_ARTIFACT_SHA256=()
OBJECT_SHA256=()
for output_leaf in "${OBJECT_OUTPUTS[@]}"; do
  require_built_output \
    "$STAGED_OBJECTS/$output_leaf" "$STAGED_OBJECTS" \
    "staged object output $output_leaf"
  OBJECT_SHA256+=("$(sha256_file "$STAGED_OBJECTS/$output_leaf")")
done
for output_leaf in "${BUILD_OUTPUTS[@]:1}"; do
  require_built_output \
    "$NATIVE_STAGING/$output_leaf" "$NATIVE_STAGING" \
    "staged build output $output_leaf"
done
for output_leaf in "${GENERATED_OUTPUTS[@]}"; do
  require_built_output \
    "$STAGED_GENERATED/$output_leaf" "$STAGED_GENERATED" \
    "staged generated output $output_leaf"
done
for artifact in "${BUILT_ARTIFACTS[@]}"; do
  BUILT_ARTIFACT_SHA256+=("$(sha256_file "$NATIVE_STAGING/$artifact")")
done

verify_frozen_file \
  'build producer' "$BUILD_PRODUCER_PATH" "$FROZEN_BUILD_PRODUCER_SHA256"
verify_frozen_file git "$GIT_PATH" "$FROZEN_GIT_SHA256"
verify_frozen_file shasum "$SHASUM_PATH" "$FROZEN_SHASUM_SHA256"
verify_frozen_file xcrun "$XCRUN_PATH" "$FROZEN_XCRUN_SHA256"
verify_frozen_file clang "$CLANG_PATH" "$FROZEN_CLANG_SHA256"
verify_frozen_file linker "$LD_PATH" "$FROZEN_LD_SHA256"
verify_frozen_file \
  sdk-settings "$SDK_SETTINGS_PATH" "$FROZEN_SDK_SETTINGS_SHA256"
verify_frozen_file libtool "$LIBTOOL_PATH" "$FROZEN_LIBTOOL_SHA256"
verify_frozen_file xxd "$XXD_PATH" "$FROZEN_XXD_SHA256"
verify_frozen_file sed "$SED_PATH" "$FROZEN_SED_SHA256"
am12_evidence_require_canonical_directory "$SDK_PATH" 'macOS SDK'
verify_native_toolchain_selection
am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12
am12_evidence_verify_tracked_file \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12/build.sh \
  "$BUILD_PRODUCER_PATH"

CURRENT_HEAD_COMMIT="$("$GIT_PATH" -C "$REPO" rev-parse HEAD)"
CURRENT_RUNTIME_TREE="$(
  "$GIT_PATH" -C "$REPO" rev-parse "$CURRENT_HEAD_COMMIT:runtime/metal12"
)"
CURRENT_RUNTIME_STATUS="$(
  "$GIT_PATH" -C "$REPO" status \
    --porcelain=v1 --untracked-files=normal -- runtime/metal12
)"
if [[ $CURRENT_HEAD_COMMIT != "$HEAD_COMMIT" ||
  $CURRENT_RUNTIME_TREE != "$RUNTIME_TREE" ||
  -n $CURRENT_RUNTIME_STATUS ]]; then
  printf 'build: runtime source changed during the staged build\n' >&2
  exit 1
fi
TEMPORARY_BUILD_MANIFEST="$NATIVE_STAGING/BUILD-MANIFEST.complete"
{
  printf 'schema: com.alloy.metal12.build-manifest.v1\n'
  printf 'author: Timur Isaev\n'
  printf 'status: complete\n'
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
  printf 'runtime_worktree_clean: yes\n'
  printf 'source_materialization: git-cat-file-frozen-head-v1\n'
  printf 'native_execution_environment: env-i-fixed-path-locale-tmp-v1\n'
  printf 'module_cache_policy: unique-ephemeral-not-published\n'
  printf 'native_toolchain_identity_scope: %s\n' \
    "$NATIVE_TOOLCHAIN_IDENTITY_SCOPE"
  printf 'lowerer_sha256: %s\n' "$LOWERER_SHA256"
  printf 'producer_path: %s\n' "$BUILD_PRODUCER_PATH"
  printf 'producer_sha256: %s\n' "$FROZEN_BUILD_PRODUCER_SHA256"
  printf 'git_path: %s\n' "$GIT_PATH"
  printf 'git_sha256: %s\n' "$FROZEN_GIT_SHA256"
  printf 'shasum_path: %s\n' "$SHASUM_PATH"
  printf 'shasum_sha256: %s\n' "$FROZEN_SHASUM_SHA256"
  printf 'xcrun_path: %s\n' "$XCRUN_PATH"
  printf 'xcrun_sha256: %s\n' "$FROZEN_XCRUN_SHA256"
  printf 'sdk_path: %s\n' "$SDK_PATH"
  printf 'sdk_version: %s\n' "$SDK_VERSION"
  printf 'sdk_build_version: %s\n' "$SDK_BUILD_VERSION"
  printf 'sdk_settings_path: %s\n' "$SDK_SETTINGS_PATH"
  printf 'sdk_settings_sha256: %s\n' "$FROZEN_SDK_SETTINGS_SHA256"
  printf 'clang_path: %s\n' "$CLANG_PATH"
  printf 'clang_sha256: %s\n' "$FROZEN_CLANG_SHA256"
  printf 'ld_path: %s\n' "$LD_PATH"
  printf 'ld_sha256: %s\n' "$FROZEN_LD_SHA256"
  printf 'libtool_path: %s\n' "$LIBTOOL_PATH"
  printf 'libtool_sha256: %s\n' "$FROZEN_LIBTOOL_SHA256"
  printf 'xxd_path: %s\n' "$XXD_PATH"
  printf 'xxd_sha256: %s\n' "$FROZEN_XXD_SHA256"
  printf 'sed_path: %s\n' "$SED_PATH"
  printf 'sed_sha256: %s\n' "$FROZEN_SED_SHA256"
  for ((artifact_index = 0;  \
  artifact_index < ${#BUILT_ARTIFACTS[@]};  \
  artifact_index++)); do
    printf 'artifact_sha256: %s  %s\n' \
      "${BUILT_ARTIFACT_SHA256[$artifact_index]}" \
      "${BUILT_ARTIFACTS[$artifact_index]}"
  done
} >"$TEMPORARY_BUILD_MANIFEST"
FROZEN_BUILD_MANIFEST_SHA256="$(sha256_file "$TEMPORARY_BUILD_MANIFEST")"

verify_frozen_file \
  'build producer' "$BUILD_PRODUCER_PATH" "$FROZEN_BUILD_PRODUCER_SHA256"
verify_frozen_file git "$GIT_PATH" "$FROZEN_GIT_SHA256"
verify_frozen_file shasum "$SHASUM_PATH" "$FROZEN_SHASUM_SHA256"
verify_frozen_file xcrun "$XCRUN_PATH" "$FROZEN_XCRUN_SHA256"
verify_frozen_file clang "$CLANG_PATH" "$FROZEN_CLANG_SHA256"
verify_frozen_file linker "$LD_PATH" "$FROZEN_LD_SHA256"
verify_frozen_file \
  sdk-settings "$SDK_SETTINGS_PATH" "$FROZEN_SDK_SETTINGS_SHA256"
verify_frozen_file libtool "$LIBTOOL_PATH" "$FROZEN_LIBTOOL_SHA256"
verify_frozen_file xxd "$XXD_PATH" "$FROZEN_XXD_SHA256"
verify_frozen_file sed "$SED_PATH" "$FROZEN_SED_SHA256"
verify_native_toolchain_selection
am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12
am12_evidence_verify_tracked_file \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12/build.sh \
  "$BUILD_PRODUCER_PATH"
[[ $("$GIT_PATH" -C "$REPO" rev-parse HEAD) == "$HEAD_COMMIT" ]] || {
  printf 'build: HEAD changed before manifest publication\n' >&2
  exit 1
}
[[ -z $(
  "$GIT_PATH" -C "$REPO" status \
    --porcelain=v1 --untracked-files=normal -- runtime/metal12
) ]] || {
  printf 'build: runtime source became dirty before manifest publication\n' >&2
  exit 1
}

for ((object_index = 0;  \
object_index < ${#OBJECT_OUTPUTS[@]};  \
object_index++)); do
  output_leaf=${OBJECT_OUTPUTS[$object_index]}
  [[ $(sha256_file "$STAGED_OBJECTS/$output_leaf") == "${OBJECT_SHA256[$object_index]}" ]] ||
    {
      printf 'build: staged object changed before publication: %s\n' \
        "$output_leaf" >&2
      exit 1
    }
  am12_evidence_require_output_leaf \
    "$OBJECTS/$output_leaf" "$OBJECTS" "object output $output_leaf"
  mv -f "$STAGED_OBJECTS/$output_leaf" "$OBJECTS/$output_leaf"
done
for output_leaf in "${GENERATED_OUTPUTS[@]}"; do
  am12_evidence_require_output_leaf \
    "$GENERATED/$output_leaf" "$GENERATED" \
    "generated output $output_leaf"
  mv -f "$STAGED_GENERATED/$output_leaf" "$GENERATED/$output_leaf"
done
for ((artifact_index = 0;  \
artifact_index < ${#BUILT_ARTIFACTS[@]};  \
artifact_index++)); do
  artifact=${BUILT_ARTIFACTS[$artifact_index]}
  if [[ $artifact == generated/* ]]; then
    continue
  fi
  [[ $(sha256_file "$NATIVE_STAGING/$artifact") == "${BUILT_ARTIFACT_SHA256[$artifact_index]}" ]] ||
    {
      printf 'build: staged artifact changed before publication: %s\n' \
        "$artifact" >&2
      exit 1
    }
  am12_evidence_require_output_leaf \
    "$BUILD/$artifact" "$BUILD" "build artifact $artifact"
  mv -f "$NATIVE_STAGING/$artifact" "$BUILD/$artifact"
done
for ((artifact_index = 0;  \
artifact_index < ${#BUILT_ARTIFACTS[@]};  \
artifact_index++)); do
  artifact=${BUILT_ARTIFACTS[$artifact_index]}
  [[ -s $BUILD/$artifact && ! -L $BUILD/$artifact &&
    $(sha256_file "$BUILD/$artifact") == "${BUILT_ARTIFACT_SHA256[$artifact_index]}" ]] ||
    {
      printf 'build: published artifact differs from staging: %s\n' \
        "$artifact" >&2
      exit 1
    }
done
[[ $(sha256_file "$TEMPORARY_BUILD_MANIFEST") == "$FROZEN_BUILD_MANIFEST_SHA256" ]] ||
  {
    printf 'build: final manifest changed before publication\n' >&2
    exit 1
  }
am12_evidence_require_output_leaf \
  "$BUILD_MANIFEST" "$BUILD" 'build manifest'
mv -f "$TEMPORARY_BUILD_MANIFEST" "$BUILD_MANIFEST"
[[ $(sha256_file "$BUILD_MANIFEST") == "$FROZEN_BUILD_MANIFEST_SHA256" ]] ||
  {
    printf 'build: published manifest differs from staged manifest\n' >&2
    exit 1
  }
for ((artifact_index = 0;  \
artifact_index < ${#BUILT_ARTIFACTS[@]};  \
artifact_index++)); do
  artifact=${BUILT_ARTIFACTS[$artifact_index]}
  [[ -s $BUILD/$artifact && ! -L $BUILD/$artifact &&
    $(sha256_file "$BUILD/$artifact") == "${BUILT_ARTIFACT_SHA256[$artifact_index]}" ]] ||
    {
      printf 'build: artifact changed after manifest publication: %s\n' \
        "$artifact" >&2
      exit 1
    }
done

printf 'built: %s\n' "$BUILD/libAlloyMetal12.a"
printf 'tests: %s\n' "$BUILD"
printf 'manifest: %s\n' "$BUILD_MANIFEST"
