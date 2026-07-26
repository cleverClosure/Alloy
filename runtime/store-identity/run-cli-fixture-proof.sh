#!/usr/bin/env bash
# Gate 6 explicit CLI and read-only fixture proof.
# Author: Timur Isaev
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE_CACHE="$PACKAGE_ROOT/.build/module-cache"
FIXTURE_SOURCE="$PACKAGE_ROOT/Tests/Fixtures/SyntheticSteamLibrary"
REGISTRY_SOURCE="$PACKAGE_ROOT/Registry/selectors.v1.json"

export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

require_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$label: expected '$expected', got '$actual'"
}

snapshot_tree() {
  local root="$1"
  local path
  find "$root" -type d -print | sed 's/^/directory /'
  find "$root" -type f -exec shasum -a 256 {} \;
  while IFS= read -r path; do
    printf 'symlink %s -> %s\n' "$path" "$(readlink "$path")"
  done < <(find "$root" -type l -print | LC_ALL=C sort)
}

snapshot_inputs() {
  local root
  for root in "${INPUT_ROOTS[@]}"; do
    snapshot_tree "$root"
  done
  shasum -a 256 \
    "$ANCHOR" \
    "$REGISTRY_SOURCE" \
    "$SYNTHETIC_REGISTRY" \
    "$NONCANONICAL_REGISTRY"
}

require_refusal_result() {
  local label="$1"
  local status="$2"
  local stdout_path="$3"
  local stderr_path="$4"
  local error_lines

  require_equal "$status" "1" "$label exit status"
  [[ ! -s "$stdout_path" ]] || fail "$label wrote standard output"
  error_lines="$(wc -l <"$stderr_path" | tr -d ' ')"
  require_equal "$error_lines" "1" "$label standard-error line count"
  rg -q '^ERROR ' "$stderr_path" || fail "$label lacked one ERROR line"
}

run_refusal() {
  local label="$1"
  local state_root="$2"
  shift 2
  local stdout_path="$WORK_ROOT/$label.stdout"
  local stderr_path="$WORK_ROOT/$label.stderr"

  set +e
  "$CLI" "$@" >"$stdout_path" 2>"$stderr_path"
  local status=$?
  set -e
  require_refusal_result "$label" "$status" "$stdout_path" "$stderr_path"
  [[ ! -e "$state_root" ]] || fail "$label created state"
}

run_observation_refusal() {
  local label="$1"
  local state_root="$2"
  shift 2
  local stdout_path="$WORK_ROOT/$label.stdout"
  local stderr_path="$WORK_ROOT/$label.stderr"

  set +e
  "$CLI" "$@" >"$stdout_path" 2>"$stderr_path"
  local status=$?
  set -e
  require_refusal_result "$label" "$status" "$stdout_path" "$stderr_path"
  if [[ -e "$state_root" ]]; then
    [[ -d "$state_root" && ! -L "$state_root" ]] ||
      fail "$label created an unsafe state root"
    [[ ! -e "$state_root/invalidations" ]] ||
      fail "$label created invalidation state"
    if [[ -e "$state_root/watcher-scratch" ]]; then
      [[ -d "$state_root/watcher-scratch" ]] ||
        fail "$label created unsafe watcher scratch state"
      [[ -z "$(find "$state_root/watcher-scratch" -mindepth 1 -print -quit)" ]] ||
        fail "$label left watcher scratch state"
    fi
    [[ -z "$(
      find "$state_root" \
        -mindepth 1 \
        ! -path "$state_root/watcher-scratch" \
        -print -quit
    )" ]] || fail "$label created unexpected state"
  fi
}

run_ancestor_refusal() {
  local label="$1"
  local state_root="$2"
  shift 2
  local stdout_path="$WORK_ROOT/$label.stdout"
  local stderr_path="$WORK_ROOT/$label.stderr"

  set +e
  "$CLI" "$@" >"$stdout_path" 2>"$stderr_path"
  local status=$?
  set -e
  require_refusal_result "$label" "$status" "$stdout_path" "$stderr_path"
  [[ ! -e "$state_root/watcher-scratch" ]] ||
    fail "$label created watcher state beside the selected library"
  [[ ! -e "$state_root/invalidations" ]] ||
    fail "$label created invalidations beside the selected library"
}

swift build \
  --disable-sandbox \
  --package-path "$PACKAGE_ROOT" \
  --product AlloyStoreIdentityFaultProbe
swift build \
  --disable-sandbox \
  --package-path "$PACKAGE_ROOT" \
  --product AlloyStoreIdentityCLI

PROBE="$PACKAGE_ROOT/.build/debug/AlloyStoreIdentityFaultProbe"
CLI="$PACKAGE_ROOT/.build/debug/AlloyStoreIdentityCLI"
[[ -x "$PROBE" ]] || fail "fault probe executable was not produced"
[[ -x "$CLI" ]] || fail "production CLI executable was not produced"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/alloy-store-cli-proof.XXXXXX")"
cleanup() {
  if [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" ]]; then
    rm -rf -- "$WORK_ROOT"
  fi
}
trap cleanup EXIT

FIXTURE_LIBRARY="$WORK_ROOT/library"
cp -R "$FIXTURE_SOURCE" "$FIXTURE_LIBRARY"
MANIFEST="$FIXTURE_LIBRARY/steamapps/appmanifest_900000.acf"
INSTALL_ROOT="$FIXTURE_LIBRARY/steamapps/common/Synthetic Game"
ANCHOR="$WORK_ROOT/anchor.json"
STATE_ROOT="$WORK_ROOT/state"
ANCHORED_IMAGE="The Life and Suffering of Sir Brante.exe"

mv "$INSTALL_ROOT/SyntheticGame.exe" "$INSTALL_ROOT/$ANCHORED_IMAGE"

"$PROBE" scan "$MANIFEST" "$INSTALL_ROOT" "$ANCHOR" \
  >"$WORK_ROOT/anchor.log"

SYNTHETIC_REGISTRY="$WORK_ROOT/selectors.json"
NONCANONICAL_REGISTRY="$WORK_ROOT/selectors-noncanonical.json"
python3 - \
  "$ANCHOR" \
  "$SYNTHETIC_REGISTRY" \
  "$NONCANONICAL_REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

anchor = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
image_path = "The Life and Suffering of Sir Brante.exe"
image_sha256 = next(
    item["sha256"] for item in anchor["files"] if item["path"] == image_path
)
registry = {
    "author": "Timur Isaev",
    "record": "alloy-store-identity-selector-registry",
    "selectors": [
        {
            "aggregate_sha256": anchor["aggregate_sha256"],
            "artifact": {
                "kind": "fingerprint",
                "path": "runtime/store-identity/Tests/Fixtures/SyntheticSteamLibrary",
                "sha256": "0" * 64,
            },
            "game_id": anchor["appid"],
            "image_hashes": {image_path: image_sha256},
            "manifest_ids": {
                depot_id: depot["manifest"]
                for depot_id, depot in anchor["depots"].items()
            },
            "selector_id": "store-001.cli-proof.900000.90000042",
            "store_build_id": anchor["buildid"],
            "storefront": "steam",
        }
    ],
    "version": 1,
}
canonical = json.dumps(
    registry,
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
).encode("utf-8") + b"\n"
Path(sys.argv[2]).write_bytes(canonical)
Path(sys.argv[3]).write_text(
    json.dumps(registry, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

CHANGED_LIBRARY="$WORK_ROOT/library-changed"
cp -R "$FIXTURE_LIBRARY" "$CHANGED_LIBRARY"
python3 - \
  "$CHANGED_LIBRARY/steamapps/common/Synthetic Game/README.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = bytearray(path.read_bytes())
if not payload:
    raise SystemExit("changed fixture file is empty")
payload[0] ^= 0x01
path.write_bytes(payload)
PY

TRAVERSAL_LIBRARY="$WORK_ROOT/library-traversal"
cp -R "$FIXTURE_LIBRARY" "$TRAVERSAL_LIBRARY"
python3 - \
  "$TRAVERSAL_LIBRARY/steamapps/appmanifest_900000.acf" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '"installdir"\t\t"Synthetic Game"'
if text.count(old) != 1:
    raise SystemExit("fixture installdir marker is not unique")
path.write_text(text.replace(old, '"installdir"\t\t".."'), encoding="utf-8")
PY

MANIFEST_SYMLINK_LIBRARY="$WORK_ROOT/library-manifest-symlink"
cp -R "$FIXTURE_LIBRARY" "$MANIFEST_SYMLINK_LIBRARY"
MANIFEST_SYMLINK="$MANIFEST_SYMLINK_LIBRARY/steamapps/appmanifest_900000.acf"
mv "$MANIFEST_SYMLINK" \
  "$MANIFEST_SYMLINK_LIBRARY/steamapps/appmanifest_900000.real.acf"
ln -s "appmanifest_900000.real.acf" "$MANIFEST_SYMLINK"

INSTALL_SYMLINK_LIBRARY="$WORK_ROOT/library-install-symlink"
cp -R "$FIXTURE_LIBRARY" "$INSTALL_SYMLINK_LIBRARY"
INSTALL_SYMLINK_ROOT="$INSTALL_SYMLINK_LIBRARY/steamapps/common"
mv "$INSTALL_SYMLINK_ROOT/Synthetic Game" \
  "$INSTALL_SYMLINK_ROOT/Synthetic Game Real"
ln -s "Synthetic Game Real" "$INSTALL_SYMLINK_ROOT/Synthetic Game"

ANCESTOR_STATE_ROOT="$WORK_ROOT/ancestor-state"
ANCESTOR_LIBRARY="$ANCESTOR_STATE_ROOT/library"
mkdir -p "$ANCESTOR_STATE_ROOT"
cp -R "$FIXTURE_LIBRARY" "$ANCESTOR_LIBRARY"

INPUT_ROOTS=(
  "$FIXTURE_LIBRARY"
  "$CHANGED_LIBRARY"
  "$TRAVERSAL_LIBRARY"
  "$MANIFEST_SYMLINK_LIBRARY"
  "$INSTALL_SYMLINK_LIBRARY"
  "$ANCESTOR_STATE_ROOT"
)
snapshot_inputs | LC_ALL=C sort >"$WORK_ROOT/inputs-before.sha256"

status="$(
  "$CLI" observe \
    --library-root "$FIXTURE_LIBRARY" \
    --app-id 900000 \
    --anchor "$ANCHOR" \
    --registry "$REGISTRY_SOURCE" \
    --state-root "$STATE_ROOT"
)"
require_equal \
  "$status" \
  "STATUS appid=900000 update=unchanged self_test=PASS invalidation=none" \
  "unchanged CLI status"

if [[ -d "$STATE_ROOT/invalidations" ]]; then
  [[ -z "$(find "$STATE_ROOT/invalidations" -type f -name '*.json' -print -quit)" ]] ||
    fail "unchanged CLI emitted an invalidation"
fi
[[ -d "$STATE_ROOT/watcher-scratch" ]] ||
  fail "unchanged CLI did not run its self-test"
[[ -z "$(find "$STATE_ROOT/watcher-scratch" -mindepth 1 -print -quit)" ]] ||
  fail "unchanged CLI left self-test scratch state"

CHANGED_STATE_ROOT="$WORK_ROOT/state-changed"
changed_status="$(
  "$CLI" observe \
    --library-root "$CHANGED_LIBRARY" \
    --app-id 900000 \
    --anchor "$ANCHOR" \
    --registry "$SYNTHETIC_REGISTRY" \
    --state-root "$CHANGED_STATE_ROOT"
)"
changed_id="${changed_status#* id=}"
changed_id="${changed_id%% *}"
[[ "$changed_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "changed CLI emitted an invalid invalidation id"
require_equal \
  "$changed_status" \
  "STATUS appid=900000 update=changed self_test=PASS created=true id=$changed_id superseded=90000042 observed=90000042" \
  "changed CLI status"
[[ -d "$CHANGED_STATE_ROOT/watcher-scratch" ]] ||
  fail "changed CLI did not run its self-test"
[[ -z "$(
  find "$CHANGED_STATE_ROOT/watcher-scratch" \
    -mindepth 1 \
    -print -quit
)" ]] || fail "changed CLI left self-test scratch state"

INVALIDATION="$CHANGED_STATE_ROOT/invalidations/${changed_id#sha256:}.json"
[[ -f "$INVALIDATION" && ! -L "$INVALIDATION" ]] ||
  fail "changed CLI did not publish one regular invalidation"
invalidation_count="$(
  find "$CHANGED_STATE_ROOT/invalidations" \
    -type f \
    -name '*.json' |
    wc -l |
    tr -d ' '
)"
require_equal "$invalidation_count" "1" "changed invalidation count"
[[ -z "$(
  find "$CHANGED_STATE_ROOT/invalidations" \
    -type f \
    -name '.*.tmp-*' \
    -print -quit
)" ]] || fail "changed CLI left a temporary invalidation"

python3 - "$INVALIDATION" "$changed_id" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
record = json.loads(raw)
canonical = json.dumps(
    record,
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
).encode("utf-8") + b"\n"
if raw != canonical:
    raise SystemExit("invalidation is not canonical JSON")
expected = {
    "added_file_paths": [],
    "changed_depot_ids": [],
    "changed_file_paths": ["README.txt"],
    "game_content_changed": True,
    "game_id": "900000",
    "invalidation_id": sys.argv[2],
    "metadata_changed": False,
    "observed_build": "90000042",
    "removed_file_paths": [],
    "selector_ids": ["store-001.cli-proof.900000.90000042"],
    "superseded_build": "90000042",
}
actual = {
    "added_file_paths": record["added_file_paths"],
    "changed_depot_ids": record["changed_depot_ids"],
    "changed_file_paths": record["changed_file_paths"],
    "game_content_changed": record["game_content_changed"],
    "game_id": record["game_id"],
    "invalidation_id": record["invalidation_id"],
    "metadata_changed": record["metadata_changed"],
    "observed_build": record["observed"]["build_id"],
    "removed_file_paths": record["removed_file_paths"],
    "selector_ids": record["selector_ids"],
    "superseded_build": record["superseded"]["build_id"],
}
if actual != expected:
    raise SystemExit(f"unexpected invalidation: {actual!r}")
PY

invalidation_before="$(
  shasum -a 256 "$INVALIDATION" | awk '{print $1}'
)"
reused_status="$(
  "$CLI" observe \
    --library-root "$CHANGED_LIBRARY" \
    --app-id 900000 \
    --anchor "$ANCHOR" \
    --registry "$SYNTHETIC_REGISTRY" \
    --state-root "$CHANGED_STATE_ROOT"
)"
require_equal \
  "$reused_status" \
  "STATUS appid=900000 update=changed self_test=PASS created=false id=$changed_id superseded=90000042 observed=90000042" \
  "idempotent changed CLI status"
invalidation_after="$(
  shasum -a 256 "$INVALIDATION" | awk '{print $1}'
)"
require_equal \
  "$invalidation_after" \
  "$invalidation_before" \
  "idempotent invalidation bytes"
invalidation_count="$(
  find "$CHANGED_STATE_ROOT/invalidations" \
    -type f \
    -name '*.json' |
    wc -l |
    tr -d ' '
)"
require_equal "$invalidation_count" "1" "idempotent invalidation count"
[[ -z "$(
  find "$CHANGED_STATE_ROOT/invalidations" \
    -type f \
    -name '.*.tmp-*' \
    -print -quit
)" ]] || fail "idempotent CLI left a temporary invalidation"

COMMON_ARGS=(
  observe
  --library-root "$FIXTURE_LIBRARY"
  --app-id 900000
  --anchor "$ANCHOR"
  --registry "$REGISTRY_SOURCE"
)

run_refusal \
  missing-state \
  "$WORK_ROOT/refusal-missing" \
  "${COMMON_ARGS[@]}"
run_refusal \
  duplicate-app \
  "$WORK_ROOT/refusal-duplicate" \
  "${COMMON_ARGS[@]}" \
  --app-id 900000 \
  --state-root "$WORK_ROOT/refusal-duplicate"
run_refusal \
  unknown-argument \
  "$WORK_ROOT/refusal-unknown" \
  "${COMMON_ARGS[@]}" \
  --unknown value \
  --state-root "$WORK_ROOT/refusal-unknown"
run_refusal \
  trailing-argument \
  "$WORK_ROOT/refusal-trailing" \
  "${COMMON_ARGS[@]}" \
  --state-root "$WORK_ROOT/refusal-trailing" \
  trailing
run_refusal \
  noncanonical-registry \
  "$WORK_ROOT/refusal-noncanonical" \
  observe \
  --library-root "$FIXTURE_LIBRARY" \
  --app-id 900000 \
  --anchor "$ANCHOR" \
  --registry "$NONCANONICAL_REGISTRY" \
  --state-root "$WORK_ROOT/refusal-noncanonical"
run_refusal \
  contained-state \
  "$FIXTURE_LIBRARY/forbidden-state" \
  "${COMMON_ARGS[@]}" \
  --state-root "$FIXTURE_LIBRARY/forbidden-state"
run_ancestor_refusal \
  ancestor-state \
  "$ANCESTOR_STATE_ROOT" \
  observe \
  --library-root "$ANCESTOR_LIBRARY" \
  --app-id 900000 \
  --anchor "$ANCHOR" \
  --registry "$REGISTRY_SOURCE" \
  --state-root "$ANCESTOR_STATE_ROOT"
run_observation_refusal \
  installdir-traversal \
  "$WORK_ROOT/refusal-traversal" \
  observe \
  --library-root "$TRAVERSAL_LIBRARY" \
  --app-id 900000 \
  --anchor "$ANCHOR" \
  --registry "$REGISTRY_SOURCE" \
  --state-root "$WORK_ROOT/refusal-traversal"
run_observation_refusal \
  manifest-symlink \
  "$WORK_ROOT/refusal-manifest-symlink" \
  observe \
  --library-root "$MANIFEST_SYMLINK_LIBRARY" \
  --app-id 900000 \
  --anchor "$ANCHOR" \
  --registry "$REGISTRY_SOURCE" \
  --state-root "$WORK_ROOT/refusal-manifest-symlink"
run_observation_refusal \
  install-root-symlink \
  "$WORK_ROOT/refusal-install-symlink" \
  observe \
  --library-root "$INSTALL_SYMLINK_LIBRARY" \
  --app-id 900000 \
  --anchor "$ANCHOR" \
  --registry "$REGISTRY_SOURCE" \
  --state-root "$WORK_ROOT/refusal-install-symlink"

snapshot_inputs | LC_ALL=C sort >"$WORK_ROOT/inputs-after.sha256"
cmp -s "$WORK_ROOT/inputs-before.sha256" "$WORK_ROOT/inputs-after.sha256" ||
  fail "CLI changed a fixture, anchor, or registry input"

printf '%s\n' \
  'SUMMARY cli-fixture unchanged=PASS changed=PASS idempotence=PASS self-test=PASS argument-refusals=4 canonical-refusals=1 traversal-refusals=1 symlink-refusals=2 state-boundary-refusals=2 inputs=UNCHANGED invalidations=1 status=PASS'
