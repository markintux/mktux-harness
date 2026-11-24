#!/usr/bin/env bash
#
# reread-guard.sh — hook PreToolUse (Bash no Claude e no Codex; Read no Claude).
#
# So age dentro de uma sessao do ralph: o ralph exporta RALPH_LOADED_DOCS com os
# arquivos que a engine ja carregou no contexto da sessao (AGENTS.md no Codex,
# CLAUDE.md e os @imports no Claude) e os que estao espelhados dentro deles
# (ex: o arquivo de diretrizes do time que uma ferramenta do framework copia
# inteiro para dentro do AGENTS.md). Fora do ralph a variavel nao existe e o hook deixa tudo passar.
#
# Por que bloquear e nao so pedir no prompt: num run real o prompt
# dizia "LEIA AGENTS.md", e 19 de 26 sessoes de implementacao leram de novo o
# arquivo que o Codex ja tinha injetado. Com o .ai/guidelines espelhado, foram
# 26 leituras de ~10k tokens cada, relidas em todo turno seguinte: 11,5% de todo
# o input do run. Ja tinha acontecido antes com os documentos do plano.
#
# Formato de RALPH_LOADED_DOCS: uma linha por arquivo, "<caminho>\t<via>", com o
# caminho relativo a raiz do repo e <via> vazio (carregado pela engine) ou o
# arquivo carregado que o contem.
# RALPH_REREAD_LOG: cada bloqueio vira uma linha "<fase>\t<ciclo>\t<modo>\t<caminho>"
# nesse arquivo; o ralph soma no relatorio.
#
# Contrato do hook (igual aos guards de perfil): exit 0 deixa passar; exit 2 bloqueia e
# o stderr volta para o agente. Sem jq/python3, falha aberto.
set -u

[ -n "${RALPH_LOADED_DOCS:-}" ] || exit 0
INPUT="$(cat)"

field() { # field <jq-expr> <python-expr>
  if command -v jq > /dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1" 2> /dev/null
  elif command -v python3 > /dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c "import json,sys
d=json.load(sys.stdin)
$2" 2> /dev/null
  fi
}

CMD=$(field '.tool_input.command // empty | if type == "array" then join(" ") else . end' \
  'c=d.get("tool_input",{}).get("command","")
print(" ".join(c) if isinstance(c,list) else c)')
FILE=$(field '.tool_input.file_path // empty' 'print(d.get("tool_input",{}).get("file_path",""))')
CWD=$(field '.cwd // empty' 'print(d.get("cwd",""))')
[ -n "$CMD$FILE" ] || exit 0

# `bash -lc 'cat AGENTS.md'` (ou o array ["bash","-lc","cat AGENTS.md"]): o que
# importa e o script dentro do -c.
if [[ "$CMD" =~ ^(/usr)?(/bin/)?(ba|z|da)?sh[[:space:]]+-l?c[[:space:]]+(.*)$ ]]; then
  CMD="${BASH_REMATCH[4]}"
  case "$CMD" in
    \'*\') CMD="${CMD#\'}"; CMD="${CMD%\'}" ;;
    \"*\") CMD="${CMD#\"}"; CMD="${CMD%\"}" ;;
  esac
fi

ROOT=$(cd "${CWD:-.}" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null) \
  || ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || ROOT="$PWD"

# rel <caminho>: relativo a raiz do repo, com . e .. resolvidos.
rel() {
  local p="$1" part out=() parts
  case "$p" in
    "$ROOT"/*) p="${p#"$ROOT"/}" ;;
    /*) printf '%s' "$p"; return ;;
    *) [ -n "$CWD" ] && [ "$CWD" != "$ROOT" ] && case "$CWD" in "$ROOT"/*) p="${CWD#"$ROOT"/}/$p" ;; esac ;;
  esac
  IFS=/ read -ra parts <<< "$p"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  (IFS=/; printf '%s' "${out[*]}")
}

# loaded_via <rel>: 0 se o arquivo esta no contexto; imprime a via (pode ser vazia).
loaded_via() {
  local path via
  while IFS=$'\t' read -r path via; do
    [ -n "$path" ] || continue
    if [ "$path" = "$1" ]; then
      printf '%s' "$via"
      return 0
    fi
  done <<< "$RALPH_LOADED_DOCS"
  return 1
}

HIT=""
HIT_VIA=""

if [ -n "$FILE" ]; then
  r=$(rel "$FILE")
  if via=$(loaded_via "$r"); then HIT="$r"; HIT_VIA="$via"; fi
fi

if [ -z "$HIT" ] && [ -n "$CMD" ]; then
  # Quebra em segmentos (&&, ||, |, ; e quebra de linha) sem partir aspas, como
  # os guards de perfil: `rg -n "AGENTS.md|x"` e um comando so.
  SEGMENTS=$(printf '%s' "$CMD" | awk '
    BEGIN { sq = 0; dq = 0 }
    {
      if (NR > 1) { printf "\n" }
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\" && dq && i < n) { printf "%s%s", c, substr($0, ++i, 1); continue }
        if (c == "\047" && !dq) { sq = !sq; printf "%s", c; continue }
        if (c == "\042" && !sq) { dq = !dq; printf "%s", c; continue }
        if (!sq && !dq && (c == ";" || c == "\174" || c == "&")) { printf "\n"; continue }
        printf "%s", c
      }
    }')
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
    [ -n "$seg" ] || continue
    read -ra words <<< "$seg"
    case "${words[0]}" in
      cat|bat|batcat|less|more|head|tail|nl|sed|awk|view|strings) ;;
      *) continue ;;
    esac
    # sed -i edita, nao le: a fase pode ter task de atualizar o AGENTS.md.
    if [ "${words[0]}" = "sed" ] && [[ " ${words[*]} " =~ \ -i|\ --in-place ]]; then
      continue
    fi
    after_redirect=0
    for w in "${words[@]:1}"; do
      case "$w" in
        '>'|'>>'|'1>'|'2>'|'&>') after_redirect=1; continue ;;
        '>'*|'>>'*) after_redirect=1; continue ;;
        -*) continue ;;
      esac
      [ "$after_redirect" -eq 1 ] && { after_redirect=0; continue; }
      w="${w#\'}"; w="${w%\'}"; w="${w#\"}"; w="${w%\"}"
      r=$(rel "$w")
      if via=$(loaded_via "$r"); then HIT="$r"; HIT_VIA="$via"; break 2; fi
    done
  done <<< "$SEGMENTS"
fi

[ -n "$HIT" ] || exit 0

if [ -n "${RALPH_REREAD_LOG:-}" ]; then
  printf '%s\t%s\t%s\t%s\n' "${RALPH_PHASE_NUM:-}" "${RALPH_PHASE_ATTEMPT:-}" \
    "${RALPH_SESSION_MODE:-}" "$HIT" >> "$RALPH_REREAD_LOG" 2> /dev/null || true
fi

if [ -n "$HIT_VIA" ]; then
  why="o conteudo dele esta espelhado dentro de $HIT_VIA, que a engine carregou inteiro no inicio desta sessao"
else
  why="a engine carregou o arquivo inteiro no inicio desta sessao"
fi
cat >&2 << EOF
BLOQUEADO pelo reread-guard do ralph: $HIT ja esta no seu contexto — $why.
Reler repete o mesmo texto em todos os turnos seguintes. Use o que voce ja tem;
vale mesmo quando outro arquivo manda ler $HIT.
Para achar um trecho especifico: rg -n '<termo>' $HIT
EOF
exit 2
