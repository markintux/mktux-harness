#!/usr/bin/env bash
# profiles/node/profile.sh — perfil Node.js com npm.
#
# Contrato em scripts/lib/profile.sh. Sourced: so define funcoes. Roda sob o
# `set -euo pipefail` do ralph.sh.

profile_detect() {
  [ -f "$1/package.json" ] && [ ! -f "$1/artisan" ] &&
    ! grep -qE '^\[(project|tool\.poetry|tool\.pytest[^]]*|build-system)\]' "$1/pyproject.toml" 2> /dev/null
}

node_has_script() {
  local script="$1"
  if command -v node > /dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      try {
        const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
        const owns = Object.prototype.hasOwnProperty.call(pkg.scripts || {}, process.argv[1]);
        process.exit(owns ? 0 : 1);
      } catch { process.exit(1); }
    ' "$script"
    return
  fi

  # Sem Node, ainda resolva um comando para que o preflight possa explicar que
  # o runtime falta. Limite o fallback ao objeto scripts, em vez do JSON todo.
  awk -v wanted="$script" '
    /"scripts"[[:space:]]*:/ { scripts=1 }
    scripts && $0 ~ "\\\"" wanted "\\\"[[:space:]]*:" { found=1 }
    scripts && /}/ { exit }
    END { exit !found }
  ' package.json
}

node_required_major() {
  local f value
  for f in .node-version .nvmrc; do
    [ -f "$f" ] || continue
    value="$(sed -n '1{s/^[[:space:]]*v//;s/[[:space:]].*$//;p;}' "$f")"
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
      echo "${value%%.*}"
      return 0
    fi
  done
  return 1
}

profile_test_cmd() {
  # Um script `check` e o gate mecanico completo do projeto real usado para
  # fundar este perfil (typecheck + lint + formato + testes + build).
  if node_has_script check; then
    echo "npm run check"
  elif node_has_script test; then
    echo "npm test"
  fi
}

profile_preflight() {
  local cmd="$1" first required_major current_major
  first="${cmd%% *}"
  [ "$(basename -- "$first")" = "npm" ] || return 0

  if ! command -v node > /dev/null 2>&1; then
    fail "Perfil Node.js detectado, mas node nao esta no PATH."
    fail "Ative a versao declarada pelo projeto antes de rodar o ralph."
    exit 1
  fi
  if ! command -v npm > /dev/null 2>&1; then
    fail "Perfil Node.js detectado, mas npm nao esta no PATH."
    exit 1
  fi

  if required_major="$(node_required_major)"; then
    current_major="$(node -p 'process.versions.node.split(".")[0]' 2> /dev/null || true)"
    if [ "$current_major" != "$required_major" ]; then
      fail "Perfil Node.js detectado, mas o projeto pede Node $required_major e o PATH fornece Node ${current_major:-desconhecido}."
      fail "Ative a versao declarada em .node-version/.nvmrc antes de rodar o ralph."
      exit 1
    fi
  fi

  if [ ! -d node_modules ] && grep -qE '"(dependencies|devDependencies)"[[:space:]]*:' package.json; then
    fail "Perfil Node.js detectado, mas node_modules nao existe."
    if [ -f package-lock.json ]; then
      fail "Rode 'npm ci' antes de iniciar o ralph."
    else
      fail "Rode 'npm install' antes de iniciar o ralph."
    fi
    exit 1
  fi
}

profile_prompt_notes() {
  echo "O projeto usa Node.js com npm: execute build, lint, formato e testes pelos"
  echo "scripts declarados em package.json; nao invoque binarios de node_modules direto."
}

profile_hook() { return 0; }
