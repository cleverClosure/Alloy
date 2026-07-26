#!/usr/bin/env bash
# Build the Alloy Metal12 library and linked proof executables.
# Author: Timur Isaev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
BUILD="$ROOT/build"
OBJECTS="$BUILD/objects"

export PATH="$REPO/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin:$PATH"
mkdir -p "$OBJECTS"

CFLAGS=(
  -fobjc-arc
  -O2
  -I"$ROOT/include"
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
  xcrun -sdk macosx clang "${CFLAGS[@]}" -c "$source" -o "$object"
}

compile_object "$ROOT/Sources/AlloyMetal12.m" "$OBJECTS/AlloyMetal12.o"
compile_object "$ROOT/Sources/ShaderProofSupport.m" "$OBJECTS/ShaderProofSupport.o"
compile_object "$ROOT/Sources/Proofs/DescriptorHeapProof.m" "$OBJECTS/DescriptorHeapProof.o"
compile_object "$ROOT/Sources/Proofs/BarrierTrackerProof.m" "$OBJECTS/BarrierTrackerProof.o"
compile_object "$ROOT/Sources/Proofs/ResidencyProof.m" "$OBJECTS/ResidencyProof.o"

libtool -static -o "$BUILD/libAlloyMetal12.a" \
  "$OBJECTS/AlloyMetal12.o" \
  "$OBJECTS/ShaderProofSupport.o" \
  "$OBJECTS/DescriptorHeapProof.o" \
  "$OBJECTS/BarrierTrackerProof.o" \
  "$OBJECTS/ResidencyProof.o"

link_executable() {
  local source=$1
  local output=$2
  xcrun -sdk macosx clang "${CFLAGS[@]}" "$source" "$BUILD/libAlloyMetal12.a" \
    "${FRAMEWORKS[@]}" -o "$output"
}

link_executable "$ROOT/Tests/descriptor_heap_test.m" "$BUILD/descriptor_heap_test"
link_executable "$ROOT/Tests/barrier_tracker_test.m" "$BUILD/barrier_tracker_test"
link_executable "$ROOT/Tests/residency_test.m" "$BUILD/residency_test"
link_executable "$ROOT/Tests/command_validation_test.m" "$BUILD/command_validation_test"
link_executable "$ROOT/Tests/trace_validation_test.m" "$BUILD/trace_validation_test"
link_executable "$ROOT/Tests/vertical_slice.m" "$BUILD/vertical_slice"
link_executable "$ROOT/Tests/ShaderRunner.m" "$BUILD/ShaderRunner"
link_executable "$ROOT/Tools/metal12_replay.m" "$BUILD/metal12_replay"

printf 'built: %s\n' "$BUILD/libAlloyMetal12.a"
printf 'tests: %s\n' "$BUILD"
