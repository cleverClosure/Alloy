#!/usr/bin/env python3
"""Deterministic, native synthetic frame source. Author: Timur Isaev."""

import argparse
import json
from pathlib import Path
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--mode", choices=("clean", "seeded", "hang", "error"), default="clean")
    args = parser.parse_args()
    if args.mode == "hang":
        while True:
            time.sleep(1)
    if args.mode == "error":
        return 23
    args.output.mkdir(parents=True, exist_ok=True)
    pixel_sum = 0
    for frame_index in range(4):
        pixels = bytearray()
        for row in range(16):
            for column in range(16):
                pixels.extend((16 * column, 16 * row, 64 * frame_index))
        if args.mode == "seeded" and frame_index == 0:
            pixels[0] = 1
        pixel_sum += sum(pixels)
        (args.output / f"frame-{frame_index:03d}.ppm").write_bytes(b"P6\n16 16\n255\n" + pixels)
    print(json.dumps({"frame_count": 4, "pixel_count": 1024, "pixel_sum": pixel_sum}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
