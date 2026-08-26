#!/usr/bin/env bash
# Stop hook (Claude) — grava snapshot cumulativo de tokens por (sessão, modelo).
# Cada Stop adiciona N linhas em .harness/tokens.jsonl (uma por modelo usado).
# Os valores são CUMULATIVOS para a sessão — agregadores devem pegar o MAX por (session, model).

set -euo pipefail

# hooks podem rodar com cwd fora do projeto — ancora tudo na raiz
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

input=$(cat)
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
session=$(echo "$input"    | jq -r '.session_id // empty')

[[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

mkdir -p .harness
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Lê o transcript JSONL, filtra mensagens assistant com usage,
# agrupa por modelo e soma tokens. Cada modelo vira uma linha em tokens.jsonl.
# vendor:"claude" + total dão o eixo comum com o log-tokens.sh do Codex (comparacao no Grafana).
# fromjson? ignora linhas truncadas — o Stop pode disparar com o transcript ainda em flush.
jq -R -s -c --arg ts "$ts" --arg session "$session" '
  split("\n")
  | map(fromjson? // empty)
  | map(select(.type == "assistant" and .message.usage != null))
  | group_by(.message.model)
  | map({
      ts: $ts,
      session_id: $session,
      vendor: "claude",
      model: .[0].message.model,
      messages: length,
      input:          (map(.message.usage.input_tokens                // 0) | add),
      output:         (map(.message.usage.output_tokens               // 0) | add),
      cache_creation: (map(.message.usage.cache_creation_input_tokens // 0) | add),
      cache_read:     (map(.message.usage.cache_read_input_tokens     // 0) | add)
    })
  | map(. + {total: (.input + .output)})
  | .[]
' "$transcript" >> .harness/tokens.jsonl

exit 0
