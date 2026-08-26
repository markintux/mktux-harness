#!/usr/bin/env bash
# Stop hook (Codex) — grava snapshot de tokens da sessao em .harness/tokens.jsonl.
#
# O rollout do Codex reporta o ACUMULADO da sessao em payload.info.total_token_usage
# na linha `token_count`. Pegamos a ULTIMA ocorrencia (total final) — nao somamos
# linha a linha (sao cumulativos; somar contaria em dobro). O modelo real (gpt-5.x)
# vive em linhas `turn_context`, nao no session_meta.
set -euo pipefail

input=$(cat)

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$root/.harness"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

session=$(printf '%s' "$input" | jq -r '.session_id // empty')
[[ -z "$session" ]] && exit 0

# Localiza o rollout desta sessao pelo sufixo do nome (…-<session_id>.jsonl).
rollout=$(find "$HOME/.codex/sessions" -type f -name "*${session}.jsonl" 2>/dev/null | head -1)
[[ -z "$rollout" || ! -f "$rollout" ]] && exit 0

# Modelo real (gpt-5.x): primeira ocorrencia de "model":"..." no rollout.
# head -1 garante UMA saida (a mesma linha turn_context repete o campo).
# Nunca usa model_provider (que seria so "openai").
model=$(grep -oE '"model":"[^"]+"' "$rollout" | head -1 | sed -E 's/"model":"([^"]+)"/\1/')
[[ -z "$model" ]] && model="unknown"

# Tokens: ULTIMA linha token_count -> payload.info.total_token_usage (acumulado final).
usage=$(grep '"type":"token_count"' "$rollout" | tail -1 \
  | jq -c '.payload.info.total_token_usage // empty' 2>/dev/null)
[[ -z "$usage" ]] && exit 0

# Formato espelhado com o tokens.jsonl do Claude (+ reasoning, especifico do Codex;
# vendor:"codex" distingue do Claude no Grafana).
printf '%s\n' "$usage" | jq -c \
  --arg ts "$ts" \
  --arg session "$session" \
  --arg model "$model" \
  '{
     ts: $ts,
     session_id: $session,
     vendor: "codex",
     model: $model,
     input:      (.input_tokens           // 0),
     output:     (.output_tokens          // 0),
     cache_read: (.cached_input_tokens     // 0),
     reasoning:  (.reasoning_output_tokens // 0),
     total:      (.total_tokens            // 0)
   }' >> "$root/.harness/tokens.jsonl"

exit 0
