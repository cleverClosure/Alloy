#!/usr/bin/env bash
# CPU-001 systematic ISA corpus: SSE2 family through FEX/Wine (issue #104, Milestone 2).
# Author: Tim Isaev
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
#     the WINEDEBUG=+module trace actually looked it up, rather than assuming
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

wine_build=${ALLOY_WINE_BUILD:-/Users/cleverclosure/Developer/Alloy/spikes/WINE-001/work/build-2}
toolchain_bin=${ALLOY_TOOLCHAIN_BIN:-/Users/cleverclosure/Developer/Alloy/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin}
wine_src=${ALLOY_WINE_SOURCE:-/Users/cleverclosure/Developer/Alloy/third_party/src/wine}
fex_src=${ALLOY_FEX_SOURCE:-/Users/cleverclosure/Developer/Alloy/third_party/src/fex}

run_mutate=1
usage() {
  cat <<'EOF'
usage: run-isa-corpus.sh [--skip-mutate]

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
for cmd in rg perl shasum; do
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

# Never race the other agent's build. The bracketed class ([A]lloy) keeps this
# command's own argv out of its own match.
contention=$(ps aux | rg '[A]lloy/spikes/WINE-001/work/build-2' || true)
if [[ -n $contention ]]; then
  echo "another process is using build-2 right now - aborting:" >&2
  echo "$contention" >&2
  exit 2
fi

work_root="$spike_root/work/isa-corpus"
guest_dir="$work_root/guest"
prefix="$work_root/prefix"
log_dir="$work_root/logs"
rm -rf "$work_root"
mkdir -p "$guest_dir" "$prefix" "$log_dir" "$work_root/native-oracle"

wine_dyld_path=${DYLD_FALLBACK_LIBRARY_PATH:-/opt/homebrew/lib}

# Bounds a Wine invocation with a timeout - macOS ships no timeout(1).
timeout_wine() { # seconds wine-args...
  local seconds=$1
  shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$wine_loader" "$@"
}

stop_server() {
  WINEPREFIX="$prefix" DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" "$wineserver" -k \
    >/dev/null 2>&1 || true
}
# Only ever stop OUR OWN prefix's server - never anything another run started.
trap stop_server EXIT

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
  timeout_wine 120 wineboot -u >"$log_dir/wineboot.log" 2>&1
stop_server

echo "-- setup negative control: unregistered prefix must refuse the x64 guest --"
set +e
(
  cd "$guest_dir"
  # WINEDEBUG=-all suppresses even err-class messages, so the channel that
  # carries the expected refusal (err:xtajit) must be turned on explicitly -
  # "-all" alone silently hides the very message this probe is looking for.
  WINEPREFIX="$prefix" WINEDEBUG=-all,+xtajit \
    DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" FEX_SILENTLOG=1 \
    timeout_wine 30 isa_corpus_sse2.exe
) >"$log_dir/unregistered.log" 2>&1
unregistered_rc=$?
set -e
stop_server
if rg -qi 'x64 emulation not implemented' "$log_dir/unregistered.log"; then
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
  timeout_wine 60 regedit "$work_root/select-fex.reg" >"$log_dir/regedit.log" 2>&1
stop_server
printf 'registered libarm64ecfex.dll under HKLM\\Software\\Microsoft\\Wow64\\amd64\n'

run_guest() { # exe-name label
  local exe=$1 label=$2
  set +e
  (
    cd "$guest_dir"
    WINEPREFIX="$prefix" WINEDLLOVERRIDES=xtajit64=n WINEDEBUG=-all,+module,+loaddll \
      DYLD_FALLBACK_LIBRARY_PATH="$wine_dyld_path" FEX_SILENTLOG=1 \
      timeout_wine 60 "$exe"
  ) >"$log_dir/$label.log" 2>&1
  echo $? >"$log_dir/$label.exit"
  set -e
}

echo "== clean run =="
run_guest isa_corpus_sse2.exe clean
clean_rc=$(cat "$log_dir/clean.exit")
clean_line=$(grep '^cpu-001 isa-corpus sse2:' "$log_dir/clean.log" || true)
clean_checksum=$(echo "$clean_line" | grep -o 'checksum=[0-9a-f]*' | cut -d= -f2 || true)
echo "exit=$clean_rc  $clean_line"

if ! rg -qF 'find_builtin_dll looking for "libarm64ecfex.dll"' "$log_dir/clean.log"; then
  echo "FAIL: never observed Wine look up the libarm64ecfex builtin - cannot trust this run" >&2
  exit 1
fi
echo "confirmed: Wine's module loader looked up libarm64ecfex.dll (trace present in $log_dir/clean.log)"

mutate_rc=
mutate_line=
mutate_checksum=
if ((run_mutate)); then
  echo "== negative control run (mutate=paddb) =="
  run_guest isa_corpus_sse2-mutate-paddb.exe mutate
  mutate_rc=$(cat "$log_dir/mutate.exit")
  mutate_line=$(grep '^cpu-001 isa-corpus sse2:' "$log_dir/mutate.log" || true)
  mutate_checksum=$(echo "$mutate_line" | grep -o 'checksum=[0-9a-f]*' | cut -d= -f2 || true)
  echo "exit=$mutate_rc  $mutate_line"
  echo "sample mismatches:"
  grep '^FAIL' "$log_dir/mutate.log" | head -3 || true
fi

stop_server
fex_sha_after=$(shasum -a 256 "$fex_dll" | awk '{print $1}')
echo "fex dll sha256 (after):  $fex_sha_after"

{
  echo "run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "wine_build: $wine_build"
  record_git_revision "$wine_src" wine
  record_git_revision "$fex_src" fex
  echo "fex_dll: $fex_dll"
  echo "fex_dll_sha256_before: $fex_sha_before"
  echo "fex_dll_sha256_after:  $fex_sha_after"
  echo "native_oracle: $native_line"
  [[ -n $native_mutate_line ]] && echo "native_oracle_mutate_paddb: $native_mutate_line"
  echo "clean_run: exit=$clean_rc $clean_line"
  [[ -n $mutate_rc ]] && echo "mutate_run: exit=$mutate_rc $mutate_line"
} | tee "$work_root/run-metadata.txt"

echo "== verdict =="
ok=1
if [[ $fex_sha_before != "$fex_sha_after" ]]; then
  echo "FAIL: build-2's libarm64ecfex.dll changed during this run (not read-only)" >&2
  ok=0
fi
if [[ $clean_rc != 0 || -z $clean_checksum || $clean_checksum != "$native_checksum" ]]; then
  echo "FAIL: clean run did not pass with the native-oracle checksum" >&2
  echo "  native=$native_checksum  fex=$clean_checksum  exit=$clean_rc" >&2
  ok=0
else
  echo "PASS: clean run matches the native oracle (checksum=$clean_checksum)"
fi
if ((run_mutate)); then
  # A nonzero exit alone is not proof the negative control fired: a perl-alarm
  # timeout (142), an unrelated SIGSEGV (139), or any other crash all exit
  # nonzero too, and crediting any of those as "the mutation was caught" would
  # pass this gate even when the guest never ran the real-vs-reference
  # comparison at all. Require the specific outcome instead: the exit code
  # run_hand_vectors()/main() actually return on a detected mismatch (1), the
  # checksum matching the known-corrupted native oracle built above (proof
  # this is genuinely the paddb-corrupted reference path, not some other
  # failure), and a FAIL line naming paddb by name.
  if [[ $mutate_rc == 0 ]]; then
    echo "FAIL: the mutate=paddb negative control passed - it must fail" >&2
    ok=0
  elif [[ $mutate_rc != 1 ]]; then
    echo "FAIL: mutate run exited $mutate_rc, not the 1 a detected mismatch produces - cannot tell a real negative control from a crash or timeout" >&2
    ok=0
  elif [[ -z $mutate_checksum || $mutate_checksum != "$native_mutate_checksum" ]]; then
    echo "FAIL: mutate run's checksum does not match the native corrupted-reference oracle" >&2
    echo "  native_mutate=$native_mutate_checksum  fex_mutate=$mutate_checksum" >&2
    ok=0
  elif ! rg -qi '^FAIL (hand-vector )?paddb\b' "$log_dir/mutate.log"; then
    echo "FAIL: mutate run never reported a paddb mismatch by name - the negative control did not demonstrably fire on the expected operation" >&2
    ok=0
  else
    echo "PASS: the mutate=paddb negative control failed, as required (exit=$mutate_rc, checksum=$mutate_checksum matches the corrupted native oracle, paddb named in the log)"
  fi
fi

((ok)) || exit 1
echo "run-isa-corpus: all required outcomes observed"
