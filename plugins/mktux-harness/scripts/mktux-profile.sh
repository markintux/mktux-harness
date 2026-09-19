#!/usr/bin/env bash
#
# mktux-profile.sh — o perfil de stack de um diretorio, para quem nao e shell.
#
# Os agents (test-runner, security-auditor) chamam isto via
# ${CLAUDE_PLUGIN_ROOT}/scripts/mktux-profile.sh em vez de adivinhar o stack:
# a resposta e a mesma que o ralph usa no gate 2.
#
# Uso: mktux-profile.sh [--dir <dir>] <comando>
#
#   name      perfil do projeto, subindo a partir de <dir>; exit 1 se nenhum
#   root      diretorio onde o perfil foi detectado; exit 1 se nenhum
#   test-cmd  comando de teste, na ordem do ralph:
#               1. RALPH_TEST_CMD (o ralph exporta o comando do gate 2 para as
#                  sessoes dele)
#               2. o do perfil
#               3. deteccao por manifest (composer, npm, pytest, go, cargo)
#             Com o perfil numa pasta acima de <dir>, sai prefixado com
#             `cd <raiz> &&`. exit 1 se nada resolver.
#   hook <e>  caminho do script do perfil para o evento <e>; exit 1 se nenhum
#   notes <a> notas do perfil para o agent <a> (profiles/<nome>/agents/<a>.md);
#             sem perfil ou sem notas: nada, exit 0
#
# <dir> default: o diretorio atual.

set -uo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/profile.sh"

dir="$PWD"
if [ "${1:-}" = "--dir" ]; then
  dir="${2:?--dir exige um caminho}"
  shift 2
fi
cmd="${1:-}"

name="" root=""
if found="$(mktux_profile_for "$dir")"; then
  IFS=$'\t' read -r name root <<< "$found"
fi

case "$cmd" in
  name)
    [ -n "$name" ] || exit 1
    echo "$name"
    ;;
  root)
    [ -n "$root" ] || exit 1
    echo "$root"
    ;;
  test-cmd)
    if [ -n "${RALPH_TEST_CMD:-}" ]; then
      echo "$RALPH_TEST_CMD"
      exit 0
    fi
    base="${root:-$(cd "$dir" && pwd)}"
    test_cmd="$(
      cd "$base" || exit 1
      if [ -n "$name" ]; then
        mktux_load_profile "$name"
        out="$(profile_test_cmd)"
        [ -n "$out" ] && { echo "$out"; exit 0; }
      fi
      mktux_generic_test_cmd
    )"
    [ -n "$test_cmd" ] || exit 1
    if [ "$base" != "$(cd "$dir" && pwd)" ]; then
      printf 'cd %q && %s\n' "$base" "$test_cmd"
    else
      echo "$test_cmd"
    fi
    ;;
  hook)
    [ -n "$name" ] || exit 1
    mktux_profile_hook "$name" "${2:?hook exige o evento}"
    ;;
  notes)
    agent="${2:?notes exige o nome do agent}"
    [ -n "$name" ] || exit 0
    notes="$MKTUX_PLUGIN_DIR/profiles/$name/agents/$agent.md"
    [ -f "$notes" ] && cat "$notes"
    exit 0
    ;;
  *)
    sed -n '3,24p' "$0" >&2
    exit 2
    ;;
esac
