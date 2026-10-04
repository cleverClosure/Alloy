#!/bin/bash
# Coordinate Metal12 build, proof, and evidence publication.
# Author: Timur Isaev

am12_evidence_lock_fail() {
  printf 'evidence lock: %s\n' "$1" >&2
  return 1
}

am12_evidence_lock_load_metadata() {
  local lock_path=$1
  local owner_pid_path="$lock_path/owner-pid"
  local owner_token_path="$lock_path/owner-token"
  local owner_pid
  local owner_token

  if [[ ! -f $owner_pid_path || -L $owner_pid_path ||
    ! -f $owner_token_path || -L $owner_token_path ]]; then
    am12_evidence_lock_fail \
      "lock owner metadata is missing or nonregular: $lock_path"
    return 1
  fi
  owner_pid=$(<"$owner_pid_path")
  owner_token=$(<"$owner_token_path")
  if [[ -z $owner_pid || $owner_pid == *[!0-9]* ]]; then
    am12_evidence_lock_fail "lock owner PID is invalid: $lock_path"
    return 1
  fi
  if ((${#owner_token} != 64)) ||
    [[ $owner_token == *[!0-9a-f]* ]]; then
    am12_evidence_lock_fail "lock owner token is invalid: $lock_path"
    return 1
  fi
  AM12_EVIDENCE_LOCK_METADATA_PID=$owner_pid
  AM12_EVIDENCE_LOCK_METADATA_TOKEN=$owner_token
}

am12_evidence_lock_validate_directory() {
  local lock_path=$1
  local canonical_lock_path

  if [[ ! -d $lock_path || -L $lock_path ]]; then
    am12_evidence_lock_fail \
      "evidence lock is missing or not a regular directory: $lock_path"
    return 1
  fi
  canonical_lock_path="$(cd "$lock_path" 2>/dev/null && pwd -P)" || {
    am12_evidence_lock_fail \
      "could not resolve evidence lock directory: $lock_path"
    return 1
  }
  if [[ $canonical_lock_path != "$lock_path" ]]; then
    am12_evidence_lock_fail \
      "evidence lock is not its canonical path: $lock_path"
    return 1
  fi
}

am12_evidence_lock_cleanup_new() {
  local lock_path=$1
  local owner_pid=$2
  local owner_token=$3
  local owner_pid_path="$lock_path/owner-pid"
  local owner_token_path="$lock_path/owner-token"
  local cleanup_failed=0

  if [[ -f $owner_pid_path && ! -L $owner_pid_path &&
    $(<"$owner_pid_path") == "$owner_pid" ]]; then
    rm -f "$owner_pid_path" || cleanup_failed=1
  elif [[ -e $owner_pid_path || -L $owner_pid_path ]]; then
    cleanup_failed=1
  fi
  if [[ -f $owner_token_path && ! -L $owner_token_path &&
    $(<"$owner_token_path") == "$owner_token" ]]; then
    rm -f "$owner_token_path" || cleanup_failed=1
  elif [[ -e $owner_token_path || -L $owner_token_path ]]; then
    cleanup_failed=1
  fi
  if [[ -d $lock_path && ! -L $lock_path ]]; then
    rmdir "$lock_path" || cleanup_failed=1
  else
    cleanup_failed=1
  fi
  if ((cleanup_failed)); then
    am12_evidence_lock_fail \
      "could not clean newly created lock; inspect without removing it: $lock_path"
    return 1
  fi
}

am12_evidence_lock_acquire() {
  if (($# != 2)); then
    am12_evidence_lock_fail \
      'acquire requires the canonical runtime root and fixed build root'
    return 1
  fi
  local runtime_root=$1
  local build_root=$2
  local canonical_runtime_root
  local canonical_build_root
  local expected_build_root
  local expected_lock_path
  local owner_pid
  local owner_token=
  local owner_pid_path
  local owner_token_path

  if [[ $runtime_root != /* || ! -d $runtime_root || -L $runtime_root ]]; then
    am12_evidence_lock_fail \
      "runtime root must be an absolute, existing, non-symlink directory: $runtime_root"
    return 1
  fi
  canonical_runtime_root="$(cd "$runtime_root" && pwd -P)"
  if [[ $canonical_runtime_root != "$runtime_root" ]]; then
    am12_evidence_lock_fail \
      "runtime root is not its canonical path: $runtime_root"
    return 1
  fi

  expected_build_root="$runtime_root/build"
  if [[ $build_root != "$expected_build_root" ]]; then
    am12_evidence_lock_fail \
      "build root must be exactly $expected_build_root"
    return 1
  fi
  if [[ -L $build_root || (-e $build_root && ! -d $build_root) ]]; then
    am12_evidence_lock_fail \
      "build root is a symlink or non-directory entry: $build_root"
    return 1
  fi
  if [[ ! -e $build_root ]] && ! mkdir -m 700 "$build_root"; then
    if [[ ! -d $build_root || -L $build_root ]]; then
      am12_evidence_lock_fail "could not create fixed build root: $build_root"
      return 1
    fi
  fi
  if [[ ! -d $build_root || -L $build_root ]]; then
    am12_evidence_lock_fail \
      "build root must be an existing, non-symlink directory: $build_root"
    return 1
  fi
  canonical_build_root="$(cd "$build_root" && pwd -P)"
  if [[ $canonical_build_root != "$expected_build_root" ]]; then
    am12_evidence_lock_fail \
      "build root is not its fixed canonical path: $build_root"
    return 1
  fi

  expected_lock_path="$build_root/.evidence.lock"
  if [[ ${AM12_EVIDENCE_LOCK_OWNER+x} ||
    ${AM12_EVIDENCE_LOCK_PATH+x} ]]; then
    am12_evidence_lock_fail \
      'caller supplied local lock-owner state'
    return 1
  fi

  if [[ ${AM12_EVIDENCE_LOCK_HELD+x} ||
    ${AM12_EVIDENCE_LOCK_OWNER_PID+x} ||
    ${AM12_EVIDENCE_LOCK_TOKEN+x} ]]; then
    if [[ ${AM12_EVIDENCE_LOCK_HELD:-} != "$expected_lock_path" ||
      -z ${AM12_EVIDENCE_LOCK_OWNER_PID:-} ||
      -z ${AM12_EVIDENCE_LOCK_TOKEN:-} ]]; then
      am12_evidence_lock_fail \
        'inherited evidence lock metadata is incomplete or targets another path'
      return 1
    fi
    am12_evidence_lock_validate_directory "$expected_lock_path" || return 1
    am12_evidence_lock_load_metadata "$expected_lock_path" || return 1
    if [[ $PPID != "$AM12_EVIDENCE_LOCK_OWNER_PID" ||
      $AM12_EVIDENCE_LOCK_METADATA_PID != "$AM12_EVIDENCE_LOCK_OWNER_PID" ||
      $AM12_EVIDENCE_LOCK_METADATA_TOKEN != "$AM12_EVIDENCE_LOCK_TOKEN" ]]; then
      am12_evidence_lock_fail \
        'nested lock use requires the direct owning parent and exact PID/token metadata'
      return 1
    fi
    AM12_EVIDENCE_LOCK_PATH=$expected_lock_path
    AM12_EVIDENCE_LOCK_OWNER=no
    return 0
  fi

  if ! mkdir -m 700 "$expected_lock_path"; then
    am12_evidence_lock_fail \
      "lock is already held or stale; inspect without removing it: $expected_lock_path"
    return 1
  fi
  owner_pid=$$
  owner_token="$(
    /usr/bin/od -An -N32 -tx1 /dev/urandom |
      /usr/bin/tr -d ' \n'
  )" || {
    am12_evidence_lock_cleanup_new \
      "$expected_lock_path" "$owner_pid" "$owner_token" || true
    am12_evidence_lock_fail 'could not generate an evidence lock token'
    return 1
  }
  if ((${#owner_token} != 64)) ||
    [[ $owner_token == *[!0-9a-f]* ]]; then
    am12_evidence_lock_cleanup_new \
      "$expected_lock_path" "$owner_pid" "$owner_token" || true
    am12_evidence_lock_fail \
      'generated evidence lock token is not a lowercase 256-bit value'
    return 1
  fi
  if ! am12_evidence_lock_validate_directory "$expected_lock_path"; then
    am12_evidence_lock_cleanup_new \
      "$expected_lock_path" "$owner_pid" "$owner_token" || true
    return 1
  fi
  owner_pid_path="$expected_lock_path/owner-pid"
  owner_token_path="$expected_lock_path/owner-token"
  if ! (
    umask 077
    set -o noclobber
    printf '%s\n' "$owner_pid" >"$owner_pid_path"
  ); then
    am12_evidence_lock_cleanup_new \
      "$expected_lock_path" "$owner_pid" "$owner_token" || true
    am12_evidence_lock_fail 'could not publish lock owner PID metadata'
    return 1
  fi
  if ! (
    umask 077
    set -o noclobber
    printf '%s\n' "$owner_token" >"$owner_token_path"
  ); then
    am12_evidence_lock_cleanup_new \
      "$expected_lock_path" "$owner_pid" "$owner_token" || true
    am12_evidence_lock_fail 'could not publish lock owner token metadata'
    return 1
  fi
  if ! am12_evidence_lock_load_metadata "$expected_lock_path" ||
    [[ $AM12_EVIDENCE_LOCK_METADATA_PID != "$owner_pid" ||
      $AM12_EVIDENCE_LOCK_METADATA_TOKEN != "$owner_token" ]]; then
    am12_evidence_lock_cleanup_new \
      "$expected_lock_path" "$owner_pid" "$owner_token" || true
    am12_evidence_lock_fail \
      'new evidence lock does not match its owner metadata'
    return 1
  fi

  AM12_EVIDENCE_LOCK_PATH=$expected_lock_path
  AM12_EVIDENCE_LOCK_OWNER=yes
  AM12_EVIDENCE_LOCK_HELD=$expected_lock_path
  AM12_EVIDENCE_LOCK_OWNER_PID=$owner_pid
  AM12_EVIDENCE_LOCK_TOKEN=$owner_token
  export \
    AM12_EVIDENCE_LOCK_HELD \
    AM12_EVIDENCE_LOCK_OWNER_PID \
    AM12_EVIDENCE_LOCK_TOKEN
}

am12_evidence_lock_exit() {
  local exit_status=$1
  local owner_pid_path
  local owner_token_path

  trap - EXIT HUP INT TERM
  if [[ ${AM12_EVIDENCE_LOCK_OWNER:-no} == yes ]]; then
    if [[ -z ${AM12_EVIDENCE_LOCK_PATH:-} ||
      ${AM12_EVIDENCE_LOCK_HELD:-} != "$AM12_EVIDENCE_LOCK_PATH" ||
      ${AM12_EVIDENCE_LOCK_OWNER_PID:-} != "$$" ||
      -z ${AM12_EVIDENCE_LOCK_TOKEN:-} ]]; then
      printf '%s\n' \
        'evidence lock: refusing to release inconsistent owner state' >&2
      exit_status=1
    elif ! am12_evidence_lock_validate_directory \
      "$AM12_EVIDENCE_LOCK_PATH" ||
      ! am12_evidence_lock_load_metadata "$AM12_EVIDENCE_LOCK_PATH" ||
      [[ $AM12_EVIDENCE_LOCK_METADATA_PID != "$$" ||
        $AM12_EVIDENCE_LOCK_METADATA_TOKEN != "$AM12_EVIDENCE_LOCK_TOKEN" ]]; then
      printf '%s\n' \
        'evidence lock: owner cannot authenticate lock metadata for release' >&2
      exit_status=1
    else
      owner_pid_path="$AM12_EVIDENCE_LOCK_PATH/owner-pid"
      owner_token_path="$AM12_EVIDENCE_LOCK_PATH/owner-token"
      if ! rm -f "$owner_pid_path" "$owner_token_path" ||
        ! rmdir "$AM12_EVIDENCE_LOCK_PATH"; then
        printf 'evidence lock: owner could not release %s\n' \
          "$AM12_EVIDENCE_LOCK_PATH" >&2
        exit_status=1
      fi
    fi
  fi
  exit "$exit_status"
}

am12_evidence_lock_install_traps() {
  trap 'am12_evidence_lock_exit "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
