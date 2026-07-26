#!/usr/bin/env bash
# Build the Alloy Metal12 library and linked proof executables.
# Author: Timur Isaev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
BUILD="$ROOT/build"
OBJECTS="$BUILD/objects"
GENERATED="$BUILD/generated"
LOWERER="$ROOT/ShaderTools/dxil_to_msl.py"
LOWERER_SHA256="$(shasum -a 256 "$LOWERER" | awk '{print $1}')"
EMBEDDED_LOWERER="$GENERATED/AM12EmbeddedLowerer.inc"

export PATH="$REPO/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin:$PATH"
mkdir -p "$OBJECTS" "$GENERATED"

TEMPORARY_EMBEDDED_LOWERER="$(mktemp "$GENERATED/.AM12EmbeddedLowerer.inc.XXXXXX")"
{
  printf '/* Generated from the canonical lowerer. Author: Timur Isaev */\n'
  xxd -i -n AM12CanonicalLowererBytes "$LOWERER" |
    sed \
      -e 's/^unsigned char /static const unsigned char /' \
      -e 's/^unsigned int /static const unsigned int /'
  printf 'static const char AM12CanonicalLowererSHA256[] = "%s";\n' "$LOWERER_SHA256"
} >"$TEMPORARY_EMBEDDED_LOWERER"
mv -f "$TEMPORARY_EMBEDDED_LOWERER" "$EMBEDDED_LOWERER"

CFLAGS=(
  -fobjc-arc
  -O2
  -I"$ROOT/include"
  -I"$GENERATED"
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
compile_object "$ROOT/Sources/Models/AM12DescriptorHeap.m" "$OBJECTS/AM12DescriptorHeap.o"
compile_object "$ROOT/Sources/Models/AM12BarrierTracker.m" "$OBJECTS/AM12BarrierTracker.o"
compile_object "$ROOT/Sources/Models/AM12ResidencyManager.m" "$OBJECTS/AM12ResidencyManager.o"
compile_object "$ROOT/Sources/ShaderLowering.m" "$OBJECTS/ShaderLowering.o"
compile_object "$ROOT/Sources/ShaderProofSupport.m" "$OBJECTS/ShaderProofSupport.o"
compile_object "$ROOT/Sources/Proofs/DescriptorHeapProof.m" "$OBJECTS/DescriptorHeapProof.o"
compile_object "$ROOT/Sources/Proofs/BarrierTrackerProof.m" "$OBJECTS/BarrierTrackerProof.o"
compile_object "$ROOT/Sources/Proofs/ResidencyProof.m" "$OBJECTS/ResidencyProof.o"

libtool -static -o "$BUILD/libAlloyMetal12.a" \
  "$OBJECTS/AlloyMetal12.o" \
  "$OBJECTS/AM12DescriptorHeap.o" \
  "$OBJECTS/AM12BarrierTracker.o" \
  "$OBJECTS/AM12ResidencyManager.o" \
  "$OBJECTS/ShaderLowering.o" \
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
link_executable "$ROOT/Tests/residency_safe_test.m" "$BUILD/residency_safe_test"
link_executable "$ROOT/Tests/lowering_api_test.m" "$BUILD/lowering_api_test"
link_executable "$ROOT/Tests/command_validation_test.m" "$BUILD/command_validation_test"
link_executable "$ROOT/Tests/trace_validation_test.m" "$BUILD/trace_validation_test"
link_executable "$ROOT/Tests/vertical_slice.m" "$BUILD/vertical_slice"
link_executable "$ROOT/Tests/ShaderRunner.m" "$BUILD/ShaderRunner"
link_executable "$ROOT/Tools/metal12_replay.m" "$BUILD/metal12_replay"
link_executable "$ROOT/Tools/metal12_lower.m" "$BUILD/metal12_lower"

printf 'built: %s\n' "$BUILD/libAlloyMetal12.a"
printf 'tests: %s\n' "$BUILD"
