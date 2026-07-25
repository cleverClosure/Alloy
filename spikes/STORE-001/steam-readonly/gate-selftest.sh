#!/usr/bin/env bash
# Negative tests for the Steam automation gate (issue #25).
# Author: Tim Isaev
#
# The gate passes on this repository. That is the outcome we want, and it is
# also the reason the gate cannot be trusted on that evidence alone: a check
# that is silently broken and a check that has nothing to report produce exactly
# the same green line. Each case below plants one violation from doc 18 §9's
# prohibited list in a synthetic repository and requires the gate to reject it,
# naming the right check. The last case plants nothing and requires a pass, so
# the suite also fails if the gate has become unable to succeed.
#
# Usage: gate-selftest.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../../.." && pwd)
gate="$here/steam-automation-gate.sh"
tool="$repo_root/tools/steam-fingerprint.py"

fail=0
work=$(mktemp -d "${TMPDIR:-/tmp}/alloy-gate-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A minimal repository the gate can scan: the shipped discovery tool, one clean
# document, and whatever violation the case adds on top.
make_repo() { # case-name
  local root="$work/$1"
  mkdir -p "$root/tools" "$root/docs"
  cp "$tool" "$root/tools/steam-fingerprint.py"
  printf '# Storefront notes\n\nDiscovery reads local manifests.\n' >"$root/docs/notes.md"
  git -C "$root" init -q
  printf '%s\n' "$root"
}

# run_case <name> <expected-exit> <expected-output-marker>
run_case() {
  local name=$1 want=$2 marker=$3 root="$work/$1" out status
  git -C "$root" add -A
  out=$(ALLOY_GATE_ROOT="$root" "$gate" 2>&1)
  status=$?

  if [[ $want == pass ]]; then
    if ((status != 0)); then
      printf 'FAIL: %s — gate rejected a clean repository\n' "$name" >&2
      printf '%s\n' "$out" | sed 's/^/        /' >&2
      fail=1
      return
    fi
  elif ((status == 0)); then
    printf 'FAIL: %s — gate passed a repository containing the violation\n' "$name" >&2
    fail=1
    return
  fi

  if ! grep -qF "$marker" <<<"$out"; then
    printf 'FAIL: %s — gate did not report %q\n' "$name" "$marker" >&2
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    fail=1
    return
  fi
  printf 'ok: %s\n' "$name"
}

# 1. Background SteamCMD orchestration to install or update a consumer game.
root=$(make_repo steamcmd-orchestration)
cat >"$root/tools/install-title.sh" <<'EOF'
#!/usr/bin/env bash
steamcmd +login anonymous +app_update 1272160 validate +quit
EOF
run_case steamcmd-orchestration fail "shipped code references steamcmd"

# 2. Reading Valve's session material to learn who is signed in.
root=$(make_repo credential-surface)
cat >"$root/tools/session.py" <<'EOF'
from pathlib import Path
users = Path("~/Steam/config/loginusers.vdf").expanduser().read_text()
EOF
run_case credential-surface fail "Steam credential or session material"

# 3. Process control over the official client.
root=$(make_repo client-process-control)
cat >"$root/tools/restart-client.sh" <<'EOF'
#!/usr/bin/env bash
pkill -f steam.exe
EOF
run_case client-process-control fail "drives the Steam client"

# 4. Discovery that writes into the library it was asked to read. The marker
#    write is injected into the shipped tool so the case exercises the real
#    snapshot comparison rather than a hand-built stand-in.
root=$(make_repo discovery-writes)
sed 's|    records = \[\]|    records = []\n    (install_root / ".alloy-scan").write_text("scanned")|' \
  "$tool" >"$root/tools/steam-fingerprint.py"
run_case discovery-writes fail "discovery modified the Steam library"

# 5. A document that proposes a steamcmd flow rather than recording that it is
#    prohibited.
root=$(make_repo undocumented-steamcmd-plan)
cat >"$root/docs/download-plan.md" <<'EOF'
# Download plan

Fetch the depot with steamcmd once the user links their account.
EOF
run_case undocumented-steamcmd-plan fail "not the legal or research record"

# 6. Nothing planted: the gate must still be able to pass.
root=$(make_repo clean-repository)
run_case clean-repository pass "STEAM-AUTOMATION: pass"

echo
if [[ $fail == 0 ]]; then
  echo "GATE-SELFTEST: pass — every check rejects its violation and the gate can still go green"
else
  echo "GATE-SELFTEST: FAIL — the gate does not detect what it claims to detect." >&2
fi
exit $fail
