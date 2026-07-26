#!/bin/bash
# Validate canonical evidence paths and tracked source bytes.
# Author: Timur Isaev

am12_evidence_path_error() {
  printf 'evidence path: %s\n' "$*" >&2
}

am12_evidence_sha256_stream() {
  if (($# != 0)); then
    am12_evidence_path_error 'sha256_stream takes no arguments'
    return 1
  fi
  local output
  local digest

  output="$(
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      LC_ALL=C \
      LANG=C \
      /usr/bin/shasum -a 256
  )" || {
    am12_evidence_path_error 'could not hash the input stream'
    return 1
  }
  digest=${output%% *}
  if ((${#digest} != 64)) || [[ $digest == *[!0-9a-f]* ]]; then
    am12_evidence_path_error \
      'clean shasum returned an invalid SHA-256 for the input stream'
    return 1
  fi
  printf '%s\n' "$digest"
}

am12_evidence_sha256_file() {
  if (($# != 1)); then
    am12_evidence_path_error 'sha256_file requires one path'
    return 1
  fi
  local path=$1
  local output
  local digest
  local parent
  local canonical_parent

  [[ -f $path && ! -L $path ]] || {
    am12_evidence_path_error \
      "cannot hash a missing, nonregular, or symlinked file: $path"
    return 1
  }
  parent=${path%/*}
  [[ -n $parent ]] || parent=/
  canonical_parent="$(
    cd "$parent" 2>/dev/null && pwd -P
  )" || {
    am12_evidence_path_error \
      "could not resolve the parent of the file being hashed: $path"
    return 1
  }
  [[ $path == /* && $canonical_parent == "$parent" ]] || {
    am12_evidence_path_error \
      "file being hashed is not below a canonical absolute parent: $path"
    return 1
  }
  output="$(
    /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      LC_ALL=C \
      LANG=C \
      /usr/bin/shasum -a 256 "$path"
  )" || {
    am12_evidence_path_error "could not hash file: $path"
    return 1
  }
  digest=${output%% *}
  if ((${#digest} != 64)) || [[ $digest == *[!0-9a-f]* ]]; then
    am12_evidence_path_error \
      "clean shasum returned an invalid SHA-256 for: $path"
    return 1
  fi
  printf '%s\n' "$digest"
}

am12_evidence_path_require_single_line() {
  local label=$1
  local value=$2

  case $value in
    *$'\n'* | *$'\r'*)
      am12_evidence_path_error "$label contains a line break"
      return 1
      ;;
  esac
}

am12_evidence_sanitize_git_environment() {
  if (($# != 0)); then
    am12_evidence_path_error \
      'sanitize_git_environment takes no arguments'
    return 1
  fi
  local unsafe_name=

  if [[ ${GIT_DIR+x} ]]; then
    unsafe_name=GIT_DIR
  elif [[ ${GIT_WORK_TREE+x} ]]; then
    unsafe_name=GIT_WORK_TREE
  elif [[ ${GIT_COMMON_DIR+x} ]]; then
    unsafe_name=GIT_COMMON_DIR
  elif [[ ${GIT_INDEX_FILE+x} ]]; then
    unsafe_name=GIT_INDEX_FILE
  elif [[ ${GIT_OBJECT_DIRECTORY+x} ]]; then
    unsafe_name=GIT_OBJECT_DIRECTORY
  elif [[ ${GIT_ALTERNATE_OBJECT_DIRECTORIES+x} ]]; then
    unsafe_name=GIT_ALTERNATE_OBJECT_DIRECTORIES
  elif [[ ${GIT_QUARANTINE_PATH+x} ]]; then
    unsafe_name=GIT_QUARANTINE_PATH
  elif [[ ${GIT_NAMESPACE+x} ]]; then
    unsafe_name=GIT_NAMESPACE
  elif [[ ${GIT_SHALLOW_FILE+x} ]]; then
    unsafe_name=GIT_SHALLOW_FILE
  elif [[ ${GIT_GRAFT_FILE+x} ]]; then
    unsafe_name=GIT_GRAFT_FILE
  elif [[ ${GIT_REPLACE_REF_BASE+x} ]]; then
    unsafe_name=GIT_REPLACE_REF_BASE
  elif [[ ${GIT_NO_REPLACE_OBJECTS+x} &&
    ${GIT_NO_REPLACE_OBJECTS:-} != 1 ]]; then
    unsafe_name=GIT_NO_REPLACE_OBJECTS
  elif [[ ${GIT_CONFIG+x} ]]; then
    unsafe_name=GIT_CONFIG
  elif [[ ${GIT_CONFIG_SYSTEM+x} ]]; then
    unsafe_name=GIT_CONFIG_SYSTEM
  elif [[ ${GIT_CONFIG_GLOBAL+x} &&
    ${GIT_CONFIG_GLOBAL:-} != /dev/null ]]; then
    unsafe_name=GIT_CONFIG_GLOBAL
  elif [[ ${GIT_CONFIG_NOSYSTEM+x} &&
    ${GIT_CONFIG_NOSYSTEM:-} != 1 ]]; then
    unsafe_name=GIT_CONFIG_NOSYSTEM
  elif [[ ${GIT_CONFIG_COUNT+x} ]]; then
    unsafe_name=GIT_CONFIG_COUNT
  elif [[ ${GIT_CONFIG_PARAMETERS+x} ]]; then
    unsafe_name=GIT_CONFIG_PARAMETERS
  elif [[ ${GIT_EXEC_PATH+x} ]]; then
    unsafe_name=GIT_EXEC_PATH
  elif [[ ${GIT_CEILING_DIRECTORIES+x} ]]; then
    unsafe_name=GIT_CEILING_DIRECTORIES
  elif [[ ${GIT_IMPLICIT_WORK_TREE+x} ]]; then
    unsafe_name=GIT_IMPLICIT_WORK_TREE
  fi

  if [[ -n $unsafe_name ]]; then
    am12_evidence_path_error \
      "refusing caller-supplied Git environment variable: $unsafe_name"
    return 1
  fi

  GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_NO_REPLACE_OBJECTS=1
  export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_NO_REPLACE_OBJECTS
}

am12_evidence_resolve_canonical_executable() {
  if (($# != 2)); then
    am12_evidence_path_error \
      'resolve_canonical_executable requires a path and label'
    return 1
  fi
  local input=$1
  local label=$2
  local directory
  local leaf
  local canonical_directory
  local canonical
  local candidate
  local target
  local hop_count=0

  am12_evidence_path_require_single_line "$label path" "$input" || return 1
  [[ $input == /* ]] || {
    am12_evidence_path_error "$label path must be absolute: $input"
    return 1
  }
  candidate=$input
  while :; do
    directory=${candidate%/*}
    leaf=${candidate##*/}
    [[ -n $directory ]] || directory=/
    [[ -n $leaf && $leaf != . && $leaf != .. ]] || {
      am12_evidence_path_error "$label has an invalid leaf: $candidate"
      return 1
    }
    canonical_directory="$(
      cd "$directory" 2>/dev/null && pwd -P
    )" || {
      am12_evidence_path_error \
        "could not resolve the parent directory for $label: $candidate"
      return 1
    }
    if [[ $canonical_directory == / ]]; then
      canonical="/$leaf"
    else
      canonical="$canonical_directory/$leaf"
    fi
    if [[ ! -L $canonical ]]; then
      break
    fi
    hop_count=$((hop_count + 1))
    if ((hop_count > 40)); then
      am12_evidence_path_error \
        "$label has more than 40 symlink hops: $input"
      return 1
    fi
    target="$(readlink "$canonical")" || {
      am12_evidence_path_error \
        "could not read $label symlink: $canonical"
      return 1
    }
    am12_evidence_path_require_single_line \
      "$label symlink target" "$target" || return 1
    case $target in
      /*) candidate=$target ;;
      *) candidate="$canonical_directory/$target" ;;
    esac
  done
  [[ ! -L $canonical && -f $canonical && -x $canonical ]] || {
    am12_evidence_path_error \
      "$label canonical path changed type or permissions: $canonical"
    return 1
  }
  printf '%s\n' "$canonical"
}

am12_evidence_require_canonical_directory() {
  if (($# != 2)); then
    am12_evidence_path_error \
      'require_canonical_directory requires a path and label'
    return 1
  fi
  local path=$1
  local label=$2
  local canonical

  am12_evidence_path_require_single_line "$label path" "$path" || return 1
  [[ $path == /* && -d $path && ! -L $path ]] || {
    am12_evidence_path_error \
      "$label must be an absolute, existing, non-symlink directory: $path"
    return 1
  }
  canonical="$(cd "$path" 2>/dev/null && pwd -P)" || {
    am12_evidence_path_error "could not resolve $label: $path"
    return 1
  }
  [[ $canonical == "$path" ]] || {
    am12_evidence_path_error "$label path is not canonical: $path"
    return 1
  }
}

am12_evidence_prepare_fixed_directory() {
  if (($# != 3)); then
    am12_evidence_path_error \
      'prepare_fixed_directory requires a path, parent, and label'
    return 1
  fi
  local path=$1
  local parent=$2
  local label=$3
  local leaf

  am12_evidence_require_canonical_directory "$parent" "$label parent" ||
    return 1
  am12_evidence_path_require_single_line "$label path" "$path" || return 1
  leaf=${path##*/}
  [[ -n $leaf && $leaf != . && $leaf != .. &&
    $path == "$parent/$leaf" ]] || {
    am12_evidence_path_error \
      "$label must be a direct child of its fixed parent: $path"
    return 1
  }
  if [[ -L $path || (-e $path && ! -d $path) ]]; then
    am12_evidence_path_error \
      "$label is a symlink or non-directory entry: $path"
    return 1
  fi
  if [[ ! -e $path ]]; then
    mkdir "$path" || {
      am12_evidence_path_error "could not create $label: $path"
      return 1
    }
  fi
  am12_evidence_require_canonical_directory "$path" "$label"
}

am12_evidence_require_output_leaf() {
  if (($# != 3)); then
    am12_evidence_path_error \
      'require_output_leaf requires a path, parent, and label'
    return 1
  fi
  local path=$1
  local parent=$2
  local label=$3
  local leaf

  am12_evidence_require_canonical_directory "$parent" "$label parent" ||
    return 1
  am12_evidence_path_require_single_line "$label path" "$path" || return 1
  leaf=${path##*/}
  [[ -n $leaf && $leaf != . && $leaf != .. &&
    $path == "$parent/$leaf" ]] || {
    am12_evidence_path_error \
      "$label must be a direct child of its fixed parent: $path"
    return 1
  }
  [[ ! -L $path ]] || {
    am12_evidence_path_error "$label must not be a symlink: $path"
    return 1
  }
  if [[ -e $path && ! -f $path ]]; then
    am12_evidence_path_error \
      "$label must be absent or a regular file: $path"
    return 1
  fi
  if [[ -e $path ]]; then
    local link_count

    link_count=$(/usr/bin/stat -f '%l' "$path") || {
      am12_evidence_path_error \
        "could not inspect the hard-link count for $label: $path"
      return 1
    }
    [[ $link_count == 1 ]] || {
      am12_evidence_path_error \
        "$label must not be a multiply linked file: $path"
      return 1
    }
  fi
}

am12_evidence_verify_tracked_file() {
  if (($# != 5)); then
    am12_evidence_path_error \
      'verify_tracked_file requires git, repository, commit, repository path, and worktree path'
    return 1
  fi
  local git_path=$1
  local repository=$2
  local commit=$3
  local repository_path=$4
  local worktree_path=$5
  local tree_record
  local mode
  local type
  local expected_object
  local actual_object
  local expected_parent
  local canonical_parent

  am12_evidence_require_canonical_directory \
    "$repository" 'tracked-file repository' || return 1
  tree_record="$(
    "$git_path" -C "$repository" ls-tree "$commit" -- "$repository_path"
  )" || {
    am12_evidence_path_error \
      "could not inspect tracked file: $repository_path"
    return 1
  }
  read -r mode type expected_object _ <<<"$tree_record"
  [[ $mode == 100644 || $mode == 100755 ]] || {
    am12_evidence_path_error \
      "tracked file does not have a regular-file mode: $repository_path"
    return 1
  }
  [[ $type == blob && -n $expected_object ]] || {
    am12_evidence_path_error \
      "tracked file is not a Git blob: $repository_path"
    return 1
  }
  [[ -f $worktree_path && ! -L $worktree_path ]] || {
    am12_evidence_path_error \
      "tracked worktree file is missing or symlinked: $worktree_path"
    return 1
  }
  expected_parent=${worktree_path%/*}
  canonical_parent="$(
    cd "$expected_parent" 2>/dev/null && pwd -P
  )" || {
    am12_evidence_path_error \
      "could not resolve tracked worktree parent: $worktree_path"
    return 1
  }
  [[ $canonical_parent == "$expected_parent" ]] || {
    am12_evidence_path_error \
      "tracked worktree parent resolves through a symlink: $worktree_path"
    return 1
  }
  actual_object="$(
    "$git_path" -C "$repository" hash-object --no-filters -- "$worktree_path"
  )" || {
    am12_evidence_path_error \
      "could not hash tracked worktree file: $worktree_path"
    return 1
  }
  [[ $actual_object == "$expected_object" ]] || {
    am12_evidence_path_error \
      "tracked worktree bytes differ from $commit: $repository_path"
    return 1
  }
}

am12_evidence_verify_tracked_tree() {
  if (($# != 4)); then
    am12_evidence_path_error \
      'verify_tracked_tree requires git, repository, commit, and repository prefix'
    return 1
  fi
  local git_path=$1
  local repository=$2
  local commit=$3
  local repository_prefix=$4
  local entry
  local metadata
  local repository_path
  local mode
  local type
  local expected_object
  local actual_object
  local worktree_path
  local worktree_parent
  local canonical_parent
  local prefix_worktree_path
  local tree_records
  local tree_validation_status=0
  local untracked_paths
  local file_count=0

  [[ -n $repository_prefix && $repository_prefix != /* &&
    $repository_prefix != .. &&
    $repository_prefix != ../* &&
    $repository_prefix != */../* &&
    $repository_prefix != */.. ]] || {
    am12_evidence_path_error \
      "tracked-tree prefix is invalid: $repository_prefix"
    return 1
  }
  am12_evidence_require_canonical_directory \
    "$repository" 'tracked-tree repository' || return 1
  prefix_worktree_path="$repository/$repository_prefix"
  am12_evidence_require_canonical_directory \
    "$prefix_worktree_path" 'tracked-tree worktree prefix' || return 1
  "$git_path" -C "$repository" cat-file -e \
    "$commit:$repository_prefix" || {
    am12_evidence_path_error \
      "tracked-tree prefix is absent at $commit: $repository_prefix"
    return 1
  }
  untracked_paths="$(
    "$git_path" -C "$repository" ls-files \
      --others --exclude-standard -- "$repository_prefix"
  )" || {
    am12_evidence_path_error \
      "could not inspect untracked files below: $repository_prefix"
    return 1
  }
  [[ -z $untracked_paths ]] || {
    am12_evidence_path_error \
      "tracked tree has nonignored untracked files below: $repository_prefix"
    return 1
  }

  tree_records=$(/usr/bin/mktemp /tmp/am12-evidence-tree.XXXXXX) || {
    am12_evidence_path_error \
      "could not create tracked-tree record staging for: $repository_prefix"
    return 1
  }
  [[ -f $tree_records && ! -L $tree_records ]] || {
    rm -f "$tree_records"
    am12_evidence_path_error \
      "tracked-tree record staging is not a regular file: $tree_records"
    return 1
  }
  if ! "$git_path" -C "$repository" ls-tree -r -z \
    "$commit" -- "$repository_prefix" >"$tree_records"; then
    rm -f "$tree_records"
    am12_evidence_path_error \
      "could not enumerate tracked tree below: $repository_prefix"
    return 1
  fi

  while IFS= read -r -d '' entry; do
    if [[ $entry != *$'\t'* ]]; then
      am12_evidence_path_error \
        "malformed Git tree record below: $repository_prefix"
      tree_validation_status=1
      break
    fi
    metadata=${entry%%$'\t'*}
    repository_path=${entry#*$'\t'}
    if ! am12_evidence_path_require_single_line \
      'tracked-tree repository path' "$repository_path"; then
      tree_validation_status=1
      break
    fi
    read -r mode type expected_object <<<"$metadata"
    if [[ $mode != 100644 && $mode != 100755 ]]; then
      am12_evidence_path_error \
        "tracked tree contains a nonregular mode: $repository_path"
      tree_validation_status=1
      break
    fi
    if [[ $type != blob || -z $expected_object ]]; then
      am12_evidence_path_error \
        "tracked tree contains a non-blob entry: $repository_path"
      tree_validation_status=1
      break
    fi
    worktree_path=$repository/$repository_path
    if [[ ! -f $worktree_path || -L $worktree_path ]]; then
      am12_evidence_path_error \
        "tracked worktree file is missing or symlinked: $worktree_path"
      tree_validation_status=1
      break
    fi
    worktree_parent=${worktree_path%/*}
    if ! canonical_parent="$(
      cd "$worktree_parent" 2>/dev/null && pwd -P
    )"; then
      am12_evidence_path_error \
        "could not resolve tracked worktree parent: $worktree_path"
      tree_validation_status=1
      break
    fi
    if [[ $canonical_parent != "$worktree_parent" ]]; then
      am12_evidence_path_error \
        "tracked worktree parent resolves through a symlink: $worktree_path"
      tree_validation_status=1
      break
    fi
    if ! actual_object="$(
      "$git_path" -C "$repository" hash-object \
        --no-filters -- "$worktree_path"
    )"; then
      am12_evidence_path_error \
        "could not hash tracked worktree file: $worktree_path"
      tree_validation_status=1
      break
    fi
    if [[ $actual_object != "$expected_object" ]]; then
      am12_evidence_path_error \
        "tracked worktree bytes differ from $commit: $repository_path"
      tree_validation_status=1
      break
    fi
    file_count=$((file_count + 1))
  done <"$tree_records"
  if ! rm -f "$tree_records"; then
    am12_evidence_path_error \
      "could not remove tracked-tree record staging: $tree_records"
    tree_validation_status=1
  fi
  ((tree_validation_status == 0)) || return 1
  ((file_count > 0)) || {
    am12_evidence_path_error \
      "tracked tree contains no files: $repository_prefix"
    return 1
  }
  untracked_paths="$(
    "$git_path" -C "$repository" ls-files \
      --others --exclude-standard -- "$repository_prefix"
  )" || {
    am12_evidence_path_error \
      "could not recheck untracked files below: $repository_prefix"
    return 1
  }
  [[ -z $untracked_paths ]] || {
    am12_evidence_path_error \
      "tracked tree gained nonignored untracked files below: $repository_prefix"
    return 1
  }
}

am12_evidence_materialize_tracked_tree() {
  if (($# != 5)); then
    am12_evidence_path_error \
      'materialize_tracked_tree requires git, repository, commit, repository prefix, and destination root'
    return 1
  fi
  local git_path=$1
  local repository=$2
  local commit=$3
  local repository_prefix=$4
  local destination_root=$5
  local tree_records
  local entry
  local metadata
  local repository_path
  local mode
  local type
  local expected_object
  local destination
  local destination_parent
  local canonical_parent
  local actual_object
  local file_count=0
  local materialization_status=0

  [[ -n $repository_prefix && $repository_prefix != /* &&
    $repository_prefix != .. &&
    $repository_prefix != ../* &&
    $repository_prefix != */../* &&
    $repository_prefix != */.. ]] || {
    am12_evidence_path_error \
      "materialized-tree prefix is invalid: $repository_prefix"
    return 1
  }
  am12_evidence_require_canonical_directory \
    "$repository" 'materialized-tree repository' || return 1
  am12_evidence_require_canonical_directory \
    "$destination_root" 'materialized-tree destination root' || return 1
  tree_records=$(/usr/bin/mktemp /tmp/am12-materialized-tree.XXXXXX) || {
    am12_evidence_path_error \
      "could not create materialized-tree records for: $repository_prefix"
    return 1
  }
  if ! "$git_path" -C "$repository" ls-tree -r -z \
    "$commit" -- "$repository_prefix" >"$tree_records"; then
    rm -f "$tree_records"
    am12_evidence_path_error \
      "could not enumerate materialized tree below: $repository_prefix"
    return 1
  fi

  while IFS= read -r -d '' entry; do
    if [[ $entry != *$'\t'* ]]; then
      am12_evidence_path_error \
        "malformed materialized Git record below: $repository_prefix"
      materialization_status=1
      break
    fi
    metadata=${entry%%$'\t'*}
    repository_path=${entry#*$'\t'}
    if ! am12_evidence_path_require_single_line \
      'materialized-tree repository path' "$repository_path"; then
      materialization_status=1
      break
    fi
    read -r mode type expected_object <<<"$metadata"
    if [[ $mode != 100644 && $mode != 100755 ]]; then
      am12_evidence_path_error \
        "materialized tree contains a nonregular mode: $repository_path"
      materialization_status=1
      break
    fi
    if [[ $type != blob || -z $expected_object ||
      ($repository_path != "$repository_prefix" &&
      $repository_path != "$repository_prefix/"*) ||
      $repository_path == /* ||
      $repository_path == ../* ||
      $repository_path == */../* ||
      $repository_path == */.. ]]; then
      am12_evidence_path_error \
        "materialized tree contains an invalid record: $repository_path"
      materialization_status=1
      break
    fi
    destination="$destination_root/$repository_path"
    destination_parent=${destination%/*}
    /bin/mkdir -p "$destination_parent" || {
      am12_evidence_path_error \
        "could not create materialized parent: $destination_parent"
      materialization_status=1
      break
    }
    canonical_parent="$(
      cd "$destination_parent" 2>/dev/null && pwd -P
    )" || {
      am12_evidence_path_error \
        "could not resolve materialized parent: $destination_parent"
      materialization_status=1
      break
    }
    if [[ $canonical_parent != "$destination_parent" ||
      -e $destination || -L $destination ]]; then
      am12_evidence_path_error \
        "materialized destination is unsafe or duplicated: $destination"
      materialization_status=1
      break
    fi
    if ! "$git_path" -C "$repository" cat-file blob \
      "$expected_object" >"$destination"; then
      am12_evidence_path_error \
        "could not materialize Git blob: $repository_path"
      materialization_status=1
      break
    fi
    if [[ $mode == 100755 ]]; then
      /bin/chmod 755 "$destination"
    else
      /bin/chmod 644 "$destination"
    fi
    actual_object="$(
      "$git_path" -C "$repository" hash-object \
        --no-filters -- "$destination"
    )" || {
      am12_evidence_path_error \
        "could not verify materialized blob: $repository_path"
      materialization_status=1
      break
    }
    if [[ $actual_object != "$expected_object" ]]; then
      am12_evidence_path_error \
        "materialized bytes differ from Git: $repository_path"
      materialization_status=1
      break
    fi
    file_count=$((file_count + 1))
  done <"$tree_records"
  if ! rm -f "$tree_records"; then
    am12_evidence_path_error \
      "could not remove materialized-tree records: $tree_records"
    materialization_status=1
  fi
  ((materialization_status == 0)) || return 1
  ((file_count > 0)) || {
    am12_evidence_path_error \
      "materialized tree contains no files: $repository_prefix"
    return 1
  }
}
