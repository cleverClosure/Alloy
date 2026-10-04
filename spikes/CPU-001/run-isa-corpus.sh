#!/usr/bin/env bash
# Complete manual ISA corpus entry point. Author: Timur Isaev
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec python3 "$here/isa-corpus-runner.py" "$@"
