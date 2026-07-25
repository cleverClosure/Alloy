#!/usr/bin/env bash
# Steam automation gate for the shipped product (counsel item 6, issue #25).
# Author: Tim Isaev
#
# The Steam Subscriber Agreement's automation provision prohibits scripts, bots
# and other non-human-controlled systems from interacting with Steam Content and
# Services, and Valve publishing SteamCMD documentation is not authorisation to
# automate a user's account. The v1 posture that follows from that (doc 18 §9)
# is read-only local discovery plus actions the user takes in Steam's own UI.
#
# "Discovery is read-only" is an assertion about what the code does to a user's
# Steam library, so this gate proves it by doing it: it builds a throwaway Steam
# library, fingerprints every byte and timestamp in it, runs the shipped
# discovery tool over it in every mode, and fails if anything moved. The grep
# checks around it close the paths a fixture cannot reach - a credential store,
# a steamcmd invocation, a synthetic click into the client.
#
# It is a gate, not a report: a green run is what licenses doc 18 §9's claim
# that the implementation matches the permitted posture.
#
# Usage: steam-automation-gate.sh
#
# ALLOY_GATE_ROOT overrides the repository the gate scans. Only gate-selftest.sh
# sets it, to point the gate at synthetic repositories that do contain the
# violations, because a gate nobody has watched fail is not yet evidence.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_root=${ALLOY_GATE_ROOT:-$(cd "$here/../../.." && pwd)}
cd "$repo_root" || exit 2

fail=0
note() { printf '  %s\n' "$*"; }
bad() {
  printf '  FAIL: %s\n' "$*" >&2
  fail=1
}
indent() { printf '        %s\n' "${1//$'\n'/$'\n'        }"; }

# First-party executable code. Two exclusions, for the same reason in different
# forms: documentation must be free to name the prohibited flows in order to
# prohibit them (check 5 governs which documents may), and this directory is the
# enforcement machinery, so the gate holds the flows as search patterns and the
# selftest holds them as fixtures. Both would otherwise report themselves.
#
# The exclusion is by directory rather than by filename because the previous
# form matched one path and silently stopped covering the selftest the moment it
# was committed - the checks were green only because the fixtures were untracked.
code_files() {
  git ls-files |
    grep -Ev '^(third_party/|tools/toolchains/)' |
    grep -Ev '^spikes/[^/]+/work/' |
    grep -Ev '^spikes/STORE-001/steam-readonly/' |
    grep -E '\.(sh|py|swift|c|h|cpp|hpp|m|mm|yml|yaml|json)$'
}

# Documents permitted to discuss steamcmd, because recording the prohibition and
# the research it came from is their job: the legal plan, the decision and spike
# records that carry the narrowing, the research findings it superseded, and this
# gate's own evidence. Anything else naming steamcmd is a new plan to automate
# Steam, which is what this check exists to catch.
STEAMCMD_ALLOWED='^(docs/research/SPIKE-LEGAL-001-(verdict|counsel-brief|preliminary-findings)\.md|docs/research/SPIKE-STORE-001-findings\.md|docs/docs/(14_DECISION_LOG|16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES|18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION)\.md|docs/CHANGELOG\.md|spikes/STORE-001/steam-readonly/.*|spikes/STORE-001/results/.*)$'

echo "== 1. steamcmd orchestration in shipped code"
hits=$(code_files | xargs grep -l -i 'steamcmd' 2>/dev/null || true)
if [[ -n $hits ]]; then
  bad "shipped code references steamcmd:"
  indent "$hits" >&2
else
  note "no shipped source file invokes steamcmd"
fi

echo "== 2. Steam credential handling"
# Valve's credential and session artefacts. Reading loginusers.vdf to name the
# signed-in account would be account interaction, not install discovery, so the
# gate treats any reference to these as a credential surface.
CRED_PATTERN='loginusers\.vdf|ssfn[0-9]|sentry\.bin|steamRememberPassword|SteamLoginSecure|steam_refresh_token|steamcommunity\.com/(login|openid)'
hits=$(code_files | xargs grep -l -E "$CRED_PATTERN" 2>/dev/null || true)
if [[ -n $hits ]]; then
  bad "shipped code touches Steam credential or session material:"
  indent "$hits" >&2
else
  note "no shipped source file reads, stores or relays Steam credentials"
fi

echo "== 3. driving the Steam client by input or process control"
# Simulated input into, or process control over, the official client. Launching
# an already-installed *game* executable after a user action is permitted and is
# what the STORE-001 launch harness does, so the pattern names the client only.
DRIVE_PATTERN='CGEventPost|CGEventCreateKeyboardEvent|osascript.*[Ss]team|tell application "Steam"|(pkill|killall|kill).*[Ss]team|steam\.exe|Steam\.app/Contents/MacOS'
hits=$(code_files | xargs grep -l -E "$DRIVE_PATTERN" 2>/dev/null || true)
if [[ -n $hits ]]; then
  bad "shipped code drives the Steam client:"
  indent "$hits" >&2
else
  note "no shipped source file simulates input to or controls the Steam client"
fi

echo "== 4. discovery leaves a Steam library byte-for-byte unchanged"
tool="$repo_root/tools/steam-fingerprint.py"
if [[ ! -f $tool ]]; then
  bad "discovery tool not found at $tool"
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/alloy-steam-readonly.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  primary="$work/library-primary"
  secondary="$work/library-secondary"
  outside="$work/outside"
  mkdir -p "$primary/steamapps/common/Sir Brante" \
    "$secondary/steamapps/common/Second Title" "$outside"

  # libraryfolders.vdf drives multi-library discovery; the second entry proves
  # the tool follows it without writing to the library it was pointed at.
  cat >"$primary/steamapps/libraryfolders.vdf" <<VDF
"libraryfolders"
{
	"0"
	{
		"path"		"$primary"
	}
	"1"
	{
		"path"		"$secondary"
	}
}
VDF

  cat >"$primary/steamapps/appmanifest_1272160.acf" <<ACF
"AppState"
{
	"appid"		"1272160"
	"name"		"The Life and Suffering of Sir Brante"
	"buildid"		"24280929"
	"installdir"		"Sir Brante"
	"InstalledDepots"
	{
		"1272161"
		{
			"manifest"		"7712163189587615000"
			"size"		"1234567"
		}
	}
}
ACF

  cat >"$secondary/steamapps/appmanifest_9999990.acf" <<ACF
"AppState"
{
	"appid"		"9999990"
	"name"		"Second Title"
	"buildid"		"1000001"
	"installdir"		"Second Title"
	"InstalledDepots"
	{
		"9999991"
		{
			"manifest"		"1111111111111111111"
			"size"		"4096"
		}
	}
}
ACF

  printf 'entitled game image\n' >"$primary/steamapps/common/Sir Brante/game.exe"
  printf 'asset payload\n' >"$primary/steamapps/common/Sir Brante/data.pak"
  printf 'second title image\n' >"$secondary/steamapps/common/Second Title/game.exe"

  # Content, size, mode and mtime of every path under both libraries. Access
  # time is deliberately not captured: reading is the permitted behaviour, and
  # reading is what moves atime. A directory's mtime moves when an entry is
  # created or removed inside it, so this also catches files the tool adds.
  snapshot() {
    local root
    for root in "$primary" "$secondary"; do
      find "$root" -mindepth 1 | sort | while IFS= read -r path; do
        if [[ -f $path && ! -L $path ]]; then
          printf '%s\t%s\t%s\n' "${path#"$work"}" \
            "$(stat -f '%p %z %m' "$path")" \
            "$(shasum -a 256 "$path" | awk '{print $1}')"
        else
          printf '%s\t%s\n' "${path#"$work"}" "$(stat -f '%p %m' "$path")"
        fi
      done
    done
  }

  before=$(snapshot)

  # Every mode the tool has, including the two that write output, run from a
  # working directory outside the library so a stray default-named output file
  # would land there and show up as an untracked artefact rather than silently
  # inside the user's Steam install.
  (cd "$outside" && python3 "$tool" "$primary") >"$work/list.log" 2>&1 ||
    bad "discovery listing failed: $(cat "$work/list.log")"
  (cd "$outside" && python3 "$tool" "$primary" --app 1272160 \
    --out "$work/fingerprint.json") >"$work/fingerprint.log" 2>&1 ||
    bad "fingerprint failed: $(cat "$work/fingerprint.log")"
  (cd "$outside" && python3 "$tool" "$primary" --app 1272160 \
    --verify "$work/fingerprint.json") >"$work/verify.log" 2>&1 ||
    bad "verify failed: $(cat "$work/verify.log")"
  (cd "$outside" && python3 "$tool" "$primary" --app 9999990 \
    --out "$work/second.json") >"$work/second.log" 2>&1 ||
    bad "second-library fingerprint failed: $(cat "$work/second.log")"

  after=$(snapshot)

  if [[ $before != "$after" ]]; then
    bad "discovery modified the Steam library:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  else
    note "both libraries unchanged after list, fingerprint and verify"
  fi

  # The permitted read set. Anything else under a Steam root is out of scope for
  # discovery, and a tool that needed more would be doing something else.
  if ! grep -q '1272160' "$work/list.log" || ! grep -q '9999990' "$work/list.log"; then
    bad "discovery did not read both libraries from libraryfolders.vdf"
  else
    note "discovery read appmanifest ACFs from both library folders"
  fi
  if ! grep -q 'EXACT MATCH' "$work/verify.log"; then
    bad "rerun verification did not report an exact match"
  else
    note "rerun verification reproduces the build identity"
  fi
  stray=$(find "$outside" -type f | wc -l | tr -d ' ')
  if [[ $stray != 0 ]]; then
    bad "discovery wrote $stray unrequested file(s) into the working directory"
  else
    note "discovery wrote nothing except the requested fingerprint files"
  fi
fi

echo "== 5. steamcmd named outside the legal and research record"
hits=$(git ls-files -- '*.md' | xargs grep -l -i 'steamcmd' 2>/dev/null |
  grep -Ev "$STEAMCMD_ALLOWED" || true)
if [[ -n $hits ]]; then
  bad "steamcmd appears in a document that is not the legal or research record:"
  indent "$hits" >&2
  printf '        A document naming steamcmd outside those files is a plan to\n' >&2
  printf '        automate Steam. Add it to the allowlist only if it records the\n' >&2
  printf '        prohibition rather than proposing the flow.\n' >&2
else
  note "steamcmd appears only where the prohibition is recorded"
fi

echo
if [[ $fail == 0 ]]; then
  echo "STEAM-AUTOMATION: pass - discovery is read-only, no account interaction"
else
  echo "STEAM-AUTOMATION: FAIL - the shipped posture exceeds doc 18 §9." >&2
  echo "The v1 design permits read-only local discovery and user-driven actions" >&2
  echo "in Steam's own UI. Anything above needs Valve's written permission." >&2
fi
exit $fail
