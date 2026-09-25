#!/usr/bin/env bash
# Claude Stop: cumulative snapshots by session and model, including subagents.
set -euo pipefail
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
script=$(cd "$(dirname "$0")/../.." && pwd)/scripts/telemetry.py
python3 "$script" claude --root "$root" || true
