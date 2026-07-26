#!/bin/bash -p
# Capture a private Metal12 build-evidence snapshot.
# Author: Timur Isaev
#
# The script reads only explicit first-party source roots and the fixed
# runtime/metal12/build output tree. It never discovers or packages ignored
# dependency checkouts. A complete capture requires signed task commits, a
# signed tag, an explicit AI-session export, and a selected manifest signer.
# External timestamping and durable storage remain separate preservation steps.
[[ $- == *p* ]] || {
  printf 'evidence capture: execute this script directly; Bash privileged mode is required\n' >&2
  exit 2
}
set -euo pipefail
umask 077
unset BASH_ENV CDPATH ENV GLOBIGNORE
shopt -u dotglob extglob failglob nocaseglob nullglob
export GIT_OPTIONAL_LOCKS=0
LC_ALL=C
LANG=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
TMPDIR=/tmp
export LANG LC_ALL PATH TMPDIR

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
RUNTIME_ROOT="$ROOT/runtime/metal12"
BUILD="$RUNTIME_ROOT/build"
OUTPUT=
PINNED_BASE_COMMIT=21136e49b9909349800e2b355076a3c8023a617e
BASE=$PINNED_BASE_COMMIT
SESSION_EXPORT=
SESSION_EXPORT_SHA256=
OPENPGP_KEY=
SSH_KEY=
SSH_KEY_SHA256=
SSH_PUBLIC_KEY=
SIGNED_TAG=
ALLOW_UNSIGNED_STAGING=0
BASE_SET=0
GIT_PATH=
GPG_PATH=
SSH_KEYGEN_PATH=

usage() {
  cat <<'EOF'
Usage:
  runtime/metal12/capture-evidence.sh --output ABSOLUTE_DIR [options]

Required for a complete capture:
  --output DIR              New directory outside the repository
  --session-export FILE     Explicit private export of the AI session
  --signed-tag TAG          Exact annotated tag name bound directly to HEAD
  --openpgp-key FINGERPRINT OpenPGP key used to sign SHA256SUMS
    or
  --ssh-key FILE            SSH private key used to sign SHA256SUMS

Options:
  --base COMMIT             Compatibility spelling for the pinned task base;
                            alternate bases are rejected
  --allow-unsigned-staging  Capture an explicitly incomplete local staging
                            snapshot and exit 3
  -h, --help                Show this help

The output is private, internal evidence. It is not a distributable release.
After capture, preserve the directory in durable private storage and retain an
external timestamp receipt for the signed SHA256SUMS file.
EOF
}

die() {
  printf 'evidence capture: %s\n' "$*" >&2
  exit 1
}

manifest_field() {
  local manifest=$1
  local key=$2

  awk -v key="$key" \
    'index($0, key ": ") == 1 {
        value = substr($0, length(key) + 3)
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
    "$manifest"
}

require_sha256() {
  local value=$1
  local label=$2

  ((${#value} == 64)) && [[ $value != *[!0-9a-f]* ]] ||
    die "$label is not a lowercase SHA-256"
}

sha256_file() {
  local path=$1
  local output
  local digest
  local parent
  local canonical_parent

  [[ $path == /* && -f $path && ! -L $path ]] ||
    die "cannot hash a relative, missing, nonregular, or symlinked file: $path"
  parent=${path%/*}
  [[ -n $parent ]] || parent=/
  canonical_parent=$(cd "$parent" && pwd -P) ||
    die "cannot resolve hash input parent: $path"
  [[ $canonical_parent == "$parent" ]] ||
    die "hash input has a symlinked or noncanonical parent: $path"
  output=$(
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      LC_ALL=C \
      LANG=C \
      /usr/bin/shasum -a 256 "$path"
  ) ||
    die "cannot hash $path"
  digest=${output%% *}
  require_sha256 "$digest" "SHA-256 for $path"
  printf '%s\n' "$digest"
}

sha256_stream() {
  local output
  local digest

  output=$(
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      LC_ALL=C \
      LANG=C \
      /usr/bin/shasum -a 256
  ) || die "cannot hash input stream"
  digest=${output%% *}
  require_sha256 "$digest" "SHA-256 for input stream"
  printf '%s\n' "$digest"
}

run_clean_native_tool() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    TMPDIR=/tmp \
    "$@"
}

verify_manifest_value() {
  local manifest=$1
  local key=$2
  local expected=$3
  local recorded

  recorded=$(manifest_field "$manifest" "$key") ||
    die "manifest omits or duplicates $key: $manifest"
  [[ $recorded == "$expected" ]] ||
    die "manifest has the wrong $key: $manifest"
}

canonical_executable_path() {
  local input=$1
  local label=$2
  local candidate=$input
  local target
  local candidate_parent
  local hop_count=0

  [[ $candidate == /* ]] ||
    die "$label does not resolve to an absolute path"
  while [[ -L $candidate ]]; do
    ((hop_count += 1))
    ((hop_count <= 40)) ||
      die "$label has too many symlink hops"
    target=$(readlink "$candidate") ||
      die "cannot read $label symlink: $candidate"
    [[ -n $target &&
      $target != *$'\n'* &&
      $target != *$'\r'* ]] ||
      die "$label symlink target is empty or multiline"
    case "$target" in
      /*) candidate=$target ;;
      *) candidate="$(dirname "$candidate")/$target" ;;
    esac
    candidate_parent=$(cd "$(dirname "$candidate")" && pwd -P) ||
      die "cannot resolve $label symlink parent"
    candidate="$candidate_parent/$(basename "$candidate")"
  done
  candidate_parent=$(cd "$(dirname "$candidate")" && pwd -P) ||
    die "cannot resolve $label parent"
  candidate="$candidate_parent/$(basename "$candidate")"
  [[ -f $candidate && -x $candidate && ! -L $candidate ]] ||
    die "$label does not resolve to a regular executable"
  printf '%s\n' "$candidate"
}

git_blob_sha256() {
  local repo_path=$1
  local tree_mode

  tree_mode=$(
    git -C "$ROOT" ls-tree "$HEAD_COMMIT" -- "$repo_path" |
      awk 'NR == 1 { print $1 }'
  )
  [[ $tree_mode == 100644 || $tree_mode == 100755 ]] ||
    die "expected a regular Git blob at HEAD: $repo_path"
  git -C "$ROOT" cat-file blob "$HEAD_COMMIT:$repo_path" |
    sha256_stream
}

verify_head_file() {
  local repo_path=$1
  local worktree_path="$ROOT/$repo_path"
  local expected_sha256
  local actual_sha256

  [[ -f $worktree_path && ! -L $worktree_path ]] ||
    die "required HEAD-bound file is missing or symlinked: $repo_path"
  expected_sha256=$(git_blob_sha256 "$repo_path")
  require_sha256 "$expected_sha256" "HEAD blob hash for $repo_path"
  actual_sha256=$(sha256_file "$worktree_path")
  [[ $actual_sha256 == "$expected_sha256" ]] ||
    die "worktree file does not match captured HEAD: $repo_path"
  printf '%s\n' "$expected_sha256"
}

while (($#)); do
  case "$1" in
    --output)
      (($# >= 2)) || die "--output requires a value"
      [[ -z $OUTPUT ]] || die "--output was specified more than once"
      OUTPUT=$2
      shift 2
      ;;
    --base)
      (($# >= 2)) || die "--base requires a value"
      ((BASE_SET == 0)) || die "--base was specified more than once"
      BASE=$2
      BASE_SET=1
      shift 2
      ;;
    --session-export)
      (($# >= 2)) || die "--session-export requires a value"
      [[ -z $SESSION_EXPORT ]] ||
        die "--session-export was specified more than once"
      SESSION_EXPORT=$2
      shift 2
      ;;
    --openpgp-key)
      (($# >= 2)) || die "--openpgp-key requires a value"
      [[ -z $OPENPGP_KEY ]] ||
        die "--openpgp-key was specified more than once"
      OPENPGP_KEY=$2
      shift 2
      ;;
    --ssh-key)
      (($# >= 2)) || die "--ssh-key requires a value"
      [[ -z $SSH_KEY ]] || die "--ssh-key was specified more than once"
      SSH_KEY=$2
      shift 2
      ;;
    --signed-tag)
      (($# >= 2)) || die "--signed-tag requires a value"
      [[ -z $SIGNED_TAG ]] || die "--signed-tag was specified more than once"
      SIGNED_TAG=$2
      shift 2
      ;;
    --allow-unsigned-staging)
      ((ALLOW_UNSIGNED_STAGING == 0)) ||
        die "--allow-unsigned-staging was specified more than once"
      ALLOW_UNSIGNED_STAGING=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n $OUTPUT ]] || die "--output is required"
[[ $BASE == "$PINNED_BASE_COMMIT" ]] ||
  die "--base must equal the pinned task base: $PINNED_BASE_COMMIT"

for rejected_git_environment in \
  GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR \
  GIT_CONFIG \
  GIT_CONFIG_COUNT \
  GIT_CONFIG_GLOBAL \
  GIT_CONFIG_NOSYSTEM \
  GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_SYSTEM \
  GIT_DIR \
  GIT_EXEC_PATH \
  GIT_EXTERNAL_DIFF \
  GIT_GRAFT_FILE \
  GIT_INDEX_FILE \
  GIT_NAMESPACE \
  GIT_NO_REPLACE_OBJECTS \
  GIT_OBJECT_DIRECTORY \
  GIT_REPLACE_REF_BASE \
  GIT_SHALLOW_FILE \
  GIT_WORK_TREE; do
  if /usr/bin/printenv "$rejected_git_environment" >/dev/null 2>&1; then
    die "caller supplied forbidden Git environment: $rejected_git_environment"
  fi
done
if /usr/bin/env |
  awk -F= '$1 ~ /^GIT_CONFIG_(KEY|VALUE)_[0-9]+$/ { found = 1 }
    END { exit !found }'; then
  die "caller supplied forbidden indexed Git configuration"
fi

GIT_COMMAND=$(command -v git) || die "git is unavailable"
GIT_PATH=$(canonical_executable_path "$GIT_COMMAND" git)
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_NO_REPLACE_OBJECTS=1

git() {
  command "$GIT_PATH" \
    -c advice.graftFileDeprecated=false \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -c core.ignoreStat=false \
    "$@"
}

[[ $OUTPUT == /* ]] || die "--output must be an absolute path"
[[ ! -e $OUTPUT ]] || die "output already exists: $OUTPUT"
OUTPUT_PARENT=$(cd "$(dirname "$OUTPUT")" && pwd -P)
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
case "$OUTPUT/" in
  "$ROOT/"*) die "--output must be outside the repository" ;;
esac
COMMON_GIT_DIR=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
COMMON_GIT_DIR=$(cd "$COMMON_GIT_DIR" && pwd -P)
case "$OUTPUT/" in
  "$COMMON_GIT_DIR/"*) die "--output must be outside the Git common directory" ;;
esac
[[ $(git -C "$ROOT" rev-parse --is-shallow-repository) == false ]] ||
  die "evidence capture rejects shallow repository history"
[[ -z $(git -C "$ROOT" replace -l) ]] ||
  die "evidence capture rejects Git replacement objects"
GRAFTS_PATH=$(git -C "$ROOT" rev-parse --git-path info/grafts)
[[ ! -e $GRAFTS_PATH && ! -L $GRAFTS_PATH ]] ||
  die "evidence capture rejects Git grafts: $GRAFTS_PATH"
export GIT_GRAFT_FILE=/dev/null
export GIT_SHALLOW_FILE=/dev/null
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=advice.graftFileDeprecated
export GIT_CONFIG_VALUE_0=false
LOCAL_CONFIG_KEYS=$(
  git -C "$ROOT" config --local --name-only --list
) || die "cannot inspect repository-local Git configuration"
WORKTREE_CONFIG_ENABLED=
WORKTREE_CONFIG_STATUS=0
WORKTREE_CONFIG_ENABLED=$(
  git -C "$ROOT" config --local --bool --get extensions.worktreeConfig \
    2>/dev/null
) || WORKTREE_CONFIG_STATUS=$?
case $WORKTREE_CONFIG_STATUS:$WORKTREE_CONFIG_ENABLED in
  0:true)
    WORKTREE_CONFIG_KEYS=$(
      git -C "$ROOT" config --worktree --name-only --list
    ) || die "cannot inspect worktree-local Git configuration"
    ;;
  0:false | 1:)
    WORKTREE_CONFIG_KEYS=
    ;;
  *)
    die "cannot resolve the worktree-local Git configuration policy"
    ;;
esac
if printf '%s\n%s\n' "$LOCAL_CONFIG_KEYS" "$WORKTREE_CONFIG_KEYS" |
  LC_ALL=C grep -Eiq \
    '^(core\.usereplacerefs|gpg\.|commit\.gpgsign|tag\.gpgsign)'; then
  die "repository-local replacement or signature-verifier config is forbidden"
fi

if [[ -n $SESSION_EXPORT ]]; then
  [[ $SESSION_EXPORT == /* ]] ||
    die "--session-export must be an absolute path"
  [[ -f $SESSION_EXPORT && ! -L $SESSION_EXPORT ]] ||
    die "session export must be a regular non-symlink file"
  SESSION_EXPORT_SHA256=$(sha256_file "$SESSION_EXPORT")
  LC_ALL=C grep -aFiq 'Alloy' "$SESSION_EXPORT" ||
    die "session export does not contain the required Alloy marker"
  LC_ALL=C grep -aEiq \
    'm12[-_ ]?84|#84|issue[[:space:]#:_-]*84' "$SESSION_EXPORT" ||
    die "session export does not contain the required M12-84 task marker"
fi
if [[ -n $SSH_KEY ]]; then
  [[ $SSH_KEY == /* ]] || die "--ssh-key must be an absolute path"
  [[ -f $SSH_KEY && ! -L $SSH_KEY ]] ||
    die "SSH signing key must be a regular non-symlink file"
fi

BASE_COMMIT=$(git -C "$ROOT" rev-parse --verify "$BASE^{commit}") ||
  die "base is not a commit: $BASE"
[[ $BASE_COMMIT == "$PINNED_BASE_COMMIT" ]] ||
  die "resolved base differs from the pinned task base"
HEAD_COMMIT=$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}') ||
  die "HEAD is not a commit"
HEAD_TREE=$(git -C "$ROOT" rev-parse "$HEAD_COMMIT^{tree}")
MERGE_BASE=$(git -C "$ROOT" merge-base "$BASE_COMMIT" "$HEAD_COMMIT") ||
  die "cannot resolve merge base"
[[ $MERGE_BASE == "$BASE_COMMIT" ]] ||
  die "$BASE is not an ancestor of the captured HEAD"
WORKTREE_STATUS=$(
  git -C "$ROOT" status --porcelain=v1 --untracked-files=normal
) || die "cannot inspect worktree status"
[[ -z $WORKTREE_STATUS ]] ||
  die "tracked or nonignored untracked changes must be committed before capture"
git -C "$ROOT" ls-files --error-unmatch \
  runtime/metal12/capture-evidence.sh >/dev/null ||
  die "capture-evidence.sh is not tracked"
CAPTURE_SCRIPT_BLOB=$(
  git -C "$ROOT" hash-object --no-filters \
    "$ROOT/runtime/metal12/capture-evidence.sh"
)
HEAD_CAPTURE_SCRIPT_BLOB=$(
  git -C "$ROOT" rev-parse \
    "$HEAD_COMMIT:runtime/metal12/capture-evidence.sh"
)
[[ $CAPTURE_SCRIPT_BLOB == "$HEAD_CAPTURE_SCRIPT_BLOB" ]] ||
  die "capture-evidence.sh does not match the captured HEAD"

validate_changed_path() {
  local changed_path=$1
  [[ -n $changed_path ]] || return 0
  case "$changed_path" in
    runtime/metal12/* | spikes/M12-00[1-6]/* | \
      docs/adr/ADR-0012-metal12-provenance-and-clean-room.md | \
      docs/CONTRIBUTING.md | PROVENANCE.log)
      ;;
    *)
      die "task range contains a path outside the evidence allowlist: $changed_path"
      ;;
  esac
}

NET_CHANGED_PATHS=$(
  git -C "$ROOT" diff --no-renames --name-only \
    "$BASE_COMMIT" "$HEAD_COMMIT"
) || die "cannot inspect task paths"
while IFS= read -r changed_path; do
  validate_changed_path "$changed_path"
done <<<"$NET_CHANGED_PATHS"

TASK_COMMITS_TEXT=$(
  git -C "$ROOT" rev-list --reverse "$BASE_COMMIT".."$HEAD_COMMIT"
) || die "cannot enumerate task commits"
TASK_COMMITS=()
while IFS= read -r commit; do
  [[ -n $commit ]] && TASK_COMMITS+=("$commit")
done <<<"$TASK_COMMITS_TEXT"

COMMIT_COUNT=0
UNSIGNED_COUNT=0
EXPECTED_PARENT=$BASE_COMMIT
for commit in "${TASK_COMMITS[@]}"; do
  ((COMMIT_COUNT += 1))
  COMMIT_PARENTS=$(git -C "$ROOT" log -1 --format=%P "$commit") ||
    die "cannot inspect commit parents: $commit"
  [[ $COMMIT_PARENTS == "$EXPECTED_PARENT" ]] ||
    die "task history must be linear from the frozen base: $commit"
  COMMIT_CHANGED_PATHS=$(
    git -C "$ROOT" diff-tree --no-commit-id --no-renames \
      --name-only -r "$EXPECTED_PARENT" "$commit"
  ) || die "cannot inspect commit paths: $commit"
  while IFS= read -r changed_path; do
    validate_changed_path "$changed_path"
  done <<<"$COMMIT_CHANGED_PATHS"
  if ! git -C "$ROOT" cat-file commit "$commit" |
    LC_ALL=C grep -E '^gpgsig(-sha256)? ' >/dev/null; then
    ((UNSIGNED_COUNT += 1))
  fi
  [[ $(git -C "$ROOT" log -1 --format=%an "$commit") == "Timur Isaev" ]] ||
    die "commit $commit has an unexpected author name"
  [[ $(git -C "$ROOT" log -1 --format=%cn "$commit") == "Timur Isaev" ]] ||
    die "commit $commit has an unexpected committer name"
  EXPECTED_PARENT=$commit
done
((COMMIT_COUNT > 0)) || die "no task commits found after $BASE"

TAG_OBJECT=
TAG_REF=
EXPECTED_SIGNER_FINGERPRINT=
FINGERPRINT_FORMAT=
GIT_SSH_ALLOWED_SIGNERS=

git_signature_command() {
  case "$SIGNATURE_KIND" in
    openpgp)
      git \
        -c gpg.format=openpgp \
        -c gpg.program="$GPG_PATH" \
        -c gpg.openpgp.program="$GPG_PATH" \
        "$@"
      ;;
    ssh)
      git \
        -c gpg.format=ssh \
        -c gpg.ssh.program="$SSH_KEYGEN_PATH" \
        -c gpg.ssh.allowedSignersFile="$GIT_SSH_ALLOWED_SIGNERS" \
        "$@"
      ;;
    *)
      die "Git signature verification requires a selected signer"
      ;;
  esac
}

tag_object_header_field() {
  local key=$1

  git -C "$ROOT" cat-file tag "$TAG_OBJECT" |
    awk -v key="$key" '
      BEGIN { in_headers = 1 }
      in_headers && $0 == "" {
        in_headers = 0
        next
      }
      in_headers && index($0, key " ") == 1 {
        value = substr($0, length(key) + 2)
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }
    '
}

verify_signed_tag_ref_binding() {
  local current_ref_object
  local tag_target_object
  local tag_target_type
  local tag_internal_name

  current_ref_object=$(
    git -C "$ROOT" show-ref --verify --hash "$TAG_REF"
  ) || die "signed tag ref disappeared: $TAG_REF"
  [[ $current_ref_object == "$TAG_OBJECT" ]] ||
    die "signed tag ref changed during capture: $TAG_REF"
  [[ $(git -C "$ROOT" cat-file -t "$TAG_OBJECT") == tag ]] ||
    die "signed tag ref does not point directly to a tag object: $TAG_REF"
  tag_target_object=$(tag_object_header_field object) ||
    die "signed tag has an invalid or duplicate object header"
  tag_target_type=$(tag_object_header_field type) ||
    die "signed tag has an invalid or duplicate type header"
  tag_internal_name=$(tag_object_header_field tag) ||
    die "signed tag has an invalid or duplicate tag header"
  [[ $tag_target_object == "$HEAD_COMMIT" ]] ||
    die "signed tag object does not point directly to captured HEAD"
  [[ $tag_target_type == commit &&
    $(git -C "$ROOT" cat-file -t "$tag_target_object") == commit ]] ||
    die "signed tag object does not declare a commit target"
  [[ $tag_internal_name == "$SIGNED_TAG" ]] ||
    die "signed tag object's internal name does not match --signed-tag"
}

if ((ALLOW_UNSIGNED_STAGING)); then
  [[ -z $OPENPGP_KEY && -z $SSH_KEY && -z $SIGNED_TAG ]] ||
    die "staging mode does not accept a signer or signed tag"
  SIGNATURE_KIND=not-provided
  VERIFIED_COMMIT_COUNT=0
  UNVERIFIED_COMMIT_COUNT=$COMMIT_COUNT
else
  ((UNSIGNED_COUNT == 0)) ||
    die "$UNSIGNED_COUNT task commit(s) are not verifiably signed"
  [[ -n $SIGNED_TAG ]] || die "--signed-tag is required"
  [[ -n $SESSION_EXPORT ]] || die "--session-export is required"
  if [[ -n $OPENPGP_KEY && -n $SSH_KEY ]]; then
    die "select exactly one manifest signer"
  fi
  [[ -n $OPENPGP_KEY || -n $SSH_KEY ]] ||
    die "--openpgp-key or --ssh-key is required"
  if [[ -n $OPENPGP_KEY ]]; then
    GPG_COMMAND=$(command -v gpg) || die "gpg is unavailable"
    GPG_PATH=$(canonical_executable_path "$GPG_COMMAND" gpg)
    [[ $OPENPGP_KEY =~ ^[[:xdigit:]]{40}([[:xdigit:]]{24})?$ ]] ||
      die "--openpgp-key must be a full fingerprint"
    "$GPG_PATH" --batch --list-secret-keys \
      "$OPENPGP_KEY" >/dev/null 2>&1 ||
      die "selected OpenPGP secret key is unavailable"
    EXPECTED_SIGNER_FINGERPRINT=$(
      "$GPG_PATH" --batch --with-colons --fingerprint "$OPENPGP_KEY" |
        awk -F: '$1 == "fpr" { print toupper($10); exit }'
    )
    NORMALIZED_OPENPGP_KEY=$(printf '%s' "$OPENPGP_KEY" | tr '[:lower:]' '[:upper:]')
    [[ $NORMALIZED_OPENPGP_KEY == "$EXPECTED_SIGNER_FINGERPRINT" ]] ||
      die "selected OpenPGP fingerprint is ambiguous"
    FINGERPRINT_FORMAT=%GP
    SIGNATURE_KIND=openpgp
  else
    SSH_KEYGEN_COMMAND=$(command -v ssh-keygen) ||
      die "ssh-keygen is unavailable"
    SSH_KEYGEN_PATH=$(
      canonical_executable_path "$SSH_KEYGEN_COMMAND" ssh-keygen
    )
    SSH_KEY_SHA256=$(sha256_file "$SSH_KEY")
    SSH_PUBLIC_KEY=$(
      "$SSH_KEYGEN_PATH" -y -f "$SSH_KEY"
    ) || die "cannot derive the selected SSH public key"
    [[ -n $SSH_PUBLIC_KEY &&
      $SSH_PUBLIC_KEY != *$'\n'* &&
      $SSH_PUBLIC_KEY != *$'\r'* ]] ||
      die "derived SSH public key is empty or multiline"
    EXPECTED_SIGNER_FINGERPRINT=$(
      printf '%s\n' "$SSH_PUBLIC_KEY" |
        "$SSH_KEYGEN_PATH" -lf - -E sha256 |
        awk '{print $2}'
    ) || die "cannot resolve SSH signing-key fingerprint"
    [[ $EXPECTED_SIGNER_FINGERPRINT == SHA256:* ]] ||
      die "SSH signing-key fingerprint is empty"
    FINGERPRINT_FORMAT=%GF
    SIGNATURE_KIND=ssh
    GIT_SSH_ALLOWED_SIGNERS=$(
      mktemp "${TMPDIR:-/tmp}/alloy-metal12-git-signers.XXXXXX"
    )
    [[ -f $GIT_SSH_ALLOWED_SIGNERS &&
      ! -L $GIT_SSH_ALLOWED_SIGNERS ]] ||
      die "cannot create the temporary SSH allowed-signers file"
    printf 'alloy-metal12-evidence %s\n' "$SSH_PUBLIC_KEY" \
      >"$GIT_SSH_ALLOWED_SIGNERS"
  fi
  [[ $SIGNED_TAG != refs/* ]] ||
    die "--signed-tag requires a bare tag name, not a refs/ path"
  TAG_REF="refs/tags/$SIGNED_TAG"
  git -C "$ROOT" check-ref-format "$TAG_REF" >/dev/null ||
    die "--signed-tag is not a valid exact tag name: $SIGNED_TAG"
  TAG_REF_OBJECT=$(
    git -C "$ROOT" show-ref --verify --hash "$TAG_REF"
  ) || die "signed tag ref does not exist: $TAG_REF"
  TAG_OBJECT=$(git -C "$ROOT" rev-parse --verify "$TAG_REF^{tag}") ||
    die "signed tag is not an annotated tag: $SIGNED_TAG"
  [[ $TAG_REF_OBJECT == "$TAG_OBJECT" ]] ||
    die "signed tag ref does not point directly to its annotated tag object"
  verify_signed_tag_ref_binding
  TAGGER_NAME=$(
    git -C "$ROOT" cat-file tag "$TAG_OBJECT" |
      awk '
        BEGIN { in_headers = 1 }
        in_headers && $0 == "" {
          in_headers = 0
          next
        }
        in_headers && /^tagger / {
          count += 1
          value = substr($0, 8)
          if (match(value, / <[^<>]*> [0-9]+ [+-][0-9]{4}$/)) {
            name = substr(value, 1, RSTART - 1)
          } else {
            invalid = 1
          }
        }
        END {
          if (count == 1 && !invalid) print name
          else exit 1
        }
      '
  ) || die "annotated tag has an invalid or duplicate tagger header"
  [[ $TAGGER_NAME == "Timur Isaev" ]] ||
    die "annotated tag has an unexpected tagger name"
  git_signature_command -C "$ROOT" \
    verify-tag "$TAG_OBJECT" >/dev/null 2>&1 ||
    die "tag signature did not verify: $SIGNED_TAG"
  [[ $(git -C "$ROOT" rev-list -n 1 "$TAG_OBJECT") == "$HEAD_COMMIT" ]] ||
    die "signed tag does not resolve to the captured HEAD: $SIGNED_TAG"
  for commit in "${TASK_COMMITS[@]}"; do
    git_signature_command -C "$ROOT" \
      verify-commit "$commit" >/dev/null 2>&1 ||
      die "commit signature did not verify: $commit"
    commit_fingerprint=$(
      git_signature_command -C "$ROOT" \
        log -1 --format="$FINGERPRINT_FORMAT" "$commit"
    )
    [[ $commit_fingerprint == "$EXPECTED_SIGNER_FINGERPRINT" ]] ||
      die "commit was signed by an unexpected key: $commit"
  done
  if [[ $SIGNATURE_KIND == ssh ]]; then
    # SSH verification above uses an allowlist containing only the selected
    # public key, so a successful verification is already key-specific.
    # verify-tag --format does not expand commit-only %GF for tag objects.
    tag_fingerprint=$EXPECTED_SIGNER_FINGERPRINT
  else
    tag_fingerprint=$(
      git_signature_command -C "$ROOT" \
        verify-tag --raw "$TAG_OBJECT" 2>&1 |
        awk '
          $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
            count += 1
            fingerprint = toupper($3)
          }
          END {
            if (count == 1) print fingerprint
            else exit 1
          }
        '
    ) || die "cannot inspect signed-tag fingerprint"
  fi
  [[ $tag_fingerprint == "$EXPECTED_SIGNER_FINGERPRINT" ]] ||
    die "tag was signed by an unexpected key: $SIGNED_TAG"
  if [[ -n $GIT_SSH_ALLOWED_SIGNERS ]]; then
    rm -f -- "$GIT_SSH_ALLOWED_SIGNERS"
    GIT_SSH_ALLOWED_SIGNERS=
  fi
  VERIFIED_COMMIT_COUNT=$COMMIT_COUNT
  UNVERIFIED_COMMIT_COUNT=0
fi

[[ -d $BUILD && ! -L $BUILD ]] ||
  die "Metal12 build output is missing or symlinked: $BUILD"
[[ $(cd "$BUILD" && pwd -P) == "$BUILD" ]] ||
  die "Metal12 build output resolves outside its fixed path"
verify_head_file runtime/metal12/evidence-lock.sh >/dev/null
verify_head_file runtime/metal12/evidence-paths.sh >/dev/null
verify_head_file runtime/metal12/compiler-runtime-identity.sh >/dev/null
# shellcheck source=runtime/metal12/evidence-lock.sh
source "$RUNTIME_ROOT/evidence-lock.sh"
# shellcheck source=runtime/metal12/evidence-paths.sh
source "$RUNTIME_ROOT/evidence-paths.sh"
# shellcheck source=runtime/metal12/compiler-runtime-identity.sh
source "$RUNTIME_ROOT/compiler-runtime-identity.sh"
am12_evidence_lock_acquire "$RUNTIME_ROOT" "$BUILD"
am12_evidence_lock_install_traps

for build_subdirectory in generated model-proofs reference shaders; do
  build_subdirectory_path="$BUILD/$build_subdirectory"
  [[ -d $build_subdirectory_path && ! -L $build_subdirectory_path ]] ||
    die "build evidence directory is missing or symlinked: $build_subdirectory"
  [[ $(cd "$build_subdirectory_path" && pwd -P) == "$build_subdirectory_path" ]] ||
    die "build evidence directory resolves outside its fixed path: $build_subdirectory"
done
RUNTIME_TREE=$(git -C "$ROOT" rev-parse "$HEAD_COMMIT:runtime/metal12")
BUILD_MANIFEST="$BUILD/BUILD-MANIFEST.txt"
[[ -s $BUILD_MANIFEST && ! -L $BUILD_MANIFEST ]] ||
  die "build manifest is missing, empty, or symlinked"
verify_manifest_value "$BUILD_MANIFEST" schema \
  com.alloy.metal12.build-manifest.v1
verify_manifest_value "$BUILD_MANIFEST" author "Timur Isaev"
verify_manifest_value "$BUILD_MANIFEST" head_commit "$HEAD_COMMIT"
verify_manifest_value "$BUILD_MANIFEST" runtime_tree "$RUNTIME_TREE"
verify_manifest_value "$BUILD_MANIFEST" runtime_worktree_clean yes
verify_manifest_value "$BUILD_MANIFEST" status complete
verify_manifest_value "$BUILD_MANIFEST" source_materialization \
  git-cat-file-frozen-head-v1
verify_manifest_value "$BUILD_MANIFEST" native_execution_environment \
  env-i-fixed-path-locale-tmp-v1
verify_manifest_value "$BUILD_MANIFEST" module_cache_policy \
  unique-ephemeral-not-published
verify_manifest_value "$BUILD_MANIFEST" static_archive_policy \
  libtool-D-normalized-metadata-v1
BUILD_MANIFEST_SHA256=$(sha256_file "$BUILD_MANIFEST")

mkdir -m 700 "$OUTPUT"
printf 'INCOMPLETE\n' >"$OUTPUT/SNAPSHOT-STATUS"
COPIED_SOURCES=()
COPIED_RELATIVES=()
COPIED_EXPECTED_SHA256=()

write_snapshot_status() {
  local status=$1
  local temporary_status
  temporary_status=$(mktemp "$OUTPUT/.SNAPSHOT-STATUS.XXXXXX")
  printf '%s\n' "$status" >"$temporary_status"
  mv -f "$temporary_status" "$OUTPUT/SNAPSHOT-STATUS"
}

copy_file() {
  local source=$1
  local relative=$2
  local expected_hash=${3:-}
  local source_hash
  local destination_hash
  [[ -s $source && ! -L $source ]] ||
    die "required evidence file is missing, empty, or not regular: $source"
  source_hash=$(sha256_file "$source")
  if [[ -n $expected_hash && $source_hash != "$expected_hash" ]]; then
    die "source does not match its frozen expected hash: $source"
  fi
  [[ -n $expected_hash ]] || expected_hash=$source_hash
  mkdir -p "$OUTPUT/$(dirname "$relative")"
  COPYFILE_DISABLE=1 cp -p "$source" "$OUTPUT/$relative"
  destination_hash=$(sha256_file "$OUTPUT/$relative")
  [[ $source_hash == "$destination_hash" ]] ||
    die "source changed while it was copied: $source"
  [[ $destination_hash == "$expected_hash" ]] ||
    die "copied evidence differs from its frozen expected hash: $source"
  COPIED_SOURCES+=("$source")
  COPIED_RELATIVES+=("$relative")
  COPIED_EXPECTED_SHA256+=("$expected_hash")
}

verify_invoked_binary() {
  local manifest=$1
  local binary_name=$2
  local binary_path=$3
  local expected_sha256
  local actual_sha256

  expected_sha256=$(
    awk -v binary="$binary_name" \
      '$1 == "invoked_binary_sha256:" && NF == 3 && $3 == binary {
        value = $2
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
      "$manifest"
  ) || die "run manifest omits or duplicates invoked binary: $binary_name"
  require_sha256 "$expected_sha256" "invoked binary hash for $binary_name"
  [[ -f $binary_path && ! -L $binary_path ]] ||
    die "invoked binary is missing or symlinked: $binary_name"
  actual_sha256=$(sha256_file "$binary_path")
  [[ $actual_sha256 == "$expected_sha256" ]] ||
    die "invoked binary does not match its run manifest: $binary_name"
}

verify_tool_identity() {
  local manifest=$1
  local path_key=$2
  local hash_key=$3
  local tool_path
  local expected_sha256
  local actual_sha256

  tool_path=$(manifest_field "$manifest" "$path_key") ||
    die "run manifest omits or duplicates $path_key: $manifest"
  expected_sha256=$(manifest_field "$manifest" "$hash_key") ||
    die "run manifest omits or duplicates $hash_key: $manifest"
  require_sha256 "$expected_sha256" "$hash_key"
  [[ $tool_path == /* && -f $tool_path && ! -L $tool_path ]] ||
    die "recorded tool is missing, relative, or symlinked: $tool_path"
  actual_sha256=$(sha256_file "$tool_path")
  [[ $actual_sha256 == "$expected_sha256" ]] ||
    die "recorded tool changed after the run: $tool_path"
}

verify_metallib_dispatch_identity() {
  local manifest=$1
  local frontend_path
  local recorded_link_target
  local resolved_path
  local link_candidate
  local canonical_link_parent
  local actual_resolved_path
  local xcrun_path
  local discovered_frontend

  verify_manifest_value "$manifest" metallib_invocation_policy \
    frozen-xcrun-sdk-dispatch-read-only-cryptex-symlink-v1
  frontend_path=$(manifest_field "$manifest" metallib_frontend_path) ||
    die "reference manifest omits or duplicates metallib_frontend_path"
  recorded_link_target=$(
    manifest_field "$manifest" metallib_frontend_link_target
  ) ||
    die "reference manifest omits or duplicates metallib_frontend_link_target"
  resolved_path=$(manifest_field "$manifest" metallib_path) ||
    die "reference manifest omits or duplicates metallib_path"
  [[ $frontend_path == /* && -L $frontend_path ]] ||
    die "recorded metallib frontend is not an absolute symlink"
  [[ -n $recorded_link_target &&
    $recorded_link_target != *$'\n'* &&
    $recorded_link_target != *$'\r'* ]] ||
    die "recorded metallib frontend link target is empty or multiline"
  [[ $(readlink "$frontend_path") == "$recorded_link_target" ]] ||
    die "metallib frontend symlink target changed after the run"

  case "$recorded_link_target" in
    /*) link_candidate=$recorded_link_target ;;
    *) link_candidate="$(dirname "$frontend_path")/$recorded_link_target" ;;
  esac
  canonical_link_parent=$(
    cd "$(dirname "$link_candidate")" && pwd -P
  ) || die "cannot resolve the metallib frontend target parent"
  actual_resolved_path="$canonical_link_parent/$(basename "$link_candidate")"
  [[ $actual_resolved_path == "$resolved_path" ]] ||
    die "metallib frontend does not resolve to the recorded canonical target"
  verify_tool_identity "$manifest" metallib_path metallib_sha256
  verify_tool_identity "$manifest" xcrun_path xcrun_sha256
  verify_tool_identity "$manifest" readlink_path readlink_sha256

  xcrun_path=$(manifest_field "$manifest" xcrun_path)
  discovered_frontend=$(
    run_clean_native_tool \
      "$xcrun_path" --sdk macosx --find metallib
  ) || die "frozen xcrun cannot rediscover the metallib frontend"
  [[ $discovered_frontend == "$frontend_path" ]] ||
    die "xcrun metallib discovery changed after the reference run"
}

verify_hash_field_path() {
  local manifest=$1
  local hash_key=$2
  local path=$3
  local expected_sha256
  local actual_sha256

  expected_sha256=$(manifest_field "$manifest" "$hash_key") ||
    die "run manifest omits or duplicates $hash_key: $manifest"
  require_sha256 "$expected_sha256" "$hash_key"
  [[ -f $path && ! -L $path ]] ||
    die "recorded input is missing or symlinked: $path"
  actual_sha256=$(sha256_file "$path")
  [[ $actual_sha256 == "$expected_sha256" ]] ||
    die "recorded input does not match $hash_key: $path"
}

manifest_named_hash() {
  local manifest=$1
  local record_key=$2
  local record_name=$3

  awk -v key="$record_key:" -v name="$record_name" \
    '$1 == key && NF == 3 && $3 == name {
      value = $2
      count += 1
    }
    END { if (count == 1) print value; else exit 1 }' \
    "$manifest"
}

verify_record_name_inventory() {
  local manifest=$1
  local record_key=$2
  local name_field=$3
  shift 3
  local expected_names
  local actual_names

  expected_names="$(
    printf '%s\n' "$@" | LC_ALL=C sort
  )"
  actual_names="$(
    awk -v key="$record_key:" -v name_field="$name_field" \
      '$1 == key {
        if (key == "case_dxc_arguments:") {
          if (name_field != 2 || NF < 3) exit 2
        } else if (name_field != 3 || NF != 3) {
          exit 2
        }
        print $name_field
      }' "$manifest" |
      LC_ALL=C sort
  )" || die "manifest has malformed $record_key records: $manifest"
  [[ $actual_names == "$expected_names" ]] ||
    die "manifest has missing, duplicate, or extra $record_key names: $manifest"
}

verify_build_manifest_identity() {
  local build_producer_sha256
  local lowerer_sha256
  local build_sdk_path
  local build_sdk_version
  local build_sdk_build_version
  local build_sdk_settings_path
  local build_xcrun_path
  local current_build_sdk_candidate
  local current_build_sdk_path
  local current_build_sdk_version
  local current_build_sdk_build_version
  local current_build_clang_path
  local current_build_ld_path

  build_producer_sha256=$(verify_head_file runtime/metal12/build.sh)
  verify_manifest_value "$BUILD_MANIFEST" \
    producer_path "$ROOT/runtime/metal12/build.sh"
  verify_manifest_value "$BUILD_MANIFEST" \
    producer_sha256 "$build_producer_sha256"
  lowerer_sha256=$(
    verify_head_file runtime/metal12/ShaderTools/dxil_to_msl.py
  )
  verify_manifest_value "$BUILD_MANIFEST" lowerer_sha256 "$lowerer_sha256"
  verify_tool_identity "$BUILD_MANIFEST" git_path git_sha256
  verify_tool_identity "$BUILD_MANIFEST" shasum_path shasum_sha256
  verify_tool_identity "$BUILD_MANIFEST" xcrun_path xcrun_sha256
  verify_tool_identity "$BUILD_MANIFEST" clang_path clang_sha256
  verify_tool_identity "$BUILD_MANIFEST" ld_path ld_sha256
  verify_tool_identity "$BUILD_MANIFEST" libtool_path libtool_sha256
  verify_tool_identity "$BUILD_MANIFEST" xxd_path xxd_sha256
  verify_tool_identity "$BUILD_MANIFEST" sed_path sed_sha256
  verify_manifest_value "$BUILD_MANIFEST" \
    static_archive_policy libtool-D-normalized-metadata-v1
  verify_manifest_value "$BUILD_MANIFEST" \
    native_toolchain_identity_scope \
    selected-executables-and-sdk-metadata-not-full-sdk-closure-v1

  build_sdk_path=$(manifest_field "$BUILD_MANIFEST" sdk_path) ||
    die "build manifest omits or duplicates sdk_path"
  [[ $build_sdk_path == /* &&
    -d $build_sdk_path &&
    ! -L $build_sdk_path &&
    $(cd "$build_sdk_path" && pwd -P) == "$build_sdk_path" ]] ||
    die "build manifest sdk_path is not a canonical existing directory"
  build_sdk_version=$(manifest_field "$BUILD_MANIFEST" sdk_version) ||
    die "build manifest omits or duplicates sdk_version"
  build_sdk_build_version=$(
    manifest_field "$BUILD_MANIFEST" sdk_build_version
  ) || die "build manifest omits or duplicates sdk_build_version"
  build_sdk_settings_path=$(
    manifest_field "$BUILD_MANIFEST" sdk_settings_path
  ) || die "build manifest omits or duplicates sdk_settings_path"
  [[ $build_sdk_settings_path == "$build_sdk_path/SDKSettings.json" ]] ||
    die "build manifest has an unexpected SDK settings path"
  verify_tool_identity \
    "$BUILD_MANIFEST" sdk_settings_path sdk_settings_sha256
  build_xcrun_path=$(manifest_field "$BUILD_MANIFEST" xcrun_path)
  current_build_sdk_candidate=$(
    run_clean_native_tool \
      "$build_xcrun_path" --sdk macosx --show-sdk-path
  ) || die "frozen build xcrun cannot rediscover the macOS SDK"
  [[ $current_build_sdk_candidate == /* &&
    -d $current_build_sdk_candidate ]] ||
    die "frozen build xcrun returned an invalid macOS SDK path"
  current_build_sdk_path=$(
    cd "$current_build_sdk_candidate" && pwd -P
  ) || die "cannot resolve the macOS SDK rediscovered by frozen xcrun"
  [[ $current_build_sdk_path == "$build_sdk_path" ]] ||
    die "xcrun macOS SDK discovery changed after the build"
  current_build_sdk_version=$(
    run_clean_native_tool \
      "$build_xcrun_path" --sdk macosx --show-sdk-version
  ) || die "frozen build xcrun cannot rediscover the SDK version"
  current_build_sdk_build_version=$(
    run_clean_native_tool \
      "$build_xcrun_path" --sdk macosx --show-sdk-build-version
  ) || die "frozen build xcrun cannot rediscover the SDK build version"
  [[ $current_build_sdk_version == "$build_sdk_version" &&
    $current_build_sdk_build_version == "$build_sdk_build_version" ]] ||
    die "xcrun SDK version changed after the build"
  current_build_clang_path=$(
    am12_evidence_resolve_canonical_executable \
      "$(run_clean_native_tool \
        "$build_xcrun_path" --sdk macosx --find clang)" clang
  ) || die "frozen build xcrun cannot rediscover clang"
  current_build_ld_path=$(
    am12_evidence_resolve_canonical_executable \
      "$(run_clean_native_tool \
        "$build_xcrun_path" --sdk macosx --find ld)" linker
  ) || die "frozen build xcrun cannot rediscover the linker"
  [[ $current_build_clang_path == "$(manifest_field "$BUILD_MANIFEST" clang_path)" &&
  $current_build_ld_path == "$(manifest_field "$BUILD_MANIFEST" ld_path)" ]] ||
    die "xcrun native-tool discovery changed after the build"
}

verify_build_manifest_identity

verify_compiler_runtime_manifest() {
  local manifest=$1

  ALLOY_WINE=$(manifest_field \
    "$manifest" compiler_runtime_wine_frontend_path) ||
    die "compiler runtime manifest omits the Wine frontend path"
  ALLOY_FEX_PREFIX=$(manifest_field \
    "$manifest" compiler_runtime_fex_runtime_root_path) ||
    die "compiler runtime manifest omits the FEX runtime root"
  ALLOY_DXC=$(manifest_field \
    "$manifest" compiler_runtime_dxc_exe_path) ||
    die "compiler runtime manifest omits the DXC path"
  DXC=$ALLOY_DXC
  export ALLOY_WINE ALLOY_FEX_PREFIX ALLOY_DXC DXC

  am12_compiler_runtime_reset
  am12_compiler_runtime_freeze ||
    die "recorded compiler runtime is unavailable or invalid"

  [[ $AM12_COMPILER_RUNTIME_IDENTITY_SCHEMA == com.alloy.metal12.compiler-runtime-identity.v2 ]] ||
    die "compiler-runtime helper has an unexpected identity schema"
  verify_manifest_value "$manifest" \
    compiler_runtime_identity_schema \
    com.alloy.metal12.compiler-runtime-identity.v2
  verify_manifest_value "$manifest" \
    compiler_runtime_identity_sha256 \
    "$AM12_COMPILER_RUNTIME_IDENTITY_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_identity_scope \
    "$AM12_COMPILER_RUNTIME_IDENTITY_SCOPE"
  verify_manifest_value "$manifest" \
    compiler_runtime_environment_policy \
    "$AM12_COMPILER_RUNTIME_ENVIRONMENT_POLICY"
  verify_manifest_value "$manifest" \
    compiler_runtime_path_policy \
    "$AM12_COMPILER_RUNTIME_PATH_POLICY"
  verify_manifest_value "$manifest" \
    compiler_runtime_lc_all_policy \
    "$AM12_COMPILER_RUNTIME_LC_ALL_POLICY"
  verify_manifest_value "$manifest" \
    compiler_runtime_lang_policy \
    "$AM12_COMPILER_RUNTIME_LANG_POLICY"
  verify_manifest_value "$manifest" \
    compiler_runtime_tmpdir_policy \
    "$AM12_COMPILER_RUNTIME_TMPDIR_POLICY"
  verify_manifest_value "$manifest" \
    compiler_runtime_dyld_fallback_library_policy \
    "$AM12_COMPILER_RUNTIME_DYLD_FALLBACK_LIBRARY_POLICY"
  verify_manifest_value "$manifest" \
    compiler_runtime_prefix_policy \
    "$AM12_COMPILER_RUNTIME_PREFIX_POLICY"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxc_bundle_identity_schema \
    "$AM12_DXC_BUNDLE_IDENTITY_SCHEMA"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxc_bundle_identity_sha256 \
    "$AM12_DXC_BUNDLE_IDENTITY_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxc_exe_path "$AM12_DXC_EXE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxc_exe_sha256 "$AM12_DXC_EXE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxcompiler_dll_path "$AM12_DXCOMPILER_DLL_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxcompiler_dll_sha256 "$AM12_DXCOMPILER_DLL_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxil_dll_path "$AM12_DXIL_DLL_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_dxil_dll_sha256 "$AM12_DXIL_DLL_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_frontend_path "$AM12_WINE_FRONTEND_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_frontend_sha256 "$AM12_WINE_FRONTEND_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_build_root "$AM12_WINE_BUILD_ROOT"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ntdll_unix_path "$AM12_WINE_NTDLL_UNIX_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ntdll_unix_sha256 \
    "$AM12_WINE_NTDLL_UNIX_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ntdll_pe_path "$AM12_WINE_NTDLL_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ntdll_pe_sha256 "$AM12_WINE_NTDLL_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_wow64_pe_path "$AM12_WINE_WOW64_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_wow64_pe_sha256 "$AM12_WINE_WOW64_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_advapi32_pe_path \
    "$AM12_WINE_ADVAPI32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_advapi32_pe_sha256 \
    "$AM12_WINE_ADVAPI32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_kernel32_pe_path \
    "$AM12_WINE_KERNEL32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_kernel32_pe_sha256 \
    "$AM12_WINE_KERNEL32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_kernelbase_pe_path \
    "$AM12_WINE_KERNELBASE_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_kernelbase_pe_sha256 \
    "$AM12_WINE_KERNELBASE_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_oleaut32_pe_path \
    "$AM12_WINE_OLEAUT32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_oleaut32_pe_sha256 \
    "$AM12_WINE_OLEAUT32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ole32_pe_path \
    "$AM12_WINE_OLE32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ole32_pe_sha256 \
    "$AM12_WINE_OLE32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_version_pe_path \
    "$AM12_WINE_VERSION_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_version_pe_sha256 \
    "$AM12_WINE_VERSION_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ucrtbase_pe_path \
    "$AM12_WINE_UCRTBASE_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_ucrtbase_pe_sha256 \
    "$AM12_WINE_UCRTBASE_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wineserver_path "$AM12_WINESERVER_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wineserver_sha256 "$AM12_WINESERVER_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_build_fex_pe_path \
    "$AM12_WINE_BUILD_FEX_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_build_fex_pe_sha256 \
    "$AM12_WINE_BUILD_FEX_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_fex_unix_bridge_path \
    "$AM12_WINE_FEX_UNIX_BRIDGE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_fex_unix_bridge_sha256 \
    "$AM12_WINE_FEX_UNIX_BRIDGE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_runtime_root_path "$AM12_FEX_RUNTIME_ROOT_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_path "$AM12_WINE_PREFIX_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_template_path \
    "$AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_system_reg_path "$AM12_FEX_SYSTEM_REG_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_system_reg_sha256 "$AM12_FEX_SYSTEM_REG_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_user_reg_path "$AM12_FEX_USER_REG_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_user_reg_sha256 "$AM12_FEX_USER_REG_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_userdef_reg_path "$AM12_FEX_USERDEF_REG_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_userdef_reg_sha256 "$AM12_FEX_USERDEF_REG_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_selector "$AM12_FEX_SELECTOR"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_c_drive_link_path \
    "$AM12_WINE_PREFIX_C_DRIVE_LINK_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_c_drive_link_target \
    "$AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_c_drive_path \
    "$AM12_WINE_PREFIX_C_DRIVE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_z_drive_link_path \
    "$AM12_WINE_PREFIX_Z_DRIVE_LINK_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_z_drive_link_target \
    "$AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_z_drive_path \
    "$AM12_WINE_PREFIX_Z_DRIVE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_ntdll_pe_path \
    "$AM12_WINE_PREFIX_NTDLL_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_ntdll_pe_sha256 \
    "$AM12_WINE_PREFIX_NTDLL_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_wow64_pe_path \
    "$AM12_WINE_PREFIX_WOW64_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_wow64_pe_sha256 \
    "$AM12_WINE_PREFIX_WOW64_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_advapi32_pe_path \
    "$AM12_WINE_PREFIX_ADVAPI32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_advapi32_pe_sha256 \
    "$AM12_WINE_PREFIX_ADVAPI32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_kernel32_pe_path \
    "$AM12_WINE_PREFIX_KERNEL32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_kernel32_pe_sha256 \
    "$AM12_WINE_PREFIX_KERNEL32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_kernelbase_pe_path \
    "$AM12_WINE_PREFIX_KERNELBASE_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_kernelbase_pe_sha256 \
    "$AM12_WINE_PREFIX_KERNELBASE_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_oleaut32_pe_path \
    "$AM12_WINE_PREFIX_OLEAUT32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_oleaut32_pe_sha256 \
    "$AM12_WINE_PREFIX_OLEAUT32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_ole32_pe_path \
    "$AM12_WINE_PREFIX_OLE32_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_ole32_pe_sha256 \
    "$AM12_WINE_PREFIX_OLE32_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_version_pe_path \
    "$AM12_WINE_PREFIX_VERSION_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_version_pe_sha256 \
    "$AM12_WINE_PREFIX_VERSION_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_ucrtbase_pe_path \
    "$AM12_WINE_PREFIX_UCRTBASE_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_ucrtbase_pe_sha256 \
    "$AM12_WINE_PREFIX_UCRTBASE_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_libarm64ecfex_pe_path \
    "$AM12_WINE_PREFIX_LIBARM64ECFEX_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_libarm64ecfex_pe_sha256 \
    "$AM12_WINE_PREFIX_LIBARM64ECFEX_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_xtajit64_pe_path \
    "$AM12_WINE_PREFIX_XTAJIT64_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_prefix_xtajit64_pe_sha256 \
    "$AM12_WINE_PREFIX_XTAJIT64_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_prefix_pe_path "$AM12_FEX_PREFIX_PE_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_prefix_pe_sha256 "$AM12_FEX_PREFIX_PE_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_prefix_xtajit64_path \
    "$AM12_FEX_PREFIX_XTAJIT64_PATH"
  verify_manifest_value "$manifest" \
    compiler_runtime_fex_prefix_xtajit64_sha256 \
    "$AM12_FEX_PREFIX_XTAJIT64_SHA256"
  verify_manifest_value "$manifest" \
    compiler_runtime_wine_dll_overrides "$AM12_WINE_DLL_OVERRIDES"
  verify_manifest_value "$manifest" \
    wine_prefix_materialization apfs-clone-of-frozen-template
  verify_manifest_value "$manifest" \
    wine_prefix_system_reg_initial_sha256 "$AM12_FEX_SYSTEM_REG_SHA256"
  verify_manifest_value "$manifest" \
    wine_prefix_selected_file_validation \
    initial-registries-and-selected-dlls-plus-mappings-v1
  verify_manifest_value "$manifest" \
    wine_server_cleanup_policy \
    frozen-wineserver-kill-wait-before-stage-delete
}

verify_run_manifest() {
  local manifest=$1
  local schema=$2
  local producer=$3
  local producer_relative
  local current_producer_sha256
  local recorded_build_manifest_sha256
  local expected_producer_sha256
  local recorded_producer_sha256

  [[ -s $manifest && ! -L $manifest ]] ||
    die "run manifest is missing, empty, or symlinked: $manifest"
  [[ $(manifest_field "$manifest" schema) == "$schema" ]] ||
    die "run manifest has the wrong schema: $manifest"
  [[ $(manifest_field "$manifest" author) == "Timur Isaev" ]] ||
    die "run manifest has the wrong author: $manifest"
  [[ $(manifest_field "$manifest" head_commit) == "$HEAD_COMMIT" ]] ||
    die "run manifest is not bound to the captured HEAD: $manifest"
  [[ $(manifest_field "$manifest" runtime_tree) == "$RUNTIME_TREE" ]] ||
    die "run manifest is not bound to the captured runtime tree: $manifest"
  recorded_build_manifest_sha256=$(
    manifest_field "$manifest" build_manifest_sha256
  )
  require_sha256 "$recorded_build_manifest_sha256" \
    "build-manifest hash in $manifest"
  [[ $recorded_build_manifest_sha256 == "$BUILD_MANIFEST_SHA256" ]] ||
    die "run manifest is not bound to the current build manifest: $manifest"
  case "$producer" in
    "$ROOT"/*) producer_relative=${producer#"$ROOT/"} ;;
    *) die "run-manifest producer is outside the repository: $producer" ;;
  esac
  expected_producer_sha256=$(verify_head_file "$producer_relative")
  current_producer_sha256=$(sha256_file "$producer")
  [[ $current_producer_sha256 == "$expected_producer_sha256" ]] ||
    die "run-manifest producer does not match captured HEAD: $producer"
  recorded_producer_sha256=$(manifest_field "$manifest" producer_sha256)
  require_sha256 "$recorded_producer_sha256" \
    "producer hash in $manifest"
  [[ $recorded_producer_sha256 == "$expected_producer_sha256" ]] ||
    die "run manifest has the wrong producer hash: $manifest"
}

verify_run_artifact() {
  local manifest=$1
  local relative=$2
  local source=$3
  local expected_artifact_hash
  local actual_artifact_hash

  expected_artifact_hash=$(
    awk -v artifact="$relative" \
      '$1 == "artifact_sha256:" && NF == 3 && $3 == artifact {
        value = $2
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
      "$manifest"
  ) || die "run manifest omits or duplicates artifact: $relative"
  require_sha256 "$expected_artifact_hash" "artifact hash for $relative"
  actual_artifact_hash=$(sha256_file "$source")
  [[ $actual_artifact_hash == "$expected_artifact_hash" ]] ||
    die "run artifact does not match its manifest: $relative"
  printf '%s\n' "$expected_artifact_hash"
}

copy_run_artifact() {
  local manifest=$1
  local record_relative=$2
  local source=$3
  local snapshot_relative=$4
  local expected_artifact_hash

  expected_artifact_hash=$(
    verify_run_artifact "$manifest" "$record_relative" "$source"
  )
  copy_file "$source" "$snapshot_relative" "$expected_artifact_hash"
}

SOURCE_PATHS=(
  PROVENANCE.log
  docs/CONTRIBUTING.md
  docs/adr/ADR-0012-metal12-provenance-and-clean-room.md
  runtime/content-store
  runtime/metal12
  spikes/M12-001
  spikes/M12-002
  spikes/M12-003
  spikes/M12-004
  spikes/M12-005
  spikes/M12-006
  third_party/MANIFEST.toml
  third_party/deps.lock
)
for source_path in "${SOURCE_PATHS[@]}"; do
  git -C "$ROOT" cat-file -e "$HEAD_COMMIT:$source_path" ||
    die "approved source path is not tracked at HEAD: $source_path"
done

SHORT_COMMIT=${HEAD_COMMIT:0:12}

mkdir -p "$OUTPUT/source" "$OUTPUT/metadata/commits"
SOURCE_MATERIALIZATION="$OUTPUT/.source-materialization"
SOURCE_ARCHIVE_ROOT="$SOURCE_MATERIALIZATION/alloy-metal12-$SHORT_COMMIT"
mkdir -m 700 "$SOURCE_MATERIALIZATION" "$SOURCE_ARCHIVE_ROOT"
for source_path in "${SOURCE_PATHS[@]}"; do
  am12_evidence_materialize_tracked_tree \
    "$GIT_PATH" "$ROOT" "$HEAD_COMMIT" "$source_path" \
    "$SOURCE_ARCHIVE_ROOT"
done
SOURCE_ARCHIVE="$OUTPUT/source/alloy-metal12-$SHORT_COMMIT.tar.gz"
SOURCE_ARCHIVE_STAGING=$(mktemp "$OUTPUT/.source-archive.XXXXXX")
/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LC_ALL=C \
  LANG=C \
  /usr/bin/tar -cf - \
  -C "$SOURCE_MATERIALIZATION" "alloy-metal12-$SHORT_COMMIT" |
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    /usr/bin/gzip -n \
    >"$SOURCE_ARCHIVE_STAGING"
chmod 400 "$SOURCE_ARCHIVE_STAGING"
SOURCE_ARCHIVE_SHA256=$(sha256_file "$SOURCE_ARCHIVE_STAGING")
SOURCE_VERIFICATION="$OUTPUT/.source-verification"
SOURCE_EXPECTED_INVENTORY="$OUTPUT/.source-expected-inventory"
SOURCE_ACTUAL_INVENTORY="$OUTPUT/.source-actual-inventory"
SOURCE_TOPLEVEL_INVENTORY="$OUTPUT/.source-toplevel-inventory"
mkdir -m 700 "$SOURCE_VERIFICATION"
/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LC_ALL=C \
  LANG=C \
  /usr/bin/tar -xzpf "$SOURCE_ARCHIVE_STAGING" -C "$SOURCE_VERIFICATION"
SOURCE_VERIFIED_ROOT="$SOURCE_VERIFICATION/alloy-metal12-$SHORT_COMMIT"
[[ -d $SOURCE_VERIFIED_ROOT && ! -L $SOURCE_VERIFIED_ROOT ]] ||
  die "source archive did not reproduce its fixed root directory"
(
  cd "$SOURCE_VERIFICATION"
  find . -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort
) >"$SOURCE_TOPLEVEL_INVENTORY"
[[ $(wc -l <"$SOURCE_TOPLEVEL_INVENTORY" | tr -d ' ') == 1 &&
$(<"$SOURCE_TOPLEVEL_INVENTORY") == "./alloy-metal12-$SHORT_COMMIT" ]] ||
  die "source archive reproduced an unexpected top-level entry"
[[ -z $(
  find "$SOURCE_VERIFICATION" -mindepth 1 ! -type d ! -type f -print -quit
) ]] || die "source archive reproduced a symlink or special file"
(
  cd "$SOURCE_ARCHIVE_ROOT"
  find . -mindepth 1 -print | LC_ALL=C sort
) >"$SOURCE_EXPECTED_INVENTORY"
(
  cd "$SOURCE_VERIFIED_ROOT"
  find . -mindepth 1 -print | LC_ALL=C sort
) >"$SOURCE_ACTUAL_INVENTORY"
cmp "$SOURCE_EXPECTED_INVENTORY" "$SOURCE_ACTUAL_INVENTORY" >/dev/null ||
  die "source archive inventory differs from materialized HEAD"
while IFS= read -r source_archive_relative; do
  source_expected_path="$SOURCE_ARCHIVE_ROOT/$source_archive_relative"
  source_actual_path="$SOURCE_VERIFIED_ROOT/$source_archive_relative"
  if [[ -f $source_expected_path ]]; then
    cmp "$source_expected_path" "$source_actual_path" >/dev/null ||
      die "source archive bytes differ from HEAD: $source_archive_relative"
    [[ $(/usr/bin/stat -f '%Lp' "$source_expected_path") == "$(/usr/bin/stat -f '%Lp' "$source_actual_path")" ]] ||
      die "source archive mode differs from HEAD: $source_archive_relative"
  fi
done <"$SOURCE_EXPECTED_INVENTORY"
[[ $(sha256_file "$SOURCE_ARCHIVE_STAGING") == "$SOURCE_ARCHIVE_SHA256" ]] ||
  die "source archive changed during round-trip verification"
mv "$SOURCE_ARCHIVE_STAGING" "$SOURCE_ARCHIVE"
[[ $(sha256_file "$SOURCE_ARCHIVE") == "$SOURCE_ARCHIVE_SHA256" ]] ||
  die "source archive changed during atomic publication"
find "$SOURCE_MATERIALIZATION" -depth -delete
find "$SOURCE_VERIFICATION" -depth -delete
rm -f \
  "$SOURCE_EXPECTED_INVENTORY" \
  "$SOURCE_ACTUAL_INVENTORY" \
  "$SOURCE_TOPLEVEL_INVENTORY"
git -C "$ROOT" format-patch --stdout --binary --no-signature \
  "$BASE_COMMIT".."$HEAD_COMMIT" >"$OUTPUT/source/task-commits.patch"
TASK_PATCH_SHA256=$(sha256_file "$OUTPUT/source/task-commits.patch")
git -C "$ROOT" diff --check "$BASE_COMMIT".."$HEAD_COMMIT"
: >"$OUTPUT/metadata/commit-list.txt"
for commit in "${TASK_COMMITS[@]}"; do
  if ((ALLOW_UNSIGNED_STAGING)); then
    if git -C "$ROOT" cat-file commit "$commit" |
      LC_ALL=C grep -E '^gpgsig(-sha256)? ' >/dev/null; then
      COMMIT_EVIDENCE_SIGNATURE_STATUS=present-unverified
    else
      COMMIT_EVIDENCE_SIGNATURE_STATUS=missing
    fi
  else
    COMMIT_EVIDENCE_SIGNATURE_STATUS=verified-selected-fingerprint
  fi
  COMMIT_EVIDENCE_LINE=$(
    git -C "$ROOT" log -1 \
      --format='%H %an <%ae> %cn <%ce> %aI %cI %s' "$commit"
  )
  printf '%s signature=%s\n' \
    "$COMMIT_EVIDENCE_LINE" "$COMMIT_EVIDENCE_SIGNATURE_STATUS" \
    >>"$OUTPUT/metadata/commit-list.txt"
  git -C "$ROOT" cat-file commit "$commit" \
    >"$OUTPUT/metadata/commits/$commit.commit"
done
if [[ -n $TAG_OBJECT ]]; then
  git -C "$ROOT" cat-file tag "$TAG_OBJECT" \
    >"$OUTPUT/metadata/signed-tag-object.txt"
fi

REQUIRED_BUILD_FILES=(
  BUILD-MANIFEST.txt
  ShaderRunner
  barrier_tracker_test
  command_validation_test
  descriptor_heap_test
  libAlloyMetal12.a
  lowering_api_test
  metal12_lower
  metal12_replay
  residency_safe_test
  residency_test
  trace_validation_test
  vertical_slice
)
EXPECTED_BUILD_ARTIFACT_RECORDS=(
  "${REQUIRED_BUILD_FILES[@]:1}"
  generated/AM12EmbeddedLowerer.inc
)
verify_record_name_inventory "$BUILD_MANIFEST" artifact_sha256 3 \
  "${EXPECTED_BUILD_ARTIFACT_RECORDS[@]}"

verify_build_manifest_artifact() {
  local build_file=$1
  local expected_artifact_hash
  local actual_artifact_hash
  expected_artifact_hash=$(
    awk -v artifact="$build_file" \
      '$1 == "artifact_sha256:" && NF == 3 && $3 == artifact {
        value = $2
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
      "$BUILD_MANIFEST"
  ) || die "build manifest omits or duplicates artifact: $build_file"
  require_sha256 "$expected_artifact_hash" \
    "build artifact hash for $build_file"
  actual_artifact_hash=$(sha256_file "$BUILD/$build_file")
  [[ $actual_artifact_hash == "$expected_artifact_hash" ]] ||
    die "build artifact does not match its manifest: $build_file"
  printf '%s\n' "$expected_artifact_hash"
}

copy_file "$BUILD_MANIFEST" "build/BUILD-MANIFEST.txt" \
  "$BUILD_MANIFEST_SHA256"
for build_file in "${REQUIRED_BUILD_FILES[@]:1}"; do
  expected_build_artifact_sha256=$(
    verify_build_manifest_artifact "$build_file"
  )
  copy_file "$BUILD/$build_file" "build/$build_file" \
    "$expected_build_artifact_sha256"
done

MODEL_MANIFEST="$BUILD/model-proofs/RUN-MANIFEST.txt"
MODEL_MANIFEST_SHA256=$(sha256_file "$MODEL_MANIFEST")
verify_run_manifest "$MODEL_MANIFEST" \
  com.alloy.metal12.model-proofs.v1 "$ROOT/runtime/metal12/run-model-proofs.sh"
MODEL_STATUS=$(manifest_field "$MODEL_MANIFEST" status)
MODEL_RESIDENCY_MODE=$(manifest_field "$MODEL_MANIFEST" residency_mode)
case "$MODEL_STATUS:$MODEL_RESIDENCY_MODE" in
  incomplete-pressure-not-run:none)
    MODEL_ARTIFACTS=(descriptor-heap.log barrier-tracker.log)
    MODEL_INVOKED_BINARIES=(descriptor_heap_test barrier_tracker_test)
    ;;
  incomplete-pressure-not-run:safe)
    MODEL_ARTIFACTS=(
      descriptor-heap.log
      barrier-tracker.log
      residency-safe.log
    )
    MODEL_INVOKED_BINARIES=(
      descriptor_heap_test
      barrier_tracker_test
      residency_safe_test
    )
    ;;
  complete-pressure-pass:pressure)
    MODEL_ARTIFACTS=(
      descriptor-heap.log
      barrier-tracker.log
      residency-pressure.log
    )
    MODEL_INVOKED_BINARIES=(
      descriptor_heap_test
      barrier_tracker_test
      residency_test
    )
    ;;
  *)
    die "model-proof manifest has an invalid status/mode pair"
    ;;
esac
EXPECTED_MODEL_ARTIFACT_RECORDS=()
for model_artifact in "${MODEL_ARTIFACTS[@]}"; do
  EXPECTED_MODEL_ARTIFACT_RECORDS+=("model-proofs/$model_artifact")
done
verify_record_name_inventory "$MODEL_MANIFEST" invoked_binary_sha256 3 \
  "${MODEL_INVOKED_BINARIES[@]}"
verify_record_name_inventory "$MODEL_MANIFEST" artifact_sha256 3 \
  "${EXPECTED_MODEL_ARTIFACT_RECORDS[@]}"
for model_binary in "${MODEL_INVOKED_BINARIES[@]}"; do
  verify_invoked_binary "$MODEL_MANIFEST" \
    "$model_binary" "$BUILD/$model_binary"
done
if ((ALLOW_UNSIGNED_STAGING == 0)) &&
  [[ $MODEL_STATUS != complete-pressure-pass ]]; then
  die "complete capture requires the residency-pressure proof"
fi
verify_manifest_value "$MODEL_MANIFEST" native_execution_environment \
  env-i-fixed-path-locale-tmp-v1
copy_file "$MODEL_MANIFEST" "build/model-proofs/RUN-MANIFEST.txt" \
  "$MODEL_MANIFEST_SHA256"
for model_artifact in "${MODEL_ARTIFACTS[@]}"; do
  copy_run_artifact "$MODEL_MANIFEST" \
    "model-proofs/$model_artifact" \
    "$BUILD/model-proofs/$model_artifact" \
    "build/model-proofs/$model_artifact"
done

expected_embedded_lowerer_sha256=$(
  verify_build_manifest_artifact generated/AM12EmbeddedLowerer.inc
)
copy_file "$BUILD/generated/AM12EmbeddedLowerer.inc" \
  "build/generated/AM12EmbeddedLowerer.inc" \
  "$expected_embedded_lowerer_sha256"

REFERENCE_MANIFEST="$BUILD/reference/RUN-MANIFEST.txt"
REFERENCE_MANIFEST_SHA256=$(sha256_file "$REFERENCE_MANIFEST")
verify_run_manifest "$REFERENCE_MANIFEST" \
  com.alloy.metal12.reference-trace.v2 \
  "$ROOT/runtime/metal12/run-reference-trace.sh"
[[ $(manifest_field "$REFERENCE_MANIFEST" status) == complete-presented ]] ||
  die "reference-trace evidence does not include presentation"
verify_manifest_value "$REFERENCE_MANIFEST" dxc_compile_mode fresh
verify_manifest_value "$REFERENCE_MANIFEST" dxc_compile_invocations 2
verify_manifest_value "$REFERENCE_MANIFEST" dxc_cache_hits 0
verify_manifest_value "$REFERENCE_MANIFEST" dxc_execution_materialization \
  private-validated-copy-of-frozen-bundle-v1
verify_manifest_value "$REFERENCE_MANIFEST" \
  compiler_runtime_selected_file_recheck \
  immediately-before-and-after-each-dxc-v1
verify_manifest_value "$REFERENCE_MANIFEST" source_materialization \
  git-cat-file-frozen-head-v1
verify_manifest_value "$REFERENCE_MANIFEST" native_execution_environment \
  env-i-fixed-path-locale-tmp-v1
verify_manifest_value "$REFERENCE_MANIFEST" python_isolation \
  isolated-mode-minus-I
verify_manifest_value "$REFERENCE_MANIFEST" module_cache_policy \
  unique-ephemeral-not-published
verify_compiler_runtime_manifest "$REFERENCE_MANIFEST"
verify_tool_identity "$REFERENCE_MANIFEST" python_path python_sha256
verify_tool_identity "$REFERENCE_MANIFEST" metal_path metal_sha256
verify_metallib_dispatch_identity "$REFERENCE_MANIFEST"
REFERENCE_INVOKED_BINARIES=(
  lowering_api_test
  metal12_lower
  command_validation_test
  vertical_slice
  trace_validation_test
  metal12_replay
)
verify_record_name_inventory "$REFERENCE_MANIFEST" invoked_binary_sha256 3 \
  "${REFERENCE_INVOKED_BINARIES[@]}"
for reference_binary in "${REFERENCE_INVOKED_BINARIES[@]}"; do
  verify_invoked_binary "$REFERENCE_MANIFEST" \
    "$reference_binary" "$BUILD/$reference_binary"
done

REFERENCE_HLSL_PATH=runtime/metal12/Tests/Fixtures/reference_scene.hlsl
REFERENCE_COMPARATOR_PATH=runtime/metal12/Tests/compare_reference.py
REFERENCE_ANSWER_KEY_PATH=spikes/M12-005/results/2026-07-25-gptk4-reference.png
verify_manifest_value "$REFERENCE_MANIFEST" \
  hlsl_git_path "$REFERENCE_HLSL_PATH"
verify_manifest_value "$REFERENCE_MANIFEST" \
  comparator_git_path "$REFERENCE_COMPARATOR_PATH"
verify_manifest_value "$REFERENCE_MANIFEST" \
  answer_key_git_path "$REFERENCE_ANSWER_KEY_PATH"
REFERENCE_HLSL_SHA256=$(git_blob_sha256 "$REFERENCE_HLSL_PATH")
REFERENCE_COMPARATOR_SHA256=$(git_blob_sha256 "$REFERENCE_COMPARATOR_PATH")
REFERENCE_ANSWER_KEY_SHA256=$(git_blob_sha256 "$REFERENCE_ANSWER_KEY_PATH")
require_sha256 "$REFERENCE_HLSL_SHA256" "reference HLSL Git-blob hash"
require_sha256 "$REFERENCE_COMPARATOR_SHA256" \
  "reference comparator Git-blob hash"
require_sha256 "$REFERENCE_ANSWER_KEY_SHA256" \
  "reference answer-key Git-blob hash"
verify_manifest_value "$REFERENCE_MANIFEST" \
  hlsl_sha256 "$REFERENCE_HLSL_SHA256"
verify_manifest_value "$REFERENCE_MANIFEST" \
  comparator_sha256 "$REFERENCE_COMPARATOR_SHA256"
verify_manifest_value "$REFERENCE_MANIFEST" \
  answer_key_sha256 "$REFERENCE_ANSWER_KEY_SHA256"
[[ $(sha256_file "$BUILD/reference/inputs/reference_scene.hlsl") == "$REFERENCE_HLSL_SHA256" ]] ||
  die "run-local reference HLSL differs from the frozen Git blob"
[[ $(sha256_file "$BUILD/reference/inputs/compare_reference.py") == "$REFERENCE_COMPARATOR_SHA256" ]] ||
  die "run-local comparator differs from the frozen Git blob"
[[ $(sha256_file "$BUILD/reference/inputs/gptk4-reference.png") == "$REFERENCE_ANSWER_KEY_SHA256" ]] ||
  die "run-local answer key differs from the frozen Git blob"

EXPECTED_REFERENCE_COMPILE_KEY="$(
  {
    printf '%s\0' \
      'alloy-metal12-reference-fresh-compile.v3' \
      'hlsl-sha256' "$REFERENCE_HLSL_SHA256" \
      'compiler-runtime-identity-sha256' \
      "$AM12_COMPILER_RUNTIME_IDENTITY_SHA256"
    printf '%s\0' \
      'vs-dxc-args' -T vs_6_0 -E vs_main -Fo reference/vs.dxil \
      -Fc reference/vs.ll \
      inputs/reference_scene.hlsl
    printf '%s\0' \
      'ps-dxc-args' -T ps_6_0 -E ps_main -Fo reference/ps.dxil \
      -Fc reference/ps.ll \
      inputs/reference_scene.hlsl
  } | sha256_stream
)"
verify_manifest_value "$REFERENCE_MANIFEST" \
  reference_compile_key "$EXPECTED_REFERENCE_COMPILE_KEY"
[[ -s $BUILD/reference/reference-shaders.compile-key &&
  ! -L $BUILD/reference/reference-shaders.compile-key &&
  $(<"$BUILD/reference/reference-shaders.compile-key") == "$EXPECTED_REFERENCE_COMPILE_KEY" ]] ||
  die "reference compile-key artifact does not match frozen inputs"
for comparison_line in \
  'size: 640x360 (230400 pixels)' \
  'baseline fnv1a64: 825861ee12085256' \
  'slice    fnv1a64: 44709706809f28e9' \
  'identical pixels: 228971/230400 (99.380%)' \
  'maximum channel delta: 1' \
  'comparison gate: PASS'; do
  grep -Fqx "$comparison_line" "$BUILD/reference/gptk-compare.log" ||
    die "reference comparison log omits: $comparison_line"
done
copy_file "$REFERENCE_MANIFEST" "build/reference/RUN-MANIFEST.txt" \
  "$REFERENCE_MANIFEST_SHA256"

REFERENCE_ARTIFACTS=(
  capture-a.bmp
  capture-a.log
  capture-b.bmp
  capture-b.log
  command-validation.log
  dxc-stderr.log
  gptk-compare.log
  inputs/compare_reference.py
  inputs/gptk4-reference.png
  inputs/reference_scene.hlsl
  live.bmp
  live.log
  presented.bmp
  presented.log
  ps.air
  ps.dxil
  ps.ll
  ps.metal
  ps.provenance.json
  reference-a.am12
  reference-b.am12
  reference-shaders.compile-key
  replay.bmp
  replay.log
  scene.metallib
  trace-validation.log
  vs.air
  vs.dxil
  vs.ll
  vs.metal
  vs.provenance.json
)
EXPECTED_REFERENCE_ARTIFACT_RECORDS=()
for reference_artifact in "${REFERENCE_ARTIFACTS[@]}"; do
  EXPECTED_REFERENCE_ARTIFACT_RECORDS+=("reference/$reference_artifact")
done
verify_record_name_inventory "$REFERENCE_MANIFEST" artifact_sha256 3 \
  "${EXPECTED_REFERENCE_ARTIFACT_RECORDS[@]}"
for reference_artifact in "${REFERENCE_ARTIFACTS[@]}"; do
  copy_run_artifact "$REFERENCE_MANIFEST" \
    "reference/$reference_artifact" \
    "$BUILD/reference/$reference_artifact" \
    "build/reference/$reference_artifact"
done

SHADER_MANIFEST="$BUILD/shaders/RUN-MANIFEST.txt"
SHADER_MANIFEST_SHA256=$(sha256_file "$SHADER_MANIFEST")
verify_run_manifest "$SHADER_MANIFEST" \
  com.alloy.metal12.shader-corpus.v2 \
  "$ROOT/runtime/metal12/run-shader-corpus.sh"
[[ $(manifest_field "$SHADER_MANIFEST" status) == complete ]] ||
  die "shader-corpus manifest is not complete"
SHADER_SUPPORTED_PASSES=$(manifest_field "$SHADER_MANIFEST" supported_passes)
SHADER_NAMED_REJECTIONS=$(manifest_field "$SHADER_MANIFEST" named_rejections)
SHADER_FAILURES=$(manifest_field "$SHADER_MANIFEST" failures)
[[ $SHADER_SUPPORTED_PASSES == 10 &&
  $SHADER_NAMED_REJECTIONS == 1 &&
  $SHADER_FAILURES == 0 ]] ||
  die "shader-corpus manifest has the wrong outcome counts"
verify_manifest_value "$SHADER_MANIFEST" fresh_compiles 11
verify_manifest_value "$SHADER_MANIFEST" cache_hits 0
verify_manifest_value "$SHADER_MANIFEST" \
  compilation_policy fresh-only-no-cache-read
verify_manifest_value "$SHADER_MANIFEST" dxc_execution_materialization \
  private-validated-copy-of-frozen-bundle-v1
verify_manifest_value "$SHADER_MANIFEST" \
  compiler_runtime_selected_file_recheck \
  immediately-before-and-after-each-dxc-v1
verify_manifest_value "$SHADER_MANIFEST" source_materialization \
  git-cat-file-frozen-head-v1
verify_manifest_value "$SHADER_MANIFEST" native_execution_environment \
  env-i-fixed-path-locale-tmp-v1
verify_manifest_value "$SHADER_MANIFEST" python_isolation \
  isolated-mode-minus-I
verify_manifest_value "$SHADER_MANIFEST" dxc_profile cs_6_0
verify_manifest_value "$SHADER_MANIFEST" dxc_entry_point main
verify_manifest_value "$SHADER_MANIFEST" \
  compile_key_schema com.alloy.metal12.shader-compile-key.v1
verify_manifest_value "$SHADER_MANIFEST" \
  compile_key_digest_scope preceding-compile-key-lines
verify_manifest_value "$SHADER_MANIFEST" \
  module_cache_policy unique-ephemeral-not-published
verify_compiler_runtime_manifest "$SHADER_MANIFEST"
REFERENCE_COMPILER_RUNTIME_IDENTITY=$(
  manifest_field "$REFERENCE_MANIFEST" compiler_runtime_identity_sha256
)
SHADER_COMPILER_RUNTIME_IDENTITY=$(
  manifest_field "$SHADER_MANIFEST" compiler_runtime_identity_sha256
)
[[ $REFERENCE_COMPILER_RUNTIME_IDENTITY == "$SHADER_COMPILER_RUNTIME_IDENTITY" ]] ||
  die "reference and shader runs used different compiler-runtime identities"
verify_tool_identity "$SHADER_MANIFEST" metal_path metal_sha256
verify_tool_identity "$SHADER_MANIFEST" xcrun_path xcrun_sha256
verify_tool_identity "$SHADER_MANIFEST" python3_path python3_sha256
verify_tool_identity "$SHADER_MANIFEST" jq_path jq_sha256
verify_tool_identity "$SHADER_MANIFEST" readlink_path readlink_sha256
verify_hash_field_path "$SHADER_MANIFEST" \
  lowering_api_test_sha256 "$BUILD/lowering_api_test"
verify_hash_field_path "$SHADER_MANIFEST" \
  metal12_lower_sha256 "$BUILD/metal12_lower"
verify_hash_field_path "$SHADER_MANIFEST" \
  shader_runner_sha256 "$BUILD/ShaderRunner"

SHADER_CASES_MANIFEST_PATH=runtime/metal12/Tests/ShaderCorpus/cases.json
SHADER_VERIFIER_PATH=runtime/metal12/ShaderTools/verify_shader_output.py
SHADER_CASES_MANIFEST_SHA256=$(git_blob_sha256 "$SHADER_CASES_MANIFEST_PATH")
SHADER_VERIFIER_SHA256=$(git_blob_sha256 "$SHADER_VERIFIER_PATH")
require_sha256 "$SHADER_CASES_MANIFEST_SHA256" \
  "shader cases-manifest Git-blob hash"
require_sha256 "$SHADER_VERIFIER_SHA256" \
  "shader verifier Git-blob hash"
verify_manifest_value "$SHADER_MANIFEST" \
  cases_manifest_sha256 "$SHADER_CASES_MANIFEST_SHA256"
verify_manifest_value "$SHADER_MANIFEST" \
  shader_verifier_sha256 "$SHADER_VERIFIER_SHA256"
copy_file "$SHADER_MANIFEST" "build/shaders/RUN-MANIFEST.txt" \
  "$SHADER_MANIFEST_SHA256"

SUPPORTED_SHADER_CASES=(
  add_cs
  clamp_cs
  intops_cs
  select_cs
  texture_bilinear_cs
  texture_point_cs
  twobuf_cs
  wave_cs
  wave_lane_index_cs
  wave_prefix_sum_cs
)
SUPPORTED_SHADER_SUFFIXES=(
  compile-key
  dxc.log
  dxil
  ll
  lower.log
  metal
  metallib
  provenance.json
  width
)
EXPECTED_SHADER_ARTIFACT_RECORDS=()
for shader_case in "${SUPPORTED_SHADER_CASES[@]}"; do
  for shader_suffix in "${SUPPORTED_SHADER_SUFFIXES[@]}"; do
    shader_artifact="$shader_case.$shader_suffix"
    EXPECTED_SHADER_ARTIFACT_RECORDS+=("shaders/$shader_artifact")
    copy_run_artifact "$SHADER_MANIFEST" \
      "shaders/$shader_artifact" "$BUILD/shaders/$shader_artifact" \
      "build/shaders/$shader_artifact"
  done
  case "$shader_case" in
    add_cs | clamp_cs | intops_cs | select_cs)
      SHADER_CASE_DATA_SUFFIXES=(
        u0.in.bin
        u0.in.bin.out
        u0.ref.bin
      )
      ;;
    texture_bilinear_cs | texture_point_cs | wave_cs | \
      wave_lane_index_cs | wave_prefix_sum_cs)
      SHADER_CASE_DATA_SUFFIXES=(
        u0.in.bin
        u0.in.bin.out
        u0.runtime.ref.bin
      )
      ;;
    twobuf_cs)
      SHADER_CASE_DATA_SUFFIXES=(
        u0.in.bin
        u0.in.bin.out
        u0.ref.bin
        u1.in.bin
        u1.in.bin.out
        u1.ref.bin
      )
      ;;
    *)
      die "shader data allowlist is incomplete: $shader_case"
      ;;
  esac
  for shader_suffix in "${SHADER_CASE_DATA_SUFFIXES[@]}"; do
    shader_artifact="$shader_case.$shader_suffix"
    EXPECTED_SHADER_ARTIFACT_RECORDS+=("shaders/$shader_artifact")
    copy_run_artifact "$SHADER_MANIFEST" \
      "shaders/$shader_artifact" "$BUILD/shaders/$shader_artifact" \
      "build/shaders/$shader_artifact"
  done
done

REJECTED_SHADER_ARTIFACTS=(
  wave_read_lane_unsupported_cs.compile-key
  wave_read_lane_unsupported_cs.dxc.log
  wave_read_lane_unsupported_cs.dxil
  wave_read_lane_unsupported_cs.ll
  wave_read_lane_unsupported_cs.lower.log
)

ALL_SHADER_CASES=("${SUPPORTED_SHADER_CASES[@]}" wave_read_lane_unsupported_cs)
EXPECTED_SHADER_INPUT_RECORDS=()
for shader_case in "${ALL_SHADER_CASES[@]}"; do
  EXPECTED_SHADER_INPUT_RECORDS+=("Tests/ShaderCorpus/$shader_case.hlsl")
done
verify_record_name_inventory "$SHADER_MANIFEST" case_input_sha256 3 \
  "${EXPECTED_SHADER_INPUT_RECORDS[@]}"
verify_record_name_inventory "$SHADER_MANIFEST" case_compile_key_sha256 3 \
  "${ALL_SHADER_CASES[@]}"
verify_record_name_inventory "$SHADER_MANIFEST" case_dxc_arguments 2 \
  "${ALL_SHADER_CASES[@]}"

for shader_case in "${ALL_SHADER_CASES[@]}"; do
  shader_input_record_path="Tests/ShaderCorpus/$shader_case.hlsl"
  shader_input_repo_path="runtime/metal12/$shader_input_record_path"
  expected_shader_input_sha256=$(git_blob_sha256 "$shader_input_repo_path")
  recorded_shader_input_sha256=$(
    manifest_named_hash "$SHADER_MANIFEST" \
      case_input_sha256 "$shader_input_record_path"
  ) || die "shader manifest omits or duplicates input: $shader_case"
  require_sha256 "$recorded_shader_input_sha256" \
    "shader input hash for $shader_case"
  [[ $recorded_shader_input_sha256 == "$expected_shader_input_sha256" ]] ||
    die "shader input hash is not bound to HEAD: $shader_case"

  expected_shader_dxc_arguments="$(
    printf -- '-T cs_6_0 -E main -Fo shaders/%s.dxil ' "$shader_case"
    printf -- '-Fc shaders/%s.ll Tests/ShaderCorpus/%s.hlsl' \
      "$shader_case" "$shader_case"
  )"
  grep -Fqx \
    "case_dxc_arguments: $shader_case  $expected_shader_dxc_arguments" \
    "$SHADER_MANIFEST" ||
    die "shader manifest has wrong or duplicate-looking DXC arguments: $shader_case"
  [[ $(
    grep -Fxc \
      "case_dxc_arguments: $shader_case  $expected_shader_dxc_arguments" \
      "$SHADER_MANIFEST"
  ) == 1 ]] ||
    die "shader manifest duplicates DXC arguments: $shader_case"

  expected_shader_compile_key_sha256="$(
    {
      printf 'schema: com.alloy.metal12.shader-compile-key.v1\n'
      printf 'source_sha256: %s\n' "$expected_shader_input_sha256"
      printf 'compiler_runtime_identity_sha256: %s\n' \
        "$AM12_COMPILER_RUNTIME_IDENTITY_SHA256"
      printf 'dxc_arguments: %s\n' "$expected_shader_dxc_arguments"
    } | sha256_stream
  )"
  recorded_shader_compile_key_sha256=$(
    manifest_named_hash "$SHADER_MANIFEST" \
      case_compile_key_sha256 "$shader_case"
  ) || die "shader manifest omits or duplicates compile key: $shader_case"
  [[ $recorded_shader_compile_key_sha256 == "$expected_shader_compile_key_sha256" ]] ||
    die "shader compile key is not bound to exact inputs: $shader_case"

  shader_compile_key_path="$BUILD/shaders/$shader_case.compile-key"
  [[ -s $shader_compile_key_path && ! -L $shader_compile_key_path ]] ||
    die "shader compile-key artifact is missing: $shader_case"
  [[ $(sed -n '1,4p' "$shader_compile_key_path" |
    sha256_stream) == "$expected_shader_compile_key_sha256" ]] ||
    die "shader compile-key prefix is wrong: $shader_case"
  [[ $(sed -n '5p' "$shader_compile_key_path") == "key_sha256: $expected_shader_compile_key_sha256" ]] ||
    die "shader compile-key digest line is wrong: $shader_case"
  [[ $(wc -l <"$shader_compile_key_path" | tr -d ' ') == 5 ]] ||
    die "shader compile-key has unexpected extra lines: $shader_case"
  [[ $(sed -n '1p' "$BUILD/shaders/$shader_case.dxc.log") == 'compile_mode: fresh' ]] ||
    die "shader DXC log does not record a fresh invocation: $shader_case"
  [[ $(sed -n '1p' "$BUILD/shaders/$shader_case.lower.log") == 'lower_mode: fresh-staging' ]] ||
    die "shader lower log is not from fresh staging: $shader_case"
done

for shader_artifact in "${REJECTED_SHADER_ARTIFACTS[@]}"; do
  EXPECTED_SHADER_ARTIFACT_RECORDS+=("shaders/$shader_artifact")
  copy_run_artifact "$SHADER_MANIFEST" \
    "shaders/$shader_artifact" "$BUILD/shaders/$shader_artifact" \
    "build/shaders/$shader_artifact"
done
EXPECTED_SHADER_ARTIFACT_RECORDS+=(shaders/texture-rgba32f.bin)
copy_run_artifact "$SHADER_MANIFEST" \
  shaders/texture-rgba32f.bin "$BUILD/shaders/texture-rgba32f.bin" \
  "build/shaders/texture-rgba32f.bin"
verify_record_name_inventory "$SHADER_MANIFEST" artifact_sha256 3 \
  "${EXPECTED_SHADER_ARTIFACT_RECORDS[@]}"

if [[ -n $SESSION_EXPORT ]]; then
  [[ -f $SESSION_EXPORT && ! -L $SESSION_EXPORT ]] ||
    die "session export changed type before capture"
  [[ $(sha256_file "$SESSION_EXPORT") == "$SESSION_EXPORT_SHA256" ]] ||
    die "session export changed after its identity was frozen"
  LC_ALL=C grep -aFiq 'Alloy' "$SESSION_EXPORT" ||
    die "session export lost the required Alloy marker"
  LC_ALL=C grep -aEiq \
    'm12[-_ ]?84|#84|issue[[:space:]#:_-]*84' "$SESSION_EXPORT" ||
    die "session export lost the required M12-84 task marker"
  copy_file \
    "$SESSION_EXPORT" "private/ai-session-export" "$SESSION_EXPORT_SHA256"
  [[ $(sha256_file "$OUTPUT/private/ai-session-export") == "$SESSION_EXPORT_SHA256" ]] ||
    die "captured session export does not match its frozen identity"
  chmod 600 "$OUTPUT/private/ai-session-export"
fi

{
  printf 'INTERNAL - NON-DISTRIBUTABLE\n\n'
  printf 'Contains proprietary Metal12 binaries, shader intermediates, '
  printf 'captures, logs, and potentially a private AI-session export.\n'
  printf 'Do not publish, attach to a public pull request, upload to public '
  printf 'CI or artifact storage, or redistribute.\n\n'
  printf 'Creator: Timur Isaev\n\n'
  printf 'This is ADR-0012 evidence, not a clean-room certification or '
  printf 'legal conclusion.\n'
} >"$OUTPUT/CLASSIFICATION.txt"

if ((ALLOW_UNSIGNED_STAGING)); then
  EXPECTED_SNAPSHOT_STATUS=STAGING_ONLY
else
  EXPECTED_SNAPSHOT_STATUS=SIGNED_AWAITING_EXTERNAL_PRESERVATION
fi

{
  printf 'author: Timur Isaev\n'
  printf 'classification: private internal evidence; not distributable\n'
  printf 'evidence_claim: evidence; not clean-room certification\n'
  printf 'capture_mode: existing-artifacts-only\n'
  printf 'source_archive_materialization: git-cat-file-allowlisted-head-v1\n'
  printf 'tests_executed_by_capture: none\n'
  printf 'network_access_by_capture: none\n'
  printf 'ai_corpus_verification_by_capture: not-performed\n'
  printf 'run_manifest_authentication: unsigned execution records; '
  printf 'snapshot signature authenticates packaged bytes, not execution\n'
  printf 'created_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'head_commit: %s\n' "$HEAD_COMMIT"
  printf 'head_tree: %s\n' "$HEAD_TREE"
  printf 'base_ref: pinned-task-base\n'
  printf 'base_commit: %s\n' "$BASE_COMMIT"
  printf 'pinned_base_commit: %s\n' "$PINNED_BASE_COMMIT"
  printf 'merge_base: %s\n' "$MERGE_BASE"
  printf 'task_commit_count: %s\n' "$COMMIT_COUNT"
  printf 'missing_commit_signature_count: %s\n' "$UNSIGNED_COUNT"
  printf 'verified_selected_fingerprint_commit_count: %s\n' \
    "$VERIFIED_COMMIT_COUNT"
  printf 'unverified_commit_count: %s\n' "$UNVERIFIED_COMMIT_COUNT"
  printf 'signed_tag: %s\n' "${SIGNED_TAG:-not-provided}"
  printf 'ai_session_export: %s\n' "$([[ -n $SESSION_EXPORT ]] && printf provided || printf not-provided)"
  if [[ -n $SESSION_EXPORT ]]; then
    printf 'ai_session_export_validation: caller-supplied; '
    printf 'marker-checked; semantic contents unattested\n'
  else
    printf 'ai_session_export_validation: not-provided\n'
  fi
  printf 'ai_session_export_sha256: %s\n' \
    "${SESSION_EXPORT_SHA256:-not-provided}"
  printf 'manifest_signature: %s\n' "$SIGNATURE_KIND"
  printf 'expected_snapshot_status: %s\n' "$EXPECTED_SNAPSHOT_STATUS"
  printf 'expected_snapshot_signer_fingerprint: %s\n' \
    "${EXPECTED_SIGNER_FINGERPRINT:-not-provided}"
  printf 'external_timestamp: pending-after-capture\n'
  printf 'durable_private_upload: pending-after-capture\n'
  printf 'residency_pressure_executed_by_capture: no\n'
  printf 'model_proof_evidence_status: %s\n' "$MODEL_STATUS"
  printf 'reference_trace_evidence_status: complete-presented\n'
  printf 'reference_dxc_compilation: fresh; 2 invocations; 0 cache hits\n'
  printf 'shader_corpus_evidence_status: complete\n'
  printf 'shader_dxc_compilation: fresh; 11 invocations; 0 cache hits\n'
  printf 'compiler_runtime_identity_sha256: %s\n' \
    "$REFERENCE_COMPILER_RUNTIME_IDENTITY"
} >"$OUTPUT/EVIDENCE-RECORD.txt"

{
  printf 'schema: com.alloy.metal12.authenticated-state.v1\n'
  printf 'author: Timur Isaev\n'
  printf 'status: %s\n' "$EXPECTED_SNAPSHOT_STATUS"
  printf 'signature_kind: %s\n' "$SIGNATURE_KIND"
  printf 'signer_fingerprint: %s\n' \
    "${EXPECTED_SIGNER_FINGERPRINT:-not-provided}"
} >"$OUTPUT/AUTHENTICATED-STATE.txt"

if [[ $SIGNATURE_KIND == openpgp ]]; then
  "$GPG_PATH" --batch --armor --export "$OPENPGP_KEY" \
    >"$OUTPUT/metadata/snapshot-signer-openpgp.asc"
  [[ -s $OUTPUT/metadata/snapshot-signer-openpgp.asc ]] ||
    die "could not export the selected OpenPGP public key"
  printf 'openpgp_fingerprint: %s\n' "$EXPECTED_SIGNER_FINGERPRINT" \
    >"$OUTPUT/metadata/snapshot-signer.txt"
elif [[ $SIGNATURE_KIND == ssh ]]; then
  [[ -f $SSH_KEY && ! -L $SSH_KEY &&
    $(sha256_file "$SSH_KEY") == "$SSH_KEY_SHA256" ]] ||
    die "SSH signing key changed after its identity was frozen"
  CURRENT_SSH_PUBLIC_KEY=$(
    "$SSH_KEYGEN_PATH" -y -f "$SSH_KEY"
  ) || die "cannot rederive the selected SSH public key"
  [[ $CURRENT_SSH_PUBLIC_KEY == "$SSH_PUBLIC_KEY" ]] ||
    die "SSH signing key changed after public-key derivation"
  printf '%s\n' "$SSH_PUBLIC_KEY" \
    >"$OUTPUT/metadata/snapshot-signer.pub"
  printf 'alloy-metal12-evidence %s\n' "$SSH_PUBLIC_KEY" \
    >"$OUTPUT/metadata/snapshot-signer.allowed_signers"
  printf 'ssh_fingerprint: %s\n' "$EXPECTED_SIGNER_FINGERPRINT" \
    >"$OUTPUT/metadata/snapshot-signer.txt"
fi

git -C "$ROOT" status --porcelain=v2 --branch --untracked-files=normal \
  >"$OUTPUT/metadata/git-status-porcelain-v2.txt"
git -C "$ROOT" status --short --branch --untracked-files=normal \
  >"$OUTPUT/metadata/git-status-short.txt"

{
  uname -srm
  sw_vers
  printf '\nBash:\n'
  /bin/bash --version 2>&1
  printf '\nXcode:\n'
  run_clean_native_tool xcodebuild -version 2>&1 ||
    printf 'unavailable\n'
  printf '\nSDK:\n'
  run_clean_native_tool \
    xcrun --sdk macosx --show-sdk-path 2>&1 ||
    printf 'unavailable\n'
  run_clean_native_tool \
    xcrun --sdk macosx --show-sdk-version 2>&1 ||
    printf 'unavailable\n'
  printf '\nClang:\n'
  run_clean_native_tool \
    xcrun --sdk macosx clang --version 2>&1 ||
    printf 'unavailable\n'
  printf '\nMetal:\n'
  run_clean_native_tool \
    xcrun --sdk macosx metal --version 2>&1 ||
    printf 'unavailable\n'
  printf '\nLibtool:\n'
  run_clean_native_tool libtool -V 2>&1 || printf 'unavailable\n'
  printf '\nGit:\n'
  git --version
  printf '\nPython:\n'
  /usr/bin/python3 --version 2>&1
  printf '\nShasum:\n'
  shasum --version 2>&1 || printf 'unavailable\n'
  printf '\nHardware model and memory:\n'
  sysctl -n hw.model hw.memsize 2>&1 || printf 'unavailable\n'
} >"$OUTPUT/metadata/environment.txt"

CAPTURE_TOOLS=(
  awk
  basename
  bash
  cat
  chmod
  cmp
  cp
  date
  dirname
  env
  find
  git
  grep
  gzip
  libtool
  mkdir
  mktemp
  mv
  od
  printenv
  python3
  readlink
  rm
  rmdir
  sed
  shasum
  sort
  stat
  ssh-keygen
  sw_vers
  sysctl
  tar
  tr
  uname
  wc
  xcodebuild
  xcrun
)
[[ $SIGNATURE_KIND == openpgp ]] && CAPTURE_TOOLS+=(gpg)
{
  for capture_tool in "${CAPTURE_TOOLS[@]}"; do
    case "$capture_tool" in
      git) capture_tool_path=$GIT_PATH ;;
      gpg) capture_tool_path=$GPG_PATH ;;
      ssh-keygen)
        if [[ -n $SSH_KEYGEN_PATH ]]; then
          capture_tool_path=$SSH_KEYGEN_PATH
        else
          capture_tool_path=$(command -v "$capture_tool") ||
            die "capture tool is unavailable: $capture_tool"
        fi
        ;;
      *)
        capture_tool_path=$(command -v "$capture_tool") ||
          die "capture tool is unavailable: $capture_tool"
        ;;
    esac
    capture_tool_path=$(
      canonical_executable_path \
        "$capture_tool_path" "capture tool $capture_tool"
    )
    [[ $capture_tool_path == /* && -f $capture_tool_path ]] ||
      die "capture tool does not resolve to a regular executable: $capture_tool"
    capture_tool_sha256=$(sha256_file "$capture_tool_path")
    printf '%s\t%s\t%s\n' \
      "$capture_tool" "$capture_tool_path" "$capture_tool_sha256"
  done
} >"$OUTPUT/metadata/capture-tools.tsv"

verify_build_manifest_identity
verify_compiler_runtime_manifest "$REFERENCE_MANIFEST"
verify_tool_identity "$REFERENCE_MANIFEST" python_path python_sha256
verify_tool_identity "$REFERENCE_MANIFEST" metal_path metal_sha256
verify_metallib_dispatch_identity "$REFERENCE_MANIFEST"
verify_compiler_runtime_manifest "$SHADER_MANIFEST"
verify_tool_identity "$SHADER_MANIFEST" metal_path metal_sha256
verify_tool_identity "$SHADER_MANIFEST" xcrun_path xcrun_sha256
verify_tool_identity "$SHADER_MANIFEST" python3_path python3_sha256
verify_tool_identity "$SHADER_MANIFEST" jq_path jq_sha256
verify_tool_identity "$SHADER_MANIFEST" readlink_path readlink_sha256

[[ $(git -C "$ROOT" rev-parse 'HEAD^{commit}') == "$HEAD_COMMIT" ]] ||
  die "HEAD changed during evidence capture"
[[ $(git -C "$ROOT" rev-parse "$HEAD_COMMIT^{tree}") == "$HEAD_TREE" ]] ||
  die "HEAD tree changed during evidence capture"
if [[ -n $TAG_OBJECT ]]; then
  verify_signed_tag_ref_binding
fi
[[ -z $(git -C "$ROOT" status --porcelain=v1 --untracked-files=normal) ]] ||
  die "tracked worktree state changed during evidence capture"
[[ $(sha256_file "$SOURCE_ARCHIVE") == "$SOURCE_ARCHIVE_SHA256" ]] ||
  die "source archive changed after round-trip verification"
[[ $(sha256_file "$OUTPUT/source/task-commits.patch") == "$TASK_PATCH_SHA256" ]] ||
  die "task patch changed after generation"
for ((copy_index = 0; copy_index < ${#COPIED_SOURCES[@]}; copy_index++)); do
  source_hash=$(sha256_file "${COPIED_SOURCES[$copy_index]}")
  destination_hash=$(sha256_file "$OUTPUT/${COPIED_RELATIVES[$copy_index]}")
  [[ $source_hash == "$destination_hash" &&
    $destination_hash == "${COPIED_EXPECTED_SHA256[$copy_index]}" ]] ||
    die "source changed after capture: ${COPIED_SOURCES[$copy_index]}"
done
cmp "$OUTPUT/build/reference/reference-a.am12" \
  "$OUTPUT/build/reference/reference-b.am12" >/dev/null ||
  die "canonical trace captures differ"
for reference_image in capture-a.bmp capture-b.bmp replay.bmp presented.bmp; do
  cmp "$OUTPUT/build/reference/live.bmp" \
    "$OUTPUT/build/reference/$reference_image" >/dev/null ||
    die "canonical reference image differs: $reference_image"
done

if ((ALLOW_UNSIGNED_STAGING)); then
  {
    printf 'This is an incomplete staging snapshot.\n'
    printf 'It is not ADR-0012 preservation evidence.\n'
    printf 'Unverified task commits: %s\n' "$UNVERIFIED_COMMIT_COUNT"
    printf 'Task commits missing a signature header: %s\n' "$UNSIGNED_COUNT"
    printf 'AI session export: %s\n' "$([[ -n $SESSION_EXPORT ]] && printf provided || printf missing)"
    printf 'Signed tag: %s\n' "${SIGNED_TAG:-missing}"
    printf 'Manifest signature: missing\n'
    printf 'Run manifests: unsigned execution records\n'
    printf 'Provider/model corpus inventory: unavailable in this environment\n'
    printf 'External timestamp and durable private upload: pending\n'
  } >"$OUTPUT/OPEN-GAPS.txt"
else
  {
    printf 'Capture prerequisites verified.\n'
    printf 'Preserve this directory in durable private storage.\n'
    printf 'Retain an external timestamp receipt for SHA256SUMS.\n'
  } >"$OUTPUT/READY-FOR-EXTERNAL-PRESERVATION"
fi

cat >"$OUTPUT/VERIFY-SNAPSHOT.sh" <<'VERIFY_SNAPSHOT_EOF'
#!/bin/bash -p
# Verify one Alloy Metal12 evidence snapshot as a closed file set.
# Author: Timur Isaev
[[ $- == *p* ]] || {
  printf 'snapshot verification: execute this script directly; Bash privileged mode is required\n' >&2
  exit 2
}
set -euo pipefail
umask 077
unset BASH_ENV CDPATH ENV GLOBIGNORE
shopt -u dotglob extglob failglob nocaseglob nullglob
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
LC_ALL=C
LANG=C
TMPDIR=/tmp
export LANG LC_ALL PATH TMPDIR

if (($# > 1)); then
  printf 'usage: %s [OUT_OF_BAND_EXPECTED_SIGNER_FINGERPRINT]\n' "$0" >&2
  exit 2
fi
OUT_OF_BAND_EXPECTED_FINGERPRINT=${1:-}

SNAPSHOT_ROOT=$(cd "$(dirname "$0")" && pwd -P)
VERIFY_TEMP=$(
  mktemp -d "$TMPDIR/alloy-metal12-snapshot-verify.XXXXXX"
)

verify_cleanup() {
  local exit_status=$?

  trap - EXIT HUP INT TERM
  if [[ -d $VERIFY_TEMP && ! -L $VERIFY_TEMP ]]; then
    find "$VERIFY_TEMP" -depth -delete || exit_status=1
  fi
  exit "$exit_status"
}

trap verify_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

verify_die() {
  printf 'snapshot verification: %s\n' "$*" >&2
  exit 1
}

manifest_field() {
  local manifest=$1
  local key=$2

  awk -v key="$key" \
    'index($0, key ": ") == 1 {
        value = substr($0, length(key) + 3)
        count += 1
      }
      END { if (count == 1) print value; else exit 1 }' \
    "$manifest"
}

run_clean_shasum() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    /usr/bin/shasum "$@"
}

file_sha256() {
  local path=$1
  local output
  local digest

  output=$(run_clean_shasum -a 256 "$path") ||
    verify_die "cannot hash frozen verifier input: $path"
  digest=${output%% *}
  ((${#digest} == 64)) && [[ $digest != *[!0-9a-f]* ]] ||
    verify_die "invalid SHA-256 for frozen verifier input: $path"
  printf '%s\n' "$digest"
}

freeze_regular_file() {
  local source=$1
  local destination=$2
  local label=$3

  [[ -f $source && ! -L $source ]] ||
    verify_die "$label is missing, nonregular, or symlinked"
  /bin/cat "$source" >"$destination" ||
    verify_die "cannot freeze $label"
  [[ -f $source && ! -L $source ]] ||
    verify_die "$label changed type while being frozen"
  cmp "$source" "$destination" >/dev/null ||
    verify_die "$label changed while being frozen"
  chmod 400 "$destination"
  FROZEN_SOURCE_FILES+=("$source")
  FROZEN_COPY_FILES+=("$destination")
}

checksum_digest_for_path() {
  local relative=$1

  awk -v requested="./$relative" '
    $2 == requested {
      digest = $1
      count += 1
    }
    END { if (count == 1) print digest; else exit 1 }
  ' "$FROZEN_SHA256SUMS"
}

freeze_checksummed_file() {
  local relative=$1
  local destination=$2
  local expected_digest

  expected_digest=$(checksum_digest_for_path "$relative") ||
    verify_die "SHA256SUMS omits or duplicates control file: $relative"
  freeze_regular_file \
    "$SNAPSHOT_ROOT/$relative" "$destination" "$relative"
  [[ $(file_sha256 "$destination") == "$expected_digest" ]] ||
    verify_die "frozen control file does not match SHA256SUMS: $relative"
}

verify_frozen_sources_unchanged() {
  local frozen_index

  for ((frozen_index = 0; frozen_index < ${#FROZEN_SOURCE_FILES[@]}; frozen_index++)); do
    [[ -f ${FROZEN_SOURCE_FILES[$frozen_index]} &&
      ! -L ${FROZEN_SOURCE_FILES[$frozen_index]} ]] ||
      verify_die "a frozen verifier input changed type"
    cmp \
      "${FROZEN_SOURCE_FILES[$frozen_index]}" \
      "${FROZEN_COPY_FILES[$frozen_index]}" >/dev/null ||
      verify_die "a frozen verifier input changed during verification"
  done
}

gpg_validsig_primary_fingerprint() {
  awk '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      candidate = $3
      if ((length($NF) == 40 || length($NF) == 64) &&
          $NF !~ /[^0-9A-Fa-f]/) {
        candidate = $NF
      }
      print toupper(candidate)
      count += 1
    }
    END { if (count != 1) exit 1 }
  '
}

[[ -d $SNAPSHOT_ROOT && ! -L $SNAPSHOT_ROOT ]] ||
  verify_die "snapshot root is missing or symlinked"
for required_file in \
  AUTHENTICATED-STATE.txt \
  EVIDENCE-RECORD.txt \
  SHA256SUMS \
  SNAPSHOT-STATUS \
  VERIFY-SNAPSHOT.sh; do
  [[ -f $SNAPSHOT_ROOT/$required_file &&
    ! -L $SNAPSHOT_ROOT/$required_file ]] ||
    verify_die "required file is missing or symlinked: $required_file"
done

FROZEN_SOURCE_FILES=()
FROZEN_COPY_FILES=()
FROZEN_SHA256SUMS="$VERIFY_TEMP/SHA256SUMS"
freeze_regular_file \
  "$SNAPSHOT_ROOT/SHA256SUMS" "$FROZEN_SHA256SUMS" SHA256SUMS

unexpected_special=$(
  find "$SNAPSHOT_ROOT" -mindepth 1 ! -type d ! -type f -print -quit
)
[[ -z $unexpected_special ]] ||
  verify_die "snapshot contains a symlink or special file: $unexpected_special"

CHECKSUM_FILES="$VERIFY_TEMP/checksummed-files.txt"
SORTED_CHECKSUM_FILES="$VERIFY_TEMP/checksummed-files.sorted.txt"
EXPECTED_FILES="$VERIFY_TEMP/expected-files.txt"
ACTUAL_FILES="$VERIFY_TEMP/actual-files.txt"
EXPECTED_DIRECTORIES="$VERIFY_TEMP/expected-directories.txt"
ACTUAL_DIRECTORIES="$VERIFY_TEMP/actual-directories.txt"

verify_snapshot_closed_set() {
  local special_entry

  special_entry=$(
    find "$SNAPSHOT_ROOT" -mindepth 1 ! -type d ! -type f -print -quit
  )
  [[ -z $special_entry ]] ||
    verify_die "snapshot contains a symlink or special file: $special_entry"
  (
    cd "$SNAPSHOT_ROOT"
    find . -type f -print | LC_ALL=C sort
  ) >"$ACTUAL_FILES"
  cmp "$EXPECTED_FILES" "$ACTUAL_FILES" >/dev/null ||
    verify_die "snapshot contains a missing or unlisted file"
  (
    cd "$SNAPSHOT_ROOT"
    find . -type d -print | LC_ALL=C sort
  ) >"$ACTUAL_DIRECTORIES"
  cmp "$EXPECTED_DIRECTORIES" "$ACTUAL_DIRECTORIES" >/dev/null ||
    verify_die "snapshot contains a missing or unlisted directory"
}

awk '
  NF == 2 &&
  length($1) == 64 &&
  $1 !~ /[^0-9a-f]/ &&
  $2 ~ /^\.\// {
    print $2
    next
  }
  { exit 1 }
' "$FROZEN_SHA256SUMS" >"$CHECKSUM_FILES" ||
  verify_die "SHA256SUMS has invalid syntax"
[[ -s $CHECKSUM_FILES ]] ||
  verify_die "SHA256SUMS has no entries"
LC_ALL=C sort "$CHECKSUM_FILES" >"$SORTED_CHECKSUM_FILES"
cmp "$CHECKSUM_FILES" "$SORTED_CHECKSUM_FILES" >/dev/null ||
  verify_die "SHA256SUMS paths are duplicated or unsorted"
UNIQUE_CHECKSUM_PATH_COUNT=$(
  LC_ALL=C sort -u "$CHECKSUM_FILES" | wc -l | tr -d ' '
)
CHECKSUM_PATH_COUNT=$(wc -l <"$CHECKSUM_FILES" | tr -d ' ')
[[ $UNIQUE_CHECKSUM_PATH_COUNT == "$CHECKSUM_PATH_COUNT" ]] ||
  verify_die "SHA256SUMS contains duplicate paths"

FROZEN_AUTHENTICATED_STATE="$VERIFY_TEMP/AUTHENTICATED-STATE.txt"
FROZEN_EVIDENCE_RECORD="$VERIFY_TEMP/EVIDENCE-RECORD.txt"
FROZEN_SNAPSHOT_STATUS="$VERIFY_TEMP/SNAPSHOT-STATUS"
freeze_checksummed_file \
  AUTHENTICATED-STATE.txt "$FROZEN_AUTHENTICATED_STATE"
freeze_checksummed_file EVIDENCE-RECORD.txt "$FROZEN_EVIDENCE_RECORD"
freeze_regular_file \
  "$SNAPSHOT_ROOT/SNAPSHOT-STATUS" \
  "$FROZEN_SNAPSHOT_STATUS" \
  SNAPSHOT-STATUS

STATE_SCHEMA=$(
  manifest_field "$FROZEN_AUTHENTICATED_STATE" schema
) || verify_die "authenticated state omits or duplicates schema"
[[ $STATE_SCHEMA == com.alloy.metal12.authenticated-state.v1 ]] ||
  verify_die "authenticated state has the wrong schema"
STATE_AUTHOR=$(
  manifest_field "$FROZEN_AUTHENTICATED_STATE" author
) || verify_die "authenticated state omits or duplicates author"
[[ $STATE_AUTHOR == "Timur Isaev" ]] ||
  verify_die "authenticated state has the wrong author"
EXPECTED_STATUS=$(
  manifest_field "$FROZEN_AUTHENTICATED_STATE" status
) || verify_die "authenticated state omits or duplicates status"
SIGNATURE_KIND=$(
  manifest_field "$FROZEN_AUTHENTICATED_STATE" signature_kind
) || verify_die "authenticated state omits or duplicates signature kind"
EXPECTED_FINGERPRINT=$(
  manifest_field "$FROZEN_AUTHENTICATED_STATE" signer_fingerprint
) || verify_die "authenticated state omits or duplicates signer fingerprint"
EVIDENCE_STATUS=$(
  manifest_field "$FROZEN_EVIDENCE_RECORD" \
    expected_snapshot_status
) || verify_die "evidence record omits or duplicates expected status"
EVIDENCE_SIGNATURE_KIND=$(
  manifest_field "$FROZEN_EVIDENCE_RECORD" manifest_signature
) || verify_die "evidence record omits or duplicates signature kind"
EVIDENCE_FINGERPRINT=$(
  manifest_field "$FROZEN_EVIDENCE_RECORD" \
    expected_snapshot_signer_fingerprint
) || verify_die "evidence record omits or duplicates signer fingerprint"
[[ $EVIDENCE_STATUS == "$EXPECTED_STATUS" &&
  $EVIDENCE_SIGNATURE_KIND == "$SIGNATURE_KIND" &&
  $EVIDENCE_FINGERPRINT == "$EXPECTED_FINGERPRINT" ]] ||
  verify_die "evidence record does not mirror authenticated state"
[[ $(wc -l <"$FROZEN_SNAPSHOT_STATUS" | tr -d ' ') == 1 ]] ||
  verify_die "SNAPSHOT-STATUS is not exactly one line"
ACTUAL_STATUS=$(<"$FROZEN_SNAPSHOT_STATUS")
[[ $ACTUAL_STATUS == "$EXPECTED_STATUS" ]] ||
  verify_die "SNAPSHOT-STATUS does not match the checksummed evidence record"

cp "$CHECKSUM_FILES" "$EXPECTED_FILES"
printf '%s\n' ./SHA256SUMS ./SNAPSHOT-STATUS >>"$EXPECTED_FILES"
case "$SIGNATURE_KIND" in
  not-provided)
    [[ $EXPECTED_STATUS == STAGING_ONLY &&
      $EXPECTED_FINGERPRINT == not-provided ]] ||
      verify_die "unsigned staging metadata is inconsistent"
    [[ -z $OUT_OF_BAND_EXPECTED_FINGERPRINT ]] ||
      verify_die "unsigned staging does not accept a signer fingerprint"
    ;;
  openpgp)
    [[ $EXPECTED_STATUS == SIGNED_AWAITING_EXTERNAL_PRESERVATION ]] ||
      verify_die "signed OpenPGP snapshot has the wrong expected status"
    [[ -n $OUT_OF_BAND_EXPECTED_FINGERPRINT &&
      $EXPECTED_FINGERPRINT == "$OUT_OF_BAND_EXPECTED_FINGERPRINT" ]] ||
      verify_die "signed snapshot does not match the out-of-band signer fingerprint"
    printf '%s\n' ./SHA256SUMS.asc >>"$EXPECTED_FILES"
    ;;
  ssh)
    [[ $EXPECTED_STATUS == SIGNED_AWAITING_EXTERNAL_PRESERVATION ]] ||
      verify_die "signed SSH snapshot has the wrong expected status"
    [[ -n $OUT_OF_BAND_EXPECTED_FINGERPRINT &&
      $EXPECTED_FINGERPRINT == "$OUT_OF_BAND_EXPECTED_FINGERPRINT" ]] ||
      verify_die "signed snapshot does not match the out-of-band signer fingerprint"
    printf '%s\n' ./SHA256SUMS.sig >>"$EXPECTED_FILES"
    ;;
  *)
    verify_die "unknown manifest signature kind: $SIGNATURE_KIND"
    ;;
esac
LC_ALL=C sort -u "$EXPECTED_FILES" -o "$EXPECTED_FILES"

printf '.\n' >"$EXPECTED_DIRECTORIES"
while IFS= read -r expected_file; do
  expected_directory=$(dirname "$expected_file")
  while [[ $expected_directory != . &&
    $expected_directory != / ]]; do
    printf '%s\n' "$expected_directory" >>"$EXPECTED_DIRECTORIES"
    expected_directory=$(dirname "$expected_directory")
  done
done <"$EXPECTED_FILES"
LC_ALL=C sort -u "$EXPECTED_DIRECTORIES" \
  -o "$EXPECTED_DIRECTORIES"

verify_snapshot_closed_set
(
  cd "$SNAPSHOT_ROOT"
  run_clean_shasum -a 256 -c "$FROZEN_SHA256SUMS" >/dev/null
) || verify_die "a checksummed file failed verification"

case "$SIGNATURE_KIND" in
  not-provided)
    VERIFY_SUCCESS_MESSAGE='Snapshot structure and unsigned checksums verified; authenticity absent.'
    ;;
  openpgp)
    for openpgp_file in \
      SHA256SUMS.asc \
      metadata/snapshot-signer.txt \
      metadata/snapshot-signer-openpgp.asc; do
      [[ -f $SNAPSHOT_ROOT/$openpgp_file &&
        ! -L $SNAPSHOT_ROOT/$openpgp_file ]] ||
        verify_die "OpenPGP evidence file is missing: $openpgp_file"
    done
    FROZEN_SIGNER_METADATA="$VERIFY_TEMP/openpgp-snapshot-signer.txt"
    FROZEN_OPENPGP_PUBLIC_KEY="$VERIFY_TEMP/snapshot-signer-openpgp.asc"
    FROZEN_SNAPSHOT_SIGNATURE="$VERIFY_TEMP/SHA256SUMS.asc"
    freeze_checksummed_file \
      metadata/snapshot-signer.txt "$FROZEN_SIGNER_METADATA"
    freeze_checksummed_file \
      metadata/snapshot-signer-openpgp.asc "$FROZEN_OPENPGP_PUBLIC_KEY"
    freeze_regular_file \
      "$SNAPSHOT_ROOT/SHA256SUMS.asc" \
      "$FROZEN_SNAPSHOT_SIGNATURE" \
      SHA256SUMS.asc
    RECORDED_FINGERPRINT=$(
      manifest_field "$FROZEN_SIGNER_METADATA" \
        openpgp_fingerprint
    ) || verify_die "OpenPGP signer metadata is invalid"
    [[ $RECORDED_FINGERPRINT == "$EXPECTED_FINGERPRINT" ]] ||
      verify_die "OpenPGP signer metadata has an unexpected fingerprint"
    GPG_PATH=$(command -v gpg) ||
      verify_die "gpg is unavailable"
    GPG_HOME="$VERIFY_TEMP/gnupg"
    mkdir -m 700 "$GPG_HOME"
    "$GPG_PATH" --batch --homedir "$GPG_HOME" --import \
      "$FROZEN_OPENPGP_PUBLIC_KEY" \
      >/dev/null 2>&1 ||
      verify_die "could not import the checksummed OpenPGP public key"
    GPG_STATUS=$(
      "$GPG_PATH" --batch --homedir "$GPG_HOME" --status-fd 1 \
        --verify "$FROZEN_SNAPSHOT_SIGNATURE" \
        "$FROZEN_SHA256SUMS" 2>/dev/null
    ) || verify_die "OpenPGP signature did not verify"
    ACTUAL_FINGERPRINT=$(
      printf '%s\n' "$GPG_STATUS" |
        gpg_validsig_primary_fingerprint
    ) || verify_die "OpenPGP verification did not yield one VALIDSIG"
    [[ $ACTUAL_FINGERPRINT == "$EXPECTED_FINGERPRINT" ]] ||
      verify_die "OpenPGP signature used an unexpected fingerprint"
    VERIFY_SUCCESS_MESSAGE="Authenticated OpenPGP snapshot verified: $ACTUAL_FINGERPRINT"
    ;;
  ssh)
    for ssh_file in \
      SHA256SUMS.sig \
      metadata/snapshot-signer.txt \
      metadata/snapshot-signer.allowed_signers \
      metadata/snapshot-signer.pub; do
      [[ -f $SNAPSHOT_ROOT/$ssh_file &&
        ! -L $SNAPSHOT_ROOT/$ssh_file ]] ||
        verify_die "SSH evidence file is missing: $ssh_file"
    done
    FROZEN_SIGNER_METADATA="$VERIFY_TEMP/ssh-snapshot-signer.txt"
    FROZEN_ALLOWED_SIGNERS="$VERIFY_TEMP/snapshot-signer.allowed_signers"
    FROZEN_SIGNER_PUBLIC_KEY="$VERIFY_TEMP/snapshot-signer.pub"
    FROZEN_SNAPSHOT_SIGNATURE="$VERIFY_TEMP/SHA256SUMS.sig"
    freeze_checksummed_file \
      metadata/snapshot-signer.txt "$FROZEN_SIGNER_METADATA"
    freeze_checksummed_file \
      metadata/snapshot-signer.allowed_signers "$FROZEN_ALLOWED_SIGNERS"
    freeze_checksummed_file \
      metadata/snapshot-signer.pub "$FROZEN_SIGNER_PUBLIC_KEY"
    freeze_regular_file \
      "$SNAPSHOT_ROOT/SHA256SUMS.sig" \
      "$FROZEN_SNAPSHOT_SIGNATURE" \
      SHA256SUMS.sig
    RECORDED_FINGERPRINT=$(
      manifest_field "$FROZEN_SIGNER_METADATA" \
        ssh_fingerprint
    ) || verify_die "SSH signer metadata is invalid"
    [[ $RECORDED_FINGERPRINT == "$EXPECTED_FINGERPRINT" ]] ||
      verify_die "SSH signer metadata has an unexpected fingerprint"
    SSH_KEYGEN_PATH=$(command -v ssh-keygen) ||
      verify_die "ssh-keygen is unavailable"
    ACTUAL_FINGERPRINT=$(
      "$SSH_KEYGEN_PATH" -lf \
        "$FROZEN_SIGNER_PUBLIC_KEY" \
        -E sha256 |
        awk '{print $2}'
    ) || verify_die "could not fingerprint the checksummed SSH public key"
    [[ $ACTUAL_FINGERPRINT == "$EXPECTED_FINGERPRINT" ]] ||
      verify_die "SSH public key has an unexpected fingerprint"
    ALLOWED_PUBLIC_KEY=$(
      sed 's/^[^ ]* //' \
        "$FROZEN_ALLOWED_SIGNERS"
    )
    FROZEN_PUBLIC_KEY_TEXT=$(
      /bin/cat "$FROZEN_SIGNER_PUBLIC_KEY"
    ) || verify_die "could not read the checksummed SSH public key"
    [[ $ALLOWED_PUBLIC_KEY == "$FROZEN_PUBLIC_KEY_TEXT" ]] ||
      verify_die "SSH allowed-signers key does not match the frozen public key"
    "$SSH_KEYGEN_PATH" -Y verify \
      -f "$FROZEN_ALLOWED_SIGNERS" \
      -I alloy-metal12-evidence \
      -n alloy-metal12-evidence-v1 \
      -s "$FROZEN_SNAPSHOT_SIGNATURE" \
      <"$FROZEN_SHA256SUMS" >/dev/null ||
      verify_die "SSH signature did not verify against the frozen signer"
    VERIFY_SUCCESS_MESSAGE="Authenticated SSH snapshot verified: $ACTUAL_FINGERPRINT"
    ;;
esac

verify_frozen_sources_unchanged
verify_snapshot_closed_set
(
  cd "$SNAPSHOT_ROOT"
  run_clean_shasum -a 256 -c "$FROZEN_SHA256SUMS" >/dev/null
) || verify_die "a checksummed file changed during verification"
verify_snapshot_closed_set
verify_frozen_sources_unchanged
printf '%s\n' "$VERIFY_SUCCESS_MESSAGE"
VERIFY_SNAPSHOT_EOF
chmod 700 "$OUTPUT/VERIFY-SNAPSHOT.sh"

[[ $(sha256_file "$SOURCE_ARCHIVE") == "$SOURCE_ARCHIVE_SHA256" ]] ||
  die "source archive changed before checksum publication"
[[ $(sha256_file "$OUTPUT/source/task-commits.patch") == "$TASK_PATCH_SHA256" ]] ||
  die "task patch changed before checksum publication"
CHECKSUM_TMP=$(mktemp "$OUTPUT/.SHA256SUMS.XXXXXX")
(
  cd "$OUTPUT"
  find . -type f \
    ! -name SHA256SUMS \
    ! -name SHA256SUMS.asc \
    ! -name SHA256SUMS.sig \
    ! -name SNAPSHOT-STATUS \
    ! -name '.SHA256SUMS.*' \
    ! -name '.SNAPSHOT-STATUS.*' \
    -exec /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    /usr/bin/shasum -a 256 {} \; |
    LC_ALL=C sort -k2 >"$CHECKSUM_TMP"
)
mv "$CHECKSUM_TMP" "$OUTPUT/SHA256SUMS"
(
  cd "$OUTPUT"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
)

if ((ALLOW_UNSIGNED_STAGING)); then
  write_snapshot_status STAGING_ONLY
  "$OUTPUT/VERIFY-SNAPSHOT.sh" >/dev/null
  printf 'Incomplete staging snapshot captured at %s\n' "$OUTPUT" >&2
  exit 3
fi

if [[ $SIGNATURE_KIND == openpgp ]]; then
  "$GPG_PATH" --batch --local-user "$OPENPGP_KEY" --armor --detach-sign \
    --output "$OUTPUT/SHA256SUMS.asc" "$OUTPUT/SHA256SUMS"
  GPG_SIGNATURE_STATUS=$(
    "$GPG_PATH" --batch --status-fd 1 \
      --verify "$OUTPUT/SHA256SUMS.asc" \
      "$OUTPUT/SHA256SUMS" 2>/dev/null
  ) || die "OpenPGP snapshot signature did not verify"
  GPG_SIGNATURE_FINGERPRINT=$(
    printf '%s\n' "$GPG_SIGNATURE_STATUS" |
      awk '
        $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
          candidate = $3
          if ((length($NF) == 40 || length($NF) == 64) &&
              $NF !~ /[^0-9A-Fa-f]/) {
            candidate = $NF
          }
          print toupper(candidate)
          count += 1
        }
        END { if (count != 1) exit 1 }
      '
  ) || die "OpenPGP verification did not yield exactly one VALIDSIG"
  [[ $GPG_SIGNATURE_FINGERPRINT == "$EXPECTED_SIGNER_FINGERPRINT" ]] ||
    die "OpenPGP snapshot signature used an unexpected fingerprint"
else
  [[ -f $SSH_KEY && ! -L $SSH_KEY &&
    $(sha256_file "$SSH_KEY") == "$SSH_KEY_SHA256" ]] ||
    die "SSH signing key changed before snapshot signing"
  [[ $("$SSH_KEYGEN_PATH" -y -f "$SSH_KEY") == "$SSH_PUBLIC_KEY" ]] ||
    die "SSH signing key no longer matches the frozen public key"
  "$SSH_KEYGEN_PATH" -Y sign -f "$SSH_KEY" \
    -n alloy-metal12-evidence-v1 \
    "$OUTPUT/SHA256SUMS"
  [[ -f $SSH_KEY && ! -L $SSH_KEY &&
    $(sha256_file "$SSH_KEY") == "$SSH_KEY_SHA256" ]] ||
    die "SSH signing key changed during snapshot signing"
  [[ $("$SSH_KEYGEN_PATH" -y -f "$SSH_KEY") == "$SSH_PUBLIC_KEY" ]] ||
    die "SSH signing key changed during snapshot signing"
  "$SSH_KEYGEN_PATH" -Y verify \
    -f "$OUTPUT/metadata/snapshot-signer.allowed_signers" \
    -I alloy-metal12-evidence \
    -n alloy-metal12-evidence-v1 \
    -s "$OUTPUT/SHA256SUMS.sig" \
    <"$OUTPUT/SHA256SUMS" >/dev/null ||
    die "SSH snapshot signature did not verify against the frozen signer"
fi

(
  cd "$OUTPUT"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C \
    LANG=C \
    /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
)
write_snapshot_status SIGNED_AWAITING_EXTERNAL_PRESERVATION
"$OUTPUT/VERIFY-SNAPSHOT.sh" "$EXPECTED_SIGNER_FINGERPRINT" >/dev/null
printf 'Signed evidence snapshot captured at %s\n' "$OUTPUT"
