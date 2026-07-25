#!/bin/bash
# M12-003 corpus driver: HLSL -> (dxc under Wine/FEX) -> DXIL -> lowered MSL
# -> metallib -> GPU run -> compare against the CPU-reference interpreter.
# Author: Tim Isaev
set -u

SPIKE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SPIKE/../.." && pwd)"
WORK="$SPIKE/work"

# Everything below used to be an absolute path under Developer/macgaming, which
# stopped existing at the rename and took this driver with it. Derive from the
# repo root, and let a caller override: the Wine build and the FEX probe prefix
# are gitignored machine state, so a worktree that has never built them has to
# borrow another checkout's.
ALLOY_WINE=${ALLOY_WINE:-"$ROOT/spikes/WINE-001/work/build-2/wine"}
ALLOY_FEX_PREFIX=${ALLOY_FEX_PREFIX:-"$ROOT/spikes/CPU-001/work/fex-runtime-probe"}
DXC=${ALLOY_DXC:-"$ROOT/tools/toolchains/dxc-v1.9.2602.24/bin/x64/dxc.exe"}

if [ ! -x "$ALLOY_WINE" ]; then
  echo "missing Wine loader: $ALLOY_WINE" >&2
  echo "  set ALLOY_WINE to a checkout with a built spikes/WINE-001/work/build-2" >&2
  exit 2
fi
# dxc.exe is a guest PE run through Wine, so it is tested for presence rather
# than for the host execute bit, which unzip does not set.
if [ ! -f "$DXC" ]; then
  echo "missing dxc: $DXC" >&2
  echo "  set ALLOY_DXC, or run tools/fetch-deps.sh" >&2
  exit 2
fi
if [ ! -d "$ALLOY_FEX_PREFIX/prefix-gui" ]; then
  echo "missing FEX probe prefix: $ALLOY_FEX_PREFIX/prefix-gui" >&2
  echo "  set ALLOY_FEX_PREFIX to a checkout that has one" >&2
  exit 2
fi
mkdir -p "$WORK/out"

run_dxc() {
  (cd "$ALLOY_FEX_PREFIX" && WINEPREFIX="$ALLOY_FEX_PREFIX/prefix-gui" \
    DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
    WINEDLLOVERRIDES="xtajit64=n" \
    "$ALLOY_WINE" "$DXC" "$@") 2>>"$WORK/out/dxc-stderr.log"
}

clang -fobjc-arc -O2 -o "$WORK/msl_run" "$SPIKE/prototype/msl_run.m" \
  -framework Metal -framework Foundation || exit 1

pass=0 fail=0 diag=0
for hlsl in "$SPIKE"/corpus/*.hlsl; do
  name="$(basename "$hlsl" .hlsl)"
  run_dxc -T cs_6_0 -E main -Fo "$WORK/out/$name.dxil" "$hlsl" >/dev/null
  run_dxc -T cs_6_0 -E main -Fc "$WORK/out/$name.ll" "$hlsl" >/dev/null
  if [ ! -f "$WORK/out/$name.dxil" ]; then
    echo "$name: dxc produced no output"
    fail=$((fail + 1))
    continue
  fi

  if ! python3 "$SPIKE/prototype/dxil_to_msl.py" \
    "$WORK/out/$name.dxil" "$WORK/out/$name.ll" "$WORK/out"; then
    if [ "$name" = wave_cs ]; then
      echo "$name: rejected with named diagnostic (expected)"
      diag=$((diag + 1))
    else
      fail=$((fail + 1))
    fi
    continue
  fi

  xcrun -sdk macosx metal -O2 "$WORK/out/$name.metal" \
    -o "$WORK/out/$name.metallib" || {
    fail=$((fail + 1))
    continue
  }

  inputs=("$WORK/out/$name".u*.in.bin)
  "$WORK/msl_run" "$WORK/out/$name.metallib" "$name" 64 "${inputs[@]}" ||
    {
      fail=$((fail + 1))
      continue
    }

  if python3 - "$name" "$WORK/out" <<'EOF'; then
import glob, struct, sys
name, out = sys.argv[1], sys.argv[2]
ok = True
for ref_path in glob.glob(f"{out}/{name}.u*.ref.bin"):
    got_path = ref_path.replace(".ref.bin", ".in.bin.out")
    ref = open(ref_path, "rb").read()
    got = open(got_path, "rb").read()
    is_int = name.startswith("intops")
    fmt = "I" if is_int else "f"
    r = struct.unpack(f"<64{fmt}", ref)
    g = struct.unpack(f"<64{fmt}", got)
    for i, (a, b) in enumerate(zip(r, g)):
        close = a == b if is_int else abs(a - b) <= 1e-5 * max(1.0, abs(a))
        if not close:
            print(f"  {name} {ref_path.rsplit('.',3)[-3]}[{i}]: ref {a} got {b}")
            ok = False
            break
sys.exit(0 if ok else 1)
EOF
    echo "$name: GPU matches CPU reference"
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done

echo "corpus: $pass pass, $diag rejected-with-diagnostic, $fail fail"
[ "$fail" -eq 0 ] && [ "$pass" -ge 5 ] && [ "$diag" -ge 1 ] &&
  echo "m12-003 shader path ok" || exit 1
