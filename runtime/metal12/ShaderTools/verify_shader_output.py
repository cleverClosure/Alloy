#!/usr/bin/env python3
# Metal12 shader-corpus fixture generator and independent CPU reference.
# Author: Timur Isaev

import json
import math
from pathlib import Path
import struct
import sys


def load_manifest(path):
    manifest = json.loads(Path(path).read_text())
    if manifest.get("version") != 1:
        raise ValueError("shader corpus manifest version must be 1")
    cases = {case["name"]: case for case in manifest["cases"]}
    return manifest, cases


def pack_values(value_type, values):
    code = "I" if value_type == "uint" else "f"
    return struct.pack(f"<{len(values)}{code}", *values)


def unpack_values(value_type, data):
    if len(data) % 4:
        raise ValueError(f"buffer length {len(data)} is not a multiple of four")
    count = len(data) // 4
    code = "I" if value_type == "uint" else "f"
    return list(struct.unpack(f"<{count}{code}", data))


def prepare_texture(manifest, output_path):
    texture = manifest["texture"]
    expected_formula = "mip * 100 + y * 10 + x + channel * 0.25"
    if texture.get("value_formula") != expected_formula:
        raise ValueError("unknown texture value formula")
    mip_levels = texture["mip_levels"]
    maximum_mip_levels = max(texture["width"], texture["height"]).bit_length()
    if not 1 <= mip_levels <= maximum_mip_levels:
        raise ValueError("texture mip level count is outside the legal 2D chain")

    values = []
    width = texture["width"]
    height = texture["height"]
    dimensions = []
    for mip in range(mip_levels):
        dimensions.append(f"{width}x{height}")
        for y in range(height):
            for x in range(width):
                for channel in range(texture["channels"]):
                    values.append(float(mip * 100 + y * 10 + x) + channel * 0.25)
        width = max(1, width // 2)
        height = max(1, height // 2)
    Path(output_path).write_bytes(pack_values("float", values))
    print(
        f"texture fixture: {', '.join(dimensions)} RGBA32Float mip chain "
        f"-> {output_path}"
    )


def texture_reference(manifest, case, count, texture_path):
    texture = manifest["texture"]
    channels = texture["channels"]
    values = unpack_values("float", Path(texture_path).read_bytes())
    mip_levels = texture["mip_levels"]
    width = texture["width"]
    height = texture["height"]
    levels = []
    offset = 0
    for _ in range(mip_levels):
        level_value_count = width * height * channels
        levels.append((width, height, values[offset : offset + level_value_count]))
        offset += level_value_count
        width = max(1, width // 2)
        height = max(1, height // 2)
    if offset != len(values):
        raise ValueError("texture fixture dimensions do not match its byte count")

    lod = float(case["lod"])
    if not lod.is_integer() or not 0 <= lod < mip_levels:
        raise ValueError("texture CPU reference requires an in-range integer explicit LOD")
    width, height, level_values = levels[int(lod)]

    def texel(x, y):
        x = min(max(x, 0), width - 1)
        y = min(max(y, 0), height - 1)
        return level_values[(y * width + x) * channels]

    u, v = case["uv"]
    if case["sampler"] == "point":
        expected = texel(math.floor(u * width), math.floor(v * height))
    elif case["sampler"] == "linear":
        x = u * width - 0.5
        y = v * height - 0.5
        x0 = math.floor(x)
        y0 = math.floor(y)
        fx = x - x0
        fy = y - y0
        top = texel(x0, y0) * (1.0 - fx) + texel(x0 + 1, y0) * fx
        bottom = texel(x0, y0 + 1) * (1.0 - fx) + texel(x0 + 1, y0 + 1) * fx
        expected = top * (1.0 - fy) + bottom * fy
    else:
        raise ValueError(f"unknown sampler {case['sampler']}")
    return [expected] * count


def wave_reference(case, inputs, simd_width):
    count = len(inputs)
    if simd_width <= 0 or count % simd_width:
        raise ValueError(
            f"{count} threads cannot be partitioned into {simd_width}-lane SIMD groups"
        )

    operation = case["operation"]
    expected = [0] * count
    for base in range(0, count, simd_width):
        group = inputs[base : base + simd_width]
        if operation == "active_sum":
            total = sum(group)
            for lane in range(simd_width):
                expected[base + lane] = total
        elif operation == "lane_index":
            for lane in range(simd_width):
                expected[base + lane] = lane
        elif operation == "prefix_sum":
            total = 0
            for lane, value in enumerate(group):
                expected[base + lane] = total & 0xFFFFFFFF
                total = (total + value) & 0xFFFFFFFF
        else:
            raise ValueError(f"unknown wave operation {operation}")
    return expected


def compare_buffers(name, buffer_name, value_type, expected_bytes, actual_bytes):
    expected = unpack_values(value_type, expected_bytes)
    actual = unpack_values(value_type, actual_bytes)
    if len(expected) != len(actual):
        print(
            f"{name} {buffer_name}: expected {len(expected)} values, "
            f"got {len(actual)}"
        )
        return False
    if expected_bytes == actual_bytes:
        return True

    for index, (reference, result) in enumerate(zip(expected, actual)):
        start = index * 4
        reference_word = expected_bytes[start : start + 4]
        result_word = actual_bytes[start : start + 4]
        if reference_word != result_word:
            if value_type == "float":
                reference_bits = struct.unpack("<I", reference_word)[0]
                result_bits = struct.unpack("<I", result_word)[0]
                print(
                    f"{name} {buffer_name}[{index}]: CPU reference {reference} "
                    f"(0x{reference_bits:08x}), GPU {result} "
                    f"(0x{result_bits:08x}); bytes differ"
                )
            else:
                print(
                    f"{name} {buffer_name}[{index}]: "
                    f"CPU reference {reference}, GPU {result}"
                )
            return False
    raise AssertionError("byte comparison failed without a differing value")


def verify(manifest, cases, name, output_dir, simd_width_path):
    case = cases[name]
    if case["expect"] != "pass":
        raise ValueError(f"{name} is not a supported corpus case")

    output_dir = Path(output_dir)
    value_type = case["value_type"]
    input_paths = sorted(output_dir.glob(f"{name}.u*.in.bin"))
    if not input_paths:
        raise ValueError(f"{name} has no generated buffer fixtures")

    if case["kind"] == "buffer":
        all_match = True
        for input_path in input_paths:
            reference_path = Path(str(input_path).replace(".in.bin", ".ref.bin"))
            actual_path = Path(str(input_path) + ".out")
            all_match &= compare_buffers(
                name,
                input_path.name.split(".")[-3],
                value_type,
                reference_path.read_bytes(),
                actual_path.read_bytes(),
            )
        if not all_match:
            return False
        print(f"{name}: GPU matches scalar CPU reference (byte-exact)")
        return True

    input_path = input_paths[0]
    actual_path = Path(str(input_path) + ".out")
    inputs = unpack_values(value_type, input_path.read_bytes())
    actual_bytes = actual_path.read_bytes()
    simd_width = int(Path(simd_width_path).read_text().strip())

    if case["kind"] == "texture":
        texture_path = output_dir / "texture-rgba32f.bin"
        expected = texture_reference(manifest, case, len(inputs), texture_path)
        label = f"{case['sampler']} explicit-LOD {case['lod']} texture CPU reference"
    elif case["kind"] == "wave":
        expected = wave_reference(case, inputs, simd_width)
        label = (
            f"{case['operation']} CPU reference "
            f"({simd_width}-lane Metal SIMD groups)"
        )
    else:
        raise ValueError(f"unknown corpus kind {case['kind']}")

    runtime_reference = output_dir / f"{name}.u0.runtime.ref.bin"
    expected_bytes = pack_values(value_type, expected)
    runtime_reference.write_bytes(expected_bytes)
    if not compare_buffers(name, "u0", value_type, expected_bytes, actual_bytes):
        return False
    print(f"{name}: GPU matches {label} (byte-exact)")
    return True


def main():
    if len(sys.argv) < 2:
        print(
            "usage: verify_shader_output.py prepare-texture <cases.json> <output> "
            "| verify <cases.json> <name> <out-dir> <thread-width-file>"
        )
        return 2

    command = sys.argv[1]
    if command == "prepare-texture" and len(sys.argv) == 4:
        manifest, _ = load_manifest(sys.argv[2])
        prepare_texture(manifest, sys.argv[3])
        return 0
    if command == "verify" and len(sys.argv) == 6:
        manifest, cases = load_manifest(sys.argv[2])
        return 0 if verify(manifest, cases, sys.argv[3], sys.argv[4], sys.argv[5]) else 1

    print("invalid arguments")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, OSError, ValueError) as error:
        print(f"reference error: {error}")
        sys.exit(2)
