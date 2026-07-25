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
    return parts, (major, minor), hashlib.sha256(data).hexdigest()


# --- stage, signatures, module constants ------------------------------------
# The graphics stages need three things the compute subset never did: which
# stage this is, what its input/output signature elements are, and the constant
# arrays dxc hoists out of indexed local arrays.  All three are stated in the
# module itself, so they are read rather than assumed.

STAGES = {"Vertex Shader": "vertex", "Pixel Shader": "fragment",
          "Compute Shader": "compute"}

# dx.op.unary.f32 opcodes, numbered by DirectX-Specs.  Only the ones the subset
# covers are listed: an opcode absent here is a named diagnostic, not a guess.
DXIL_UNARY = {
    6: "fabs", 7: "saturate", 12: "cos", 13: "sin", 17: "atan",
    22: "fract", 24: "sqrt", 26: "rint", 27: "floor", 28: "ceil", 29: "trunc",
}


def parse_stage(text):
    m = re.search(r"^;PSVRuntimeInfo:\s*\n;\s*(.+?)\s*$", text, re.M)
    if not m:
        raise Unsupported("M12003-parse: PSVRuntimeInfo stage line not found")
    stage = STAGES.get(m.group(1))
    if not stage:
        raise Unsupported(f"M12003-unsupported: shader stage '{m.group(1)}'")
    return stage


def parse_signatures(text):
    """Ordered input/output signature elements, indexed the way dx.op.loadInput
    and dx.op.storeOutput index them: by position in the table."""
    sigs = {}
    for which in ("Input", "Output"):
        rows = []
        block = re.search(rf"^; {which} signature:\s*\n;\s*\n"
                          r"; Name.*?\n; -+.*?\n(.*?)^;\s*$", text, re.M | re.S)
        if block:
            for line in block.group(1).splitlines():
                cols = line.lstrip(";").split()
                # Name Index Mask Register SysValue Format [Used]
                if len(cols) < 6:
                    continue
                rows.append({"name": cols[0], "index": int(cols[1]),
                             "mask": cols[2], "register": cols[3],
                             "sysvalue": cols[4], "format": cols[5]})
        sigs[which.lower()] = rows
    return sigs


def parse_globals(text):
    """Constant arrays dxc emits for locally-indexed arrays, e.g. a float2[3]
    scalarized into two [3 x float] globals."""
    out = {}
    for m in re.finditer(r"^(@[\w.]+) = internal unnamed_addr constant "
                         r"\[(\d+) x float\] \[(.*?)\]\s*$", text, re.M):
        values = [parse_value(v.strip().removeprefix("float ").strip())
                  for v in m.group(3).split(",")]
        if len(values) != int(m.group(2)):
            raise Unsupported(f"M12003-parse: bad constant array {m.group(1)}")
        out[m.group(1)] = values
    return out


# --- normalized IR ----------------------------------------------------------
# ops: ("handle", dst, range_id) ("tid", dst) ("load", dst, handle, idx, elem_ty)
#      ("bin", dst, op, a, b, ty) ("cmp", dst, pred, a, b) ("sel", dst, c, a, b)
#      ("store", handle, idx, val, elem_ty)
# graphics additions:
#      ("loadinput", dst, sig_elem, col, ty) ("storeoutput", sig_elem, col, val)
#      ("cbload", dst, handle, reg) ("extract", dst, src, member)
#      ("unary", dst, opcode, a) ("logic", dst, op, a, b)
#      ("gep", dst, global_name, idx) ("ptrload", dst, ptr)
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
        m = re.match(r"(%[\w.]+) = fcmp(?: fast)? (ogt|olt|oge|ole|oeq) float ([^,]+), (.+)", line)
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
        m = re.match(r"(%[\w.]+) = call (?:float|i32) @dx\.op\.loadInput\.(f32|i32)\("
                     r"i32 4, i32 (\d+), i32 \d+, i8 (\d+), i32 undef\)", line)
        if m:
            ops.append(("loadinput", m.group(1), int(m.group(3)), int(m.group(4)),
                        m.group(2)))
            continue
        m = re.match(r"call void @dx\.op\.storeOutput\.f32\("
                     r"i32 5, i32 (\d+), i32 \d+, i8 (\d+), float ([^)]+)\)", line)
        if m:
            ops.append(("storeoutput", int(m.group(1)), int(m.group(2)),
                        parse_value(m.group(3))))
            continue
        m = re.match(r"(%[\w.]+) = call %dx\.types\.CBufRet\.f32 "
                     r"@dx\.op\.cbufferLoadLegacy\.f32\("
                     r"i32 59, %dx\.types\.Handle (%[\w.]+), i32 (\d+)\)", line)
        if m:
            ops.append(("cbload", m.group(1), m.group(2), int(m.group(3))))
            continue
        m = re.match(r"(%[\w.]+) = extractvalue %dx\.types\.CBufRet\.f32 (%[\w.]+), (\d+)",
                     line)
        if m:
            ops.append(("extract", m.group(1), m.group(2), int(m.group(3))))
            continue
        m = re.match(r"(%[\w.]+) = call float @dx\.op\.unary\.f32\("
                     r"i32 (\d+), float ([^)]+)\)", line)
        if m:
            code = int(m.group(2))
            if code not in DXIL_UNARY:
                raise Unsupported(f"M12003-unsupported: dx.op.unary.f32 opcode {code}")
            ops.append(("unary", m.group(1), code, parse_value(m.group(3))))
            continue
        m = re.match(r"(%[\w.]+) = (and|or) i1 (%[\w.]+), (%[\w.]+)", line)
        if m:
            ops.append(("logic", m.group(1), m.group(2), m.group(3), m.group(4)))
            continue
        m = re.match(r"(%[\w.]+) = getelementptr \[\d+ x float\], \[\d+ x float\]\* "
                     r"(@[\w.]+), i32 0, i32 ([^\s,]+)", line)
        if m:
            ops.append(("gep", m.group(1), m.group(2), parse_value(m.group(3))))
            continue
        m = re.match(r"(%[\w.]+) = load float, float\* (%[\w.]+), align \d+", line)
        if m:
            ops.append(("ptrload", m.group(1), m.group(2)))
            continue
        m = re.match(r".*@(dx\.op\.[\w.]+)", line)
        if m:
            raise Unsupported(f"M12003-unsupported: {m.group(1)}")
        raise Unsupported(f"M12003-unsupported: instruction '{line}'")
    return ops


# --- MSL lowering -----------------------------------------------------------

def msl_name(v):
    return v.replace("%", "t").replace(".", "_").replace("@", "g_")


def sig_field(elem):
    """MSL struct field name for a signature element. Stable and derived from
    the signature table, so vertex output and fragment input agree."""
    return f"{elem['name'].lower()}{elem['index']}"


MASK_WIDTH = {"x": 1, "xy": 2, "xyz": 3, "xyzw": 4}


def sig_width(elem):
    w = MASK_WIDTH.get(elem["mask"])
    if not w:
        raise Unsupported(f"M12003-unsupported: signature mask '{elem['mask']}'")
    return w


def emit_body(ops, handles, globals_, ref, read_input, write_output):
    """Statement list for the straight-line op stream. Shared by every stage:
    only how a value enters and leaves the shader differs between them."""
    types = {}
    cbufs = {}    # ssa -> (range_id, register)
    geps = {}     # ssa -> (global name, index)
    lines = []

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
            cop = {"ogt": ">", "olt": "<", "oge": ">=", "ole": "<=", "oeq": "=="}[pred]
            lines.append(f"    bool {ref(dst)} = {ref(a)} {cop} {ref(b)};")
            types[dst] = "bool"
        elif kind == "sel":
            _, dst, c, a, b = op
            lines.append(f"    float {ref(dst)} = {ref(c)} ? {ref(a)} : {ref(b)};")
            types[dst] = "f32"
        elif kind == "store":
            _, h, idx, val, ty = op
            lines.append(f"    u{handles[h]}[{ref(idx, 'i32')}] = {ref(val)};")
        elif kind == "loadinput":
            _, dst, elem, col, ty = op
            # The type matters: a vertex id lowered as float cannot index the
            # constant array dxc hoisted the position table into.
            mty = "float" if ty == "f32" else "uint"
            lines.append(f"    {mty} {ref(dst)} = {read_input(elem, col, ty)};")
            types[dst] = ty
        elif kind == "storeoutput":
            _, elem, col, val = op
            lines.append(f"    {write_output(elem, col)} = {ref(val)};")
        elif kind == "cbload":
            cbufs[op[1]] = (handles[op[2]], op[3])
        elif kind == "extract":
            rng, reg = cbufs[op[2]]
            lines.append(f"    float {ref(op[1])} = cb{rng}[{reg}][{op[3]}];")
            types[op[1]] = "f32"
        elif kind == "unary":
            _, dst, code, a = op
            lines.append(f"    float {ref(dst)} = {DXIL_UNARY[code]}({ref(a)});")
            types[dst] = "f32"
        elif kind == "logic":
            _, dst, o, a, b = op
            lines.append(f"    bool {ref(dst)} = {ref(a)} {'&&' if o == 'and' else '||'} {ref(b)};")
            types[dst] = "bool"
        elif kind == "gep":
            geps[op[1]] = (op[2], op[3])
        elif kind == "ptrload":
            g, idx = geps[op[2]]
            lines.append(f"    float {ref(op[1])} = {msl_name(g)}[{ref(idx, 'i32')}];")
            types[op[1]] = "f32"
    return lines


def make_ref():
    def ref(v, want=None):
        if isinstance(v, str):
            return msl_name(v)
        if want == "i32" or isinstance(v, int):
            return f"{v}u" if v >= 0 else str(v)
        return f"{v!r}f"
    return ref


def emit_globals(globals_):
    out = []
    for g, values in sorted(globals_.items()):
        body = ", ".join(f"{v!r}f" for v in values)
        out.append(f"constant float {msl_name(g)}[{len(values)}] = {{{body}}};")
    return out


def stage_struct(name, elems):
    """Interstage struct, shared by the vertex output and the fragment input so
    the two stages cannot silently disagree about layout."""
    fields = []
    for e in elems:
        w = sig_width(e)
        ty = "float" if w == 1 else f"float{w}"
        attr = " [[position]]" if e["sysvalue"] == "POS" else ""
        fields.append(f"    {ty} {sig_field(e)}{attr};")
    return f"struct {name}\n{{\n" + "\n".join(fields) + "\n};"


def lower_msl(ops, name, stage="compute", sigs=None, globals_=None):
    sigs = sigs or {"input": [], "output": []}
    globals_ = globals_ or {}
    handles = {}
    ref = make_ref()
    header = ["#include <metal_stdlib>", "using namespace metal;", ""]
    header += emit_globals(globals_)
    if globals_:
        header.append("")

    if stage == "compute":
        def read_input(elem, col, ty):
            raise Unsupported("M12003-unsupported: loadInput in a compute shader")

        def write_output(elem, col):
            raise Unsupported("M12003-unsupported: storeOutput in a compute shader")

        lines = emit_body(ops, handles, globals_, ref, read_input, write_output)
        buffers = sorted({rng for kind, *rest in ops if kind == "handle"
                          for rng in [rest[1]]})
        params = ",\n".join(
            f"    device {'float' if not any(o[0] == 'load' and o[4] == 'i32' or o[0] == 'store' and o[4] == 'i32' for o in ops) else 'uint'} *u{b} [[buffer({b})]]"
            for b in buffers)
        return ("\n".join(header) + f"kernel void {name}(\n{params},\n"
                f"    uint tid [[thread_position_in_grid]])\n{{\n"
                + "\n".join(lines) + "\n}\n")

    # --- graphics stages ---
    cbv_ranges = sorted({rest[1] for kind, *rest in ops if kind == "handle"})
    cb_params = [f"    constant float4 *cb{r} [[buffer({r})]]" for r in cbv_ranges]

    if stage == "vertex":
        outs = sigs["output"]
        if not outs:
            raise Unsupported("M12003-parse: vertex stage has no output signature")

        def read_input(elem, col, ty):
            e = sigs["input"][elem]
            if e["sysvalue"] != "VERTID":
                raise Unsupported(
                    f"M12003-unsupported: vertex input system value '{e['sysvalue']}'")
            return "vid"

        def write_output(elem, col):
            e = outs[elem]
            suffix = "" if sig_width(e) == 1 else f"[{col}]"
            return f"out.{sig_field(e)}{suffix}"

        lines = emit_body(ops, handles, globals_, ref, read_input, write_output)
        params = ["    uint vid [[vertex_id]]"] + cb_params
        return ("\n".join(header) + stage_struct("Interstage", outs) + "\n\n"
                + f"vertex Interstage {name}(\n" + ",\n".join(params) + ")\n{\n"
                + "    Interstage out;\n" + "\n".join(lines)
                + "\n    return out;\n}\n")

    if stage == "fragment":
        ins = sigs["input"]
        outs = sigs["output"]
        if len(outs) != 1 or outs[0]["sysvalue"] != "TARGET":
            raise Unsupported("M12003-unsupported: fragment output signature "
                              "is not a single render target")

        def read_input(elem, col, ty):
            e = ins[elem]
            suffix = "" if sig_width(e) == 1 else f"[{col}]"
            return f"in.{sig_field(e)}{suffix}"

        def write_output(elem, col):
            return f"out[{col}]"

        lines = emit_body(ops, handles, globals_, ref, read_input, write_output)
        params = ["    Interstage in [[stage_in]]"] + cb_params
        width = sig_width(outs[0])
        return ("\n".join(header) + stage_struct("Interstage", ins) + "\n\n"
                + f"fragment float{width} {name}(\n" + ",\n".join(params) + ")\n{\n"
                + f"    float{width} out;\n" + "\n".join(lines)
                + "\n    return out;\n}\n")

    raise Unsupported(f"M12003-unsupported: stage '{stage}'")


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
            env[dst] = {"ogt": x > y, "olt": x < y, "oge": x >= y,
                        "ole": x <= y, "oeq": x == y}[pred]
        elif kind == "sel":
            _, dst, c, a, b = op
            env[dst] = val(a) if env[c] else val(b)
        elif kind == "store":
            _, h, idx, v, ty = op
            buffers[handles[h]][int(val(op[2]))] = val(v)


STAGE_PREFIX = {"compute": "cs", "vertex": "vs", "fragment": "ps"}


def main():
    if len(sys.argv) != 4:
        print("usage: dxil_to_msl.py <name.dxil> <name.ll> <out-dir>")
        return 2
    dxil_path, ll_path, out_dir = sys.argv[1:4]
    name = dxil_path.rsplit("/", 1)[-1].removesuffix(".dxil")

    data = open(dxil_path, "rb").read()
    parts, (major, minor), dxil_hash = parse_container(data)
    ll_text = open(ll_path).read()
    stage = parse_stage(ll_text)
    model = f"{STAGE_PREFIX[stage]}_{major}_{minor}"
    sigs = parse_signatures(ll_text) if stage != "compute" else None
    globals_ = parse_globals(ll_text)
    ops = parse_ll(ll_text)

    msl_a = lower_msl(ops, name, stage, sigs, globals_)
    msl_b = lower_msl(ops, name, stage, sigs, globals_)
    if msl_a != msl_b:
        print("M12003-determinism: lowering not byte-identical")
        return 3

    msl_path = f"{out_dir}/{name}.metal"
    open(msl_path, "w").write(msl_a)
    record = {
        "shader": name, "stage": stage, "model": model,
        "container_sha256": dxil_hash,
        "ll_sha256": hashlib.sha256(ll_text.encode()).hexdigest(),
        "msl_sha256": hashlib.sha256(msl_a.encode()).hexdigest(),
        "ops": len(ops),
    }
    open(f"{out_dir}/{name}.provenance.json", "w").write(json.dumps(record, indent=1))

    if stage != "compute":
        # The graphics stages have no buffer-in/buffer-out shape to interpret;
        # their execution reference is the rendered image compared against the
        # M12-005 baseline, not a CPU replay of this op list.
        print(f"{name}: model {model}, {len(ops)} ops, {stage} stage, "
              f"msl {record['msl_sha256'][:12]}")
        return 0

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
