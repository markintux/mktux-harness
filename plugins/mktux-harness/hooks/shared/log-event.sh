#!/usr/bin/env bash
#
# log-event.sh — telemetria de eventos. Identico para Claude Code e Codex:
# ambos entregam o payload do hook em stdin como JSON e ignoram o stdout.
#
# Cada evento vira uma linha em .harness/events.jsonl, enriquecida com
# timestamp UTC e branch. Nunca falha o hook: sai 0 em qualquer cenario.
#
# O payload vai enxuto. Gravado inteiro, o tool_response de cada Read e de cada
# suite rodada fez o events.jsonl do bargi chegar a 146 MB, com linhas de 500 KB,
# e nada le esse conteudo. A saida da ferramenta vira so o tamanho
# (tool_response_chars), toda string passa de 2000 caracteres cortada (o
# content de um Write, um prompt colado), e o arquivo gira em 20 MB.
set -euo pipefail

input=$(cat)

# Hooks podem rodar com cwd fora do projeto. Ancora na raiz, nesta ordem:
# variavel do Claude -> raiz do git -> cwd.
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
mkdir -p "$root/.harness"
log="$root/.harness/events.jsonl"

if [ -f "$log" ] && [ "$(wc -c < "$log")" -gt 20971520 ]; then
  mv -f "$log" "$log.1"
fi

# Timestamp UTC portavel (o `date` do BSD/macOS nao tem %N para milissegundos).
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

printf '%s\n' "$input" | jq -c \
  --arg ts "$ts" \
  --arg branch "$branch" '
  def clip:
    if type == "string" and length > 2000 then .[0:2000] + "…(+\(length - 2000) chars)"
    elif type == "object" then map_values(clip)
    elif type == "array" then map(clip)
    else . end;
  ({ts: $ts, branch: $branch} + .)
  | if has("tool_response") then
      .tool_response_chars = (.tool_response | if type == "string" then . else tojson end | length)
      | del(.tool_response)
    else . end
  | clip' \
  >> "$log" 2> /dev/null || true

exit 0
