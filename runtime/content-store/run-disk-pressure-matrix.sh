#!/usr/bin/env bash
# Author: Timur Isaev
set -euo pipefail
package_root="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$package_root/run-disk-pressure-matrix.py" "$@"
