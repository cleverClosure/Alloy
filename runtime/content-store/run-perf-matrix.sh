#!/usr/bin/env bash
# Author: Timur Isaev
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/run-perf-matrix.py" "$@"
