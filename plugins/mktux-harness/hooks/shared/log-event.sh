#!/usr/bin/env bash
#
# log-event.sh — telemetria de eventos. Identico para Claude Code e Codex:
# ambos entregam o payload do hook em stdin como JSON e ignoram o stdout.
#
# Cada evento vira uma linha em .harness/events.jsonl, enriquecida com
# timestamp UTC e branch. Nunca falha o hook: sai 0 em qualquer cenario.
set -euo pipefail

input=$(cat)

# Hooks podem rodar com cwd fora do projeto. Ancora na raiz, nesta ordem:
# variavel do Claude -> raiz do git -> cwd.
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
mkdir -p "$root/.harness"

# Timestamp UTC portavel (o `date` do BSD/macOS nao tem %N para milissegundos).
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

echo "$input" | jq -c \
  --arg ts "$ts" \
  --arg branch "$branch" \
  '{ts: $ts, branch: $branch} + .' \
  >> "$root/.harness/events.jsonl"

exit 0
