#!/usr/bin/env python3
# Metal12 Phase-1 image comparison: the runtime bitmap against the M12-005
# baseline image, per channel.
# Author: Timur Isaev
#
# A digest match is a single bit of information and a digest mismatch is none
# at all, so this reports the distribution: how many pixels agree exactly, how
# far the worst channel is off, and where any difference sits. PNG decoding is
# first-party (zlib plus the five standard filters) rather than a dependency.
#
# Provenance: ADR-0012 discipline model; see ../PROVENANCE.md.

import collections
import struct
import sys
import zlib

# The reference scene's own digest constants, matched exactly rather than
# taken from the FNV-1a definition: d3d12_reference.c seeds with
# 1469598103934665603, which is not the standard 64-bit offset basis. Using the
# textbook value here would produce a number that cannot be compared with
# anything M12-005 recorded.
FNV_OFFSET = 1469598103934665603
FNV_PRIME = 1099511628211
EXPECTED_SIZE = (640, 360)
EXPECTED_BASELINE_FNV = 0x825861EE12085256
EXPECTED_SLICE_FNV = 0x44709706809F28E9
MIN_EXACT_PIXELS = 228971
MAX_CHANNEL_DELTA = 1


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, width, height, depth, color = 8, b"", 0, 0, 0, 0
    while pos < len(data):
        length, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8: pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(
                ">IIBBBBB", body
            )
            if depth != 8 or color not in (2, 6) or interlace:
                raise SystemExit(
                    f"{path}: unsupported PNG (depth {depth}, colour {color})"
                )
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    channels = 3 if color == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * channels
    out = bytearray(height * stride)
    prev = bytearray(stride)
    src = 0
    for y in range(height):
        filt = raw[src]
        src += 1
        line = bytearray(raw[src: src + stride])
        src += stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            x = line[i]
            if filt == 1:
                x += a
            elif filt == 2:
                x += b
            elif filt == 3:
                x += (a + b) >> 1
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                x += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            elif filt != 0:
                raise SystemExit(f"{path}: unknown PNG filter {filt}")
            line[i] = x & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return width, height, channels, bytes(out)


def read_bmp24(path):
    data = open(path, "rb").read()
    if data[:2] != b"BM":
        raise SystemExit(f"{path}: not a BMP")
    off, = struct.unpack_from("<I", data, 10)
    width, height, planes, bits = struct.unpack_from("<iihh", data, 18)
    if bits != 24 or planes != 1:
        raise SystemExit(f"{path}: expected a 24-bit BMP")
    top_down = height < 0
    height = abs(height)
    stride = ((width * 3 + 3) // 4) * 4
    rows = []
    for y in range(height):
        start = off + y * stride
        rows.append(data[start:start + width * 3])
    if not top_down:
        rows.reverse()
    # BMP stores BGR; normalise to RGB.
    out = bytearray()
    for row in rows:
        for x in range(width):
            out += bytes((row[x * 3 + 2], row[x * 3 + 1], row[x * 3 + 0]))
    return width, height, bytes(out)


def fnv1a_rgb(pixels):
    digest = FNV_OFFSET
    for byte in pixels:
        digest = ((digest ^ byte) * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return digest


def main():
    if len(sys.argv) != 3:
        print("usage: compare_reference.py <baseline.png> <slice.bmp>")
        return 2
    bw, bh, bch, bpix = read_png(sys.argv[1])
    sw, sh, spix = read_bmp24(sys.argv[2])
    if (bw, bh) != (sw, sh):
        print(f"size mismatch: baseline {bw}x{bh}, slice {sw}x{sh}")
        return 1

    base_rgb = bytearray()
    for i in range(bw * bh):
        base_rgb += bpix[i * bch: i * bch + 3]

    exact = 0
    deltas = collections.Counter()
    worst = [0, 0, 0]
    worst_at = None
    for i in range(bw * bh):
        b = base_rgb[i * 3: i * 3 + 3]
        s = spix[i * 3: i * 3 + 3]
        if b == s:
            exact += 1
            deltas[0] += 1
            continue
        d = [abs(b[c] - s[c]) for c in range(3)]
        m = max(d)
        deltas[m] += 1
        if m > max(worst):
            worst, worst_at = d, (i % bw, i // bw)

    total = bw * bh
    baseline_fnv = fnv1a_rgb(bytes(base_rgb))
    slice_fnv = fnv1a_rgb(spix)
    observed_max_delta = max(deltas)
    print(f"size: {bw}x{bh} ({total} pixels)")
    print(f"baseline fnv1a64: {baseline_fnv:016x}")
    print(f"slice    fnv1a64: {slice_fnv:016x}")
    print(f"identical pixels: {exact}/{total} ({100.0 * exact / total:.3f}%)")
    print(f"maximum channel delta: {observed_max_delta}")
    print("max-channel-delta histogram:")
    for delta in sorted(deltas):
        print(
            f"  delta {delta:3d}: {deltas[delta]:7d} pixels "
            f"({100.0 * deltas[delta] / total:.3f}%)"
        )
    if worst_at:
        print(f"worst pixel at {worst_at}: per-channel delta {worst}")

    failures = []
    if (bw, bh) != EXPECTED_SIZE:
        failures.append(f"unexpected dimensions {(bw, bh)}")
    if baseline_fnv != EXPECTED_BASELINE_FNV:
        failures.append(f"unexpected baseline fingerprint {baseline_fnv:016x}")
    if slice_fnv != EXPECTED_SLICE_FNV:
        failures.append(f"unexpected slice fingerprint {slice_fnv:016x}")
    if exact < MIN_EXACT_PIXELS:
        failures.append(f"only {exact} pixels match exactly")
    if observed_max_delta > MAX_CHANNEL_DELTA:
        failures.append(f"maximum channel delta is {observed_max_delta}")
    if failures:
        for failure in failures:
            print(f"gate failure: {failure}", file=sys.stderr)
        print("comparison gate: FAIL")
        return 1
    print("comparison gate: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
