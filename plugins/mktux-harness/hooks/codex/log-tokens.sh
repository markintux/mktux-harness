#!/usr/bin/env bash
# Stop hook (Codex) — grava snapshot de tokens da sessao em .harness/tokens.jsonl.
#
# O rollout do Codex reporta o ACUMULADO da sessao em payload.info.total_token_usage
# na linha `token_count`. Pegamos a ULTIMA ocorrencia (total ate aqui) — nao somamos
# linha a linha (sao cumulativos; somar contaria em dobro). O modelo real (gpt-5.x)
# vive em linhas `turn_context`, nao no session_meta.
#
# O Stop do Codex dispara a cada turno, e o profile-hook do Stop pode abrir outro:
# a mesma sessao ganha uma linha por turno, cada uma com o acumulado ate ali.
# Agregadores pegam a ULTIMA linha por session_id — no run social-proof, 74
# sessoes tinham duas linhas, e somar tudo contava essas em dobro.
#
# Subagents (spawn_agent) gravam rollout proprio, e o do pai nao inclui o consumo
# deles. Cada subagent vira uma linha com o proprio session_id e `parent`. Num run
# real do ralph eram 28 subagents, +26% de input que o tokens.jsonl nao via.
#
# Sessao do ralph (RALPH_PHASE_NUM no ambiente): cada linha leva ralph_phase,
# ralph_cycle e ralph_mode (impl|verify|judge). Sem isso, medir um run por fase era
# casar timestamp com o log do ralph na mao.
set -euo pipefail

input=$(cat)

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$root/.harness"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sessions_dir="${CODEX_HOME:-$HOME/.codex}/sessions"

session=$(printf '%s' "$input" | jq -r '.session_id // empty')
[[ -z "$session" ]] && exit 0

# Localiza o rollout desta sessao pelo sufixo do nome (…-<session_id>.jsonl).
rollout=$(find "$sessions_dir" -type f -name "*${session}.jsonl" 2>/dev/null | head -1)
[[ -z "$rollout" || ! -f "$rollout" ]] && exit 0

# emit <rollout> <session_id> [parent] — uma linha no tokens.jsonl.
emit() {
  local file="$1" id="$2" parent="${3:-}" model usage

  # Modelo real (gpt-5.x): primeira ocorrencia de "model":"..." no rollout.
  # head -1 garante UMA saida (a mesma linha turn_context repete o campo).
  # Nunca usa model_provider (que seria so "openai").
  model=$(grep -oE '"model":"[^"]+"' "$file" | head -1 | sed -E 's/"model":"([^"]+)"/\1/')
  [[ -z "$model" ]] && model="unknown"

  # Tokens: ULTIMA linha token_count -> payload.info.total_token_usage (acumulado final).
  # Subagent criado por fork embute o historico do pai, mas nao os token_count dele.
  usage=$(grep '"type":"token_count"' "$file" | tail -1 \
    | jq -c '.payload.info.total_token_usage // empty' 2>/dev/null)
  [[ -z "$usage" ]] && return 0

  # Formato espelhado com o tokens.jsonl do Claude (+ reasoning, especifico do Codex;
  # vendor:"codex" distingue do Claude no Grafana).
  printf '%s\n' "$usage" | jq -c \
    --arg ts "$ts" \
    --arg session "$id" \
    --arg model "$model" \
    --arg parent "$parent" \
    --arg phase "${RALPH_PHASE_NUM:-}" \
    --arg cycle "${RALPH_PHASE_ATTEMPT:-}" \
    --arg mode "${RALPH_SESSION_MODE:-}" \
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
     } + (if $parent == "" then {} else {parent: $parent} end)
       + (if $phase == "" then {} else {
           ralph_phase: ($phase | tonumber? // $phase),
           ralph_cycle: ($cycle | tonumber? // $cycle),
           ralph_mode: $mode
         } end)' >> "$root/.harness/tokens.jsonl"
}

emit "$rollout" "$session"

# Subagents: o session_meta na primeira linha do rollout traz o parent_thread_id.
# So rollouts abertos depois do pai podem ser filhos dele — o nome comeca com
# rollout-<data>T<hora>, entao a comparacao de string basta. Em largura, para
# pegar subagent de subagent.
start=$(basename "$rollout" | cut -c1-27)
candidates=$(find "$sessions_dir" -type f -name 'rollout-*.jsonl' 2>/dev/null \
  | awk -F/ -v s="$start" 'substr($NF, 1, 27) >= s')
[[ -z "$candidates" ]] && exit 0

queue=("$session")
while ((${#queue[@]})); do
  parent="${queue[0]}"
  queue=("${queue[@]:1}")
  while IFS= read -r file; do
    [[ "$file" == "$rollout" ]] && continue
    meta=$(head -1 "$file")
    [[ "$meta" == *"\"parent_thread_id\":\"$parent\""* ]] || continue
    child=$(printf '%s' "$meta" | jq -r '.payload.id // empty' 2>/dev/null)
    [[ -z "$child" ]] && continue
    emit "$file" "$child" "$parent"
    queue+=("$child")
  done <<< "$candidates"
done

exit 0
