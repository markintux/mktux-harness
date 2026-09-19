#!/usr/bin/env bash
# profiles/python/profile.sh — perfil Python com pytest.
#
# Contrato em scripts/lib/profile.sh. Sourced: so define funcoes. Roda sob o
# `set -euo pipefail` do ralph.sh.

profile_detect() {
  [ -f "$1/pyproject.toml" ] &&
    grep -qE '^\[(project|tool\.poetry|tool\.pytest[^]]*|build-system)\]' "$1/pyproject.toml"
}

python_has_pytest_config() {
  [ -f pytest.ini ] || grep -qF '[tool.pytest' pyproject.toml
}

python_pytest_in_dev_extra() {
  awk '
    /^\[project\.optional-dependencies\]$/ { optional=1; next }
    optional && /^\[/ { exit }
    optional && /^[[:space:]]*("[^"]+"|[A-Za-z0-9_-]+)[[:space:]]*=/ {
      key=$0
      sub(/=.*/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^"|"$/, "", key)
      dev=(key == "dev")
    }
    dev && /pytest/ { found=1 }
    END { exit !found }
  ' pyproject.toml
}

profile_test_cmd() {
  python_has_pytest_config || return 0
  if [ -f uv.lock ]; then
    echo "uv run pytest"
  elif [ -f poetry.lock ]; then
    echo "poetry run pytest"
  else
    echo "pytest"
  fi
}

profile_preflight() {
  local cmd="$1" first runner
  first="${cmd%% *}"
  runner="$(basename -- "$first")"

  case "$runner" in
    uv)
      if ! command -v uv > /dev/null 2>&1; then
        fail "Perfil Python detectado com uv.lock, mas uv nao esta no PATH."
        exit 1
      fi
      [[ "$cmd" == *pytest* ]] || return 0
      if ! uv run --no-sync pytest --version > /dev/null 2>&1; then
        fail "Perfil Python detectado, mas pytest nao esta instalado no ambiente uv."
        if python_pytest_in_dev_extra; then
          fail "Rode 'uv sync --extra dev' antes de iniciar o ralph."
        else
          fail "Sincronize as dependencias de desenvolvimento antes de iniciar o ralph."
        fi
        exit 1
      fi
      ;;
    poetry)
      if ! command -v poetry > /dev/null 2>&1; then
        fail "Perfil Python detectado com poetry.lock, mas poetry nao esta no PATH."
        exit 1
      fi
      [[ "$cmd" == *pytest* ]] || return 0
      if ! poetry run pytest --version > /dev/null 2>&1; then
        fail "Perfil Python detectado, mas pytest nao esta instalado no ambiente Poetry."
        fail "Instale as dependencias de desenvolvimento antes de iniciar o ralph."
        exit 1
      fi
      ;;
    pytest)
      if ! command -v pytest > /dev/null 2>&1; then
        fail "Perfil Python detectado, mas pytest nao esta no PATH."
        fail "Ative ou prepare o ambiente de desenvolvimento antes de iniciar o ralph."
        exit 1
      fi
      ;;
  esac
}

profile_prompt_notes() {
  if [ -f uv.lock ]; then
    echo "O projeto usa uv: rode ferramentas Python no ambiente do projeto via 'uv run'."
  elif [ -f poetry.lock ]; then
    echo "O projeto usa Poetry: rode ferramentas Python via 'poetry run'."
  else
    echo "O projeto usa Python: respeite o ambiente virtual e os comandos documentados."
  fi
  if grep -qF '[tool.ruff' pyproject.toml; then
    echo "Ruff esta configurado no pyproject.toml; use o comando documentado pelo projeto."
  fi
}

profile_hook() { return 0; }
