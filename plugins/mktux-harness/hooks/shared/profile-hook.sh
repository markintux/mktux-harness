#!/usr/bin/env bash
#
# profile-hook.sh <evento> — encaminha um hook para o script do perfil de stack.
#
# hooks.json e codex-hooks.json chamam isto em vez de nomear um stack. O perfil
# e detectado subindo a partir do cwd do evento (perfil numa subpasta de
# monorepo tambem conta). O script do perfil recebe o mesmo stdin e decide
# saida e exit code (exit 2 bloqueia; o Stop do Codex le JSON do stdout).
# Sem perfil, ou perfil sem script para o evento: exit 0 sem saida.
#
# Eventos: pre-bash (PreToolUse Bash) | claude-post-edit (PostToolUse
# Edit|Write, Claude) | codex-stop (Stop, Codex).

set -u

event="${1:?uso: profile-hook.sh <evento>}"
plugin="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
. "$plugin/scripts/lib/profile.sh" 2> /dev/null || exit 0

input="$(cat)"

# cwd do evento: o Claude manda no payload; o Codex nao manda no PreToolUse.
dir=""
if command -v jq > /dev/null 2>&1; then
  dir=$(printf '%s' "$input" | jq -r '.cwd // empty' 2> /dev/null)
elif command -v python3 > /dev/null 2>&1; then
  dir=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("cwd", ""))
except Exception:
    pass' 2> /dev/null)
fi
[ -n "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2> /dev/null || pwd)}"

found="$(mktux_profile_for "$dir")" || exit 0
script="$(mktux_profile_hook "${found%%$'\t'*}" "$event")" || exit 0
[ -f "$script" ] || exit 0

printf '%s' "$input" | bash "$script"
