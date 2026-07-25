#!/usr/bin/env bash
# Stage the shippable runtime with patented-codec paths disabled (item 5).
# Author: Tim Isaev
#
# The verdict permits disabling H.264/HEVC and other unconfirmed patented-codec
# paths in the external build as an alternative to waiting on a written answer
# from the licensing administrators. This script is that disabling, made
# concrete and checkable.
#
# It stages a runtime tree and omits every module that links or implements a
# codec, then runs codec-scan.sh against the staged tree. The distinction that
# matters is between the *development* build - which may have FFmpeg available
# on the machine - and the *shipped* tree, which must not contain a reachable
# codec implementation. Only the latter is distributed, and only the latter is
# what the item 5 factual claim is about.
#
# Removal is safe for the runtime, proven rather than assumed: LEGAL-001 result
# 01 boots the entitled title with winedmo.so absent and gets 243 modules loaded,
# GameManager reached and zero load failures - identical to the run with it
# present.
#
# Usage: stage-runtime.sh <wine-build> <staging-dir>
set -euo pipefail

BUILD=${1:?wine build directory required}
STAGE=${2:?staging directory required}
HERE=$(cd "$(dirname "$0")" && pwd)

# Modules omitted from external builds because they link or implement a codec.
# Each entry is a reason, not just a name: a denylist without reasons rots.
EXCLUDE_REASONS=(
  "winedmo.so|links libavcodec/libavformat/libavutil; Wine media demux+decode"
  "winegstreamer.so|GStreamer media path; not linked today, excluded regardless"
)

echo "== staging runtime into $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"
rsync -a --exclude='*.o' --exclude='*.a' --exclude='tests/' "$BUILD/" "$STAGE/"

echo "== disabling patented-codec paths"
for entry in "${EXCLUDE_REASONS[@]}"; do
  name=${entry%%|*}
  reason=${entry#*|}
  found=0
  while IFS= read -r f; do
    rm -f "$f"
    found=1
  done < <(find "$STAGE" -name "$name" 2>/dev/null)
  if [[ $found == 1 ]]; then
    echo "   removed $name — $reason"
  else
    echo "   $name not present — $reason"
  fi
done

# Record why the staged tree differs from the build it came from, so the
# exclusion is auditable from the artifact rather than only from this script.
cat >"$STAGE/CODEC-EXCLUSIONS.txt" <<EOF
Patented-codec paths disabled in this runtime per counsel checklist item 5.
Staged from: $BUILD
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Excluded modules:
$(for e in "${EXCLUDE_REASONS[@]}"; do printf '  %s — %s\n' "${e%%|*}" "${e#*|}"; done)

Rationale: the pre-counsel verdict permits disabling H.264/HEVC and other
unconfirmed patented-codec paths in external builds instead of waiting for a
written answer from Via LA and Access Advance. Removal is proven harmless for
the runtime in LEGAL-001 result 01.

This exclusion must be revisited if a written answer is obtained (issue #49) or
if a title requires the media path.
EOF

echo "== verifying the staged tree"
"$HERE/codec-scan.sh" "$STAGE" "${3:-}" "${4:-}"
