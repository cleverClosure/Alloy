#!/bin/bash
# Freeze the declared DXC bundle, selected Wine/FEX files, and execution policy.
# Author: Timur Isaev
set -euo pipefail

AM12_COMPILER_RUNTIME_IDENTITY_SCHEMA='com.alloy.metal12.compiler-runtime-identity.v2'
AM12_DXC_BUNDLE_IDENTITY_SCHEMA='com.alloy.metal12.dxc-bundle-identity.v1'
AM12_COMPILER_RUNTIME_IDENTITY_SCOPE='dxc-bundle-and-declared-wine-fex-selected-files-and-policy-v2'
AM12_COMPILER_RUNTIME_ENVIRONMENT_POLICY='env-i-fixed-allowlist-v1'
AM12_COMPILER_RUNTIME_PATH_POLICY='/usr/bin:/bin:/usr/sbin:/sbin'
AM12_COMPILER_RUNTIME_LC_ALL_POLICY=C
AM12_COMPILER_RUNTIME_LANG_POLICY=C
AM12_COMPILER_RUNTIME_TMPDIR_POLICY=/tmp
AM12_COMPILER_RUNTIME_DYLD_FALLBACK_LIBRARY_POLICY='unset'
AM12_COMPILER_RUNTIME_PREFIX_POLICY='unique-run-copy-with-selected-leaf-validation-v1'

am12_cri_error() {
  printf 'compiler runtime identity: %s\n' "$*" >&2
}

am12_cri_require_single_line() {
  local label=$1
  local value=$2

  case $value in
    *$'\n'* | *$'\r'*)
      am12_cri_error "$label contains a line break"
      return 1
      ;;
  esac
}

am12_cri_canonical_directory() {
  local input=$1
  local label=$2
  local canonical

  am12_cri_require_single_line "$label path" "$input" || return 1
  if [[ ! -d $input ]]; then
    am12_cri_error "$label directory is missing: $input"
    return 1
  fi
  canonical="$(cd "$input" 2>/dev/null && pwd -P)" || {
    am12_cri_error "could not resolve $label directory: $input"
    return 1
  }
  am12_cri_require_single_line "canonical $label path" "$canonical" || return 1
  printf '%s\n' "$canonical"
}

am12_cri_canonical_regular_file() {
  local input=$1
  local label=$2
  local directory
  local canonical

  am12_cri_require_single_line "$label path" "$input" || return 1
  if [[ -L $input ]]; then
    am12_cri_error "$label must not be a symlink: $input"
    return 1
  fi
  if [[ ! -f $input ]]; then
    am12_cri_error "$label is missing or not a regular file: $input"
    return 1
  fi
  directory="$(cd "$(dirname "$input")" 2>/dev/null && pwd -P)" || {
    am12_cri_error "could not resolve the parent of $label: $input"
    return 1
  }
  canonical="$directory/$(basename "$input")"
  if [[ -L $canonical ]]; then
    am12_cri_error "$label must not resolve to a symlink leaf: $canonical"
    return 1
  fi
  if [[ ! -f $canonical ]]; then
    am12_cri_error "$label resolved to a missing or nonregular file: $canonical"
    return 1
  fi
  am12_cri_require_single_line "canonical $label path" "$canonical" || return 1
  printf '%s\n' "$canonical"
}

am12_cri_require_symlink_target() {
  if (($# != 3)); then
    am12_cri_error \
      'require_symlink_target requires a path, expected target, and label'
    return 1
  fi
  local path=$1
  local expected_target=$2
  local label=$3
  local actual_target

  am12_cri_require_single_line "$label path" "$path" || return 1
  am12_cri_require_single_line \
    "$label expected target" "$expected_target" || return 1
  if [[ ! -L $path ]]; then
    am12_cri_error "$label must be a symlink: $path"
    return 1
  fi
  actual_target="$(readlink "$path")" || {
    am12_cri_error "could not read $label: $path"
    return 1
  }
  am12_cri_require_single_line "$label target" "$actual_target" || return 1
  if [[ $actual_target != "$expected_target" ]]; then
    am12_cri_error \
      "$label target must be $expected_target; found: $actual_target"
    return 1
  fi
  printf '%s\n' "$actual_target"
}

am12_cri_resolve_wine_frontend() {
  local configured=$1
  local candidate
  local directory
  local target
  local hop_count=0

  am12_cri_require_single_line 'configured Wine frontend path' "$configured" ||
    return 1
  case $configured in
    /*) candidate=$configured ;;
    *) candidate="$PWD/$configured" ;;
  esac

  while [[ -L $candidate ]]; do
    hop_count=$((hop_count + 1))
    if ((hop_count > 40)); then
      am12_cri_error "Wine frontend has too many symlink hops: $configured"
      return 1
    fi
    target="$(readlink "$candidate")" || {
      am12_cri_error "could not read Wine frontend symlink: $candidate"
      return 1
    }
    am12_cri_require_single_line 'Wine frontend symlink target' "$target" ||
      return 1
    case $target in
      /*) candidate=$target ;;
      *) candidate="$(dirname "$candidate")/$target" ;;
    esac
    directory="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || {
      am12_cri_error "could not resolve Wine frontend symlink parent: $candidate"
      return 1
    }
    candidate="$directory/$(basename "$candidate")"
  done

  if [[ ! -f $candidate || ! -x $candidate ]]; then
    am12_cri_error \
      "resolved Wine frontend is missing, nonregular, or nonexecutable: $candidate"
    return 1
  fi
  directory="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || {
    am12_cri_error "could not resolve Wine frontend parent: $candidate"
    return 1
  }
  candidate="$directory/$(basename "$candidate")"
  if [[ -L $candidate || ! -f $candidate || ! -x $candidate ]]; then
    am12_cri_error \
      "resolved Wine frontend is a symlink, nonregular, or nonexecutable: $candidate"
    return 1
  fi
  am12_cri_require_single_line 'resolved Wine frontend path' "$candidate" ||
    return 1
  printf '%s\n' "$candidate"
}

am12_cri_sha256() {
  local path=$1

  if ! declare -F am12_evidence_sha256_file >/dev/null; then
    am12_cri_error \
      'source evidence-paths.sh before freezing compiler runtime identity'
    return 1
  fi
  am12_evidence_sha256_file "$path"
}

am12_cri_parse_fex_selector() {
  local system_reg=$1
  local expected_section='[Software\\Microsoft\\Wow64\\amd64]'
  local in_section=0
  local section_count=0
  local selector_count=0
  local selector=
  local line

  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == \[* ]]; then
      in_section=0
      if [[ $line == "$expected_section" ||
        $line == "$expected_section "* ]]; then
        section_count=$((section_count + 1))
        in_section=1
      fi
      continue
    fi
    if ((in_section)) && [[ $line == @=* ]]; then
      selector_count=$((selector_count + 1))
      case $line in
        '@="'*'"')
          selector=${line#'@="'}
          selector=${selector%'"'}
          ;;
        *)
          am12_cri_error \
            "malformed default value in the Wow64 amd64 registry section"
          return 1
          ;;
      esac
    fi
  done <"$system_reg"

  if ((section_count != 1)); then
    am12_cri_error \
      "system.reg must contain exactly one Wow64 amd64 section; found $section_count"
    return 1
  fi
  if ((selector_count != 1)); then
    am12_cri_error \
      "Wow64 amd64 section must contain exactly one default selector; found $selector_count"
    return 1
  fi
  if [[ $selector != libarm64ecfex.dll ]]; then
    am12_cri_error \
      "Wow64 amd64 selector must be libarm64ecfex.dll; found: $selector"
    return 1
  fi
  printf '%s\n' "$selector"
}

am12_cri_discover() {
  local configured_dxc
  local dxc_directory
  local expected_wine_frontend
  local c_drive_resolved
  local z_drive_resolved

  declare -F am12_evidence_sha256_file >/dev/null ||
    {
      am12_cri_error \
        'source evidence-paths.sh before freezing compiler runtime identity'
      return 1
    }
  if ! command -v readlink >/dev/null 2>&1; then
    am12_cri_error 'missing required tool: readlink'
    return 1
  fi
  if [[ -n ${ALLOY_DXC:-} ]]; then
    configured_dxc=$ALLOY_DXC
  elif [[ -n ${DXC:-} ]]; then
    configured_dxc=$DXC
  else
    am12_cri_error 'set ALLOY_DXC or DXC before freezing the identity'
    return 1
  fi
  if [[ -z ${ALLOY_WINE:-} ]]; then
    am12_cri_error 'set ALLOY_WINE before freezing the identity'
    return 1
  fi
  if [[ -z ${ALLOY_FEX_PREFIX:-} ]]; then
    am12_cri_error 'set ALLOY_FEX_PREFIX before freezing the identity'
    return 1
  fi

  AM12_DXC_EXE_PATH="$(
    am12_cri_canonical_regular_file "$configured_dxc" 'DXC executable'
  )" || return 1
  if [[ $(basename "$AM12_DXC_EXE_PATH") != dxc.exe ]]; then
    am12_cri_error "DXC executable must be named dxc.exe: $AM12_DXC_EXE_PATH"
    return 1
  fi
  dxc_directory=$(dirname "$AM12_DXC_EXE_PATH")
  AM12_DXCOMPILER_DLL_PATH="$(
    am12_cri_canonical_regular_file \
      "$dxc_directory/dxcompiler.dll" 'DXC compiler library'
  )" || return 1
  AM12_DXIL_DLL_PATH="$(
    am12_cri_canonical_regular_file \
      "$dxc_directory/dxil.dll" 'DXIL validation library'
  )" || return 1

  AM12_WINE_FRONTEND_PATH="$(
    am12_cri_resolve_wine_frontend "$ALLOY_WINE"
  )" || return 1
  AM12_WINE_BUILD_ROOT="$(
    am12_cri_canonical_directory \
      "$(dirname "$AM12_WINE_FRONTEND_PATH")/../.." 'Wine build root'
  )" || return 1
  expected_wine_frontend="$AM12_WINE_BUILD_ROOT/tools/wine/wine"
  if [[ $AM12_WINE_FRONTEND_PATH != "$expected_wine_frontend" ]]; then
    am12_cri_error \
      "Wine frontend is not the expected build-tree frontend: $AM12_WINE_FRONTEND_PATH"
    return 1
  fi

  AM12_WINE_NTDLL_UNIX_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/ntdll/ntdll.so" 'Wine ntdll Unix library'
  )" || return 1
  AM12_WINE_NTDLL_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/ntdll/aarch64-windows/ntdll.dll" \
      'Wine ntdll PE library'
  )" || return 1
  AM12_WINE_WOW64_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/wow64/aarch64-windows/wow64.dll" \
      'Wine wow64 PE library'
  )" || return 1
  AM12_WINE_ADVAPI32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/advapi32/aarch64-windows/advapi32.dll" \
      'Wine advapi32 PE library'
  )" || return 1
  AM12_WINE_KERNEL32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/kernel32/aarch64-windows/kernel32.dll" \
      'Wine kernel32 PE library'
  )" || return 1
  AM12_WINE_KERNELBASE_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/kernelbase/aarch64-windows/kernelbase.dll" \
      'Wine kernelbase PE library'
  )" || return 1
  AM12_WINE_OLEAUT32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/oleaut32/aarch64-windows/oleaut32.dll" \
      'Wine oleaut32 PE library'
  )" || return 1
  AM12_WINE_OLE32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/ole32/aarch64-windows/ole32.dll" \
      'Wine ole32 PE library'
  )" || return 1
  AM12_WINE_VERSION_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/version/aarch64-windows/version.dll" \
      'Wine version PE library'
  )" || return 1
  AM12_WINE_UCRTBASE_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/ucrtbase/aarch64-windows/ucrtbase.dll" \
      'Wine ucrtbase PE library'
  )" || return 1
  AM12_WINESERVER_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/server/wineserver" 'Wine server'
  )" || return 1
  AM12_WINE_BUILD_FEX_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll" \
      'Wine build FEX PE library'
  )" || return 1
  AM12_WINE_FEX_UNIX_BRIDGE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_BUILD_ROOT/dlls/libarm64ecfex/libarm64ecfex.so" \
      'Wine FEX Unix bridge'
  )" || return 1

  AM12_FEX_RUNTIME_ROOT_PATH="$(
    am12_cri_canonical_directory "$ALLOY_FEX_PREFIX" 'FEX runtime root'
  )" || return 1
  AM12_WINE_PREFIX_PATH="$(
    am12_cri_canonical_directory \
      "$AM12_FEX_RUNTIME_ROOT_PATH/prefix-gui" 'Wine prefix'
  )" || return 1
  AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH=$AM12_WINE_PREFIX_PATH
  AM12_FEX_SYSTEM_REG_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_PATH/system.reg" 'Wine prefix system.reg'
  )" || return 1
  AM12_FEX_USER_REG_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_PATH/user.reg" 'Wine prefix user.reg'
  )" || return 1
  AM12_FEX_USERDEF_REG_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_PATH/userdef.reg" 'Wine prefix userdef.reg'
  )" || return 1
  AM12_WINE_PREFIX_C_DRIVE_LINK_PATH="$AM12_WINE_PREFIX_PATH/dosdevices/c:"
  AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET="$(
    am12_cri_require_symlink_target \
      "$AM12_WINE_PREFIX_C_DRIVE_LINK_PATH" ../drive_c \
      'Wine prefix c: mapping'
  )" || return 1
  c_drive_resolved="$(
    cd "$(dirname "$AM12_WINE_PREFIX_C_DRIVE_LINK_PATH")/$AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET" &&
      pwd -P
  )" || {
    am12_cri_error 'could not resolve the Wine prefix c: mapping'
    return 1
  }
  AM12_WINE_PREFIX_C_DRIVE_PATH="$AM12_WINE_PREFIX_PATH/drive_c"
  if [[ $c_drive_resolved != "$AM12_WINE_PREFIX_C_DRIVE_PATH" ||
    ! -d $AM12_WINE_PREFIX_C_DRIVE_PATH ||
    -L $AM12_WINE_PREFIX_C_DRIVE_PATH ]]; then
    am12_cri_error \
      'Wine prefix c: mapping does not resolve to the fixed drive_c directory'
    return 1
  fi
  AM12_WINE_PREFIX_Z_DRIVE_LINK_PATH="$AM12_WINE_PREFIX_PATH/dosdevices/z:"
  AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET="$(
    am12_cri_require_symlink_target \
      "$AM12_WINE_PREFIX_Z_DRIVE_LINK_PATH" / \
      'Wine prefix z: mapping'
  )" || return 1
  z_drive_resolved="$(
    cd "$AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET" && pwd -P
  )" || {
    am12_cri_error 'could not resolve the Wine prefix z: mapping'
    return 1
  }
  AM12_WINE_PREFIX_Z_DRIVE_PATH=/
  if [[ $z_drive_resolved != "$AM12_WINE_PREFIX_Z_DRIVE_PATH" ]]; then
    am12_cri_error 'Wine prefix z: mapping does not resolve to /'
    return 1
  fi
  AM12_WINE_PREFIX_NTDLL_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/ntdll.dll" \
      'Wine prefix ntdll library'
  )" || return 1
  AM12_WINE_PREFIX_WOW64_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/wow64.dll" \
      'Wine prefix wow64 library'
  )" || return 1
  AM12_WINE_PREFIX_ADVAPI32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/advapi32.dll" \
      'Wine prefix advapi32 library'
  )" || return 1
  AM12_WINE_PREFIX_KERNEL32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/kernel32.dll" \
      'Wine prefix kernel32 library'
  )" || return 1
  AM12_WINE_PREFIX_KERNELBASE_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/kernelbase.dll" \
      'Wine prefix kernelbase library'
  )" || return 1
  AM12_WINE_PREFIX_OLEAUT32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/oleaut32.dll" \
      'Wine prefix oleaut32 library'
  )" || return 1
  AM12_WINE_PREFIX_OLE32_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/ole32.dll" \
      'Wine prefix ole32 library'
  )" || return 1
  AM12_WINE_PREFIX_VERSION_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/version.dll" \
      'Wine prefix version library'
  )" || return 1
  AM12_WINE_PREFIX_UCRTBASE_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH/windows/system32/ucrtbase.dll" \
      'Wine prefix ucrtbase library'
  )" || return 1
  AM12_FEX_PREFIX_PE_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_PATH/drive_c/windows/system32/libarm64ecfex.dll" \
      'Wine prefix FEX PE library'
  )" || return 1
  AM12_FEX_PREFIX_XTAJIT64_PATH="$(
    am12_cri_canonical_regular_file \
      "$AM12_WINE_PREFIX_PATH/drive_c/windows/system32/xtajit64.dll" \
      'Wine prefix xtajit64 library'
  )" || return 1
  AM12_WINE_PREFIX_LIBARM64ECFEX_PE_PATH=$AM12_FEX_PREFIX_PE_PATH
  AM12_WINE_PREFIX_XTAJIT64_PE_PATH=$AM12_FEX_PREFIX_XTAJIT64_PATH

  AM12_FEX_SELECTOR="$(
    am12_cri_parse_fex_selector "$AM12_FEX_SYSTEM_REG_PATH"
  )" || return 1
  AM12_WINE_DLL_OVERRIDES='xtajit64=n'

  AM12_DXC_EXE_SHA256="$(am12_cri_sha256 "$AM12_DXC_EXE_PATH")" || return 1
  AM12_DXCOMPILER_DLL_SHA256="$(
    am12_cri_sha256 "$AM12_DXCOMPILER_DLL_PATH"
  )" || return 1
  AM12_DXIL_DLL_SHA256="$(am12_cri_sha256 "$AM12_DXIL_DLL_PATH")" || return 1
  AM12_WINE_FRONTEND_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_FRONTEND_PATH"
  )" || return 1
  AM12_WINE_NTDLL_UNIX_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_NTDLL_UNIX_PATH"
  )" || return 1
  AM12_WINE_NTDLL_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_NTDLL_PE_PATH"
  )" || return 1
  AM12_WINE_WOW64_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_WOW64_PE_PATH"
  )" || return 1
  AM12_WINE_ADVAPI32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_ADVAPI32_PE_PATH"
  )" || return 1
  AM12_WINE_KERNEL32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_KERNEL32_PE_PATH"
  )" || return 1
  AM12_WINE_KERNELBASE_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_KERNELBASE_PE_PATH"
  )" || return 1
  AM12_WINE_OLEAUT32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_OLEAUT32_PE_PATH"
  )" || return 1
  AM12_WINE_OLE32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_OLE32_PE_PATH"
  )" || return 1
  AM12_WINE_VERSION_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_VERSION_PE_PATH"
  )" || return 1
  AM12_WINE_UCRTBASE_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_UCRTBASE_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_NTDLL_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_NTDLL_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_WOW64_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_WOW64_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_ADVAPI32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_ADVAPI32_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_KERNEL32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_KERNEL32_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_KERNELBASE_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_KERNELBASE_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_OLEAUT32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_OLEAUT32_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_OLE32_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_OLE32_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_VERSION_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_VERSION_PE_PATH"
  )" || return 1
  AM12_WINE_PREFIX_UCRTBASE_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_PREFIX_UCRTBASE_PE_PATH"
  )" || return 1
  AM12_WINESERVER_SHA256="$(am12_cri_sha256 "$AM12_WINESERVER_PATH")" ||
    return 1
  AM12_WINE_BUILD_FEX_PE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_BUILD_FEX_PE_PATH"
  )" || return 1
  AM12_WINE_FEX_UNIX_BRIDGE_SHA256="$(
    am12_cri_sha256 "$AM12_WINE_FEX_UNIX_BRIDGE_PATH"
  )" || return 1
  AM12_FEX_PREFIX_PE_SHA256="$(
    am12_cri_sha256 "$AM12_FEX_PREFIX_PE_PATH"
  )" || return 1
  AM12_FEX_PREFIX_XTAJIT64_SHA256="$(
    am12_cri_sha256 "$AM12_FEX_PREFIX_XTAJIT64_PATH"
  )" || return 1
  AM12_WINE_PREFIX_LIBARM64ECFEX_PE_SHA256=$AM12_FEX_PREFIX_PE_SHA256
  AM12_WINE_PREFIX_XTAJIT64_PE_SHA256=$AM12_FEX_PREFIX_XTAJIT64_SHA256
  AM12_FEX_SYSTEM_REG_SHA256="$(
    am12_cri_sha256 "$AM12_FEX_SYSTEM_REG_PATH"
  )" || return 1
  AM12_FEX_USER_REG_SHA256="$(
    am12_cri_sha256 "$AM12_FEX_USER_REG_PATH"
  )" || return 1
  AM12_FEX_USERDEF_REG_SHA256="$(
    am12_cri_sha256 "$AM12_FEX_USERDEF_REG_PATH"
  )" || return 1

  if [[ $AM12_WINE_BUILD_FEX_PE_SHA256 != "$AM12_FEX_PREFIX_PE_SHA256" ]]; then
    am12_cri_error \
      'Wine build and prefix libarm64ecfex.dll hashes do not match'
    return 1
  fi
}

am12_compiler_runtime_identity_emit_nul() {
  printf '%s\0' \
    'schema' "$AM12_COMPILER_RUNTIME_IDENTITY_SCHEMA" \
    'identity_scope' "$AM12_COMPILER_RUNTIME_IDENTITY_SCOPE" \
    'environment_policy' "$AM12_COMPILER_RUNTIME_ENVIRONMENT_POLICY" \
    'path_policy' "$AM12_COMPILER_RUNTIME_PATH_POLICY" \
    'lc_all_policy' "$AM12_COMPILER_RUNTIME_LC_ALL_POLICY" \
    'lang_policy' "$AM12_COMPILER_RUNTIME_LANG_POLICY" \
    'tmpdir_policy' "$AM12_COMPILER_RUNTIME_TMPDIR_POLICY" \
    'dyld_fallback_library_policy' \
    "$AM12_COMPILER_RUNTIME_DYLD_FALLBACK_LIBRARY_POLICY" \
    'prefix_policy' "$AM12_COMPILER_RUNTIME_PREFIX_POLICY" \
    'dxc_bundle_identity_schema' "$AM12_DXC_BUNDLE_IDENTITY_SCHEMA" \
    'dxc_bundle_identity_sha256' "$AM12_DXC_BUNDLE_IDENTITY_SHA256" \
    'dxc_exe_path' "$AM12_DXC_EXE_PATH" \
    'dxc_exe_sha256' "$AM12_DXC_EXE_SHA256" \
    'dxcompiler_dll_path' "$AM12_DXCOMPILER_DLL_PATH" \
    'dxcompiler_dll_sha256' "$AM12_DXCOMPILER_DLL_SHA256" \
    'dxil_dll_path' "$AM12_DXIL_DLL_PATH" \
    'dxil_dll_sha256' "$AM12_DXIL_DLL_SHA256" \
    'wine_frontend_path' "$AM12_WINE_FRONTEND_PATH" \
    'wine_frontend_sha256' "$AM12_WINE_FRONTEND_SHA256" \
    'wine_build_root' "$AM12_WINE_BUILD_ROOT" \
    'wine_ntdll_unix_path' "$AM12_WINE_NTDLL_UNIX_PATH" \
    'wine_ntdll_unix_sha256' "$AM12_WINE_NTDLL_UNIX_SHA256" \
    'wine_ntdll_pe_path' "$AM12_WINE_NTDLL_PE_PATH" \
    'wine_ntdll_pe_sha256' "$AM12_WINE_NTDLL_PE_SHA256" \
    'wine_wow64_pe_path' "$AM12_WINE_WOW64_PE_PATH" \
    'wine_wow64_pe_sha256' "$AM12_WINE_WOW64_PE_SHA256" \
    'wine_advapi32_pe_path' "$AM12_WINE_ADVAPI32_PE_PATH" \
    'wine_advapi32_pe_sha256' "$AM12_WINE_ADVAPI32_PE_SHA256" \
    'wine_kernel32_pe_path' "$AM12_WINE_KERNEL32_PE_PATH" \
    'wine_kernel32_pe_sha256' "$AM12_WINE_KERNEL32_PE_SHA256" \
    'wine_kernelbase_pe_path' "$AM12_WINE_KERNELBASE_PE_PATH" \
    'wine_kernelbase_pe_sha256' "$AM12_WINE_KERNELBASE_PE_SHA256" \
    'wine_oleaut32_pe_path' "$AM12_WINE_OLEAUT32_PE_PATH" \
    'wine_oleaut32_pe_sha256' "$AM12_WINE_OLEAUT32_PE_SHA256" \
    'wine_ole32_pe_path' "$AM12_WINE_OLE32_PE_PATH" \
    'wine_ole32_pe_sha256' "$AM12_WINE_OLE32_PE_SHA256" \
    'wine_version_pe_path' "$AM12_WINE_VERSION_PE_PATH" \
    'wine_version_pe_sha256' "$AM12_WINE_VERSION_PE_SHA256" \
    'wine_ucrtbase_pe_path' "$AM12_WINE_UCRTBASE_PE_PATH" \
    'wine_ucrtbase_pe_sha256' "$AM12_WINE_UCRTBASE_PE_SHA256" \
    'wineserver_path' "$AM12_WINESERVER_PATH" \
    'wineserver_sha256' "$AM12_WINESERVER_SHA256" \
    'wine_build_fex_pe_path' "$AM12_WINE_BUILD_FEX_PE_PATH" \
    'wine_build_fex_pe_sha256' "$AM12_WINE_BUILD_FEX_PE_SHA256" \
    'wine_fex_unix_bridge_path' "$AM12_WINE_FEX_UNIX_BRIDGE_PATH" \
    'wine_fex_unix_bridge_sha256' "$AM12_WINE_FEX_UNIX_BRIDGE_SHA256" \
    'fex_runtime_root_path' "$AM12_FEX_RUNTIME_ROOT_PATH" \
    'wine_prefix_path' "$AM12_WINE_PREFIX_PATH" \
    'wine_prefix_template_path' \
    "$AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH" \
    'fex_system_reg_path' "$AM12_FEX_SYSTEM_REG_PATH" \
    'fex_system_reg_sha256' "$AM12_FEX_SYSTEM_REG_SHA256" \
    'fex_user_reg_path' "$AM12_FEX_USER_REG_PATH" \
    'fex_user_reg_sha256' "$AM12_FEX_USER_REG_SHA256" \
    'fex_userdef_reg_path' "$AM12_FEX_USERDEF_REG_PATH" \
    'fex_userdef_reg_sha256' "$AM12_FEX_USERDEF_REG_SHA256" \
    'fex_selector' "$AM12_FEX_SELECTOR" \
    'wine_prefix_c_drive_link_path' \
    "$AM12_WINE_PREFIX_C_DRIVE_LINK_PATH" \
    'wine_prefix_c_drive_link_target' \
    "$AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET" \
    'wine_prefix_c_drive_path' "$AM12_WINE_PREFIX_C_DRIVE_PATH" \
    'wine_prefix_z_drive_link_path' \
    "$AM12_WINE_PREFIX_Z_DRIVE_LINK_PATH" \
    'wine_prefix_z_drive_link_target' \
    "$AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET" \
    'wine_prefix_z_drive_path' "$AM12_WINE_PREFIX_Z_DRIVE_PATH" \
    'wine_prefix_ntdll_pe_path' "$AM12_WINE_PREFIX_NTDLL_PE_PATH" \
    'wine_prefix_ntdll_pe_sha256' "$AM12_WINE_PREFIX_NTDLL_PE_SHA256" \
    'wine_prefix_wow64_pe_path' "$AM12_WINE_PREFIX_WOW64_PE_PATH" \
    'wine_prefix_wow64_pe_sha256' "$AM12_WINE_PREFIX_WOW64_PE_SHA256" \
    'wine_prefix_advapi32_pe_path' "$AM12_WINE_PREFIX_ADVAPI32_PE_PATH" \
    'wine_prefix_advapi32_pe_sha256' \
    "$AM12_WINE_PREFIX_ADVAPI32_PE_SHA256" \
    'wine_prefix_kernel32_pe_path' "$AM12_WINE_PREFIX_KERNEL32_PE_PATH" \
    'wine_prefix_kernel32_pe_sha256' \
    "$AM12_WINE_PREFIX_KERNEL32_PE_SHA256" \
    'wine_prefix_kernelbase_pe_path' \
    "$AM12_WINE_PREFIX_KERNELBASE_PE_PATH" \
    'wine_prefix_kernelbase_pe_sha256' \
    "$AM12_WINE_PREFIX_KERNELBASE_PE_SHA256" \
    'wine_prefix_oleaut32_pe_path' "$AM12_WINE_PREFIX_OLEAUT32_PE_PATH" \
    'wine_prefix_oleaut32_pe_sha256' \
    "$AM12_WINE_PREFIX_OLEAUT32_PE_SHA256" \
    'wine_prefix_ole32_pe_path' "$AM12_WINE_PREFIX_OLE32_PE_PATH" \
    'wine_prefix_ole32_pe_sha256' "$AM12_WINE_PREFIX_OLE32_PE_SHA256" \
    'wine_prefix_version_pe_path' "$AM12_WINE_PREFIX_VERSION_PE_PATH" \
    'wine_prefix_version_pe_sha256' \
    "$AM12_WINE_PREFIX_VERSION_PE_SHA256" \
    'wine_prefix_ucrtbase_pe_path' "$AM12_WINE_PREFIX_UCRTBASE_PE_PATH" \
    'wine_prefix_ucrtbase_pe_sha256' \
    "$AM12_WINE_PREFIX_UCRTBASE_PE_SHA256" \
    'wine_prefix_libarm64ecfex_pe_path' \
    "$AM12_WINE_PREFIX_LIBARM64ECFEX_PE_PATH" \
    'wine_prefix_libarm64ecfex_pe_sha256' \
    "$AM12_WINE_PREFIX_LIBARM64ECFEX_PE_SHA256" \
    'wine_prefix_xtajit64_pe_path' "$AM12_WINE_PREFIX_XTAJIT64_PE_PATH" \
    'wine_prefix_xtajit64_pe_sha256' \
    "$AM12_WINE_PREFIX_XTAJIT64_PE_SHA256" \
    'fex_prefix_pe_path' "$AM12_FEX_PREFIX_PE_PATH" \
    'fex_prefix_pe_sha256' "$AM12_FEX_PREFIX_PE_SHA256" \
    'fex_prefix_xtajit64_path' "$AM12_FEX_PREFIX_XTAJIT64_PATH" \
    'fex_prefix_xtajit64_sha256' "$AM12_FEX_PREFIX_XTAJIT64_SHA256" \
    'wine_dll_overrides' "$AM12_WINE_DLL_OVERRIDES"
}

am12_compiler_runtime_dxc_bundle_emit_nul() {
  printf '%s\0' \
    'schema' "$AM12_DXC_BUNDLE_IDENTITY_SCHEMA" \
    'dxc_exe_path' "$AM12_DXC_EXE_PATH" \
    'dxc_exe_sha256' "$AM12_DXC_EXE_SHA256" \
    'dxcompiler_dll_path' "$AM12_DXCOMPILER_DLL_PATH" \
    'dxcompiler_dll_sha256' "$AM12_DXCOMPILER_DLL_SHA256" \
    'dxil_dll_path' "$AM12_DXIL_DLL_PATH" \
    'dxil_dll_sha256' "$AM12_DXIL_DLL_SHA256"
}

am12_compiler_runtime_calculate_dxc_bundle() {
  local digest

  digest="$(
    am12_compiler_runtime_dxc_bundle_emit_nul |
      am12_evidence_sha256_stream
  )" || {
    am12_cri_error 'could not calculate the DXC bundle aggregate'
    return 1
  }
  if ((${#digest} != 64)) || [[ $digest == *[!0-9a-f]* ]]; then
    am12_cri_error 'DXC bundle aggregate is not a valid SHA-256'
    return 1
  fi
  AM12_DXC_BUNDLE_IDENTITY_SHA256=$digest
  AM12_DXC_BUNDLE_SHA256=$digest
}

am12_compiler_runtime_identity_calculate() {
  local digest

  am12_compiler_runtime_calculate_dxc_bundle || return 1
  digest="$(
    am12_compiler_runtime_identity_emit_nul |
      am12_evidence_sha256_stream
  )" || {
    am12_cri_error 'could not calculate the aggregate identity'
    return 1
  }
  if ((${#digest} != 64)) || [[ $digest == *[!0-9a-f]* ]]; then
    am12_cri_error 'aggregate identity is not a valid SHA-256'
    return 1
  fi
  AM12_COMPILER_RUNTIME_IDENTITY_SHA256=$digest
}

am12_cri_export_snapshot() {
  export \
    AM12_COMPILER_RUNTIME_IDENTITY_SCHEMA \
    AM12_COMPILER_RUNTIME_IDENTITY_SHA256 \
    AM12_COMPILER_RUNTIME_IDENTITY_SCOPE \
    AM12_COMPILER_RUNTIME_ENVIRONMENT_POLICY \
    AM12_COMPILER_RUNTIME_PATH_POLICY \
    AM12_COMPILER_RUNTIME_LC_ALL_POLICY \
    AM12_COMPILER_RUNTIME_LANG_POLICY \
    AM12_COMPILER_RUNTIME_TMPDIR_POLICY \
    AM12_COMPILER_RUNTIME_DYLD_FALLBACK_LIBRARY_POLICY \
    AM12_COMPILER_RUNTIME_PREFIX_POLICY \
    AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH \
    AM12_DXC_BUNDLE_IDENTITY_SCHEMA \
    AM12_DXC_BUNDLE_IDENTITY_SHA256 \
    AM12_DXC_BUNDLE_SHA256 \
    AM12_DXC_EXE_PATH \
    AM12_DXC_EXE_SHA256 \
    AM12_DXCOMPILER_DLL_PATH \
    AM12_DXCOMPILER_DLL_SHA256 \
    AM12_DXIL_DLL_PATH \
    AM12_DXIL_DLL_SHA256 \
    AM12_WINE_FRONTEND_PATH \
    AM12_WINE_FRONTEND_SHA256 \
    AM12_WINE_BUILD_ROOT \
    AM12_WINE_NTDLL_UNIX_PATH \
    AM12_WINE_NTDLL_UNIX_SHA256 \
    AM12_WINE_NTDLL_PE_PATH \
    AM12_WINE_NTDLL_PE_SHA256 \
    AM12_WINE_WOW64_PE_PATH \
    AM12_WINE_WOW64_PE_SHA256 \
    AM12_WINE_ADVAPI32_PE_PATH \
    AM12_WINE_ADVAPI32_PE_SHA256 \
    AM12_WINE_KERNEL32_PE_PATH \
    AM12_WINE_KERNEL32_PE_SHA256 \
    AM12_WINE_KERNELBASE_PE_PATH \
    AM12_WINE_KERNELBASE_PE_SHA256 \
    AM12_WINE_OLEAUT32_PE_PATH \
    AM12_WINE_OLEAUT32_PE_SHA256 \
    AM12_WINE_OLE32_PE_PATH \
    AM12_WINE_OLE32_PE_SHA256 \
    AM12_WINE_VERSION_PE_PATH \
    AM12_WINE_VERSION_PE_SHA256 \
    AM12_WINE_UCRTBASE_PE_PATH \
    AM12_WINE_UCRTBASE_PE_SHA256 \
    AM12_WINESERVER_PATH \
    AM12_WINESERVER_SHA256 \
    AM12_WINE_BUILD_FEX_PE_PATH \
    AM12_WINE_BUILD_FEX_PE_SHA256 \
    AM12_WINE_FEX_UNIX_BRIDGE_PATH \
    AM12_WINE_FEX_UNIX_BRIDGE_SHA256 \
    AM12_FEX_RUNTIME_ROOT_PATH \
    AM12_WINE_PREFIX_PATH \
    AM12_FEX_SYSTEM_REG_PATH \
    AM12_FEX_SYSTEM_REG_SHA256 \
    AM12_FEX_USER_REG_PATH \
    AM12_FEX_USER_REG_SHA256 \
    AM12_FEX_USERDEF_REG_PATH \
    AM12_FEX_USERDEF_REG_SHA256 \
    AM12_FEX_SELECTOR \
    AM12_WINE_PREFIX_C_DRIVE_LINK_PATH \
    AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET \
    AM12_WINE_PREFIX_C_DRIVE_PATH \
    AM12_WINE_PREFIX_Z_DRIVE_LINK_PATH \
    AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET \
    AM12_WINE_PREFIX_Z_DRIVE_PATH \
    AM12_WINE_PREFIX_NTDLL_PE_PATH \
    AM12_WINE_PREFIX_NTDLL_PE_SHA256 \
    AM12_WINE_PREFIX_WOW64_PE_PATH \
    AM12_WINE_PREFIX_WOW64_PE_SHA256 \
    AM12_WINE_PREFIX_ADVAPI32_PE_PATH \
    AM12_WINE_PREFIX_ADVAPI32_PE_SHA256 \
    AM12_WINE_PREFIX_KERNEL32_PE_PATH \
    AM12_WINE_PREFIX_KERNEL32_PE_SHA256 \
    AM12_WINE_PREFIX_KERNELBASE_PE_PATH \
    AM12_WINE_PREFIX_KERNELBASE_PE_SHA256 \
    AM12_WINE_PREFIX_OLEAUT32_PE_PATH \
    AM12_WINE_PREFIX_OLEAUT32_PE_SHA256 \
    AM12_WINE_PREFIX_OLE32_PE_PATH \
    AM12_WINE_PREFIX_OLE32_PE_SHA256 \
    AM12_WINE_PREFIX_VERSION_PE_PATH \
    AM12_WINE_PREFIX_VERSION_PE_SHA256 \
    AM12_WINE_PREFIX_UCRTBASE_PE_PATH \
    AM12_WINE_PREFIX_UCRTBASE_PE_SHA256 \
    AM12_WINE_PREFIX_LIBARM64ECFEX_PE_PATH \
    AM12_WINE_PREFIX_LIBARM64ECFEX_PE_SHA256 \
    AM12_WINE_PREFIX_XTAJIT64_PE_PATH \
    AM12_WINE_PREFIX_XTAJIT64_PE_SHA256 \
    AM12_FEX_PREFIX_PE_PATH \
    AM12_FEX_PREFIX_PE_SHA256 \
    AM12_FEX_PREFIX_XTAJIT64_PATH \
    AM12_FEX_PREFIX_XTAJIT64_SHA256 \
    AM12_WINE_DLL_OVERRIDES
}

am12_compiler_runtime_freeze() {
  if (($# != 0)); then
    am12_cri_error 'freeze takes no arguments'
    return 1
  fi
  if [[ ${AM12_CRI_FROZEN:-0} == 1 ]]; then
    am12_cri_error 'identity is already frozen in this shell'
    return 1
  fi
  am12_cri_discover || return 1
  am12_compiler_runtime_identity_calculate || return 1
  AM12_CRI_FROZEN_IDENTITY_SHA256=$AM12_COMPILER_RUNTIME_IDENTITY_SHA256
  AM12_CRI_FROZEN=1
  am12_cri_export_snapshot
}

am12_compiler_runtime_recheck() {
  local frozen_identity
  local current_identity

  if (($# != 0)); then
    am12_cri_error 'recheck takes no arguments'
    return 1
  fi
  if [[ ${AM12_CRI_FROZEN:-0} != 1 ||
    -z ${AM12_CRI_FROZEN_IDENTITY_SHA256:-} ]]; then
    am12_cri_error 'freeze the identity before rechecking it'
    return 1
  fi
  frozen_identity=$AM12_CRI_FROZEN_IDENTITY_SHA256
  current_identity="$(
    am12_cri_discover || exit 1
    am12_compiler_runtime_identity_calculate || exit 1
    printf '%s\n' "$AM12_COMPILER_RUNTIME_IDENTITY_SHA256"
  )" || {
    am12_cri_error 'could not transactionally recheck the frozen identity'
    return 1
  }
  if [[ $current_identity != "$frozen_identity" ]]; then
    am12_cri_error \
      "identity changed: froze $frozen_identity, now $current_identity"
    return 1
  fi
}

am12_compiler_runtime_verify_private_dxc_bundle() {
  if [[ ${AM12_CRI_FROZEN:-0} != 1 ||
    -z ${AM12_PRIVATE_DXC_ROOT:-} ]]; then
    am12_cri_error 'materialize the private DXC bundle before verifying it'
    return 1
  fi
  am12_evidence_require_canonical_directory \
    "$AM12_PRIVATE_DXC_ROOT" 'private DXC bundle' || return 1
  if [[ $(am12_cri_sha256 "$AM12_PRIVATE_DXC_EXE_PATH") != "$AM12_DXC_EXE_SHA256" ||
  $(am12_cri_sha256 "$AM12_PRIVATE_DXCOMPILER_DLL_PATH") != "$AM12_DXCOMPILER_DLL_SHA256" ||
  $(am12_cri_sha256 "$AM12_PRIVATE_DXIL_DLL_PATH") != "$AM12_DXIL_DLL_SHA256" ]]; then
    am12_cri_error 'private DXC bundle differs from the frozen source bundle'
    return 1
  fi
}

am12_compiler_runtime_materialize_private_dxc_bundle() {
  if (($# != 1)); then
    am12_cri_error \
      'materialize_private_dxc_bundle requires one destination directory'
    return 1
  fi
  local destination=$1
  local destination_parent=${destination%/*}

  if [[ ${AM12_CRI_FROZEN:-0} != 1 ]]; then
    am12_cri_error 'freeze the identity before materializing a DXC bundle'
    return 1
  fi
  am12_evidence_require_canonical_directory \
    "$destination_parent" 'private DXC bundle parent' || return 1
  if [[ $destination != "$destination_parent/"* ||
    -e $destination || -L $destination ]]; then
    am12_cri_error \
      "private DXC bundle destination is unsafe or already exists: $destination"
    return 1
  fi
  /bin/mkdir -m 700 "$destination" || {
    am12_cri_error \
      "could not create private DXC bundle destination: $destination"
    return 1
  }
  AM12_PRIVATE_DXC_ROOT=$destination
  AM12_PRIVATE_DXC_EXE_PATH="$destination/dxc.exe"
  AM12_PRIVATE_DXCOMPILER_DLL_PATH="$destination/dxcompiler.dll"
  AM12_PRIVATE_DXIL_DLL_PATH="$destination/dxil.dll"
  COPYFILE_DISABLE=1 /bin/cp -p \
    "$AM12_DXC_EXE_PATH" "$AM12_PRIVATE_DXC_EXE_PATH" || return 1
  COPYFILE_DISABLE=1 /bin/cp -p \
    "$AM12_DXCOMPILER_DLL_PATH" "$AM12_PRIVATE_DXCOMPILER_DLL_PATH" ||
    return 1
  COPYFILE_DISABLE=1 /bin/cp -p \
    "$AM12_DXIL_DLL_PATH" "$AM12_PRIVATE_DXIL_DLL_PATH" || return 1
  /bin/chmod 500 "$AM12_PRIVATE_DXC_EXE_PATH"
  /bin/chmod 400 \
    "$AM12_PRIVATE_DXCOMPILER_DLL_PATH" "$AM12_PRIVATE_DXIL_DLL_PATH"
  am12_compiler_runtime_verify_private_dxc_bundle
}

am12_compiler_runtime_reset() {
  if (($# != 0)); then
    am12_cri_error 'reset takes no arguments'
    return 1
  fi
  AM12_CRI_FROZEN=0
  unset \
    AM12_CRI_FROZEN_IDENTITY_SHA256 \
    AM12_PRIVATE_DXC_ROOT \
    AM12_PRIVATE_DXC_EXE_PATH \
    AM12_PRIVATE_DXCOMPILER_DLL_PATH \
    AM12_PRIVATE_DXIL_DLL_PATH \
    AM12_COMPILER_RUNTIME_IDENTITY_SHA256 \
    AM12_DXC_BUNDLE_IDENTITY_SHA256 \
    AM12_DXC_BUNDLE_SHA256 \
    AM12_DXC_EXE_PATH \
    AM12_DXC_EXE_SHA256 \
    AM12_DXCOMPILER_DLL_PATH \
    AM12_DXCOMPILER_DLL_SHA256 \
    AM12_DXIL_DLL_PATH \
    AM12_DXIL_DLL_SHA256 \
    AM12_WINE_FRONTEND_PATH \
    AM12_WINE_FRONTEND_SHA256 \
    AM12_WINE_BUILD_ROOT \
    AM12_WINE_NTDLL_UNIX_PATH \
    AM12_WINE_NTDLL_UNIX_SHA256 \
    AM12_WINE_NTDLL_PE_PATH \
    AM12_WINE_NTDLL_PE_SHA256 \
    AM12_WINE_WOW64_PE_PATH \
    AM12_WINE_WOW64_PE_SHA256 \
    AM12_WINE_ADVAPI32_PE_PATH \
    AM12_WINE_ADVAPI32_PE_SHA256 \
    AM12_WINE_KERNEL32_PE_PATH \
    AM12_WINE_KERNEL32_PE_SHA256 \
    AM12_WINE_KERNELBASE_PE_PATH \
    AM12_WINE_KERNELBASE_PE_SHA256 \
    AM12_WINE_OLEAUT32_PE_PATH \
    AM12_WINE_OLEAUT32_PE_SHA256 \
    AM12_WINE_OLE32_PE_PATH \
    AM12_WINE_OLE32_PE_SHA256 \
    AM12_WINE_VERSION_PE_PATH \
    AM12_WINE_VERSION_PE_SHA256 \
    AM12_WINE_UCRTBASE_PE_PATH \
    AM12_WINE_UCRTBASE_PE_SHA256 \
    AM12_WINESERVER_PATH \
    AM12_WINESERVER_SHA256 \
    AM12_WINE_BUILD_FEX_PE_PATH \
    AM12_WINE_BUILD_FEX_PE_SHA256 \
    AM12_WINE_FEX_UNIX_BRIDGE_PATH \
    AM12_WINE_FEX_UNIX_BRIDGE_SHA256 \
    AM12_FEX_RUNTIME_ROOT_PATH \
    AM12_WINE_PREFIX_PATH \
    AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH \
    AM12_FEX_SYSTEM_REG_PATH \
    AM12_FEX_SYSTEM_REG_SHA256 \
    AM12_FEX_USER_REG_PATH \
    AM12_FEX_USER_REG_SHA256 \
    AM12_FEX_USERDEF_REG_PATH \
    AM12_FEX_USERDEF_REG_SHA256 \
    AM12_FEX_SELECTOR \
    AM12_WINE_PREFIX_C_DRIVE_LINK_PATH \
    AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET \
    AM12_WINE_PREFIX_C_DRIVE_PATH \
    AM12_WINE_PREFIX_Z_DRIVE_LINK_PATH \
    AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET \
    AM12_WINE_PREFIX_Z_DRIVE_PATH \
    AM12_WINE_PREFIX_NTDLL_PE_PATH \
    AM12_WINE_PREFIX_NTDLL_PE_SHA256 \
    AM12_WINE_PREFIX_WOW64_PE_PATH \
    AM12_WINE_PREFIX_WOW64_PE_SHA256 \
    AM12_WINE_PREFIX_ADVAPI32_PE_PATH \
    AM12_WINE_PREFIX_ADVAPI32_PE_SHA256 \
    AM12_WINE_PREFIX_KERNEL32_PE_PATH \
    AM12_WINE_PREFIX_KERNEL32_PE_SHA256 \
    AM12_WINE_PREFIX_KERNELBASE_PE_PATH \
    AM12_WINE_PREFIX_KERNELBASE_PE_SHA256 \
    AM12_WINE_PREFIX_OLEAUT32_PE_PATH \
    AM12_WINE_PREFIX_OLEAUT32_PE_SHA256 \
    AM12_WINE_PREFIX_OLE32_PE_PATH \
    AM12_WINE_PREFIX_OLE32_PE_SHA256 \
    AM12_WINE_PREFIX_VERSION_PE_PATH \
    AM12_WINE_PREFIX_VERSION_PE_SHA256 \
    AM12_WINE_PREFIX_UCRTBASE_PE_PATH \
    AM12_WINE_PREFIX_UCRTBASE_PE_SHA256 \
    AM12_WINE_PREFIX_LIBARM64ECFEX_PE_PATH \
    AM12_WINE_PREFIX_LIBARM64ECFEX_PE_SHA256 \
    AM12_WINE_PREFIX_XTAJIT64_PE_PATH \
    AM12_WINE_PREFIX_XTAJIT64_PE_SHA256 \
    AM12_FEX_PREFIX_PE_PATH \
    AM12_FEX_PREFIX_PE_SHA256 \
    AM12_FEX_PREFIX_XTAJIT64_PATH \
    AM12_FEX_PREFIX_XTAJIT64_SHA256 \
    AM12_WINE_DLL_OVERRIDES
}

am12_compiler_runtime_append_manifest() {
  if (($# != 1)); then
    am12_cri_error 'append_manifest requires one manifest path'
    return 1
  fi
  local manifest=${1:-}

  if [[ ${AM12_CRI_FROZEN:-0} != 1 ||
    -z ${AM12_COMPILER_RUNTIME_IDENTITY_SHA256:-} ]]; then
    am12_cri_error 'freeze the identity before appending manifest fields'
    return 1
  fi
  am12_cri_require_single_line 'manifest destination path' "$manifest" ||
    return 1
  if [[ -L $manifest ]]; then
    am12_cri_error "manifest destination must not be a symlink: $manifest"
    return 1
  fi
  if [[ ! -f $manifest ]]; then
    am12_cri_error "manifest destination must be an existing regular file: $manifest"
    return 1
  fi

  {
    printf 'compiler_runtime_identity_schema: %s\n' \
      "$AM12_COMPILER_RUNTIME_IDENTITY_SCHEMA"
    printf 'compiler_runtime_identity_sha256: %s\n' \
      "$AM12_COMPILER_RUNTIME_IDENTITY_SHA256"
    printf 'compiler_runtime_identity_scope: %s\n' \
      "$AM12_COMPILER_RUNTIME_IDENTITY_SCOPE"
    printf 'compiler_runtime_environment_policy: %s\n' \
      "$AM12_COMPILER_RUNTIME_ENVIRONMENT_POLICY"
    printf 'compiler_runtime_path_policy: %s\n' \
      "$AM12_COMPILER_RUNTIME_PATH_POLICY"
    printf 'compiler_runtime_lc_all_policy: %s\n' \
      "$AM12_COMPILER_RUNTIME_LC_ALL_POLICY"
    printf 'compiler_runtime_lang_policy: %s\n' \
      "$AM12_COMPILER_RUNTIME_LANG_POLICY"
    printf 'compiler_runtime_tmpdir_policy: %s\n' \
      "$AM12_COMPILER_RUNTIME_TMPDIR_POLICY"
    printf 'compiler_runtime_dyld_fallback_library_policy: %s\n' \
      "$AM12_COMPILER_RUNTIME_DYLD_FALLBACK_LIBRARY_POLICY"
    printf 'compiler_runtime_prefix_policy: %s\n' \
      "$AM12_COMPILER_RUNTIME_PREFIX_POLICY"
    printf 'compiler_runtime_dxc_bundle_identity_schema: %s\n' \
      "$AM12_DXC_BUNDLE_IDENTITY_SCHEMA"
    printf 'compiler_runtime_dxc_bundle_identity_sha256: %s\n' \
      "$AM12_DXC_BUNDLE_IDENTITY_SHA256"
    printf 'compiler_runtime_dxc_exe_path: %s\n' "$AM12_DXC_EXE_PATH"
    printf 'compiler_runtime_dxc_exe_sha256: %s\n' "$AM12_DXC_EXE_SHA256"
    printf 'compiler_runtime_dxcompiler_dll_path: %s\n' \
      "$AM12_DXCOMPILER_DLL_PATH"
    printf 'compiler_runtime_dxcompiler_dll_sha256: %s\n' \
      "$AM12_DXCOMPILER_DLL_SHA256"
    printf 'compiler_runtime_dxil_dll_path: %s\n' "$AM12_DXIL_DLL_PATH"
    printf 'compiler_runtime_dxil_dll_sha256: %s\n' "$AM12_DXIL_DLL_SHA256"
    printf 'compiler_runtime_wine_frontend_path: %s\n' \
      "$AM12_WINE_FRONTEND_PATH"
    printf 'compiler_runtime_wine_frontend_sha256: %s\n' \
      "$AM12_WINE_FRONTEND_SHA256"
    printf 'compiler_runtime_wine_build_root: %s\n' "$AM12_WINE_BUILD_ROOT"
    printf 'compiler_runtime_wine_ntdll_unix_path: %s\n' \
      "$AM12_WINE_NTDLL_UNIX_PATH"
    printf 'compiler_runtime_wine_ntdll_unix_sha256: %s\n' \
      "$AM12_WINE_NTDLL_UNIX_SHA256"
    printf 'compiler_runtime_wine_ntdll_pe_path: %s\n' \
      "$AM12_WINE_NTDLL_PE_PATH"
    printf 'compiler_runtime_wine_ntdll_pe_sha256: %s\n' \
      "$AM12_WINE_NTDLL_PE_SHA256"
    printf 'compiler_runtime_wine_wow64_pe_path: %s\n' \
      "$AM12_WINE_WOW64_PE_PATH"
    printf 'compiler_runtime_wine_wow64_pe_sha256: %s\n' \
      "$AM12_WINE_WOW64_PE_SHA256"
    printf 'compiler_runtime_wine_advapi32_pe_path: %s\n' \
      "$AM12_WINE_ADVAPI32_PE_PATH"
    printf 'compiler_runtime_wine_advapi32_pe_sha256: %s\n' \
      "$AM12_WINE_ADVAPI32_PE_SHA256"
    printf 'compiler_runtime_wine_kernel32_pe_path: %s\n' \
      "$AM12_WINE_KERNEL32_PE_PATH"
    printf 'compiler_runtime_wine_kernel32_pe_sha256: %s\n' \
      "$AM12_WINE_KERNEL32_PE_SHA256"
    printf 'compiler_runtime_wine_kernelbase_pe_path: %s\n' \
      "$AM12_WINE_KERNELBASE_PE_PATH"
    printf 'compiler_runtime_wine_kernelbase_pe_sha256: %s\n' \
      "$AM12_WINE_KERNELBASE_PE_SHA256"
    printf 'compiler_runtime_wine_oleaut32_pe_path: %s\n' \
      "$AM12_WINE_OLEAUT32_PE_PATH"
    printf 'compiler_runtime_wine_oleaut32_pe_sha256: %s\n' \
      "$AM12_WINE_OLEAUT32_PE_SHA256"
    printf 'compiler_runtime_wine_ole32_pe_path: %s\n' \
      "$AM12_WINE_OLE32_PE_PATH"
    printf 'compiler_runtime_wine_ole32_pe_sha256: %s\n' \
      "$AM12_WINE_OLE32_PE_SHA256"
    printf 'compiler_runtime_wine_version_pe_path: %s\n' \
      "$AM12_WINE_VERSION_PE_PATH"
    printf 'compiler_runtime_wine_version_pe_sha256: %s\n' \
      "$AM12_WINE_VERSION_PE_SHA256"
    printf 'compiler_runtime_wine_ucrtbase_pe_path: %s\n' \
      "$AM12_WINE_UCRTBASE_PE_PATH"
    printf 'compiler_runtime_wine_ucrtbase_pe_sha256: %s\n' \
      "$AM12_WINE_UCRTBASE_PE_SHA256"
    printf 'compiler_runtime_wineserver_path: %s\n' "$AM12_WINESERVER_PATH"
    printf 'compiler_runtime_wineserver_sha256: %s\n' "$AM12_WINESERVER_SHA256"
    printf 'compiler_runtime_wine_build_fex_pe_path: %s\n' \
      "$AM12_WINE_BUILD_FEX_PE_PATH"
    printf 'compiler_runtime_wine_build_fex_pe_sha256: %s\n' \
      "$AM12_WINE_BUILD_FEX_PE_SHA256"
    printf 'compiler_runtime_wine_fex_unix_bridge_path: %s\n' \
      "$AM12_WINE_FEX_UNIX_BRIDGE_PATH"
    printf 'compiler_runtime_wine_fex_unix_bridge_sha256: %s\n' \
      "$AM12_WINE_FEX_UNIX_BRIDGE_SHA256"
    printf 'compiler_runtime_fex_runtime_root_path: %s\n' \
      "$AM12_FEX_RUNTIME_ROOT_PATH"
    printf 'compiler_runtime_wine_prefix_path: %s\n' "$AM12_WINE_PREFIX_PATH"
    printf 'compiler_runtime_wine_prefix_template_path: %s\n' \
      "$AM12_COMPILER_RUNTIME_WINE_PREFIX_TEMPLATE_PATH"
    printf 'compiler_runtime_fex_system_reg_path: %s\n' \
      "$AM12_FEX_SYSTEM_REG_PATH"
    printf 'compiler_runtime_fex_system_reg_sha256: %s\n' \
      "$AM12_FEX_SYSTEM_REG_SHA256"
    printf 'compiler_runtime_fex_user_reg_path: %s\n' \
      "$AM12_FEX_USER_REG_PATH"
    printf 'compiler_runtime_fex_user_reg_sha256: %s\n' \
      "$AM12_FEX_USER_REG_SHA256"
    printf 'compiler_runtime_fex_userdef_reg_path: %s\n' \
      "$AM12_FEX_USERDEF_REG_PATH"
    printf 'compiler_runtime_fex_userdef_reg_sha256: %s\n' \
      "$AM12_FEX_USERDEF_REG_SHA256"
    printf 'compiler_runtime_fex_selector: %s\n' "$AM12_FEX_SELECTOR"
    printf 'compiler_runtime_wine_prefix_c_drive_link_path: %s\n' \
      "$AM12_WINE_PREFIX_C_DRIVE_LINK_PATH"
    printf 'compiler_runtime_wine_prefix_c_drive_link_target: %s\n' \
      "$AM12_WINE_PREFIX_C_DRIVE_LINK_TARGET"
    printf 'compiler_runtime_wine_prefix_c_drive_path: %s\n' \
      "$AM12_WINE_PREFIX_C_DRIVE_PATH"
    printf 'compiler_runtime_wine_prefix_z_drive_link_path: %s\n' \
      "$AM12_WINE_PREFIX_Z_DRIVE_LINK_PATH"
    printf 'compiler_runtime_wine_prefix_z_drive_link_target: %s\n' \
      "$AM12_WINE_PREFIX_Z_DRIVE_LINK_TARGET"
    printf 'compiler_runtime_wine_prefix_z_drive_path: %s\n' \
      "$AM12_WINE_PREFIX_Z_DRIVE_PATH"
    printf 'compiler_runtime_wine_prefix_ntdll_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_NTDLL_PE_PATH"
    printf 'compiler_runtime_wine_prefix_ntdll_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_NTDLL_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_wow64_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_WOW64_PE_PATH"
    printf 'compiler_runtime_wine_prefix_wow64_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_WOW64_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_advapi32_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_ADVAPI32_PE_PATH"
    printf 'compiler_runtime_wine_prefix_advapi32_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_ADVAPI32_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_kernel32_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_KERNEL32_PE_PATH"
    printf 'compiler_runtime_wine_prefix_kernel32_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_KERNEL32_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_kernelbase_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_KERNELBASE_PE_PATH"
    printf 'compiler_runtime_wine_prefix_kernelbase_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_KERNELBASE_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_oleaut32_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_OLEAUT32_PE_PATH"
    printf 'compiler_runtime_wine_prefix_oleaut32_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_OLEAUT32_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_ole32_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_OLE32_PE_PATH"
    printf 'compiler_runtime_wine_prefix_ole32_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_OLE32_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_version_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_VERSION_PE_PATH"
    printf 'compiler_runtime_wine_prefix_version_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_VERSION_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_ucrtbase_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_UCRTBASE_PE_PATH"
    printf 'compiler_runtime_wine_prefix_ucrtbase_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_UCRTBASE_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_libarm64ecfex_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_LIBARM64ECFEX_PE_PATH"
    printf 'compiler_runtime_wine_prefix_libarm64ecfex_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_LIBARM64ECFEX_PE_SHA256"
    printf 'compiler_runtime_wine_prefix_xtajit64_pe_path: %s\n' \
      "$AM12_WINE_PREFIX_XTAJIT64_PE_PATH"
    printf 'compiler_runtime_wine_prefix_xtajit64_pe_sha256: %s\n' \
      "$AM12_WINE_PREFIX_XTAJIT64_PE_SHA256"
    printf 'compiler_runtime_fex_prefix_pe_path: %s\n' \
      "$AM12_FEX_PREFIX_PE_PATH"
    printf 'compiler_runtime_fex_prefix_pe_sha256: %s\n' \
      "$AM12_FEX_PREFIX_PE_SHA256"
    printf 'compiler_runtime_fex_prefix_xtajit64_path: %s\n' \
      "$AM12_FEX_PREFIX_XTAJIT64_PATH"
    printf 'compiler_runtime_fex_prefix_xtajit64_sha256: %s\n' \
      "$AM12_FEX_PREFIX_XTAJIT64_SHA256"
    printf 'compiler_runtime_wine_dll_overrides: %s\n' \
      "$AM12_WINE_DLL_OVERRIDES"
  } >>"$manifest"
}

am12_compiler_runtime_identity_freeze() {
  am12_compiler_runtime_freeze "$@"
}

am12_compiler_runtime_identity_recheck() {
  am12_compiler_runtime_recheck "$@"
}

am12_compiler_runtime_identity_reset() {
  am12_compiler_runtime_reset "$@"
}

am12_compiler_runtime_identity_append_manifest() {
  am12_compiler_runtime_append_manifest "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  am12_cri_error 'source this helper; do not execute it directly'
  exit 2
fi
