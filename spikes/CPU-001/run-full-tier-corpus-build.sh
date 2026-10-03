#!/usr/bin/env bash
# Cross-compile the CPU corpus without running a Windows guest.
# Author: Timur Isaev
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/work"
work=$(mktemp -d "$here/work/test-all-corpus.XXXXXX")
trap 'rm -rf "$work"' EXIT
bash "$here/testcases/build-corpus.sh" "$work"
