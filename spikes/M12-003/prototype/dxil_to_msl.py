#!/usr/bin/env python3
# M12-003 DXIL-to-MSL lowering prototype.
# Author: Tim Isaev
#
# Ingests a DXIL container (validated structurally), takes the DXC textual
# disassembly of its program module, parses a defined compute subset into a
# normalized op list, lowers it to MSL source, and interprets the same op
# list on the CPU as the execution reference.  Anything outside the subset
# fails with a named diagnostic - never silently.  Lowering runs twice and
# must be byte-identical; artifact hashes land in a provenance record.
#
# Provenance: ADR-0012 discipline model; see ../PROVENANCE.md.

import hashlib
import json
import re
import struct
import sys


class Unsupported(Exception):
    pass


def parse_container(data):
    if data[:4] != b"DXBC":
        raise Unsupported("M12003-container: bad magic")
    total, part_count = struct.unpack_from("<II", data, 24)
    if total != len(data):
        raise Unsupported("M12003-container: size mismatch")
    offsets = struct.unpack_from(f"<{part_count}I", data, 32)
    parts = {}
    for off in offsets:
        fourcc, size = struct.unpack_from("<4sI", data, off)
        if off + 8 + size > len(data):
            raise Unsupported("M12003-container: part overruns file")
        parts[fourcc.decode()] = data[off + 8 : off + 8 + size]
    if "DXIL" not in parts:
        raise Unsupported("M12003-container: no DXIL part")
    version, = struct.unpack_from("<I", parts["DXIL"], 0)
    major, minor = (version >> 4) & 0xF, version & 0xF
    return parts, f"cs_{major}_{minor}", hashlib.sha256(data).hexdigest()


# --- normalized IR ----------------------------------------------------------
# ops: ("handle", dst, range_id) ("tid", dst) ("load", dst, handle, idx, elem_ty)
#      ("bin", dst, op, a, b, ty) ("cmp", dst, pred, a, b) ("sel", dst, c, a, b)
#      ("store", handle, idx, val, elem_ty)
# values: temps "%N" or python float/int constants

FLOAT_RE = r"(?:[-+]?[0-9][\w.+-]*)"


def parse_value(tok):
    tok = tok.strip()
    if tok.startswith("%"):
        return tok
    if tok.startswith("0x"):
        return struct.unpack(">d", bytes.fromhex(tok[2:]))[0]
    try:
        return int(tok)
    except ValueError:
        return float(tok)


def parse_ll(text):
    ops = []
    body = re.search(r"define void @\w+\(\) \{(.*?)\n\}", text, re.S)
    if not body:
        raise Unsupported("M12003-parse: entry function not found")
    for raw in body.group(1).splitlines():
        line = raw.split(";")[0].strip()
        if not line or line == "ret void":
            continue
        m = re.match(r"(%[\w.]+) = call %dx\.types\.Handle @dx\.op\.createHandle\("
                     r"i32 57, i8 \d+, i32 (\d+), i32 \d+, i1 false\)", line)
        if m:
            ops.append(("handle", m.group(1), int(m.group(2))))
            continue
        m = re.match(r"(%[\w.]+) = call i32 @dx\.op\.threadId\.i32\(i32 93, i32 0\)", line)
        if m:
            ops.append(("tid", m.group(1)))
            continue
        m = re.match(r"(%[\w.]+) = call %dx\.types\.ResRet\.(f32|i32) @dx\.op\.bufferLoad\.\2\("
                     r"i32 68, %dx\.types\.Handle (%[\w.]+), i32 ([^,]+), i32 [^)]+\)", line)
        if m:
            ops.append(("load", m.group(1), m.group(3), parse_value(m.group(4)), m.group(2)))
            continue
        m = re.match(r"(%[\w.]+) = extractvalue %dx\.types\.ResRet\.(?:f32|i32) (%[\w.]+), 0",
                     line)
        if m:
            ops.append(("alias", m.group(1), m.group(2)))
            continue
        m = re.match(r"(%[\w.]+) = (fmul|fadd|fsub|fdiv)(?: fast)? float ([^,]+), (.+)", line)
        if m:
            ops.append(("bin", m.group(1), m.group(2), parse_value(m.group(3)),
                        parse_value(m.group(4)), "f32"))
            continue
        m = re.match(r"(%[\w.]+) = (mul|add|sub)(?: nuw)?(?: nsw)? i32 ([^,]+), (.+)", line)
        if m:
            ops.append(("bin", m.group(1), m.group(2), parse_value(m.group(3)),
                        parse_value(m.group(4)), "i32"))
            continue
        m = re.match(r"(%[\w.]+) = call float @dx\.op\.binary\.f32\(i32 (35|36), "
                     r"float ([^,]+), float ([^)]+)\)", line)
        if m:
            op = "fmax" if m.group(2) == "35" else "fmin"
            ops.append(("bin", m.group(1), op, parse_value(m.group(3)),
                        parse_value(m.group(4)), "f32"))
            continue
        m = re.match(r"(%[\w.]+) = fcmp(?: fast)? (ogt|olt|oge|ole) float ([^,]+), (.+)", line)
        if m:
            ops.append(("cmp", m.group(1), m.group(2), parse_value(m.group(3)),
                        parse_value(m.group(4))))
            continue
        m = re.match(r"(%[\w.]+) = select i1 (%[\w.]+), float ([^,]+), float (.+)", line)
        if m:
            ops.append(("sel", m.group(1), m.group(2), parse_value(m.group(3)),
                        parse_value(m.group(4))))
            continue
        m = re.match(r"call void @dx\.op\.bufferStore\.(f32|i32)\(i32 69, "
                     r"%dx\.types\.Handle (%[\w.]+), i32 ([^,]+), i32 [^,]+, "
                     r"(?:float|i32) ([^,]+),.*i8 1\)", line)
        if m:
            ops.append(("store", m.group(2), parse_value(m.group(3)),
                        parse_value(m.group(4)), m.group(1)))
            continue
        m = re.match(r".*@(dx\.op\.[\w.]+)", line)
        if m:
            raise Unsupported(f"M12003-unsupported: {m.group(1)}")
        raise Unsupported(f"M12003-unsupported: instruction '{line}'")
    return ops


# --- MSL lowering -----------------------------------------------------------

def lower_msl(ops, name):
    handles = {}          # ssa -> buffer range id
    types = {}            # ssa -> "f32"/"i32"/"bool"
    lines = []
    buffers = sorted({rng for kind, *rest in ops if kind == "handle"
                      for rng in [rest[1]]})

    def ref(v, want=None):
        if isinstance(v, str):
            return v.replace("%", "t").replace(".", "_")
        if want == "i32" or isinstance(v, int):
            return f"{v}u" if v >= 0 else str(v)
        return f"{v!r}f"

    for op in ops:
        kind = op[0]
        if kind == "handle":
            handles[op[1]] = op[2]
        elif kind == "tid":
            lines.append(f"    uint {ref(op[1])} = tid;")
            types[op[1]] = "i32"
        elif kind == "load":
            ty = "float" if op[4] == "f32" else "uint"
            lines.append(f"    {ty} {ref(op[1])} = u{handles[op[2]]}[{ref(op[3], 'i32')}];")
            types[op[1]] = op[4]
        elif kind == "alias":
            src_ty = types.get(op[2], "f32")
            ty = "float" if src_ty == "f32" else "uint"
            lines.append(f"    {ty} {ref(op[1])} = {ref(op[2])};")
            types[op[1]] = src_ty
        elif kind == "bin":
            _, dst, o, a, b, ty = op
            mty = "float" if ty == "f32" else "uint"
            expr = {
                "fmul": f"{ref(a)} * {ref(b)}", "fadd": f"{ref(a)} + {ref(b)}",
                "fsub": f"{ref(a)} - {ref(b)}", "fdiv": f"{ref(a)} / {ref(b)}",
                "mul": f"{ref(a, 'i32')} * {ref(b, 'i32')}",
                "add": f"{ref(a, 'i32')} + {ref(b, 'i32')}",
                "sub": f"{ref(a, 'i32')} - {ref(b, 'i32')}",
                "fmax": f"fmax({ref(a)}, {ref(b)})", "fmin": f"fmin({ref(a)}, {ref(b)})",
            }[o]
            lines.append(f"    {mty} {ref(dst)} = {expr};")
            types[dst] = ty
        elif kind == "cmp":
            _, dst, pred, a, b = op
            cop = {"ogt": ">", "olt": "<", "oge": ">=", "ole": "<="}[pred]
            lines.append(f"    bool {ref(dst)} = {ref(a)} {cop} {ref(b)};")
            types[dst] = "bool"
        elif kind == "sel":
            _, dst, c, a, b = op
            lines.append(f"    float {ref(dst)} = {ref(c)} ? {ref(a)} : {ref(b)};")
            types[dst] = "f32"
        elif kind == "store":
            _, h, idx, val, ty = op
            lines.append(f"    u{handles[h]}[{ref(idx, 'i32')}] = {ref(val)};")

    params = ",\n".join(
        f"    device {'float' if not any(o[0] == 'load' and o[4] == 'i32' or o[0] == 'store' and o[4] == 'i32' for o in ops) else 'uint'} *u{b} [[buffer({b})]]"
        for b in buffers)
    return (f"#include <metal_stdlib>\nusing namespace metal;\n"
            f"kernel void {name}(\n{params},\n"
            f"    uint tid [[thread_position_in_grid]])\n{{\n" + "\n".join(lines) + "\n}\n")


# --- CPU reference interpreter ---------------------------------------------

def interpret(ops, buffers, tid):
    env, handles = {}, {}

    def val(v):
        return env[v] if isinstance(v, str) else v

    for op in ops:
        kind = op[0]
        if kind == "handle":
            handles[op[1]] = op[2]
        elif kind == "tid":
            env[op[1]] = tid
        elif kind == "load":
            env[op[1]] = buffers[handles[op[2]]][int(val(op[3]))]
        elif kind == "alias":
            env[op[1]] = env[op[2]]
        elif kind == "bin":
            _, dst, o, a, b, ty = op
            x, y = val(a), val(b)
            if ty == "i32":
                r = {"mul": x * y, "add": x + y, "sub": x - y}[o] & 0xFFFFFFFF
            else:
                r = {"fmul": x * y, "fadd": x + y, "fsub": x - y,
                     "fdiv": x / y if y else float("inf"),
                     "fmax": max(x, y), "fmin": min(x, y)}[o]
                r = struct.unpack("f", struct.pack("f", r))[0]
            env[dst] = r
        elif kind == "cmp":
            _, dst, pred, a, b = op
            x, y = val(a), val(b)
            env[dst] = {"ogt": x > y, "olt": x < y, "oge": x >= y, "ole": x <= y}[pred]
        elif kind == "sel":
            _, dst, c, a, b = op
            env[dst] = val(a) if env[c] else val(b)
        elif kind == "store":
            _, h, idx, v, ty = op
            buffers[handles[h]][int(val(op[2]))] = val(v)


def main():
    if len(sys.argv) != 4:
        print("usage: dxil_to_msl.py <name.dxil> <name.ll> <out-dir>")
        return 2
    dxil_path, ll_path, out_dir = sys.argv[1:4]
    name = dxil_path.rsplit("/", 1)[-1].removesuffix(".dxil")

    data = open(dxil_path, "rb").read()
    parts, model, dxil_hash = parse_container(data)
    ll_text = open(ll_path).read()
    ops = parse_ll(ll_text)

    msl_a = lower_msl(ops, name)
    msl_b = lower_msl(ops, name)
    if msl_a != msl_b:
        print("M12003-determinism: lowering not byte-identical")
        return 3

    msl_path = f"{out_dir}/{name}.metal"
    open(msl_path, "w").write(msl_a)
    record = {
        "shader": name, "model": model,
        "container_sha256": dxil_hash,
        "ll_sha256": hashlib.sha256(ll_text.encode()).hexdigest(),
        "msl_sha256": hashlib.sha256(msl_a.encode()).hexdigest(),
        "ops": len(ops),
    }
    open(f"{out_dir}/{name}.provenance.json", "w").write(json.dumps(record, indent=1))

    # CPU reference over the standard test pattern
    n = 64
    int_shader = any(o[0] == "store" and o[4] == "i32" for o in ops)
    nbuf = max(o[2] for o in ops if o[0] == "handle") + 1
    if int_shader:
        buffers = [[(i * 7 + b) & 0xFFFFFFFF for i in range(n)] for b in range(nbuf)]
    else:
        buffers = [[struct.unpack("f", struct.pack("f", (i - 32) / 8.0 + b))[0]
                    for i in range(n)] for b in range(nbuf)]
    inputs = [list(b) for b in buffers]
    for tid in range(n):
        interpret(ops, buffers, tid)
    fmt = "I" if int_shader else "f"
    for b in range(nbuf):
        open(f"{out_dir}/{name}.u{b}.in.bin", "wb").write(
            struct.pack(f"<{n}{fmt}", *inputs[b]))
        open(f"{out_dir}/{name}.u{b}.ref.bin", "wb").write(
            struct.pack(f"<{n}{fmt}", *buffers[b]))
    print(f"{name}: model {model}, {len(ops)} ops, {nbuf} buffer(s), "
          f"msl {record['msl_sha256'][:12]}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Unsupported as e:
        print(e)
        sys.exit(4)
