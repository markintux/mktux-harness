# lib/profile.sh — deteccao e carga do perfil de stack.
#
# Sourced pelo ralph.sh, pelo dispatcher de hooks (hooks/shared/profile-hook.sh)
# e pelo mktux-profile.sh. So define funcoes e MKTUX_PLUGIN_DIR.
#
# Um perfil e um diretorio profiles/<nome>/ cujo profile.sh define:
#
#   profile_detect <dir>     0 se o perfil vale para <dir> (so esse dir, sem subir)
#   profile_test_cmd         ecoa o comando de teste default, com o cwd na raiz do
#                            projeto; vazio = o perfil nao tem opiniao
#   profile_preflight <cmd>  valida o ambiente antes de o gate 2 rodar <cmd>. Usa
#                            log/fail do chamador e sai com exit 1 quando o
#                            ambiente nao roda <cmd>
#   profile_prompt_notes     linhas extras para o prompt de implementacao
#   profile_hook <evento>    caminho, relativo ao perfil, do script de um evento
#                            de hook (pre-bash | claude-post-edit | codex-stop);
#                            vazio = o perfil nao age nesse evento
#
# Texto do perfil, fora do profile.sh:
#   profiles/<nome>/agents/<agent>.md      notas que so um agent le (Claude; o
#                                          Codex nao carrega agents), via
#                                          `mktux-profile.sh notes <agent>`
#   skills/<skill>/references/<nome>.md    convencoes que uma skill carrega; mora
#                                          ao lado dela porque e o unico caminho
#                                          que os dois engines resolvem. Um agent
#                                          que precisa do mesmo texto le dali.
#
# O core (ralph.sh, hooks.json, agents) nunca nomeia um stack: pergunta ao perfil.

MKTUX_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# mktux_profile_at <dir> -> nome do perfil que vale exatamente para <dir>
mktux_profile_at() {
  local dir="$1" p
  for p in "$MKTUX_PLUGIN_DIR"/profiles/*/profile.sh; do
    [ -f "$p" ] || continue
    # subshell: cada profile.sh define as mesmas funcoes profile_*
    if ( . "$p" && profile_detect "$dir" ); then
      basename "$(dirname "$p")"
      return 0
    fi
  done
  return 1
}

# mktux_profile_for <dir> -> "<nome>\t<raiz>" do perfil mais proximo, subindo a
# partir de <dir>. Perfil numa subpasta de monorepo so e achado subindo do cwd.
mktux_profile_for() {
  local dir name
  dir="$(cd "$1" 2> /dev/null && pwd)" || return 1
  while :; do
    if name="$(mktux_profile_at "$dir")"; then
      printf '%s\t%s\n' "$name" "$dir"
      return 0
    fi
    [ "$dir" = "/" ] && return 1
    dir="$(dirname "$dir")"
  done
}

# mktux_load_profile <nome> -> define as funcoes profile_* no shell atual
mktux_load_profile() {
  # shellcheck disable=SC1090
  . "$MKTUX_PLUGIN_DIR/profiles/$1/profile.sh"
}

# mktux_profile_hook <nome> <evento> -> caminho absoluto do script do evento
mktux_profile_hook() {
  local rel
  rel="$( . "$MKTUX_PLUGIN_DIR/profiles/$1/profile.sh" && profile_hook "$2" )" || return 1
  [ -n "$rel" ] || return 1
  printf '%s\n' "$MKTUX_PLUGIN_DIR/profiles/$1/$rel"
}

# mktux_generic_test_cmd -> comando de teste por manifest, para projeto sem
# perfil ou perfil sem opiniao (cwd = raiz do projeto)
mktux_generic_test_cmd() {
  if [ -f composer.json ] && grep -qE '"test"[[:space:]]*:' composer.json; then
    echo "composer test"
  elif [ -f package.json ] && grep -qE '"test"[[:space:]]*:' package.json; then
    echo "npm test"
  elif [ -f pytest.ini ] || { [ -f pyproject.toml ] && grep -qF '[tool.pytest' pyproject.toml; }; then
    # Com lock do uv ou do poetry o pytest mora no virtualenv do projeto, nao no
    # PATH do host: `pytest` puro falharia em toda fase. `uv run` sincroniza o
    # ambiente sozinho — e o jeito do projeto rodar, nao uma instalacao a parte.
    if [ -f uv.lock ]; then
      echo "uv run pytest"
    elif [ -f poetry.lock ]; then
      echo "poetry run pytest"
    else
      echo "pytest"
    fi
  elif [ -f go.mod ]; then
    echo "go test ./..."
  elif [ -f Cargo.toml ]; then
    echo "cargo test"
  fi
}
