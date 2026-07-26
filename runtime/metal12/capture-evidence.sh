#!/bin/bash
# Capture a private Metal12 build-evidence snapshot.
# Author: Timur Isaev
#
# The script reads only explicit first-party source roots and the fixed
# runtime/metal12/build output tree. It never discovers or packages ignored
# dependency checkouts. A complete capture requires signed task commits, a
# signed tag, an explicit AI-session export, and a selected manifest signer.
# External timestamping and durable storage remain separate preservation steps.
set -euo pipefail
umask 077
export GIT_OPTIONAL_LOCKS=0
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
BUILD="$ROOT/runtime/metal12/build"
OUTPUT=
BASE=origin/main
SESSION_EXPORT=
OPENPGP_KEY=
SSH_KEY=
SIGNED_TAG=
ALLOW_UNSIGNED_STAGING=0
BASE_SET=0

usage() {
  cat <<'EOF'
Usage:
  runtime/metal12/capture-evidence.sh --output ABSOLUTE_DIR [options]

Required for a complete capture:
  --output DIR              New directory outside the repository
  --session-export FILE     Explicit private export of the AI session
  --signed-tag TAG          Signed tag that resolves to HEAD
  --openpgp-key FINGERPRINT OpenPGP key used to sign SHA256SUMS
    or
  --ssh-key FILE            SSH private key used to sign SHA256SUMS

Options:
  --base REF                Task base (default: origin/main)
  --allow-unsigned-staging  Capture an explicitly incomplete local staging
                            snapshot and exit 3
  -h, --help                Show this help

The output is private, internal evidence. It is not a distributable release.
After capture, preserve the directory in durable private storage and retain an
external timestamp receipt for the signed SHA256SUMS file.
EOF
}

die() {
  printf 'evidence capture: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --output)
      (($# >= 2)) || die "--output requires a value"
      [[ -z $OUTPUT ]] || die "--output was specified more than once"
      OUTPUT=$2
      shift 2
      ;;
    --base)
      (($# >= 2)) || die "--base requires a value"
      ((BASE_SET == 0)) || die "--base was specified more than once"
      BASE=$2
      BASE_SET=1
      shift 2
      ;;
    --session-export)
      (($# >= 2)) || die "--session-export requires a value"
      [[ -z $SESSION_EXPORT ]] ||
        die "--session-export was specified more than once"
      SESSION_EXPORT=$2
      shift 2
      ;;
    --openpgp-key)
      (($# >= 2)) || die "--openpgp-key requires a value"
      [[ -z $OPENPGP_KEY ]] ||
        die "--openpgp-key was specified more than once"
      OPENPGP_KEY=$2
      shift 2
      ;;
    --ssh-key)
      (($# >= 2)) || die "--ssh-key requires a value"
      [[ -z $SSH_KEY ]] || die "--ssh-key was specified more than once"
      SSH_KEY=$2
      shift 2
      ;;
    --signed-tag)
      (($# >= 2)) || die "--signed-tag requires a value"
      [[ -z $SIGNED_TAG ]] || die "--signed-tag was specified more than once"
      SIGNED_TAG=$2
      shift 2
      ;;
    --allow-unsigned-staging)
      ((ALLOW_UNSIGNED_STAGING == 0)) ||
        die "--allow-unsigned-staging was specified more than once"
      ALLOW_UNSIGNED_STAGING=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n $OUTPUT ]] || die "--output is required"
[[ $OUTPUT == /* ]] || die "--output must be an absolute path"
[[ ! -e $OUTPUT ]] || die "output already exists: $OUTPUT"
OUTPUT_PARENT=$(cd "$(dirname "$OUTPUT")" && pwd -P)
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
case "$OUTPUT/" in
  "$ROOT/"*) die "--output must be outside the repository" ;;
esac
COMMON_GIT_DIR=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
COMMON_GIT_DIR=$(cd "$COMMON_GIT_DIR" && pwd -P)
case "$OUTPUT/" in
  "$COMMON_GIT_DIR/"*) die "--output must be outside the Git common directory" ;;
esac

if [[ -n $SESSION_EXPORT ]]; then
  [[ $SESSION_EXPORT == /* ]] ||
    die "--session-export must be an absolute path"
  [[ -f $SESSION_EXPORT && ! -L $SESSION_EXPORT ]] ||
    die "session export must be a regular non-symlink file"
fi
if [[ -n $SSH_KEY ]]; then
  [[ $SSH_KEY == /* ]] || die "--ssh-key must be an absolute path"
  [[ -f $SSH_KEY && ! -L $SSH_KEY ]] ||
    die "SSH signing key must be a regular non-symlink file"
fi

BASE_COMMIT=$(git -C "$ROOT" rev-parse --verify "$BASE^{commit}") ||
  die "base is not a commit: $BASE"
HEAD_COMMIT=$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}') ||
  die "HEAD is not a commit"
HEAD_TREE=$(git -C "$ROOT" rev-parse "$HEAD_COMMIT^{tree}")
MERGE_BASE=$(git -C "$ROOT" merge-base "$BASE_COMMIT" "$HEAD_COMMIT") ||
  die "cannot resolve merge base"
[[ $MERGE_BASE == "$BASE_COMMIT" ]] ||
  die "$BASE is not an ancestor of the captured HEAD"
WORKTREE_STATUS=$(
  git -C "$ROOT" status --porcelain=v1 --untracked-files=normal
) || die "cannot inspect worktree status"
[[ -z $WORKTREE_STATUS ]] ||
  die "tracked or nonignored untracked changes must be committed before capture"
git -C "$ROOT" ls-files --error-unmatch \
  runtime/metal12/capture-evidence.sh >/dev/null ||
  die "capture-evidence.sh is not tracked"
CAPTURE_SCRIPT_BLOB=$(
  git -C "$ROOT" hash-object "$ROOT/runtime/metal12/capture-evidence.sh"
)
HEAD_CAPTURE_SCRIPT_BLOB=$(
  git -C "$ROOT" rev-parse \
    "$HEAD_COMMIT:runtime/metal12/capture-evidence.sh"
)
[[ $CAPTURE_SCRIPT_BLOB == "$HEAD_CAPTURE_SCRIPT_BLOB" ]] ||
  die "capture-evidence.sh does not match the captured HEAD"

validate_changed_path() {
  local changed_path=$1
  [[ -n $changed_path ]] || return 0
  case "$changed_path" in
    runtime/metal12/* | spikes/M12-00[1-6]/* | \
      docs/adr/ADR-0012-metal12-provenance-and-clean-room.md | \
      docs/CONTRIBUTING.md | PROVENANCE.log)
      ;;
    *)
      die "task range contains a path outside the evidence allowlist: $changed_path"
      ;;
  esac
}

NET_CHANGED_PATHS=$(
  git -C "$ROOT" diff --no-renames --name-only \
    "$BASE_COMMIT" "$HEAD_COMMIT"
) || die "cannot inspect task paths"
while IFS= read -r changed_path; do
  validate_changed_path "$changed_path"
done <<<"$NET_CHANGED_PATHS"

TASK_COMMITS_TEXT=$(
  git -C "$ROOT" rev-list --reverse "$BASE_COMMIT".."$HEAD_COMMIT"
) || die "cannot enumerate task commits"
TASK_COMMITS=()
while IFS= read -r commit; do
  [[ -n $commit ]] && TASK_COMMITS+=("$commit")
done <<<"$TASK_COMMITS_TEXT"

COMMIT_COUNT=0
UNSIGNED_COUNT=0
EXPECTED_PARENT=$BASE_COMMIT
for commit in "${TASK_COMMITS[@]}"; do
  ((COMMIT_COUNT += 1))
  COMMIT_PARENTS=$(git -C "$ROOT" log -1 --format=%P "$commit") ||
    die "cannot inspect commit parents: $commit"
  [[ $COMMIT_PARENTS == "$EXPECTED_PARENT" ]] ||
    die "task history must be linear from the frozen base: $commit"
  COMMIT_CHANGED_PATHS=$(
    git -C "$ROOT" diff-tree --no-commit-id --no-renames \
      --name-only -r "$EXPECTED_PARENT" "$commit"
  ) || die "cannot inspect commit paths: $commit"
  while IFS= read -r changed_path; do
    validate_changed_path "$changed_path"
  done <<<"$COMMIT_CHANGED_PATHS"
  signature_status=$(git -C "$ROOT" log -1 --format=%G? "$commit")
  case "$signature_status" in
    G | U) ;;
    *) ((UNSIGNED_COUNT += 1)) ;;
  esac
  [[ $(git -C "$ROOT" log -1 --format=%an "$commit") == "Timur Isaev" ]] ||
    die "commit $commit has an unexpected author name"
  [[ $(git -C "$ROOT" log -1 --format=%cn "$commit") == "Timur Isaev" ]] ||
    die "commit $commit has an unexpected committer name"
  EXPECTED_PARENT=$commit
done
((COMMIT_COUNT > 0)) || die "no task commits found after $BASE"

TAG_OBJECT=
EXPECTED_SIGNER_FINGERPRINT=
FINGERPRINT_FORMAT=
if ((ALLOW_UNSIGNED_STAGING)); then
  [[ -z $OPENPGP_KEY && -z $SSH_KEY && -z $SIGNED_TAG ]] ||
    die "staging mode does not accept a signer or signed tag"
  SIGNATURE_KIND=not-provided
else
  ((UNSIGNED_COUNT == 0)) ||
    die "$UNSIGNED_COUNT task commit(s) are not verifiably signed"
  [[ -n $SIGNED_TAG ]] || die "--signed-tag is required"
  [[ -n $SESSION_EXPORT ]] || die "--session-export is required"
  if [[ -n $OPENPGP_KEY && -n $SSH_KEY ]]; then
    die "select exactly one manifest signer"
  fi
  [[ -n $OPENPGP_KEY || -n $SSH_KEY ]] ||
    die "--openpgp-key or --ssh-key is required"
  if [[ -n $OPENPGP_KEY ]]; then
    [[ $OPENPGP_KEY =~ ^[[:xdigit:]]{40}([[:xdigit:]]{24})?$ ]] ||
      die "--openpgp-key must be a full fingerprint"
    gpg --batch --list-secret-keys "$OPENPGP_KEY" >/dev/null 2>&1 ||
      die "selected OpenPGP secret key is unavailable"
    EXPECTED_SIGNER_FINGERPRINT=$(
      gpg --batch --with-colons --fingerprint "$OPENPGP_KEY" |
        awk -F: '$1 == "fpr" { print toupper($10); exit }'
    )
    NORMALIZED_OPENPGP_KEY=$(printf '%s' "$OPENPGP_KEY" | tr '[:lower:]' '[:upper:]')
    [[ $NORMALIZED_OPENPGP_KEY == "$EXPECTED_SIGNER_FINGERPRINT" ]] ||
      die "selected OpenPGP fingerprint is ambiguous"
    FINGERPRINT_FORMAT=%GP
    SIGNATURE_KIND=openpgp
  else
    EXPECTED_SIGNER_FINGERPRINT=$(
      ssh-keygen -lf "$SSH_KEY" -E sha256 | awk '{print $2}'
    ) || die "cannot resolve SSH signing-key fingerprint"
    [[ -n $EXPECTED_SIGNER_FINGERPRINT ]] ||
      die "SSH signing-key fingerprint is empty"
    FINGERPRINT_FORMAT=%GF
    SIGNATURE_KIND=ssh
  fi
  TAG_OBJECT=$(git -C "$ROOT" rev-parse --verify "$SIGNED_TAG^{tag}") ||
    die "signed tag is not an annotated tag: $SIGNED_TAG"
  git -C "$ROOT" verify-tag "$TAG_OBJECT" >/dev/null 2>&1 ||
    die "tag signature did not verify: $SIGNED_TAG"
  [[ $(git -C "$ROOT" rev-list -n 1 "$TAG_OBJECT") == "$HEAD_COMMIT" ]] ||
    die "signed tag does not resolve to the captured HEAD: $SIGNED_TAG"
  for commit in "${TASK_COMMITS[@]}"; do
    git -C "$ROOT" verify-commit "$commit" >/dev/null 2>&1 ||
      die "commit signature did not verify: $commit"
    commit_fingerprint=$(
      git -C "$ROOT" log -1 --format="$FINGERPRINT_FORMAT" "$commit"
    )
    [[ $commit_fingerprint == "$EXPECTED_SIGNER_FINGERPRINT" ]] ||
      die "commit was signed by an unexpected key: $commit"
  done
  tag_fingerprint=$(
    git -C "$ROOT" verify-tag --format="$FINGERPRINT_FORMAT" \
      "$TAG_OBJECT" 2>/dev/null
  ) || die "cannot inspect signed-tag fingerprint"
  [[ $tag_fingerprint == "$EXPECTED_SIGNER_FINGERPRINT" ]] ||
    die "tag was signed by an unexpected key: $SIGNED_TAG"
fi

[[ -d $BUILD && ! -L $BUILD ]] ||
  die "Metal12 build output is missing or symlinked: $BUILD"
[[ $(cd "$BUILD" && pwd -P) == "$BUILD" ]] ||
  die "Metal12 build output resolves outside its fixed path"
for build_subdirectory in generated graphics-regression model-proofs reference shaders; do
  build_subdirectory_path="$BUILD/$build_subdirectory"
  [[ -d $build_subdirectory_path && ! -L $build_subdirectory_path ]] ||
    die "build evidence directory is missing or symlinked: $build_subdirectory"
  [[ $(cd "$build_subdirectory_path" && pwd -P) == "$build_subdirectory_path" ]] ||
    die "build evidence directory resolves outside its fixed path: $build_subdirectory"
done
RUNTIME_TREE=$(git -C "$ROOT" rev-parse "$HEAD_COMMIT:runtime/metal12")
BUILD_MANIFEST="$BUILD/BUILD-MANIFEST.txt"
[[ -s $BUILD_MANIFEST && ! -L $BUILD_MANIFEST ]] ||
  die "build manifest is missing, empty, or symlinked"
grep -Fqx "head_commit: $HEAD_COMMIT" "$BUILD_MANIFEST" ||
  die "build manifest is not bound to the captured HEAD"
grep -Fqx "runtime_tree: $RUNTIME_TREE" "$BUILD_MANIFEST" ||
  die "build manifest is not bound to the captured runtime tree"
grep -Fqx 'runtime_worktree_clean: yes' "$BUILD_MANIFEST" ||
  die "build manifest records a dirty runtime worktree"
BUILD_MANIFEST_SHA256=$(shasum -a 256 "$BUILD_MANIFEST" | awk '{print $1}')

mkdir -m 700 "$OUTPUT"
printf 'INCOMPLETE\n' >"$OUTPUT/SNAPSHOT-STATUS"
COPIED_SOURCES=()
COPIED_RELATIVES=()

write_snapshot_status() {
  local status=$1
  local temporary_status
  temporary_status=$(mktemp "$OUTPUT/.SNAPSHOT-STATUS.XXXXXX")
  printf '%s\n' "$status" >"$temporary_status"
  mv -f "$temporary_status" "$OUTPUT/SNAPSHOT-STATUS"
}

copy_file() {
  local source=$1
  local relative=$2
  local source_hash
  local destination_hash
  [[ -s $source && ! -L $source ]] ||
    die "required evidence file is missing, empty, or not regular: $source"
  source_hash=$(shasum -a 256 "$source" | awk '{print $1}')
  mkdir -p "$OUTPUT/$(dirname "$relative")"
  COPYFILE_DISABLE=1 cp -p "$source" "$OUTPUT/$relative"
  destination_hash=$(shasum -a 256 "$OUTPUT/$relative" | awk '{print $1}')
  [[ $source_hash == "$destination_hash" ]] ||
    die "source changed while it was copied: $source"
  COPIED_SOURCES+=("$source")
  COPIED_RELATIVES+=("$relative")
}

manifest_field() {
  local manifest=$1
  local key=$2
  awk -F': ' -v key="$key" \
    '$1 == key { value = $2; count += 1 }
      END { if (count == 1) print value; else exit 1 }' \
    "$manifest"
}

verify_run_manifest() {
  local manifest=$1
  local schema=$2
  local producer=$3
  local recorded_build_manifest_sha256
  local expected_producer_sha256
  local recorded_producer_sha256

  [[ $(manifest_field "$manifest" schema) == "$schema" ]] ||
    die "run manifest has the wrong schema: $manifest"
  [[ $(manifest_field "$manifest" head_commit) == "$HEAD_COMMIT" ]] ||
    die "run manifest is not bound to the captured HEAD: $manifest"
  [[ $(manifest_field "$manifest" runtime_tree) == "$RUNTIME_TREE" ]] ||
    die "run manifest is not bound to the captured runtime tree: $manifest"
  recorded_build_manifest_sha256=$(
    manifest_field "$manifest" build_manifest_sha256
  )
  [[ $recorded_build_manifest_sha256 == "$BUILD_MANIFEST_SHA256" ]] ||
    die "run manifest is not bound to the current build manifest: $manifest"
  expected_producer_sha256=$(shasum -a 256 "$producer" | awk '{print $1}')
  recorded_producer_sha256=$(manifest_field "$manifest" producer_sha256)
  [[ $recorded_producer_sha256 == "$expected_producer_sha256" ]] ||
    die "run manifest has the wrong producer hash: $manifest"
}

verify_run_artifact() {
  local manifest=$1
  local relative=$2
  local source=$3
  local expected_artifact_hash
  local actual_artifact_hash

  expected_artifact_hash=$(
    awk -v artifact="$relative" \
      '$1 == "artifact_sha256:" && $3 == artifact {
        value = $2
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
      "$manifest"
  ) || die "run manifest omits or duplicates artifact: $relative"
  actual_artifact_hash=$(shasum -a 256 "$source" | awk '{print $1}')
  [[ $actual_artifact_hash == "$expected_artifact_hash" ]] ||
    die "run artifact does not match its manifest: $relative"
}

SOURCE_PATHS=(
  PROVENANCE.log
  docs/CONTRIBUTING.md
  docs/adr/ADR-0012-metal12-provenance-and-clean-room.md
  runtime/content-store
  runtime/metal12
  spikes/M12-001
  spikes/M12-002
  spikes/M12-003
  spikes/M12-004
  spikes/M12-005
  spikes/M12-006
  third_party/MANIFEST.toml
  third_party/deps.lock
)
for source_path in "${SOURCE_PATHS[@]}"; do
  git -C "$ROOT" cat-file -e "$HEAD_COMMIT:$source_path" ||
    die "approved source path is not tracked at HEAD: $source_path"
done

SHORT_COMMIT=${HEAD_COMMIT:0:12}

mkdir -p "$OUTPUT/source" "$OUTPUT/metadata/commits"
git -C "$ROOT" archive --format=tar \
  --prefix="alloy-metal12-$SHORT_COMMIT/" "$HEAD_COMMIT" -- \
  "${SOURCE_PATHS[@]}" |
  gzip -n >"$OUTPUT/source/alloy-metal12-$SHORT_COMMIT.tar.gz"
git -C "$ROOT" format-patch --stdout --binary --no-signature \
  "$BASE_COMMIT".."$HEAD_COMMIT" >"$OUTPUT/source/task-commits.patch"
git -C "$ROOT" diff --check "$BASE_COMMIT".."$HEAD_COMMIT"
git -C "$ROOT" log --reverse \
  --format='%H %G? %an <%ae> %cn <%ce> %aI %cI %s' \
  "$BASE_COMMIT".."$HEAD_COMMIT" \
  >"$OUTPUT/metadata/commit-list.txt"
for commit in "${TASK_COMMITS[@]}"; do
  git -C "$ROOT" cat-file commit "$commit" \
    >"$OUTPUT/metadata/commits/$commit.commit"
done
if [[ -n $TAG_OBJECT ]]; then
  git -C "$ROOT" cat-file tag "$TAG_OBJECT" \
    >"$OUTPUT/metadata/signed-tag-object.txt"
fi

REQUIRED_BUILD_FILES=(
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
for build_file in "${REQUIRED_BUILD_FILES[@]}"; do
  copy_file "$BUILD/$build_file" "build/$build_file"
done

verify_build_manifest_artifact() {
  local build_file=$1
  local expected_artifact_hash
  local actual_artifact_hash
  expected_artifact_hash=$(
    awk -v artifact="$build_file" \
      '$1 == "artifact_sha256:" && $3 == artifact { print $2 }' \
      "$BUILD_MANIFEST"
  )
  [[ -n $expected_artifact_hash ]] ||
    die "build manifest omits artifact: $build_file"
  actual_artifact_hash=$(shasum -a 256 "$BUILD/$build_file" | awk '{print $1}')
  [[ $actual_artifact_hash == "$expected_artifact_hash" ]] ||
    die "build artifact does not match its manifest: $build_file"
}

for build_file in "${REQUIRED_BUILD_FILES[@]:1}"; do
  verify_build_manifest_artifact "$build_file"
done

MODEL_MANIFEST="$BUILD/model-proofs/RUN-MANIFEST.txt"
verify_run_manifest "$MODEL_MANIFEST" \
  com.alloy.metal12.model-proofs.v1 "$ROOT/runtime/metal12/run-model-proofs.sh"
MODEL_STATUS=$(manifest_field "$MODEL_MANIFEST" status)
MODEL_RESIDENCY_MODE=$(manifest_field "$MODEL_MANIFEST" residency_mode)
case "$MODEL_STATUS:$MODEL_RESIDENCY_MODE" in
  incomplete-pressure-not-run:none)
    MODEL_ARTIFACTS=(descriptor-heap.log barrier-tracker.log)
    ;;
  incomplete-pressure-not-run:safe)
    MODEL_ARTIFACTS=(
      descriptor-heap.log
      barrier-tracker.log
      residency-safe.log
    )
    ;;
  complete-pressure-pass:pressure)
    MODEL_ARTIFACTS=(
      descriptor-heap.log
      barrier-tracker.log
      residency-pressure.log
    )
    ;;
  *)
    die "model-proof manifest has an invalid status/mode pair"
    ;;
esac
if ((ALLOW_UNSIGNED_STAGING == 0)) &&
  [[ $MODEL_STATUS != complete-pressure-pass ]]; then
  die "complete capture requires the residency-pressure proof"
fi
copy_file "$MODEL_MANIFEST" "build/model-proofs/RUN-MANIFEST.txt"
for model_artifact in "${MODEL_ARTIFACTS[@]}"; do
  verify_run_artifact "$MODEL_MANIFEST" \
    "model-proofs/$model_artifact" "$BUILD/model-proofs/$model_artifact"
  copy_file "$BUILD/model-proofs/$model_artifact" \
    "build/model-proofs/$model_artifact"
done

copy_file "$BUILD/generated/AM12EmbeddedLowerer.inc" \
  "build/generated/AM12EmbeddedLowerer.inc"
verify_build_manifest_artifact generated/AM12EmbeddedLowerer.inc

REFERENCE_MANIFEST="$BUILD/reference/RUN-MANIFEST.txt"
verify_run_manifest "$REFERENCE_MANIFEST" \
  com.alloy.metal12.reference-trace.v1 \
  "$ROOT/runtime/metal12/run-reference-trace.sh"
[[ $(manifest_field "$REFERENCE_MANIFEST" status) == complete-presented ]] ||
  die "reference-trace evidence does not include presentation"
copy_file "$REFERENCE_MANIFEST" "build/reference/RUN-MANIFEST.txt"

REFERENCE_ARTIFACTS=(
  capture-a.bmp
  capture-a.log
  capture-b.bmp
  capture-b.log
  command-validation.log
  dxc-stderr.log
  gptk-compare.log
  live.bmp
  live.log
  presented.bmp
  presented.log
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
for reference_artifact in "${REFERENCE_ARTIFACTS[@]}"; do
  verify_run_artifact "$REFERENCE_MANIFEST" \
    "reference/$reference_artifact" \
    "$BUILD/reference/$reference_artifact"
  copy_file "$BUILD/reference/$reference_artifact" \
    "build/reference/$reference_artifact"
done

GRAPHICS_ARTIFACTS=(
  ps.air
  ps.metal
  ps.provenance.json
  vs.air
  vs.metal
  vs.provenance.json
)
for graphics_artifact in "${GRAPHICS_ARTIFACTS[@]}"; do
  verify_run_artifact "$REFERENCE_MANIFEST" \
    "graphics-regression/$graphics_artifact" \
    "$BUILD/graphics-regression/$graphics_artifact"
  copy_file "$BUILD/graphics-regression/$graphics_artifact" \
    "build/graphics-regression/$graphics_artifact"
done

SHADER_MANIFEST="$BUILD/shaders/RUN-MANIFEST.txt"
verify_run_manifest "$SHADER_MANIFEST" \
  com.alloy.metal12.shader-corpus.v1 \
  "$ROOT/runtime/metal12/run-shader-corpus.sh"
[[ $(manifest_field "$SHADER_MANIFEST" status) == complete ]] ||
  die "shader-corpus manifest is not complete"
SHADER_SUPPORTED_PASSES=$(manifest_field "$SHADER_MANIFEST" supported_passes)
SHADER_NAMED_REJECTIONS=$(manifest_field "$SHADER_MANIFEST" named_rejections)
SHADER_FAILURES=$(manifest_field "$SHADER_MANIFEST" failures)
[[ $SHADER_SUPPORTED_PASSES == 10 &&
  $SHADER_NAMED_REJECTIONS == 1 &&
  $SHADER_FAILURES == 0 ]] ||
  die "shader-corpus manifest has the wrong outcome counts"
copy_file "$SHADER_MANIFEST" "build/shaders/RUN-MANIFEST.txt"

SUPPORTED_SHADER_CASES=(
  add_cs
  clamp_cs
  intops_cs
  select_cs
  texture_bilinear_cs
  texture_point_cs
  twobuf_cs
  wave_cs
  wave_lane_index_cs
  wave_prefix_sum_cs
)
SUPPORTED_SHADER_SUFFIXES=(
  compile-key
  dxc.log
  dxil
  ll
  lower.log
  metal
  metallib
  provenance.json
  width
)
for shader_case in "${SUPPORTED_SHADER_CASES[@]}"; do
  for shader_suffix in "${SUPPORTED_SHADER_SUFFIXES[@]}"; do
    shader_artifact="$shader_case.$shader_suffix"
    verify_run_artifact "$SHADER_MANIFEST" \
      "shaders/$shader_artifact" "$BUILD/shaders/$shader_artifact"
    copy_file "$BUILD/shaders/$shader_artifact" \
      "build/shaders/$shader_artifact"
  done
  case "$shader_case" in
    add_cs | clamp_cs | intops_cs | select_cs)
      SHADER_CASE_DATA_SUFFIXES=(
        u0.in.bin
        u0.in.bin.out
        u0.ref.bin
      )
      ;;
    texture_bilinear_cs | texture_point_cs | wave_cs | \
      wave_lane_index_cs | wave_prefix_sum_cs)
      SHADER_CASE_DATA_SUFFIXES=(
        u0.in.bin
        u0.in.bin.out
        u0.runtime.ref.bin
      )
      ;;
    twobuf_cs)
      SHADER_CASE_DATA_SUFFIXES=(
        u0.in.bin
        u0.in.bin.out
        u0.ref.bin
        u1.in.bin
        u1.in.bin.out
        u1.ref.bin
      )
      ;;
    *)
      die "shader data allowlist is incomplete: $shader_case"
      ;;
  esac
  for shader_suffix in "${SHADER_CASE_DATA_SUFFIXES[@]}"; do
    shader_artifact="$shader_case.$shader_suffix"
    verify_run_artifact "$SHADER_MANIFEST" \
      "shaders/$shader_artifact" "$BUILD/shaders/$shader_artifact"
    copy_file "$BUILD/shaders/$shader_artifact" \
      "build/shaders/$shader_artifact"
  done
done

REJECTED_SHADER_ARTIFACTS=(
  wave_read_lane_unsupported_cs.compile-key
  wave_read_lane_unsupported_cs.dxc.log
  wave_read_lane_unsupported_cs.dxil
  wave_read_lane_unsupported_cs.ll
  wave_read_lane_unsupported_cs.lower.log
)
for shader_artifact in "${REJECTED_SHADER_ARTIFACTS[@]}"; do
  verify_run_artifact "$SHADER_MANIFEST" \
    "shaders/$shader_artifact" "$BUILD/shaders/$shader_artifact"
  copy_file "$BUILD/shaders/$shader_artifact" \
    "build/shaders/$shader_artifact"
done
verify_run_artifact "$SHADER_MANIFEST" \
  shaders/texture-rgba32f.bin "$BUILD/shaders/texture-rgba32f.bin"
copy_file "$BUILD/shaders/texture-rgba32f.bin" \
  "build/shaders/texture-rgba32f.bin"

if [[ -n $SESSION_EXPORT ]]; then
  copy_file "$SESSION_EXPORT" "private/ai-session-export"
  chmod 600 "$OUTPUT/private/ai-session-export"
fi

{
  printf 'INTERNAL - NON-DISTRIBUTABLE\n\n'
  printf 'Contains proprietary Metal12 binaries, shader intermediates, '
  printf 'captures, logs, and potentially a private AI-session export.\n'
  printf 'Do not publish, attach to a public pull request, upload to public '
  printf 'CI or artifact storage, or redistribute.\n\n'
  printf 'Creator: Timur Isaev\n\n'
  printf 'This is ADR-0012 evidence, not a clean-room certification or '
  printf 'legal conclusion.\n'
} >"$OUTPUT/CLASSIFICATION.txt"

{
  printf 'author: Timur Isaev\n'
  printf 'classification: private internal evidence; not distributable\n'
  printf 'evidence_claim: evidence; not clean-room certification\n'
  printf 'capture_mode: existing-artifacts-only\n'
  printf 'tests_executed_by_capture: none\n'
  printf 'network_access_by_capture: none\n'
  printf 'ai_corpus_verification_by_capture: not-performed\n'
  printf 'created_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'head_tree: %s\n' "$HEAD_TREE"
  printf 'base_ref: %s\n' "$BASE"
  printf 'base_commit: %s\n' "$BASE_COMMIT"
  printf 'merge_base: %s\n' "$MERGE_BASE"
  printf 'task_commit_count: %s\n' "$COMMIT_COUNT"
  printf 'unsigned_or_unverified_commit_count: %s\n' "$UNSIGNED_COUNT"
  printf 'signed_tag: %s\n' "${SIGNED_TAG:-not-provided}"
  printf 'ai_session_export: %s\n' "$([[ -n $SESSION_EXPORT ]] && printf provided || printf not-provided)"
  printf 'manifest_signature: %s\n' "$SIGNATURE_KIND"
  printf 'external_timestamp: pending-after-capture\n'
  printf 'durable_private_upload: pending-after-capture\n'
  printf 'residency_pressure_executed_by_capture: no\n'
  printf 'model_proof_evidence_status: %s\n' "$MODEL_STATUS"
  printf 'reference_trace_evidence_status: complete-presented\n'
  printf 'shader_corpus_evidence_status: complete\n'
} >"$OUTPUT/EVIDENCE-RECORD.txt"

if [[ $SIGNATURE_KIND == openpgp ]]; then
  gpg --batch --with-colons --fingerprint "$OPENPGP_KEY" |
    awk -F: '$1 == "fpr" { print "openpgp_fingerprint: " $10; found = 1; exit }
      END { if (!found) exit 1 }' \
      >"$OUTPUT/metadata/snapshot-signer.txt"
elif [[ $SIGNATURE_KIND == ssh ]]; then
  ssh-keygen -lf "$SSH_KEY" >"$OUTPUT/metadata/snapshot-signer.txt"
fi

git -C "$ROOT" status --porcelain=v2 --branch --untracked-files=normal \
  >"$OUTPUT/metadata/git-status-porcelain-v2.txt"
git -C "$ROOT" status --short --branch --untracked-files=normal \
  >"$OUTPUT/metadata/git-status-short.txt"

{
  uname -srm
  sw_vers
  printf '\nBash:\n'
  /bin/bash --version 2>&1
  printf '\nXcode:\n'
  xcodebuild -version 2>&1 || printf 'unavailable\n'
  printf '\nSDK:\n'
  xcrun --sdk macosx --show-sdk-path 2>&1 || printf 'unavailable\n'
  xcrun --sdk macosx --show-sdk-version 2>&1 || printf 'unavailable\n'
  printf '\nClang:\n'
  xcrun --sdk macosx clang --version 2>&1 || printf 'unavailable\n'
  printf '\nMetal:\n'
  xcrun --sdk macosx metal --version 2>&1 || printf 'unavailable\n'
  printf '\nLibtool:\n'
  libtool -V 2>&1 || printf 'unavailable\n'
  printf '\nGit:\n'
  git --version
  printf '\nPython:\n'
  /usr/bin/python3 --version 2>&1
  printf '\nShasum:\n'
  shasum --version 2>&1 || printf 'unavailable\n'
  printf '\nHardware model and memory:\n'
  sysctl -n hw.model hw.memsize 2>&1 || printf 'unavailable\n'
} >"$OUTPUT/metadata/environment.txt"

CAPTURE_TOOLS=(
  awk
  bash
  cmp
  cp
  find
  git
  gzip
  shasum
  sort
  ssh-keygen
)
[[ $SIGNATURE_KIND == openpgp ]] && CAPTURE_TOOLS+=(gpg)
{
  for capture_tool in "${CAPTURE_TOOLS[@]}"; do
    capture_tool_path=$(command -v "$capture_tool") ||
      die "capture tool is unavailable: $capture_tool"
    [[ $capture_tool_path == /* && -f $capture_tool_path ]] ||
      die "capture tool does not resolve to a regular executable: $capture_tool"
    capture_tool_sha256=$(shasum -a 256 "$capture_tool_path" | awk '{print $1}')
    printf '%s\t%s\t%s\n' \
      "$capture_tool" "$capture_tool_path" "$capture_tool_sha256"
  done
} >"$OUTPUT/metadata/capture-tools.tsv"

[[ $(git -C "$ROOT" rev-parse 'HEAD^{commit}') == "$HEAD_COMMIT" ]] ||
  die "HEAD changed during evidence capture"
[[ $(git -C "$ROOT" rev-parse "$HEAD_COMMIT^{tree}") == "$HEAD_TREE" ]] ||
  die "HEAD tree changed during evidence capture"
[[ -z $(git -C "$ROOT" status --porcelain=v1 --untracked-files=normal) ]] ||
  die "tracked worktree state changed during evidence capture"
for ((copy_index = 0; copy_index < ${#COPIED_SOURCES[@]}; copy_index++)); do
  source_hash=$(shasum -a 256 "${COPIED_SOURCES[$copy_index]}" | awk '{print $1}')
  destination_hash=$(
    shasum -a 256 "$OUTPUT/${COPIED_RELATIVES[$copy_index]}" |
      awk '{print $1}'
  )
  [[ $source_hash == "$destination_hash" ]] ||
    die "source changed after capture: ${COPIED_SOURCES[$copy_index]}"
done
cmp "$OUTPUT/build/reference/reference-a.am12" \
  "$OUTPUT/build/reference/reference-b.am12" >/dev/null ||
  die "canonical trace captures differ"
for reference_image in capture-a.bmp capture-b.bmp replay.bmp presented.bmp; do
  cmp "$OUTPUT/build/reference/live.bmp" \
    "$OUTPUT/build/reference/$reference_image" >/dev/null ||
    die "canonical reference image differs: $reference_image"
done

if ((ALLOW_UNSIGNED_STAGING)); then
  {
    printf 'This is an incomplete staging snapshot.\n'
    printf 'It is not ADR-0012 preservation evidence.\n'
    printf 'Unsigned or unverifiable task commits: %s\n' "$UNSIGNED_COUNT"
    printf 'AI session export: %s\n' "$([[ -n $SESSION_EXPORT ]] && printf provided || printf missing)"
    printf 'Signed tag: %s\n' "${SIGNED_TAG:-missing}"
    printf 'Manifest signature: missing\n'
    printf 'External timestamp and durable private upload: pending\n'
  } >"$OUTPUT/OPEN-GAPS.txt"
else
  {
    printf 'Capture prerequisites verified.\n'
    printf 'Preserve this directory in durable private storage.\n'
    printf 'Retain an external timestamp receipt for SHA256SUMS.\n'
  } >"$OUTPUT/READY-FOR-EXTERNAL-PRESERVATION"
fi

CHECKSUM_TMP=$(mktemp "$OUTPUT/.SHA256SUMS.XXXXXX")
(
  cd "$OUTPUT"
  find . -type f \
    ! -name SHA256SUMS \
    ! -name SHA256SUMS.asc \
    ! -name SHA256SUMS.sig \
    ! -name SNAPSHOT-STATUS \
    ! -name '.SHA256SUMS.*' \
    ! -name '.SNAPSHOT-STATUS.*' \
    -exec shasum -a 256 {} \; |
    LC_ALL=C sort -k2 >"$CHECKSUM_TMP"
)
mv "$CHECKSUM_TMP" "$OUTPUT/SHA256SUMS"
(
  cd "$OUTPUT"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

if ((ALLOW_UNSIGNED_STAGING)); then
  write_snapshot_status STAGING_ONLY
  printf 'Incomplete staging snapshot captured at %s\n' "$OUTPUT" >&2
  exit 3
fi

if [[ $SIGNATURE_KIND == openpgp ]]; then
  gpg --batch --local-user "$OPENPGP_KEY" --armor --detach-sign \
    --output "$OUTPUT/SHA256SUMS.asc" "$OUTPUT/SHA256SUMS"
  gpg --batch --verify "$OUTPUT/SHA256SUMS.asc" "$OUTPUT/SHA256SUMS"
else
  ssh-keygen -Y sign -f "$SSH_KEY" -n alloy-metal12-evidence-v1 \
    "$OUTPUT/SHA256SUMS"
  ssh-keygen -Y check-novalidate -n alloy-metal12-evidence-v1 \
    -s "$OUTPUT/SHA256SUMS.sig" <"$OUTPUT/SHA256SUMS"
fi

(
  cd "$OUTPUT"
  shasum -a 256 -c SHA256SUMS >/dev/null
)
write_snapshot_status SIGNED_AWAITING_EXTERNAL_PRESERVATION
printf 'Signed evidence snapshot captured at %s\n' "$OUTPUT"
