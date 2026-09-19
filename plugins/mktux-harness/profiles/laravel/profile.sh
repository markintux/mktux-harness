# profiles/laravel/profile.sh — perfil Laravel (Sail).
#
# Contrato em scripts/lib/profile.sh. Sourced: so define funcoes. Roda sob o
# `set -euo pipefail` do ralph.sh.

profile_detect() { [ -f "$1/artisan" ]; }

# Laravel Sail: a suite roda DENTRO do container. Rodar `composer test` /
# `php artisan test` no host falha (sem PHP, sem banco, sem rede do compose).
# Ecoa o caminho do binario sail quando o projeto usa Sail.
laravel_sail_bin() {
  [ -f artisan ] || return 1
  if [ -x vendor/bin/sail ]; then
    echo "vendor/bin/sail"
    return 0
  fi
  # Sail declarado no composer.json mas vendor/ ainda nao instalado.
  if [ -f composer.json ] && grep -qF 'laravel/sail' composer.json; then
    echo "vendor/bin/sail"
    return 0
  fi
  return 1
}

# Containers de pe? O wrapper do sail imprime "Sail is not running." e sai != 0.
laravel_sail_running() {
  local sail="$1" out rc=0
  out=$("$sail" ps 2>&1) || rc=$?
  grep -qiF 'is not running' <<< "$out" && return 1
  [ "$rc" -ne 0 ] && return 1
  grep -qiE '(^|[[:space:]])(Up|running)([[:space:]]|$)' <<< "$out"
}

profile_test_cmd() {
  local sail
  # Sail vem ANTES de composer: num projeto Laravel dockerizado o host nao tem
  # PHP nem acesso ao banco, e `composer test` mentiria como gate.
  if sail="$(laravel_sail_bin)"; then
    # --compact: a saida do gate 2 vira prompt de correcao (tail -200). O formato
    # verboso do PHPUnit enche esse orcamento com ruido em vez de falhas.
    echo "$sail artisan test --compact"
  elif [ -f composer.json ] && grep -qE '"test"[[:space:]]*:' composer.json; then
    echo "composer test"
  else
    echo "php artisan test"
  fi
}

# Gate 2 so tem valor se rodar de verdade. Sail com containers parados falha
# toda fase e queima ciclos de correcao inuteis — aborta antes da 1a sessao.
profile_preflight() {
  local cmd="$1" sail first
  sail="$(laravel_sail_bin)" || return 0
  # O comando invoca o sail? Olha o executavel (1o token), nao a string
  # inteira: um caminho como /tmp/sail-fixture/test.sh nao usa sail.
  first="${cmd%% *}"
  [ "$(basename -- "$first")" = "sail" ] || return 0

  if [ ! -x "$sail" ]; then
    fail "Laravel Sail detectado, mas $sail nao existe."
    fail "Rode a instalacao de dependencias do projeto (ex: composer install) antes."
    exit 1
  fi

  if ! laravel_sail_running "$sail"; then
    fail "Laravel Sail detectado, mas os containers nao estao de pe."
    fail "A suite de testes (gate 2) roda dentro do container e falharia em toda fase."
    fail "Suba o ambiente antes de rodar o ralph:"
    fail "    $sail up -d"
    exit 1
  fi

  log "Sail: containers de pe"
}

# Sem isto o agente roda `php artisan test` no host de um projeto Sail: ele ve
# verde e o gate 2 ve vermelho. O filtro e o teste focado que o prompt pede
# durante o trabalho: a suite inteira fica para o fim.
profile_prompt_notes() {
  local sail
  if sail="$(laravel_sail_bin)"; then
    echo "O projeto usa Laravel Sail: artisan, composer, php e testes rodam DENTRO"
    echo "do container, via '$sail <cmd>'. Nunca rode essas ferramentas no host."
    echo "Teste focado: '$sail artisan test --compact --filter=<NomeDoTeste>'."
  else
    echo "Teste focado: 'php artisan test --compact --filter=<NomeDoTeste>'."
  fi
}

profile_hook() {
  case "$1" in
    pre-bash)         echo "hooks/shared/sail-guard.sh" ;;
    claude-post-edit) echo "hooks/claude/pint-and-test.sh" ;;
    codex-stop)       echo "hooks/codex/pint-and-test.sh" ;;
  esac
}
