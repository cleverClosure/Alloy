#!/usr/bin/env bash
# Author: Timur Isaev
set -euo pipefail
script_root="$(cd "$(dirname "$0")" && pwd)"
exec python3 -B "$script_root/check_all.py" "$@"
