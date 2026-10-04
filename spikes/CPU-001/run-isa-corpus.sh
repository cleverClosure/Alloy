#!/usr/bin/env bash
# CPU-001 systematic ISA corpus: SSE2 family through FEX/Wine (issue #104, Milestone 2).
# Author: Timur Isaev
#
# Builds testcases/isa_corpus_sse2.c as the x64 Windows guest and runs it
# through spikes/WINE-001/work/build-2's already-built Wine+FEX, read-only,
# in a private scratch prefix under spikes/CPU-001/work/ (gitignored). A
# single run produces both outcomes the milestone requires:
#
#   - the clean build's checksum must equal the native-oracle checksum
#     (testcases/build-isa-corpus-native.sh) - proof that FEX's real SSE2
#     translation agrees with a portable C reference computed independently,
#     on real arm64 hardware, with no translator involved on that side;
#   - the -DALLOY_CORPUS_MUTATE_PADDB build must FAIL through this same
#     path - the negative control, without which a clean pass proves nothing.
#     A nonzero exit alone would also be produced by a timeout or an
#     unrelated crash, so the verdict additionally requires the specific
#     detected-mismatch exit code, the checksum matching a native build of
#     the identical corrupted reference, and a FAIL line naming paddb -
#     a crash cannot forge all three.
#
# Setup gotchas this script exists to get right every time (CLAUDE.md
# "Runtime gotchas", results 04 and 18):
#
#   - Wine resolves libarm64ecfex.dll as a BUILTIN from build-2's own build
#     tree (dlls/libarm64ecfex/aarch64-windows/), never from anything placed
#     in the prefix's system32 - so nothing is copied there, and this script
#     instead hashes that exact file before and after the run and asserts
#     the WINEDEBUG=+loaddll trace actually loaded it, rather than assuming
#     the registry key alone is enough.
#   - A fresh prefix has no x64 emulator registered under
#     HKLM\Software\Microsoft\Wow64\amd64 - run the guest before writing that
#     key and Wine's stub prints "x64 emulation not implemented"; this script
#     demonstrates that failure on purpose before registering the key, so the
#     registration step is shown to be load-bearing rather than assumed to be.
#   - WINEDLLOVERRIDES needs xtajit64=n for the guest run, and
#     mscoree,mshtml= for prefix creation so wineboot never stops to offer a
#     Gecko/Mono download that nobody here can answer.
#
# build-2 and the cross toolchain are gitignored local state that exists only
# in the primary checkout, not in a worktree - both are read-only inputs
# here, addressed by absolute path (env-overridable) rather than derived
# relative to this checkout.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
spike_root=$script_dir
# shellcheck source=spikes/CPU-001/isa-corpus-verdict.sh
source "$script_dir/isa-corpus-verdict.sh"

wine_build=${ALLOY_WINE_BUILD:-/Users/cleverclosure/Developer/Alloy/spikes/WINE-001/work/build-2}
toolchain_bin=${ALLOY_TOOLCHAIN_BIN:-/Users/cleverclosure/Developer/Alloy/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin}
wine_src=${ALLOY_WINE_SOURCE:-/Users/cleverclosure/Developer/Alloy/third_party/src/wine}
fex_src=${ALLOY_FEX_SOURCE:-/Users/cleverclosure/Developer/Alloy/third_party/src/fex}

run_mutate=1
usage() {
  cat <<'EOF'
usage: run-isa-corpus.sh [--skip-mutate | --selftest]

Builds the SSE2 ISA-corpus x64 guest and runs it through build-2's Wine/FEX
in a private, freshly-created scratch prefix. By default also builds and
runs the -DALLOY_CORPUS_MUTATE_PADDB negative control; --skip-mutate omits
that second run for a faster dev-loop check (the milestone needs both).

Environment overrides:
  ALLOY_WINE_BUILD     Wine build to run against (default: build-2)
  ALLOY_TOOLCHAIN_BIN  cross-toolchain bin directory
  ALLOY_WINE_SOURCE    Wine source checkout, recorded in run metadata only
  ALLOY_FEX_SOURCE     FEX source checkout, recorded in run metadata only
EOF
}
while (($#)); do
  case "$1" in
    --selftest)
      isa_corpus_verdict_selftest
      exit
      ;;
    --skip-mutate)
      run_mutate=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for dir in "$wine_build" "$toolchain_bin"; do
  [[ -d $dir ]] || {
    echo "missing required directory: $dir" >&2
    exit 2
  }
done
for cmd in rg perl shasum python3; do
  command -v "$cmd" >/dev/null || {
    echo "missing required command: $cmd" >&2
    exit 2
  }
done

wine_loader="$wine_build/loader/wine"
wineserver="$wine_build/server/wineserver"
fex_dll="$wine_build/dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
cross_cc="$toolchain_bin/x86_64-w64-mingw32-clang"
for f in "$wine_loader" "$wineserver" "$fex_dll" "$cross_cc"; do
  [[ -x $f ]] || {
    echo "missing required executable: $f" >&2
    exit 2
  }
done

# Every invocation checks the selected runtime and the shared runtime separately.
work_parent="$spike_root/work/isa-corpus"
runtime_guard="$script_dir/isa-corpus-runtime.py"
python3 "$runtime_guard" check-directory "$wine_build" "$work_parent"
mkdir -p "$work_parent"
work_root=$(mktemp -d "$work_parent/run.XXXXXX")
guest_dir="$work_root/guest"
prefix="$work_root/prefix"
log_dir="$work_root/logs"
mkdir -p "$guest_dir" "$prefix" "$log_dir" "$work_root/native-oracle"
python3 "$runtime_guard" snapshot "$wine_build" "$work_root/runtime-before.json"
inventory_done=0

wine_dyld_path=${DYLD_FALLBACK_LIBRARY_PATH:-/opt/homebrew/lib}

# Bound both time and diagnostic volume, and record exact source/binary identity.
timeout_wine() { # seconds log wine-args...
  local seconds=$1 log=$2
  shift 2
  python3 "$runtime_guard" run --build "$wine_build" --wine-source "$wine_src" \
    --fex-source "$fex_src" --baseline "$work_root/runtime-before.json" \
    --timeout "$seconds" --log "$log" -- "$@"
}

stop_server() {
  local option rc
  for option in -k -w; do
    rc=0
    WINEPREFIX="$prefix" DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" \
      perl -e 'alarm shift; exec @ARGV' 10 "$wineserver" "$option" >/dev/null 2>&1 || rc=$?
    # -k returns 1 when this private prefix's server has already exited.
    # A timeout or another failure must still fail cleanup; -w must succeed.
    if ((rc != 0)) && ! [[ $option == -k && $rc == 1 ]]; then
      return 1
    fi
  done
}
finish() {
  local rc=$?
  trap - EXIT
  stop_server || rc=1
  if ((!inventory_done)); then
    if ! python3 "$runtime_guard" snapshot "$wine_build" "$work_root/runtime-after.json" ||
      ! cmp -s "$work_root/runtime-before.json" "$work_root/runtime-after.json"; then
      echo "FAIL: runtime inventory changed or could not be verified" >&2
      rc=1
    fi
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

record_git_revision() { # path label
  local path=$1 label=$2
  if git -C "$path" rev-parse HEAD >/dev/null 2>&1; then
    local head branch dirty
    head=$(git -C "$path" rev-parse HEAD)
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD)
    dirty=$(git -C "$path" status --porcelain)
    printf '%s: branch=%s head=%s dirty=%s\n' "$label" "$branch" "$head" \
      "$([[ -n $dirty ]] && echo yes || echo no)"
    # An `if`, not `[[ -n $dirty ]] && ...`: with a clean checkout the `&&`
    # form's own exit status is 1 (the test was false), which is this
    # function's last command and, under set -e, silently killed the whole
    # script right here - before the verdict ever printed. Caught by running
    # the real script end-to-end with a clean fex checkout, not part of the
    # review findings this pass was fixing.
    if [[ -n $dirty ]]; then
      printf '%s\n' "$dirty" | sed "s/^/  $label: /"
    fi
  else
    printf '%s: not a git checkout at %s\n' "$label" "$path"
  fi
}

echo "== build =="
echo "cc x64 guest"
"$cross_cc" -O2 -Wall -Wextra -o "$guest_dir/isa_corpus_sse2.exe" \
  "$spike_root/testcases/isa_corpus_sse2.c"
if ((run_mutate)); then
  echo "cc x64 guest (mutate=paddb, negative control)"
  "$cross_cc" -O2 -Wall -Wextra -DALLOY_CORPUS_MUTATE_PADDB \
    -o "$guest_dir/isa_corpus_sse2-mutate-paddb.exe" "$spike_root/testcases/isa_corpus_sse2.c"
fi

echo "building native oracle"
"$spike_root/testcases/build-isa-corpus-native.sh" "$work_root/native-oracle" \
  >"$log_dir/native-oracle-build.log" 2>&1
native_line=$(tail -n1 "$work_root/native-oracle/native-oracle-clean.log")
native_checksum=$(echo "$native_line" | grep -o 'checksum=[0-9a-f]*' | cut -d= -f2)
echo "native oracle: $native_line"

native_mutate_line=
native_mutate_checksum=
if ((run_mutate)); then
  echo "building native oracle (mutate=paddb) - the known-corrupted checksum the FEX"
  echo "  negative control run below must reproduce, not just exit nonzero"
  "$spike_root/testcases/build-isa-corpus-native.sh" "$work_root/native-oracle" \
    -DALLOY_CORPUS_MUTATE_PADDB >>"$log_dir/native-oracle-build.log" 2>&1
  native_mutate_line=$(tail -n1 "$work_root/native-oracle/native-oracle-PADDB.log")
  native_mutate_checksum=$(echo "$native_mutate_line" | grep -o 'checksum=[0-9a-f]*' | cut -d= -f2)
  echo "native oracle (mutate=paddb): $native_mutate_line"
fi

echo "== prefix setup =="
fex_sha_before=$(shasum -a 256 "$fex_dll" | awk '{print $1}')
echo "fex dll (build-2 builtin): $fex_dll"
echo "fex dll sha256 (before): $fex_sha_before"

# Gecko/Mono overrides so a fresh prefix never blocks on a download dialog
# nobody here can answer.
WINEPREFIX="$prefix" WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all \
  DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" FEX_SILENTLOG=1 \
  timeout_wine 120 "$log_dir/wineboot.log" wineboot -u
stop_server

echo "-- setup negative control: unregistered prefix must refuse the x64 guest --"
set +e
(
  cd "$guest_dir"
  # WINEDEBUG=-all suppresses even err-class messages, so the channel that
  # carries the expected refusal (err:xtajit) must be turned on explicitly -
  # "-all" alone silently hides the very message this probe is looking for.
  WINEPREFIX="$prefix" WINEDLLOVERRIDES="xtajit64=b;mscoree,mshtml=" WINEDEBUG=-all,+xtajit,+loaddll \
    DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" FEX_SILENTLOG=1 \
    timeout_wine 60 "$log_dir/unregistered.log" isa_corpus_sse2.exe
)
unregistered_rc=$?
set -e
stop_server
if [[ $unregistered_rc == 1 ]] &&
  rg -qi 'x64 emulation not implemented' "$log_dir/unregistered.log" &&
  rg -q 'trace:loaddll:build_module Loaded L"[^"\n]*xtajit64\.dll" at [0-9A-Fa-f]+: builtin' "$log_dir/unregistered.log" &&
  ! rg -q 'trace:loaddll:build_module Loaded L"[^"\n]*libarm64ecfex\.dll" at [0-9A-Fa-f]+: builtin' "$log_dir/unregistered.log"; then
  echo "confirmed: unregistered prefix refuses the x64 guest (\"x64 emulation not implemented\")"
else
  echo "FAIL setup check: expected \"x64 emulation not implemented\" from an unregistered prefix" >&2
  echo "  (rc=$unregistered_rc, see $log_dir/unregistered.log)" >&2
  exit 1
fi

cat >"$work_root/select-fex.reg" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\Software\Microsoft\Wow64\amd64]
@="libarm64ecfex.dll"
EOF
WINEPREFIX="$prefix" WINEDEBUG=-all \
  DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" FEX_SILENTLOG=1 \
  timeout_wine 60 "$log_dir/regedit.log" regedit "$work_root/select-fex.reg"
stop_server
printf 'registered libarm64ecfex.dll under HKLM\\Software\\Microsoft\\Wow64\\amd64\n'

run_guest() { # exe-name label
  local exe=$1 label=$2
  set +e
  (
    cd "$guest_dir"
    WINEPREFIX="$prefix" WINEDLLOVERRIDES=xtajit64=n WINEDEBUG=-all,+module,+loaddll \
      DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" FEX_SILENTLOG=1 \
      timeout_wine 60 "$log_dir/$label.log" "$exe"
  )
  local result=$?
  set -e
  echo "$result" >"$log_dir/$label.exit"
  stop_server
  if ! rg -q 'trace:loaddll:build_module Loaded L"[^"\n]*libarm64ecfex\.dll" at [0-9A-Fa-f]+: builtin' "$log_dir/$label.log"; then
    echo "FAIL: no actual builtin FEX load in $label" >&2
    exit 1
  fi
}

echo "== clean run =="
run_guest isa_corpus_sse2.exe clean
clean_rc=$(cat "$log_dir/clean.exit")
clean_line=$(grep '^cpu-001 isa-corpus sse2:' "$log_dir/clean.log" || true)
echo "exit=$clean_rc  $clean_line"

echo "confirmed: Wine loaded builtin libarm64ecfex.dll (trace present in $log_dir/clean.log)"

mutate_rc=
mutate_line=
if ((run_mutate)); then
  echo "== negative control run (mutate=paddb) =="
  run_guest isa_corpus_sse2-mutate-paddb.exe mutate
  mutate_rc=$(cat "$log_dir/mutate.exit")
  mutate_line=$(grep '^cpu-001 isa-corpus sse2:' "$log_dir/mutate.log" || true)
  echo "exit=$mutate_rc  $mutate_line"
  echo "sample mismatches:"
  grep '^FAIL' "$log_dir/mutate.log" | head -3 || true
fi

stop_server
fex_sha_after=$(shasum -a 256 "$fex_dll" | awk '{print $1}')
echo "fex dll sha256 (after):  $fex_sha_after"
python3 "$runtime_guard" snapshot "$wine_build" "$work_root/runtime-after.json"
cmp "$work_root/runtime-before.json" "$work_root/runtime-after.json"
inventory_done=1
echo "confirmed: complete runtime inventory unchanged"
echo "runtime inventories and per-run source/binary identities: $work_root"

{
  echo "run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "wine_build: $wine_build"
  record_git_revision "$wine_src" wine
  record_git_revision "$fex_src" fex
  echo "fex_dll: $fex_dll"
  echo "fex_dll_sha256_before: $fex_sha_before"
  echo "fex_dll_sha256_after:  $fex_sha_after"
  echo "native_oracle: $native_line"
  if [[ -n $native_mutate_line ]]; then
    echo "native_oracle_mutate_paddb: $native_mutate_line"
  fi
  echo "clean_run: exit=$clean_rc $clean_line"
  if [[ -n $mutate_rc ]]; then
    echo "mutate_run: exit=$mutate_rc $mutate_line"
  fi
} | tee "$work_root/run-metadata.txt"

echo "== verdict =="
ok=1
if [[ $fex_sha_before != "$fex_sha_after" ]]; then
  echo "FAIL: build-2's libarm64ecfex.dll changed during this run (not read-only)" >&2
  ok=0
fi
if ! isa_corpus_verdict clean "$log_dir/clean.log" "$clean_rc" "$native_checksum" none; then
  ok=0
fi
if ((run_mutate)); then
  if ! isa_corpus_verdict mutation "$log_dir/mutate.log" "$mutate_rc" "$native_mutate_checksum" paddb; then
    ok=0
  fi
fi

((ok)) || exit 1
if ((run_mutate)); then
  echo "run-isa-corpus: all required outcomes observed"
else
  echo "run-isa-corpus: clean development check passed; required mutation NOT RUN"
fi
