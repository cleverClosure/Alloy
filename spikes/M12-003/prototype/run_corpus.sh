#!/bin/bash
# M12-003 corpus driver: HLSL -> (dxc under Wine/FEX) -> DXIL -> lowered MSL
# -> metallib -> GPU run -> compare against the CPU-reference interpreter.
# Author: Tim Isaev
set -u

SPIKE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$SPIKE/work"
PROBE=/Users/cleverclosure/Developer/macgaming/spikes/CPU-001/work/fex-runtime-probe
WINE=/Users/cleverclosure/Developer/macgaming/spikes/WINE-001/work/build-2/loader/wine
DXC="$WORK/dxc-win/bin/x64/dxc.exe"
mkdir -p "$WORK/out"

run_dxc() {
  (cd "$PROBE" && WINEPREFIX="$PROBE/prefix-gui" \
    DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
    WINEDLLOVERRIDES="xtajit64=n" \
    "$WINE" "$DXC" "$@") 2>>"$WORK/out/dxc-stderr.log"
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
