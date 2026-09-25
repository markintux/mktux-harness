#!/usr/bin/env bash
# Codex Stop: cumulative snapshots, including child rollouts.
set -euo pipefail
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
script=$(cd "$(dirname "$0")/../.." && pwd)/scripts/telemetry.py
python3 "$script" codex --root "$root" || true
