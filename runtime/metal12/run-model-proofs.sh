#!/bin/bash
# Run the promoted M12-001, M12-002, and M12-004 proof thresholds.
# Author: Timur Isaev
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
BUILD="$ROOT/build"
EVIDENCE="$BUILD/model-proofs"
RUN_MANIFEST="$EVIDENCE/RUN-MANIFEST.txt"
RESIDENCY_MODE=none

if [[ ${1:-} == --include-residency-pressure ]]; then
  RESIDENCY_MODE=pressure
elif [[ ${1:-} == --include-residency-safe ]]; then
  RESIDENCY_MODE=safe
elif (($#)); then
  printf 'usage: %s [--include-residency-safe|--include-residency-pressure]\n' "$0" >&2
  exit 2
fi

mkdir -p "$EVIDENCE"
HEAD_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
RUNTIME_TREE="$(git -C "$REPO" rev-parse HEAD:runtime/metal12)"
TEMPORARY_RUN_MANIFEST="$(mktemp "$EVIDENCE/.RUN-MANIFEST.txt.XXXXXX")"
{
  printf 'schema: com.alloy.metal12.model-proofs.v1\n'
  printf 'author: Timur Isaev\n'
  printf 'status: in-progress\n'
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
} >"$TEMPORARY_RUN_MANIFEST"
mv -f "$TEMPORARY_RUN_MANIFEST" "$RUN_MANIFEST"

write_run_manifest() {
  local status=$1
  local current_head
  local current_runtime_tree
  local runtime_status
  local build_manifest_sha256
  local evidence_file
  local evidence_sha256
  local evidence_files

  current_head="$(git -C "$REPO" rev-parse HEAD)"
  current_runtime_tree="$(git -C "$REPO" rev-parse HEAD:runtime/metal12)"
  runtime_status="$(
    git -C "$REPO" status --porcelain=v1 --untracked-files=normal -- runtime/metal12
  )"
  if [[ $current_head != "$HEAD_COMMIT" ||
    $current_runtime_tree != "$RUNTIME_TREE" ||
    -n $runtime_status ]]; then
    status=invalid-source-state
  fi
  build_manifest_sha256="$(
    shasum -a 256 "$BUILD/BUILD-MANIFEST.txt" | awk '{print $1}'
  )"
  evidence_files=(descriptor-heap.log barrier-tracker.log)
  if [[ $RESIDENCY_MODE == safe ]]; then
    evidence_files+=(residency-safe.log)
  elif [[ $RESIDENCY_MODE == pressure ]]; then
    evidence_files+=(residency-pressure.log)
  fi
  TEMPORARY_RUN_MANIFEST="$(mktemp "$EVIDENCE/.RUN-MANIFEST.txt.XXXXXX")"
  {
    printf 'schema: com.alloy.metal12.model-proofs.v1\n'
    printf 'author: Timur Isaev\n'
    printf 'status: %s\n' "$status"
    printf 'residency_mode: %s\n' "$RESIDENCY_MODE"
    printf 'head_commit: %s\n' "$HEAD_COMMIT"
    printf 'runtime_tree: %s\n' "$RUNTIME_TREE"
    printf 'build_manifest_sha256: %s\n' "$build_manifest_sha256"
    printf 'producer_sha256: %s\n' \
      "$(shasum -a 256 "$ROOT/run-model-proofs.sh" | awk '{print $1}')"
    for evidence_file in "${evidence_files[@]}"; do
      [[ -s $EVIDENCE/$evidence_file ]] ||
        return 1
      evidence_sha256="$(
        shasum -a 256 "$EVIDENCE/$evidence_file" | awk '{print $1}'
      )"
      printf 'artifact_sha256: %s  model-proofs/%s\n' \
        "$evidence_sha256" "$evidence_file"
    done
  } >"$TEMPORARY_RUN_MANIFEST"
  mv -f "$TEMPORARY_RUN_MANIFEST" "$RUN_MANIFEST"
}

"$ROOT/build.sh"

printf '== descriptor heap proof\n'
"$ROOT/build/descriptor_heap_test" 2>&1 |
  tee "$EVIDENCE/descriptor-heap.log"

printf '== barrier tracker proof\n'
"$ROOT/build/barrier_tracker_test" 2>&1 |
  tee "$EVIDENCE/barrier-tracker.log"

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
  "$ROOT/build/residency_safe_test" 2>&1 |
    tee "$EVIDENCE/residency-safe.log"
  write_run_manifest incomplete-pressure-not-run
  printf '%s\n' \
    '== residency pressure proof: NOT RUN' \
    'Re-run with --include-residency-pressure only after explicit host-risk approval.' >&2
  exit 3
fi

printf '== residency proof (explicit hardware-pressure gate)\n'
"$ROOT/build/residency_test" 2>&1 |
  tee "$EVIDENCE/residency-pressure.log"

write_run_manifest complete-pressure-pass
printf 'model proofs: PASS\n'
