#!/usr/bin/env bash
# Author: Timur Isaev
set -euo pipefail
probe_root="$(cd "$(dirname "$0")" && pwd)"
swift test --package-path "$probe_root"
python3 "$probe_root/test-v2-corpus.py"
