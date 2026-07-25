#!/usr/bin/env bash
# Codec-clean gate for the shipped runtime (counsel item 5, issue #24).
# Author: Tim Isaev
#
# The pre-counsel verdict's factual argument is that this product "distributes
# no encoder, decoder implementation or encoded content" and merely passes
# game-provided bitstreams to the operating system. That is an assertion about
# the binaries, so it has to be checked against the binaries - and the first
# time it was checked, it was false: Wine's winedmo module linked libavcodec
# because configure found FFmpeg on the build machine and enabled it silently.
#
# This script fails when a codec implementation is reachable from the shipped
# runtime. It is a release gate, not a report: a green run is what licenses the
# claim, and the claim must not be made in writing to a licensing administrator
# without one.
#
# Usage: codec-scan.sh <wine-build> [provider-dir] [unixlib-dir]
set -uo pipefail

BUILD=${1:?wine build directory required}
PROVIDERS=${2:-}
UNIXLIB=${3:-}

fail=0
note() { printf '  %s\n' "$*"; }
bad() {
  printf '  FAIL: %s\n' "$*" >&2
  fail=1
}

# Symbols that indicate a codec *implementation* is present, as opposed to a
# call into the operating system's frameworks (which is the permitted design).
IMPL_SYMS='avcodec_|avformat_|av_frame_|sws_scale|swr_convert|x264_|openh264|de265_|vpx_codec'

echo "== 1. dynamic dependencies on codec libraries"
while IFS= read -r f; do
  deps=$(otool -L "$f" 2>/dev/null | tail -n +2 |
    rg -N -i -o '[^ ]*(libavcodec|libavformat|libavutil|libswscale|libswresample|libx264|libopenh264|libde265|libvpx|gstreamer)[^ ]*' || true)
  if [[ -n $deps ]]; then
    bad "$(basename "$f") links a codec library:"
    printf '        %s\n' "$deps" >&2
  fi
done < <(
  find "$BUILD" -name '*.so' -not -path '*/tests/*' 2>/dev/null
  [[ -n $PROVIDERS ]] && find "$PROVIDERS" -name '*.dll' 2>/dev/null
  [[ -n $UNIXLIB ]] && find "$UNIXLIB" -name '*.so' 2>/dev/null
)
[[ $fail == 0 ]] && note "no shipped binary links a codec library"

echo "== 2. codec-implementation symbols"
found=0
while IFS= read -r f; do
  n=$(nm -a "$f" 2>/dev/null | rg -Nc "$IMPL_SYMS" || true)
  if [[ ${n:-0} -gt 0 ]]; then
    bad "$(basename "$f") references $n codec-implementation symbols"
    found=1
  fi
done < <(find "$BUILD" -name '*.so' -not -path '*/tests/*' 2>/dev/null)
[[ $found == 0 ]] && note "no codec-implementation symbols in any shipped binary"

echo "== 3. GStreamer media path"
if rg -Nq "GSTREAMER_LIBS=''" "$BUILD/config.log" 2>/dev/null; then
  note "configure found no GStreamer (GSTREAMER_LIBS empty)"
else
  gst=$(find "$BUILD/dlls/winegstreamer" \( -name '*.so' -o -name '*.dll' \) 2>/dev/null | head -1)
  if [[ -n $gst ]]; then
    bad "winegstreamer is built as a loadable module: $gst"
  else
    note "winegstreamer has no loadable module built"
  fi
fi

echo "== 4. build provenance"
# A missing config.log must not read as a pass. "The file is not there" and
# "the option is off" are different facts, and only one of them is evidence.
#
# A staged tree is judged differently from a development build. What item 5's
# factual claim is about is the runtime that ships, so a staged tree carrying a
# recorded exclusion passes on its *contents* - checks 1 and 2 above - even
# though the build it came from had FFmpeg available. A development tree gets no
# such latitude, because nothing has excluded anything from it.
if [[ -f $BUILD/CODEC-EXCLUSIONS.txt ]]; then
  note "staged tree with recorded codec exclusions:"
  while IFS= read -r line; do note "    $line"; done \
    < <(rg -N '^  \S+\.so' "$BUILD/CODEC-EXCLUSIONS.txt" 2>/dev/null || true)
  note "contents verified by checks 1-2; source build provenance is in the file"
elif [[ ! -f $BUILD/config.log ]]; then
  bad "no config.log and no CODEC-EXCLUSIONS.txt in $BUILD - cannot be verified"
elif rg -Nq '#define HAVE_FFMPEG 1' "$BUILD/config.log" 2>/dev/null; then
  bad "HAVE_FFMPEG is set - stage with stage-runtime.sh or configure --without-ffmpeg"
else
  note "HAVE_FFMPEG is not set"
fi

echo
if [[ $fail == 0 ]]; then
  echo "CODEC-CLEAN: pass"
else
  echo "CODEC-CLEAN: FAIL - the runtime contains a codec implementation." >&2
  echo "The verdict's factual argument does not hold for this build, and the" >&2
  echo "item 5 letters must not be sent asserting that it does (see #49)." >&2
fi
exit $fail
