#!/usr/bin/env bash
# Author: Timur Isaev
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
swift test --package-path "$ROOT/runtime/trust"
BIN=$(swift build --package-path "$ROOT/runtime/trust" --show-bin-path)
python3 "$ROOT/runtime/trust/Tests/cli-proof.py" "$BIN/alloy-trust-dev"
python3 "$ROOT/runtime/trust/Tests/scan-key-material.py"
