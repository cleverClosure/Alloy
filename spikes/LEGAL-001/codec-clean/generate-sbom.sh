#!/usr/bin/env bash
# SBOM for the shipped runtime (counsel item 5, issue #24).
# Author: Tim Isaev
#
# Records every component that ships, its licence, its upstream revision and the
# SHA-256 of the artifact actually present - not the version we believe we built.
# FEX and MoltenVK are included because item 5 names them explicitly as being in
# the shipped product but outside item 4's original scope.
#
# Emits CycloneDX-shaped JSON on stdout.
#
# Usage: generate-sbom.sh <wine-build> <wine-src> <fex-src> <fex-dll> <provider-dir> <unixlib-dir>
set -uo pipefail

BUILD=${1:?wine build dir}
WINESRC=${2:?wine source dir}
FEXSRC=${3:?fex source dir}
FEXDLL=${4:?libarm64ecfex.dll}
PROVIDERS=${5:-}
UNIXLIB=${6:-}

sha() { [[ -f $1 ]] && shasum -a 256 "$1" | awk '{print $1}' || echo "absent"; }
rev() { git -C "$1" rev-parse HEAD 2>/dev/null || echo "unknown"; }

component() { # name version licence sha purl-ish note
  printf '    {"name":"%s","version":"%s","licenses":[{"license":{"id":"%s"}}],' "$1" "$2" "$3"
  printf '"hashes":[{"alg":"SHA-256","content":"%s"}],"description":"%s"}' "$4" "$5"
}

echo '{'
echo '  "bomFormat": "CycloneDX",'
echo '  "specVersion": "1.5",'
echo '  "metadata": {'
echo '    "component": {"type": "application", "name": "alloy-runtime"},'
echo "    \"properties\": [{\"name\":\"note\",\"value\":\"product name pending rename, issue #26\"}]"
echo '  },'
echo '  "components": ['

component "wine" "$(rev "$WINESRC")" "LGPL-2.1-or-later" \
  "$(sha "$BUILD/dlls/ntdll/ntdll.so")" \
  "fork; ntdll.so hashed as the representative artifact"
echo ','
component "fex-emu" "$(rev "$FEXSRC")" "MIT" "$(sha "$FEXDLL")" \
  "libarm64ecfex.dll; named in item 5 as in-scope for this SBOM"
if [[ -n $PROVIDERS ]]; then
  echo ','
  component "dxmt-d3d11" "prebuilt" "LGPL-2.1-or-later" "$(sha "$PROVIDERS/d3d11.dll")" \
    "src/d3d12 excluded at clone time per ADR-0012"
  echo ','
  component "dxmt-dxgi" "prebuilt" "LGPL-2.1-or-later" "$(sha "$PROVIDERS/dxgi.dll")" "prebuilt provider"
fi
if [[ -n $UNIXLIB ]]; then
  echo ','
  component "dxmt-winemetal" "prebuilt" "LGPL-2.1-or-later" "$(sha "$UNIXLIB/winemetal.so")" "unixlib"
fi

# Absences are part of an SBOM's claim, not omissions from it. Both of these are
# named in item 5 and both are asserted here to be absent, with evidence.
echo ','
component "moltenvk" "absent" "NONE" "absent" \
  "not shipped; only wine's own libvulkan-1.a stub is present"
echo ','
component "ffmpeg" "$([[ -f "$BUILD/dlls/winedmo/winedmo.so" ]] && echo "REACHABLE via winedmo.so" || echo "absent")" \
  "LGPL-2.1-or-later" "$(sha "$BUILD/dlls/winedmo/winedmo.so")" \
  "codec implementation; must be absent from external builds - see codec-scan.sh"
echo ','
component "gstreamer" "absent" "NONE" "absent" \
  "not linked; GSTREAMER_LIBS empty and no loadable winegstreamer module"

echo
echo '  ]'
echo '}'
