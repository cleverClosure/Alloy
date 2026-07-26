#!/bin/bash -p
# Run the promoted M12-001, M12-002, and M12-004 proof thresholds.
# Author: Timur Isaev
[[ $- == *p* ]] || {
  printf 'model proofs: execute this script directly; Bash privileged mode is required\n' >&2
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
EVIDENCE="$BUILD/model-proofs"
RUN_MANIFEST="$EVIDENCE/RUN-MANIFEST.txt"
BUILD_MANIFEST="$BUILD/BUILD-MANIFEST.txt"
RESIDENCY_MODE=none
RUN_STAGING=

if [[ ${1:-} == --include-residency-pressure ]]; then
  RESIDENCY_MODE=pressure
elif [[ ${1:-} == --include-residency-safe ]]; then
  RESIDENCY_MODE=safe
elif (($#)); then
  printf 'usage: %s [--include-residency-safe|--include-residency-pressure]\n' "$0" >&2
  exit 2
fi

# shellcheck source=runtime/metal12/evidence-paths.sh
source "$ROOT/evidence-paths.sh"
# shellcheck source=runtime/metal12/evidence-lock.sh
source "$ROOT/evidence-lock.sh"
# shellcheck disable=SC2119 # The sanitizer rejects forwarded arguments.
am12_evidence_sanitize_git_environment

sha256_file() {
  am12_evidence_sha256_file "$1"
}

GIT_PATH="$(
  am12_evidence_resolve_canonical_executable "$(command -v git)" git
)"
am12_evidence_lock_acquire "$ROOT" "$BUILD"
am12_evidence_lock_install_traps

run_clean_native_tool() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    TMPDIR=/tmp \
    "$@"
}

model_stage_cleanup() {
  [[ -n $RUN_STAGING ]] || return 0
  case $RUN_STAGING in
    "$BUILD"/.model-proofs-run.*) ;;
    *)
      printf 'model proofs: refusing to clean unexpected staging path: %s\n' \
        "$RUN_STAGING" >&2
      return 1
      ;;
  esac
  [[ ! -L $RUN_STAGING ]] || {
    printf 'model proofs: refusing to clean symlinked staging path\n' >&2
    return 1
  }
  [[ ! -d $RUN_STAGING ]] ||
    find "$RUN_STAGING" -depth -delete
}

model_exit() {
  local exit_status=$1

  trap - EXIT
  if ! model_stage_cleanup; then
    exit_status=1
  fi
  am12_evidence_lock_exit "$exit_status"
}

trap 'model_exit "$?"' EXIT

if [[ -e $EVIDENCE && (! -d $EVIDENCE || -L $EVIDENCE) ]]; then
  printf 'model proofs: evidence path is not a regular directory: %s\n' \
    "$EVIDENCE" >&2
  exit 1
fi
mkdir -p "$EVIDENCE"
if [[ $(cd "$EVIDENCE" && pwd -P) != "$EVIDENCE" ]]; then
  printf 'model proofs: evidence path is not canonical: %s\n' "$EVIDENCE" >&2
  exit 1
fi

RUN_STAGING="$(mktemp -d "$BUILD/.model-proofs-run.XXXXXX")"
am12_evidence_require_canonical_directory \
  "$RUN_STAGING" "model-proof staging"

rm -f \
  "$RUN_MANIFEST" \
  "$EVIDENCE/descriptor-heap.log" \
  "$EVIDENCE/barrier-tracker.log" \
  "$EVIDENCE/residency-safe.log" \
  "$EVIDENCE/residency-pressure.log"

HEAD_COMMIT="$("$GIT_PATH" -C "$REPO" rev-parse HEAD)"
RUNTIME_TREE="$(
  "$GIT_PATH" -C "$REPO" rev-parse "$HEAD_COMMIT:runtime/metal12"
)"
am12_evidence_verify_tracked_tree \
  "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12
FROZEN_PRODUCER_SHA256="$(
  sha256_file "$ROOT/run-model-proofs.sh"
)"
FROZEN_BUILD_MANIFEST_SHA256=
PROOF_BINARIES=(descriptor_heap_test barrier_tracker_test)
if [[ $RESIDENCY_MODE == safe ]]; then
  PROOF_BINARIES+=(residency_safe_test)
elif [[ $RESIDENCY_MODE == pressure ]]; then
  PROOF_BINARIES+=(residency_test)
fi
FROZEN_PROOF_BINARY_SHA256=()
PROOF_EXECUTABLES=()

manifest_field() {
  local manifest=$1
  local key=$2

  awk -v key="$key" \
    'index($0, key ": ") == 1 {
        value = substr($0, length(key) + 3)
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
    "$manifest"
}

manifest_artifact_sha256() {
  local manifest=$1
  local artifact=$2

  awk -v artifact="$artifact" \
    '$1 == "artifact_sha256:" && NF == 3 && $3 == artifact {
      value = $2
      count += 1
    }
    END { if (count == 1) print value; else exit 1 }' \
    "$manifest"
}

verify_frozen_inputs() {
  local current_head
  local current_runtime_tree
  local runtime_status
  local current_build_manifest_sha256
  local current_producer_sha256
  local proof_index
  local proof_binary
  local current_proof_binary_sha256
  local staged_proof_binary

  current_head="$("$GIT_PATH" -C "$REPO" rev-parse HEAD)"
  current_runtime_tree="$(
    "$GIT_PATH" -C "$REPO" rev-parse "$current_head:runtime/metal12"
  )"
  runtime_status="$(
    "$GIT_PATH" -C "$REPO" status \
      --porcelain=v1 --untracked-files=normal -- runtime/metal12
  )"
  if [[ $current_head != "$HEAD_COMMIT" ||
    $current_runtime_tree != "$RUNTIME_TREE" ||
    -n $runtime_status ]]; then
    printf '%s\n' \
      'model proofs: source state changed during the proof run' >&2
    return 1
  fi
  if ! am12_evidence_verify_tracked_tree \
    "$GIT_PATH" "$REPO" "$HEAD_COMMIT" runtime/metal12; then
    printf '%s\n' \
      'model proofs: tracked source bytes differ from the frozen commit' >&2
    return 1
  fi

  if [[ ! -f $BUILD_MANIFEST || -L $BUILD_MANIFEST ]]; then
    printf '%s\n' \
      'model proofs: frozen build manifest is missing or not regular' >&2
    return 1
  fi
  current_build_manifest_sha256="$(
    sha256_file "$BUILD_MANIFEST"
  )"
  if [[ $current_build_manifest_sha256 != "$FROZEN_BUILD_MANIFEST_SHA256" ]]; then
    printf '%s\n' \
      'model proofs: build manifest changed during the proof run' >&2
    return 1
  fi

  current_producer_sha256="$(
    sha256_file "$ROOT/run-model-proofs.sh"
  )"
  if [[ $current_producer_sha256 != "$FROZEN_PRODUCER_SHA256" ]]; then
    printf '%s\n' \
      'model proofs: producer changed during the proof run' >&2
    return 1
  fi

  for ((proof_index = 0; proof_index < ${#PROOF_BINARIES[@]}; proof_index++)); do
    proof_binary=${PROOF_BINARIES[$proof_index]}
    if [[ ! -f $BUILD/$proof_binary || -L $BUILD/$proof_binary ]]; then
      printf 'model proofs: proof binary is missing or not regular: %s\n' \
        "$proof_binary" >&2
      return 1
    fi
    current_proof_binary_sha256="$(
      sha256_file "$BUILD/$proof_binary"
    )"
    if [[ $current_proof_binary_sha256 != "${FROZEN_PROOF_BINARY_SHA256[$proof_index]}" ]]; then
      printf 'model proofs: proof binary changed during the run: %s\n' \
        "$proof_binary" >&2
      return 1
    fi
    staged_proof_binary=${PROOF_EXECUTABLES[$proof_index]}
    if [[ ! -x $staged_proof_binary ||
      -L $staged_proof_binary ||
      $(sha256_file "$staged_proof_binary") != "${FROZEN_PROOF_BINARY_SHA256[$proof_index]}" ]]; then
      printf 'model proofs: staged proof binary changed: %s\n' \
        "$proof_binary" >&2
      return 1
    fi
  done
}

write_run_manifest() {
  local status=$1
  local evidence_file
  local evidence_sha256
  local evidence_files
  local evidence_hashes
  local evidence_index
  local manifest_sha256
  local proof_index
  local temporary_run_manifest

  if ! verify_frozen_inputs; then
    return 1
  fi
  evidence_files=(descriptor-heap.log barrier-tracker.log)
  if [[ $RESIDENCY_MODE == safe ]]; then
    evidence_files+=(residency-safe.log)
  elif [[ $RESIDENCY_MODE == pressure ]]; then
    evidence_files+=(residency-pressure.log)
  fi
  evidence_hashes=()
  for evidence_file in "${evidence_files[@]}"; do
    if [[ ! -s $RUN_STAGING/$evidence_file ||
      -L $RUN_STAGING/$evidence_file ]]; then
      printf 'model proofs: evidence file is missing or not regular: %s\n' \
        "$evidence_file" >&2
      return 1
    fi
    evidence_sha256="$(
      sha256_file "$RUN_STAGING/$evidence_file"
    )"
    evidence_hashes+=("$evidence_sha256")
  done

  temporary_run_manifest="$RUN_STAGING/RUN-MANIFEST.txt"
  {
    printf 'schema: com.alloy.metal12.model-proofs.v1\n'
    printf 'author: Timur Isaev\n'
    printf 'status: %s\n' "$status"
    printf 'residency_mode: %s\n' "$RESIDENCY_MODE"
    printf 'head_commit: %s\n' "$HEAD_COMMIT"
    printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
    printf 'build_manifest_sha256: %s\n' "$FROZEN_BUILD_MANIFEST_SHA256"
    printf 'producer_sha256: %s\n' "$FROZEN_PRODUCER_SHA256"
    printf 'native_execution_environment: env-i-fixed-path-locale-tmp-v1\n'
    for ((proof_index = 0;  \
    proof_index < ${#PROOF_BINARIES[@]};  \
    proof_index++)); do
      printf 'invoked_binary_sha256: %s  %s\n' \
        "${FROZEN_PROOF_BINARY_SHA256[$proof_index]}" \
        "${PROOF_BINARIES[$proof_index]}"
    done
    for ((evidence_index = 0;  \
    evidence_index < ${#evidence_files[@]};  \
    evidence_index++)); do
      printf 'artifact_sha256: %s  model-proofs/%s\n' \
        "${evidence_hashes[$evidence_index]}" \
        "${evidence_files[$evidence_index]}"
    done
  } >"$temporary_run_manifest"
  manifest_sha256="$(sha256_file "$temporary_run_manifest")"

  if ! verify_frozen_inputs; then
    return 1
  fi
  for ((evidence_index = 0;  \
  evidence_index < ${#evidence_files[@]};  \
  evidence_index++)); do
    evidence_file=${evidence_files[$evidence_index]}
    am12_evidence_require_output_leaf \
      "$EVIDENCE/$evidence_file" "$EVIDENCE" \
      "model-proof artifact $evidence_file"
    mv -f "$RUN_STAGING/$evidence_file" "$EVIDENCE/$evidence_file"
  done
  for ((evidence_index = 0;  \
  evidence_index < ${#evidence_files[@]};  \
  evidence_index++)); do
    evidence_file=${evidence_files[$evidence_index]}
    [[ -s $EVIDENCE/$evidence_file &&
      ! -L $EVIDENCE/$evidence_file &&
      $(sha256_file "$EVIDENCE/$evidence_file") == "${evidence_hashes[$evidence_index]}" ]] ||
      {
        printf 'model proofs: published artifact changed: %s\n' \
          "$evidence_file" >&2
        return 1
      }
  done
  verify_frozen_inputs
  am12_evidence_require_output_leaf \
    "$RUN_MANIFEST" "$EVIDENCE" "model-proof run manifest"
  mv -f "$temporary_run_manifest" "$RUN_MANIFEST"
  [[ $(sha256_file "$RUN_MANIFEST") == "$manifest_sha256" ]] ||
    {
      printf 'model proofs: published run manifest changed\n' >&2
      return 1
    }
  for ((evidence_index = 0;  \
  evidence_index < ${#evidence_files[@]};  \
  evidence_index++)); do
    evidence_file=${evidence_files[$evidence_index]}
    [[ $(sha256_file "$EVIDENCE/$evidence_file") == "${evidence_hashes[$evidence_index]}" ]] ||
      {
        printf 'model proofs: artifact changed after manifest publication: %s\n' \
          "$evidence_file" >&2
        return 1
      }
  done
}

"$ROOT/build.sh"

if [[ ! -f $BUILD_MANIFEST || -L $BUILD_MANIFEST ]]; then
  printf '%s\n' \
    'model proofs: build did not produce a regular build manifest' >&2
  exit 1
fi
FROZEN_BUILD_MANIFEST_SHA256="$(
  sha256_file "$BUILD_MANIFEST"
)"
if [[ $(manifest_field "$BUILD_MANIFEST" schema) != com.alloy.metal12.build-manifest.v1 ||
$(manifest_field "$BUILD_MANIFEST" author) != "Timur Isaev" ||
$(manifest_field "$BUILD_MANIFEST" status) != complete ||
$(manifest_field "$BUILD_MANIFEST" head_commit) != "$HEAD_COMMIT" ||
$(manifest_field "$BUILD_MANIFEST" runtime_tree) != "$RUNTIME_TREE" ||
$(manifest_field "$BUILD_MANIFEST" runtime_worktree_clean) != yes ||
$(manifest_field "$BUILD_MANIFEST" source_materialization) != git-cat-file-frozen-head-v1 ||
$(manifest_field "$BUILD_MANIFEST" native_execution_environment) != env-i-fixed-path-locale-tmp-v1 ||
$(manifest_field "$BUILD_MANIFEST" module_cache_policy) != unique-ephemeral-not-published ||
$(manifest_field "$BUILD_MANIFEST" native_toolchain_identity_scope) != selected-executables-and-sdk-metadata-not-full-sdk-closure-v1 ]]; then
  printf '%s\n' \
    'model proofs: build manifest does not describe the frozen clean source' >&2
  exit 1
fi
for proof_binary in "${PROOF_BINARIES[@]}"; do
  if [[ ! -f $BUILD/$proof_binary || -L $BUILD/$proof_binary ]]; then
    printf 'model proofs: build omitted proof binary: %s\n' \
      "$proof_binary" >&2
    exit 1
  fi
  proof_binary_sha256="$(
    sha256_file "$BUILD/$proof_binary"
  )"
  if [[ $(manifest_artifact_sha256 "$BUILD_MANIFEST" "$proof_binary") != "$proof_binary_sha256" ]]; then
    printf 'model proofs: build manifest has the wrong binary hash: %s\n' \
      "$proof_binary" >&2
    exit 1
  fi
  FROZEN_PROOF_BINARY_SHA256+=("$proof_binary_sha256")
done
if [[ $(sha256_file "$BUILD_MANIFEST") != "$FROZEN_BUILD_MANIFEST_SHA256" ]]; then
  printf '%s\n' \
    'model proofs: build manifest changed while proof inputs were frozen' >&2
  exit 1
fi

mkdir "$RUN_STAGING/bin"
am12_evidence_require_canonical_directory \
  "$RUN_STAGING/bin" "model-proof binary staging"
for ((proof_index = 0;  \
proof_index < ${#PROOF_BINARIES[@]};  \
proof_index++)); do
  proof_binary=${PROOF_BINARIES[$proof_index]}
  staged_proof_binary="$RUN_STAGING/bin/$proof_binary"
  COPYFILE_DISABLE=1 /bin/cp -p \
    "$BUILD/$proof_binary" "$staged_proof_binary"
  [[ -x $staged_proof_binary &&
    ! -L $staged_proof_binary &&
    $(sha256_file "$staged_proof_binary") == "${FROZEN_PROOF_BINARY_SHA256[$proof_index]}" ]] ||
    {
      printf 'model proofs: could not freeze proof binary: %s\n' \
        "$proof_binary" >&2
      exit 1
    }
  PROOF_EXECUTABLES+=("$staged_proof_binary")
done

printf '== descriptor heap proof\n'
run_clean_native_tool "$RUN_STAGING/bin/descriptor_heap_test" 2>&1 |
  tee "$RUN_STAGING/descriptor-heap.log"

printf '== barrier tracker proof\n'
run_clean_native_tool "$RUN_STAGING/bin/barrier_tracker_test" 2>&1 |
  tee "$RUN_STAGING/barrier-tracker.log"

if [[ $RESIDENCY_MODE == none ]]; then
  write_run_manifest incomplete-pressure-not-run
  printf '%s\n' \
    '== residency proofs: NOT RUN' \
    'The safe path can still peak around 820 MiB; use --include-residency-safe deliberately.' \
    'The full proof allocates through Metal'\''s advisory budget and up to 1 GiB beyond it.' \
    'Use --include-residency-pressure only after explicit host-risk approval.' >&2
  exit 3
fi

if [[ $RESIDENCY_MODE == safe ]]; then
  printf '== residency proof (non-oversubscribing checks)\n'
  run_clean_native_tool "$RUN_STAGING/bin/residency_safe_test" 2>&1 |
    tee "$RUN_STAGING/residency-safe.log"
  write_run_manifest incomplete-pressure-not-run
  printf '%s\n' \
    '== residency pressure proof: NOT RUN' \
    'Re-run with --include-residency-pressure only after explicit host-risk approval.' >&2
  exit 3
fi

printf '== residency proof (explicit hardware-pressure gate)\n'
run_clean_native_tool "$RUN_STAGING/bin/residency_test" 2>&1 |
  tee "$RUN_STAGING/residency-pressure.log"

write_run_manifest complete-pressure-pass
printf 'model proofs: PASS\n'
