#!/usr/bin/env bash
#
# test-ralph.sh — suite red/green do scripts/ralph.sh com engine mock.
#
# Nenhuma chamada de rede, nenhum token gasto: binarios fake `claude` e `codex`
# entram no PATH e o comportamento e escolhido por MOCK_SCENARIO.
#
# Uso: scripts/test-ralph.sh [nome-do-caso]   (exit 0 = tudo verde)

set -uo pipefail

# Os scripts sob teste sao IRMAOS deste arquivo. Com ".." o caminho apontava
# para a raiz do plugin, onde nao ha ralph.sh: toda a suite saia 127.
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
# RALPH_BIN permite apontar para uma copia patchada (prova red dos testes).
RALPH="${RALPH_BIN:-$SCRIPTS/ralph.sh}"
WATCH="${WATCH_BIN:-$SCRIPTS/ralph-watch.sh}"
# Uma copia patchada do ralph.sh fora de scripts/ acha a lib de perfis por
# aqui. Fixo neste plugin: o MKTUX_HARNESS_ROOT de quem roda pode ser outro clone.
export MKTUX_HARNESS_ROOT
MKTUX_HARNESS_ROOT="$(cd "$SCRIPTS/.." && pwd)"
ONLY="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
CURRENT=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()   { PASS=$((PASS + 1)); echo -e "  ${GREEN}ok${NC}   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1"; }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then ok "$msg"; else bad "$msg (esperado '$expected', veio '$actual')"; fi
}

assert_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" "$haystack_file"; then ok "$msg"; else bad "$msg (nao achou '$needle')"; fi
}

assert_not_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" "$haystack_file"; then bad "$msg (achou '$needle')"; else ok "$msg"; fi
}

# ---------------------------------------------------------------------------
# Mock engine — vale para claude e codex (dispatch por basename)
# ---------------------------------------------------------------------------

make_mocks() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/mock-engine" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

name=$(basename "$0")
state="${MOCK_STATE:?}"
scenario="${MOCK_SCENARIO:-ok}"
prompt=""
verify=0

# O ralph exporta o comando do gate 2 para as sessoes (o test-runner le dali).
printf '%s\n' "${RALPH_TEST_CMD-<unset>}" >> "$state/session_test_cmd"
# Fase, ciclo e modo: o log-tokens grava os tres em cada linha do tokens.jsonl.
printf '%s %s %s\n' "${RALPH_PHASE_NUM-}" "${RALPH_PHASE_ATTEMPT-}" "${RALPH_SESSION_MODE-}" >> "$state/session_env"
printf '%s\n' "${RALPH_RUN_ID-}" >> "$state/session_run_ids"

bump() {
  local f="$state/$1" n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1))
  echo "$n" > "$f"
  echo "$n"
}

model=""
effort=""
disallowed=""
strict=0
tools=""
noskills=0
last=""

# Os hooks do plugin gravam telemetria na raiz do projeto a cada tool call.
if [ "${MOCK_HARNESS:-0}" = "1" ]; then
  mkdir -p .harness
  echo "{\"session\":\"$name\"}" >> .harness/events.jsonl
fi

if [ "$name" = "claude" ]; then
  # claude -p real le stdin quando nao e TTY: se o ralph nao redirecionar
  # < /dev/null, o mock engole o stream de quem chamou (ex: manifest do loop).
  [ -t 0 ] || cat > /dev/null
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --allowedTools) verify=1; shift 2 ;;
      --disallowedTools) disallowed="$2"; shift 2 ;;
      --tools) tools="$2"; shift 2 ;;
      --disable-slash-commands) noskills=1; shift ;;
      --strict-mcp-config) strict=1; shift ;;
      --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --output-format) shift 2 ;;
      # Isolamento dos hooks do ai-memory: uma linha por sessao que o recebeu.
      --setting-sources) echo "$2" >> "$state/setting_sources"; shift 2 ;;
      --settings)
        echo "$2" > "$state/settings_path"
        if [ -f "$2" ]; then
          cat "$2" > "$state/settings_json"
          ls -l "$2" | cut -c1-10 > "$state/settings_perm"
        else
          printf '%s\n' "$2" > "$state/settings_json"
        fi
        shift 2 ;;
      *) shift ;;
    esac
  done
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sandbox) [ "$2" = "read-only" ] && verify=1; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      -o|--output-last-message) last="$2"; shift 2 ;;
      -c)
        case "$2" in
          model_reasoning_effort=*) effort="${2#*=}" ;;
          hooks.state=*) echo "$2" >> "$state/hook_overrides" ;;
          features.memories=*) echo "$2" >> "$state/codex_memories" ;;
        esac
        shift 2 ;;
      *) shift ;;
    esac
  done
  prompt=$(cat)
fi

grep -q '^RALPH_VERIFY' <<< "$prompt" && verify=1

# --- juiz das contestacoes (gate 2 vermelho) --------------------------------
# Procede nos cenarios contest-protected*: a fase proibe tocar no arquivo que a
# suite precisa. Nos demais recusa, com o numero da primeira contestacao.
if grep -q '^RALPH_JUDGE' <<< "$prompt"; then
  n=$(bump judge_calls)
  ro=0
  [ "$name" = "claude" ] && [[ "$disallowed" == *Write* ]] && ro=1
  [ "$name" = "codex" ] && [ "$verify" -eq 1 ] && ro=1
  echo "$ro" > "$state/judge_readonly"
  echo "$model" > "$state/judge_model"
  cnum=$(grep -oE '^RALPH-CONTEST: TASK [0-9]+' <<< "$prompt" | head -1 | grep -oE '[0-9]+$' || true)
  case "$scenario" in
    contest-protected|contest-protected-late)
      verdict="CONTEST TASK ${cnum:-1}: UPHELD — src/protected.txt: aceitar o tipo que o framework passa" ;;
    *)
      verdict="CONTEST TASK ${cnum:-1}: REJECTED — a suite fica verde sem mexer em src/protected.txt" ;;
  esac
  [ -n "$last" ] && printf '%s' "$verdict" > "$last"
  echo "$verdict"
  exit 0
fi

# Grava o modelo pedido para a sessao verificadora (assert do teste de modelo).
if [ "$verify" -eq 1 ] && [ -n "$model" ]; then
  echo "$model" > "$state/verify_model"
fi
if [ "$verify" -eq 1 ] && [ -n "$effort" ]; then
  echo "$effort" > "$state/verify_effort"
fi
if [ "$verify" -eq 1 ] && [ "$name" = "claude" ]; then
  echo "$disallowed" > "$state/verify_disallowed"
  echo "$strict" > "$state/verify_strict"
  echo "$tools" > "$state/verify_tools"
  echo "$noskills" > "$state/verify_noskills"
fi
if [ "$verify" -eq 1 ] && [ "$name" = "codex" ]; then
  echo "$last" > "$state/verify_last_path"
fi
if [ "$verify" -eq 0 ] && [ "$name" = "codex" ] && [ -n "$last" ]; then
  echo "$last" > "$state/impl_last_path"
fi
if [ "$verify" -eq 0 ] && [ -n "$effort" ]; then
  echo "$effort" > "$state/impl_effort"
fi

# --- verificador independente ------------------------------------------------
# Verifica o CODIGO REAL, como o verificador de verdade: sem arquivo de
# implementacao no repo, a fase esta incompleta.
if [ "$verify" -eq 1 ]; then
  n=$(bump verify_calls)
  tasks=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")

  implemented=0
  compgen -G "src/impl-*.txt" > /dev/null 2>&1 && implemented=1

  last_dest=/dev/null
  if [ "$name" = "codex" ] && [ -n "$last" ] && [ "${MOCK_CODEX_NO_LAST:-0}" != "1" ]; then
    last_dest="$last"
  fi

  if [ "$implemented" -eq 0 ]; then
    for i in $(seq 1 "$tasks"); do echo "TASK $i: INCOMPLETE — nenhum codigo encontrado"; done \
      | tee "$last_dest"
    exit 0
  fi

  emit_tasks() {
    if [ "$scenario" = "verify-manual-incomplete" ]; then
      # Julga a task (manual) mesmo sem ela estar na lista pedida.
      local i=0 l
      while IFS= read -r l; do
        i=$((i + 1))
        case "$l" in
          *"(manual)"*) echo "TASK $i: INCOMPLETE — aguardando o formatador" ;;
          *) echo "TASK $i: DONE" ;;
        esac
      done < <(grep -E '^[[:space:]]*- \[[ x]\]' <<< "$prompt")
    elif { [ "$scenario" = "contest-verified" ] || [ "$scenario" = "contest-late" ]; } \
      && grep -q '^## Phase 1:' <<< "$prompt" && ! grep -q '^RALPH-CONTEST: TASK 1 ' <<< "$prompt"; then
      # Fase 1 sem a contestacao no prompt: cobra a letra da task.
      echo "TASK 1: INCOMPLETE — usa outro token em vez de border-border"
      for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE"; done
    elif [ "$scenario" = "contest-rejected" ] && [ "$n" -eq 1 ]; then
      echo "TASK 1: INCOMPLETE — contestacao recusada: border-border esta definido em tailwind.config.js:30"
      for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE"; done
    elif { [ "$scenario" = "verify-incomplete-once" ] || [ "$scenario" = "contest-other" ]; } && [ "$n" -eq 1 ]; then
      echo "TASK 1: INCOMPLETE — o arquivo nao foi criado"
      for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE"; done
    else
      for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE"; done
    fi
  }

  # -o: o codex grava so a mensagem final, sem \n no fim da ultima linha.
  # MOCK_CODEX_NO_LAST simula a engine que nao gravou (codex antigo, crash).
  printf '%s' "$(emit_tasks)" > "$last_dest"

  # verify-last-only: o transcript nao traz veredito legivel; so o -o traz.
  if [ "$scenario" = "verify-last-only" ]; then
    echo "transcript sem veredito"
    exit 0
  fi

  emit_tasks
  # `codex exec` reimprime a ultima mensagem do agente depois do resumo de
  # tokens: o bloco TASK sai DUAS vezes no log. Reproduzido aqui porque foi o
  # que quebrou o gate 3 num run real.
  if [ "$name" = "codex" ]; then
    echo "tokens used"
    echo "32.203"
    emit_tasks
  fi
  exit 0
fi

# --- sessao de implementacao -------------------------------------------------
n=$(bump impl_calls)
# Quem roda a engine: o teste de sinal manda SIGTERM para esse processo.
echo "$PPID" > "$state/engine_ppid"

# hang-once: a 1a sessao trava (comando esperando input que nunca chega).
if [ "$scenario" = "hang-once" ] && [ "$n" -eq 1 ]; then
  sleep 37
fi

emit_claude_limit() { echo "{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"result\":\"Claude AI usage limit reached|$1\"}"; }

case "$scenario" in
  limit-epoch)
    if [ "$n" -eq 1 ]; then
      emit_claude_limit "$(date +%s)"
      exit 1
    fi
    ;;
  limit-generic)
    if [ "$n" -eq 1 ]; then
      echo "Rate limit reached. Try again later."
      exit 1
    fi
    ;;
  sigint)
    # Ctrl-C durante a sessao: o shell devolve 128+SIGINT.
    echo "Interrompido."
    exit 130
    ;;
esac

# stall-after-red: escreve no 1o ciclo (teste vermelho), depois trava sem
# escrever nada. already-done: o codigo ja existe em HEAD, o engine nao escreve.
write=1
[ "$scenario" = "empty-diff" ] && write=0
[ "$scenario" = "already-done" ] && write=0
[ "$scenario" = "stall-after-red" ] && [ "$n" -gt 1 ] && write=0
[ "$scenario" = "contest-late" ] && [ "$n" -eq 2 ] && write=0
# contest-protected*: a suite so fica verde com src/unlocked.txt, que a fase
# proibe criar. A sessao respeita a trava (nao escreve na correcao) ate o prompt
# trazer a trava liberada pelo juiz.
unlocked=0 protected_phase=0
grep -q '^## Travas liberadas pelo juiz' <<< "$prompt" && unlocked=1
case "$scenario" in
  contest-protected|contest-protected-late|contest-protected-rejected)
    grep -q '^## Phase 1:' <<< "$prompt" && protected_phase=1
    [ "$protected_phase" -eq 1 ] && [ "$n" -gt 1 ] && [ "$unlocked" -eq 0 ] && write=0 ;;
esac

if [ "$write" -eq 1 ]; then
  mkdir -p src
  echo "impl $n" > "src/impl-$n.txt"
  [ "$unlocked" -eq 1 ] && echo "liberado" > src/unlocked.txt
fi

if [ "$scenario" = "false-limit-json" ] && [ "$name" = "claude" ]; then
  # O agente CITOU a frase no resultado (leu um log, resumiu um erro alheio).
  # A sessao terminou limpa: is_error=false. Nao e limite de uso. Como o log do
  # modo impl e UMA linha de JSON, nenhum `tail` isola esse texto.
  echo '{"type":"result","subtype":"success","is_error":false,"result":"Rodei a suite. O log da app tinha a linha: Claude AI usage limit reached. Corrigido."}'
  exit 0
fi

if [ "$scenario" = "false-429" ]; then
  # 429 no MEIO do log: e output de teste do projeto, nao limite de uso.
  echo "FAIL tests/HttpClientTest: expected 429 Too Many Requests, got 200"
  for i in $(seq 1 25); do echo "linha de ruido $i"; done
  echo "Suite corrigida. Done."
  exit 0
fi

# Mensagem final da sessao: o .result do claude, o -o do codex.
final="implementado"
case "$scenario" in
  contest-verified|contest-rejected)
    [ "$n" -eq 1 ] && final="$final
RALPH-CONTEST: TASK 1 — o token border-border nao existe (tailwind.config.js:26)" ;;
  contest-late)
    [ "$n" -eq 2 ] && final="$final
RALPH-CONTEST: TASK 1 — o token border-border nao existe (tailwind.config.js:26)" ;;
  contest-green|contest-test-red)
    final="$final
RALPH-CONTEST: TASK 2 — BR-13 exige o filtro que a task nao cita (feature-description.md:149)" ;;
  contest-other)
    [ "$n" -eq 1 ] && final="$final
RALPH-CONTEST: TASK 2 — BR-13 exige o filtro que a task nao cita (feature-description.md:149)" ;;
  empty-diff)
    final="Travado: SendPubReportsTest so passa tocando o comando, proibido nesta fase" ;;
  contest-protected|contest-protected-rejected)
    [ "$protected_phase" -eq 1 ] && [ "$unlocked" -eq 0 ] && final="$final
RALPH-CONTEST: TASK 1 — src/protected.txt:3 tipa o argumento errado e a fase proibe tocar nele" ;;
  contest-protected-late)
    [ "$protected_phase" -eq 1 ] && [ "$n" -gt 1 ] && [ "$unlocked" -eq 0 ] && final="$final
RALPH-CONTEST: TASK 1 — src/protected.txt:3 tipa o argumento errado e a fase proibe tocar nele" ;;
esac
[ -n "$last" ] && printf '%s\n' "$final" > "$last"
if [ "$name" = "claude" ]; then
  printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' \
    "$(printf '%s' "$final" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
else
  echo "Done."
  echo "$final"
fi
exit 0
MOCK

  chmod +x "$bin/mock-engine"
  cp "$bin/mock-engine" "$bin/claude"
  cp "$bin/mock-engine" "$bin/codex"

  # ai-memory fake: `status` responde conforme MOCK_MEMORY_STATUS; `write-page`
  # guarda args e corpo por chamada e sai conforme MOCK_MEMORY_WRITE. Grava o
  # HEAD no momento da chamada para provar que a pagina e escrita pos-commit.
  cat > "$bin/ai-memory" <<'MEMMOCK'
#!/usr/bin/env bash
set -uo pipefail
state="${MOCK_STATE:?}"
case "${1:-}" in
  status) exit "${MOCK_MEMORY_STATUS:-0}" ;;
  write-page)
    f="$state/memory_calls"; n=0
    [ -f "$f" ] && n=$(cat "$f")
    n=$((n + 1)); echo "$n" > "$f"
    shift
    printf '%s\n' "$*" > "$state/memory_args-$n"
    cat > "$state/memory_body-$n"
    git rev-parse --short HEAD > "$state/memory_head-$n"
    exit "${MOCK_MEMORY_WRITE:-0}"
    ;;
esac
exit 0
MEMMOCK
  chmod +x "$bin/ai-memory"
}

make_testcmd() {
  cat > "$1" <<'TESTCMD'
#!/usr/bin/env bash
set -uo pipefail
state="${MOCK_STATE:?}"
scenario="${MOCK_SCENARIO:-ok}"
# sail test real (docker compose exec) anexa stdin: mesmo risco do claude -p.
[ -t 0 ] || cat > /dev/null
f="$state/test_calls"; n=0
[ -f "$f" ] && n=$(cat "$f")
n=$((n + 1)); echo "$n" > "$f"

if [ "$scenario" = "test-red-once" ] || [ "$scenario" = "stall-after-red" ] || [ "$scenario" = "contest-test-red" ]; then
  if [ "$n" -eq 1 ]; then
    echo "1 failing test: ExpectedFooTest"
    exit 1
  fi
fi
case "$scenario" in
  contest-protected|contest-protected-late|contest-protected-rejected)
    if [ -d src ] && [ ! -f src/unlocked.txt ]; then
      echo "1 failing test: ProtectedTypeTest (500 em src/protected.txt:3)"
      exit 1
    fi ;;
esac
echo "all green"
exit 0
TESTCMD
  chmod +x "$1"
}

PHASES_FIXTURE='# Test Project — Project Phases

<!-- inputs: project-description.md@sha256:000000000000 -->

## Overview

Projeto de teste.

## Phase 1: Foundation

- [ ] **Task:** cria o arquivo A
  - **Acceptance criteria:**
    - o arquivo existe
- [ ] **Task:** cria o arquivo B
  - **Acceptance criteria:**
    - o arquivo existe

## Phase 2: Feature

- [ ] **Task:** cria o arquivo C
  - **Acceptance criteria:**
    - o arquivo existe

## Open Questions

- nenhuma
'

# Fixture de projeto Laravel + Sail. `sail ps` responde conforme SAIL_UP.
make_sail_fixture() {
  local repo="$1" up="$2"

  touch "$repo/artisan"
  cat > "$repo/composer.json" <<'JSON'
{
  "require-dev": { "laravel/sail": "^1.0" },
  "scripts": { "test": "phpunit" }
}
JSON

  mkdir -p "$repo/vendor/bin"
  cat > "$repo/vendor/bin/sail" <<SAILMOCK
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = "ps" ]; then
  if [ "$up" = "up" ]; then
    echo "NAME                IMAGE            STATUS"
    echo "proj-laravel.test-1 sail-8.3/app     Up 2 hours"
    exit 0
  fi
  echo "Sail is not running."
  exit 1
fi
if [ "\${1:-}" = "test" ] || { [ "\${1:-}" = "artisan" ] && [ "\${2:-}" = "test" ]; }; then
  exec "\$MOCK_TEST_CMD"
fi
exit 0
SAILMOCK
  chmod +x "$repo/vendor/bin/sail"
}

# new_case <nome> -> ecoa o diretorio do repo fixture
new_case() {
  local name="$1"
  local dir="$TMP/$name"
  # claude-home / codex-home: config de usuario da engine. Vazias, a suite nao
  # depende dos hooks instalados na maquina de quem roda os testes.
  mkdir -p "$dir/repo" "$dir/state" "$dir/bin" "$dir/claude-home" "$dir/codex-home"
  make_mocks "$dir/bin"
  make_testcmd "$dir/test.sh"

  (
    cd "$dir/repo" || exit 1
    git init -q
    git config user.email "test@ralph"
    git config user.name "Ralph Test"
    mkdir -p .spec/init
    printf '%s' "$PHASES_FIXTURE" > .spec/init/project-phases.md
    git add -A
    git commit -q -m "chore: fixture"
  )
  echo "$dir"
}

# run_ralph <dir> <scenario> [args...] -> ecoa o exit code; log em <dir>/out.log
run_ralph() {
  local dir="$1" scenario="$2"; shift 2
  local rc=0
  (
    cd "$dir/repo" || exit 1
    PATH="$dir/bin:$PATH" \
    MOCK_STATE="$dir/state" \
    MOCK_SCENARIO="$scenario" \
    MOCK_TEST_CMD="$dir/test.sh" \
    RALPH_LIMIT_WAIT_DEFAULT=1 \
    RALPH_LIMIT_BUFFER=1 \
    RALPH_VERIFY="${CASE_VERIFY:-}" \
    RALPH_VERIFY_MODEL="${CASE_VERIFY_MODEL:-}" \
    RALPH_VERIFY_EFFORT="${CASE_VERIFY_EFFORT:-}" \
    RALPH_SMOKE="${CASE_SMOKE:-0}" \
    RALPH_SESSION_TIMEOUT="${CASE_SESSION_TIMEOUT:-}" \
    RALPH_MEMORY="${CASE_MEMORY:-0}" \
    RALPH_MEMORY_BIN="${CASE_MEMORY_BIN:-ai-memory}" \
    RALPH_HOOK_ISOLATION="${CASE_HOOK_ISOLATION:-1}" \
    RALPH_MEM0="" \
    RALPH_MEM0_USER="${CASE_MEM0_USER:-}" \
    MOCK_MEMORY_STATUS="${CASE_MEMORY_STATUS:-0}" \
    MOCK_MEMORY_WRITE="${CASE_MEMORY_WRITE:-0}" \
    MOCK_CODEX_NO_LAST="${CASE_CODEX_NO_LAST:-0}" \
    MOCK_HARNESS="${CASE_HARNESS:-0}" \
    CLAUDE_CONFIG_DIR="$dir/claude-home" \
    CODEX_HOME="$dir/codex-home" \
      bash "$RALPH" "$@" > "$dir/out.log" 2>&1
  ) || rc=$?
  echo "$rc"
}

commits() { git -C "$1/repo" rev-list --count HEAD; }

case_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# count_lines <arquivo> -> numero de linhas; 0 quando o arquivo nao existe
count_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

header() { CURRENT="$1"; echo -e "\n${YELLOW}== $1${NC}"; }

# ---------------------------------------------------------------------------
# 1. Fase ok de primeira -> 1 commit por fase, progresso gravado
# ---------------------------------------------------------------------------
if case_enabled ok-first; then
  header "1. fase ok de primeira"
  d=$(new_case ok-first)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "2 commits de fase (1 fixture + 2)"
  assert_contains "$d/repo/.phases/.progress" "phase-01.md" "progresso registra phase-01"
  assert_contains "$d/repo/.phases/.progress" "phase-02.md" "progresso registra phase-02"
  assert_eq "feat(phase-2): Feature" "$(git -C "$d/repo" log -1 --pretty=%s)" "mensagem de commit da ultima fase"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "1 sessao de implementacao por fase (2 fases)"
  assert_eq 2 "$(cat "$d/state/verify_calls")" "gate 3 (default always) rodou em toda fase"
  assert_eq "1 1 impl
1 1 verify
2 1 impl
2 1 verify" "$(cat "$d/state/session_env")" "sessoes recebem fase, ciclo e modo (para o tokens.jsonl)"
  assert_eq 1 "$(sort -u "$d/state/session_run_ids" | wc -l | tr -d ' ')" "todas as sessoes recebem o mesmo run id"
  assert_eq 1 "$(find "$d/repo/.harness/runs" -name '*.json' | wc -l | tr -d ' ')" "resumo local criado pela invocacao"
  assert_eq "partial" "$(jq -r '.summary.status' "$d/repo/.harness/runs/"*.json)" "engine mock sem usage fica parcial"
fi

# ---------------------------------------------------------------------------
# 2. Gate 2 vermelho 1x -> ciclo de correcao -> verde -> 1 commit so
# ---------------------------------------------------------------------------
if case_enabled test-red-once; then
  header "2. gate 2 vermelho uma vez -> ciclo de correcao"
  d=$(new_case test-red-once)
  rc=$(run_ralph "$d" test-red-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit por fase (ciclo intermediario nao commita)"
  assert_contains "$d/out.log" "Gate 2 vermelho" "gate 2 reportado vermelho"
  assert_contains "$d/out.log" "Ciclo de correcao 2/2" "entrou em ciclo de correcao"
  # o prompt de correcao carrega a causa REAL, nao "os testes falharam" generico
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "ExpectedFooTest" "prompt de correcao carrega a saida do teste"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "O gate 2" "correcao deixa suite completa para o gate 2"
  assert_not_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "suite completa UMA vez" "correcao sem suite completa obrigatoria"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "## Fase a completar" "prompt de correcao e auto-contido (fase inteira)"
  # logs por ciclo, nunca sobrescritos
  test -f "$d/repo/.phases/logs/phase-01.cycle-1.log" && test -f "$d/repo/.phases/logs/phase-01.cycle-2.log" \
    && ok "logs por ciclo preservados" || bad "logs por ciclo preservados"
fi

# ---------------------------------------------------------------------------
# 3. Engine nao escreve nada e a fase esta incompleta -> falha sem commit
#    (gate 1 sinaliza; quem reprova e o verificador, contra o codigo real)
# ---------------------------------------------------------------------------
if case_enabled empty-diff; then
  header "3. engine nao escreve nada + fase incompleta -> falha sem commit"
  d=$(new_case empty-diff)
  rc=$(run_ralph "$d" empty-diff --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 1 "$rc" "exit 1"
  assert_eq 1 "$(commits "$d")" "nenhum commit criado (sem --allow-empty)"
  assert_contains "$d/out.log" "a sessao nao escreveu nada" "gate 1 sinalizou a sessao vazia"
  assert_contains "$d/out.log" "Gate 3 vermelho" "verificador reprovou contra o codigo real"
  assert_contains "$d/out.log" "Parando na primeira fase que falhou" "politica default = parar"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "sem alterar nenhum arquivo" "causa do ciclo cita a sessao vazia"
fi

# ---------------------------------------------------------------------------
# 4. Verificador INCOMPLETE 1x -> ciclo -> DONE -> commit
# ---------------------------------------------------------------------------
if case_enabled verify-incomplete; then
  header "4. verificador INCOMPLETE uma vez -> ciclo -> DONE"
  d=$(new_case verify-incomplete)
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit por fase"
  assert_contains "$d/out.log" "Gate 3 vermelho" "gate 3 reportado vermelho"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "TASK 1: INCOMPLETE" "prompt de correcao carrega as tasks incompletas verbatim"
  test -f "$d/repo/.phases/logs/phase-01.verify-1.log" && ok "log do verificador por ciclo" || bad "log do verificador por ciclo"
fi

# ---------------------------------------------------------------------------
# 5. Limite com epoch -> espera -> re-executa a MESMA fase sem consumir ciclo
# ---------------------------------------------------------------------------
if case_enabled limit-epoch; then
  header "5. limite com epoch -> espera -> mesma fase"
  d=$(new_case limit-epoch)
  # --max-cycles 1: se a espera consumisse um ciclo, a fase falharia
  rc=$(run_ralph "$d" limit-epoch --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (limite nao consome ciclo)"
  assert_eq 3 "$(commits "$d")" "fases commitadas apos a espera"
  assert_contains "$d/out.log" "Limite de uso atingido" "limite detectado"
  assert_contains "$d/out.log" "Reset previsto para" "epoch de reset extraido do log"
  test -f "$d/repo/.phases/logs/phase-01.cycle-1.limit-1.log" \
    && ok "log da tentativa antes do retry preservado" \
    || bad "log da tentativa antes do retry preservado"
fi

# ---------------------------------------------------------------------------
# 6. Limite generico sem epoch -> fallback wait
# ---------------------------------------------------------------------------
if case_enabled limit-generic; then
  header "6. limite generico sem epoch -> fallback"
  d=$(new_case limit-generic)
  rc=$(run_ralph "$d" limit-generic --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "Sem horario de reset no output" "usou o fallback de espera"
  assert_eq 3 "$(commits "$d")" "fases commitadas apos a espera"
fi

# ---------------------------------------------------------------------------
# 7. "429 Too Many Requests" no MEIO do log -> NAO dispara espera (regressao)
# ---------------------------------------------------------------------------
if case_enabled false-429; then
  header "7. 429 no meio do log nao dispara espera"
  d=$(new_case false-429)
  start=$(date +%s)
  rc=$(run_ralph "$d" false-429 --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  elapsed=$(($(date +%s) - start))
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/out.log" "Limite de uso atingido" "nao interpretou 429 de teste como limite"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" "429 Too Many Requests" "o 429 realmente estava no log"
  [ "$elapsed" -lt 5 ] && ok "sem espera (${elapsed}s)" || bad "sem espera (${elapsed}s)"
fi

# ---------------------------------------------------------------------------
# 8. Segunda execucao com mesmo input -> fases feitas puladas (resume vivo)
# ---------------------------------------------------------------------------
if case_enabled resume; then
  header "8. resume: segunda execucao pula fases feitas"
  d=$(new_case resume)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "primeira execucao verde"
  before=$(commits "$d")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "segunda execucao verde"
  assert_eq "$before" "$(commits "$d")" "nenhum commit novo"
  assert_contains "$d/out.log" "Progresso anterior preservado" "progresso preservado (input inalterado)"
  assert_contains "$d/out.log" "(ja completada)" "fases puladas"
fi

# ---------------------------------------------------------------------------
# 9. Input mutado entre execucoes -> progresso invalidado com aviso
# ---------------------------------------------------------------------------
if case_enabled resume-invalidated; then
  header "9. input mutado -> progresso invalidado"
  d=$(new_case resume-invalidated)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "primeira execucao verde"
  before=$(commits "$d")
  (
    cd "$d/repo" || exit 1
    printf '\n## Phase 3: Extra\n\n- [ ] **Task:** cria o arquivo D\n  - **Acceptance criteria:**\n    - o arquivo existe\n' >> .spec/init/project-phases.md
    git add -A && git commit -q -m "chore: nova fase"
  )
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "segunda execucao verde"
  assert_contains "$d/out.log" "progresso zerado" "progresso invalidado com aviso"
  # As fases 1 e 2 ja tem commit feat(phase-N): os gates as revalidam contra
  # HEAD, sem sessao. So a fase nova abre sessao e commita.
  assert_contains "$d/out.log" "Fase ja commitada neste branch (feat(phase-1))" "fase commitada revalidada sem sessao"
  assert_eq 3 "$(cat "$d/state/impl_calls")" "so a fase nova abriu sessao (2 do 1o run + 1)"
  assert_eq $((before + 2)) "$(commits "$d")" "commit da mutacao + fase 3"
fi

# ---------------------------------------------------------------------------
# 10. Arvore suja no preflight -> abort antes de qualquer sessao
# ---------------------------------------------------------------------------
if case_enabled dirty-tree; then
  header "10. arvore suja -> abort no preflight"
  d=$(new_case dirty-tree)
  echo "trabalho nao commitado" > "$d/repo/rascunho.txt"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Arvore de trabalho suja" "abortou com instrucao"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de engine iniciada" || ok "nenhuma sessao de engine iniciada"
fi

# ---------------------------------------------------------------------------
# 11. Contrato de formato do input -> abort antes de gastar token
# ---------------------------------------------------------------------------
if case_enabled bad-format; then
  header "11. heading de fase torto -> abort no preflight"
  d=$(new_case bad-format)
  (
    cd "$d/repo" || exit 1
    sed 's/^## Phase 2: Feature$/## Phase Two — Feature/' .spec/init/project-phases.md > .heading.tmp \
      && mv .heading.tmp .spec/init/project-phases.md
    git add -A && git commit -q -m "chore: heading torto"
  )
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  # "## Phase Two" nao casa com '^## Phase [0-9]+: ' -> heading malformado
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Contrato de formato violado" "abortou por formato invalido"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de engine iniciada" || ok "nenhuma sessao de engine iniciada"
fi

# ---------------------------------------------------------------------------
# 12. Ciclo de correcao que nao escreve nada, mas o codigo do ciclo anterior
#     esta completo e verde -> a fase passa (o verificador manda, nao o diff)
# ---------------------------------------------------------------------------
if case_enabled stall-after-red; then
  header "12. ciclo sem escrita + codigo completo -> gate 3 decide, fase passa"
  d=$(new_case stall-after-red)
  rc=$(run_ralph "$d" stall-after-red --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  # o mock so escreve na 1a sessao: fase 1 commita apos o ciclo 2; fase 2 cai
  # no caminho "ja implementada" (o verificador ve o codigo e aprova)
  assert_eq 2 "$(commits "$d")" "1 commit (fase 1); fase 2 nao tinha o que commitar"
  assert_contains "$d/out.log" "Gate 2 vermelho" "o ciclo comecou por um gate 2 vermelho"
  assert_contains "$d/out.log" "a sessao nao escreveu nada" "gate 1 sinalizou a sessao vazia do ciclo 2"
  assert_contains "$d/out.log" "feat(phase-1)" "fase 1 commitada apos o ciclo de correcao"
fi

# ---------------------------------------------------------------------------
# 17. Fase JA implementada em HEAD (run anterior commitada) -> reconhecida
#     sem commit, sem falhar. Regressao do bug real: o engine nao escreve
#     porque nao ha o que escrever, e o gate 1 reprovava isso.
# ---------------------------------------------------------------------------
if case_enabled already-done; then
  header "17. fase ja implementada em HEAD -> reconhecida sem commit"
  d=$(new_case already-done)
  # simula a run anterior: codigo implementado e commitado a mao, progress vazio
  mkdir -p "$d/repo/src"
  echo "impl previo" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: trabalho da run anterior"
  before=$(commits "$d")

  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (nao reprova fase ja implementada)"
  assert_contains "$d/out.log" "JA IMPLEMENTADA" "reconheceu a fase como feita"
  assert_eq "$before" "$(commits "$d")" "nenhum commit criado (nada a commitar)"
  assert_contains "$d/repo/.phases/.progress" "phase-01.md" "progresso registra a fase"
  assert_contains "$d/repo/.phases/.progress" "phase-02.md" "progresso registra a fase seguinte"
fi

# ---------------------------------------------------------------------------
# 18. Fase falhou -> avisa que o trabalho parcial ficou na arvore
# ---------------------------------------------------------------------------
if case_enabled dirty-after-fail; then
  header "18. fase falhou com trabalho na arvore -> instrui o dev"
  d=$(new_case dirty-after-fail)
  # verify-incomplete-once com 1 ciclo: escreve, testes verdes, verificador reprova
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1"
  assert_eq 1 "$(commits "$d")" "nenhum commit"
  assert_contains "$d/out.log" "trabalho parcial desta fase ficou na arvore" "avisou sobre a arvore suja"
  assert_contains "$d/out.log" "git clean -fd" "deu a saida de descarte"
fi

# ---------------------------------------------------------------------------
# 19. --no-verify desliga o gate 3 mesmo no caminho suspeito (sessao sem
#     escrita). Escolha explicita do dev: o ralph confia no gate 2 sozinho.
# ---------------------------------------------------------------------------
if case_enabled no-verify; then
  header "19. --no-verify desliga o gate 3 ate no caminho suspeito"
  d=$(new_case no-verify)
  rc=$(run_ralph "$d" empty-diff --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-verify)
  assert_eq 0 "$rc" "exit 0 (gate 2 verde decide sozinho)"
  assert_contains "$d/out.log" "Gate 3 pulado (--no-verify)" "skip explicito logado"
  assert_contains "$d/out.log" "Gate 2 verde contra o codigo em HEAD" "mensagem nao menciona gate 3 (nao rodou)"
  test -f "$d/state/verify_calls" && bad "nenhuma sessao verificadora gasta" || ok "nenhuma sessao verificadora gasta"
fi

# ---------------------------------------------------------------------------
# 20. RALPH_VERIFY=auto (opt-in): caminho feliz (sessao escreveu + suite verde)
#     pula o gate 3; a fase ainda commita.
# ---------------------------------------------------------------------------
if case_enabled verify-auto; then
  header "20. RALPH_VERIFY=auto pula o gate 3 no caminho feliz"
  d=$(new_case verify-auto)
  rc=$(CASE_VERIFY=auto run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "fases commitadas"
  assert_contains "$d/out.log" "Gate 3 pulado: a sessao escreveu codigo" "skip logado com a causa"
  test -f "$d/state/verify_calls" && bad "nenhuma sessao verificadora gasta" || ok "nenhuma sessao verificadora gasta"
fi

# ---------------------------------------------------------------------------
# 21. Verificador roda com modelo barato: haiku por default no claude,
#     RALPH_VERIFY_MODEL sobrepoe.
# ---------------------------------------------------------------------------
if case_enabled verify-model; then
  header "21. verificador usa modelo barato (haiku default, env sobrepoe)"
  d=$(new_case verify-model)
  # fase ja implementada em HEAD: sessao nao escreve -> gate 3 roda em auto
  mkdir -p "$d/repo/src"
  echo "impl previo" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: trabalho previo"
  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "haiku" "$(cat "$d/state/verify_model" 2>/dev/null)" "verify chamado com --model haiku"
  assert_contains "$d/out.log" "modelo: haiku" "log do gate 3 informa o modelo"

  d2=$(new_case verify-model-override)
  mkdir -p "$d2/repo/src"
  echo "impl previo" > "$d2/repo/src/impl-1.txt"
  git -C "$d2/repo" add -A && git -C "$d2/repo" commit -q -m "feat: trabalho previo"
  rc=$(CASE_VERIFY_MODEL=sonnet run_ralph "$d2" already-done --engine claude --test-cmd "$d2/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (override)"
  assert_eq "sonnet" "$(cat "$d2/state/verify_model" 2>/dev/null)" "RALPH_VERIFY_MODEL sobrepoe o default"
fi

# ---------------------------------------------------------------------------
# 13. Laravel Sail com containers de pe -> gate 2 usa `vendor/bin/sail test`
#     (e NAO `composer test`, que rodaria no host sem PHP nem banco)
# ---------------------------------------------------------------------------
if case_enabled sail-up; then
  header "13. Laravel Sail up -> gate 2 roda sail test"
  d=$(new_case sail-up)
  make_sail_fixture "$d/repo" up
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude)   # sem --test-cmd: exercita a deteccao
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "comando de teste (detectado): vendor/bin/sail artisan test --compact" "detectou sail test"
  assert_not_contains "$d/out.log" "composer test" "composer test nao foi escolhido"
  assert_contains "$d/out.log" "Sail: containers de pe" "checou containers no preflight"
  # base = 2 commits (fixture + chore: sail) + 2 fases
  assert_eq 4 "$(commits "$d")" "fases commitadas (gate 2 rodou de verdade)"
  assert_eq 2 "$(cat "$d/state/test_calls")" "a suite rodou 1x por fase, via sail"
  # o agente precisa saber qual runner usar, senao roda php artisan test no host
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "vendor/bin/sail artisan test --compact" "prompt informa o comando de teste"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Nunca rode essas ferramentas no host" "prompt avisa sobre o container"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Teste focado: 'vendor/bin/sail artisan test --compact --filter=" "prompt da o teste focado pelo sail"
fi

# ---------------------------------------------------------------------------
# 14. Sail com containers parados -> abort no preflight, zero tokens
# ---------------------------------------------------------------------------
if case_enabled sail-down; then
  header "14. Laravel Sail down -> abort no preflight"
  d=$(new_case sail-down)
  make_sail_fixture "$d/repo" down
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "containers nao estao de pe" "abortou com a causa"
  assert_contains "$d/out.log" "vendor/bin/sail up -d" "instruiu como subir o ambiente"
  assert_eq 2 "$(commits "$d")" "nenhum commit de fase"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de engine iniciada" || ok "nenhuma sessao de engine iniciada"
fi

# ---------------------------------------------------------------------------
# 15. --test-cmd sobrepoe a deteccao de Sail
# ---------------------------------------------------------------------------
if case_enabled sail-override; then
  header "15. --test-cmd sobrepoe a deteccao de Sail"
  d=$(new_case sail-override)
  make_sail_fixture "$d/repo" down   # containers parados, mas o cmd nao usa sail
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (nao checa containers para cmd sem sail)"
  assert_contains "$d/out.log" "comando de teste (--test-cmd)" "override respeitado"
  assert_eq 4 "$(commits "$d")" "fases commitadas"
fi

# ---------------------------------------------------------------------------
# 16. Laravel sem Sail -> composer test (regressao: nao vira sail test)
# ---------------------------------------------------------------------------
if case_enabled laravel-no-sail; then
  header "16. Laravel sem Sail -> composer test"
  d=$(new_case laravel-no-sail)
  touch "$d/repo/artisan"
  printf '{ "scripts": { "test": "phpunit" } }\n' > "$d/repo/composer.json"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: laravel"
  # nao roda ate o fim: so precisamos do preflight resolvendo o comando
  run_ralph "$d" empty-diff --engine claude --max-cycles 1 > /dev/null
  assert_contains "$d/out.log" "comando de teste (detectado): composer test" "sem sail -> composer test"
  assert_not_contains "$d/out.log" "Sail" "nao mencionou Sail"
fi

# ---------------------------------------------------------------------------
echo ""

# ---------------------------------------------------------------------------
# 22. Patches locais: smoke test da engine + pagina por fase no ai-memory
# ---------------------------------------------------------------------------
if case_enabled local-patches; then
  header "22. smoke test + ai-memory (patches locais)"

  CASE_SMOKE=1
  CASE_MEMORY=1
  d=$(new_case local-patches)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 com smoke e memoria ligados"
  assert_contains "$d/out.log" "Smoke test OK" "smoke test rodou no preflight"
  assert_contains "$d/out.log" "Memoria gravada no ai-memory" "ai-memory gravou a fase"
  assert_eq 3 "$(commits "$d")" "fases commitadas normalmente (1 fixture + 2 fases)"

  d=$(new_case local-patches-nosmoke)
  rc=$(run_ralph "$d" ok --engine claude --no-smoke --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 com --no-smoke"
  assert_contains "$d/out.log" "Smoke test pulado" "--no-smoke pula o smoke"
  assert_not_contains "$d/out.log" "Smoke test OK" "nenhuma sessao gasta no smoke"

  CASE_SMOKE=0
  CASE_MEMORY=0
fi

# ---------------------------------------------------------------------------
# 23. Verificador no codex: modelo e effort baratos por default (patch local)
# ---------------------------------------------------------------------------
if case_enabled verify-codex-defaults; then
  header "23. verificador no codex usa luna + effort low (patch local)"
  d=$(new_case verify-codex-defaults)
  mkdir -p "$d/repo/src"
  echo "impl previo" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: trabalho previo"
  rc=$(run_ralph "$d" already-done --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "gpt-5.6-luna" "$(cat "$d/state/verify_model" 2>/dev/null)" "verify no codex usa gpt-5.6-luna"
  assert_eq "low" "$(cat "$d/state/verify_effort" 2>/dev/null)" "verify no codex usa effort low"
  assert_contains "$d/out.log" "modelo: gpt-5.6-luna, effort: low" "log do gate 3 informa modelo e effort"

  d2=$(new_case verify-codex-override)
  mkdir -p "$d2/repo/src"
  echo "impl previo" > "$d2/repo/src/impl-1.txt"
  git -C "$d2/repo" add -A && git -C "$d2/repo" commit -q -m "feat: trabalho previo"
  CASE_VERIFY_MODEL=gpt-5.4-mini
  CASE_VERIFY_EFFORT=medium
  rc=$(run_ralph "$d2" already-done --engine codex --test-cmd "$d2/test.sh" --max-cycles 1)
  CASE_VERIFY_MODEL=""
  CASE_VERIFY_EFFORT=""
  assert_eq 0 "$rc" "exit 0 (override)"
  assert_eq "gpt-5.4-mini" "$(cat "$d2/state/verify_model" 2>/dev/null)" "RALPH_VERIFY_MODEL sobrepoe no codex"
  assert_eq "medium" "$(cat "$d2/state/verify_effort" 2>/dev/null)" "RALPH_VERIFY_EFFORT sobrepoe no codex"
fi

# ---------------------------------------------------------------------------
# 24. Ctrl-C na sessao aborta o run; nao vira ciclo de correcao (patch local)
# ---------------------------------------------------------------------------
if case_enabled sigint; then
  header "24. Ctrl-C aborta o run em vez de abrir ciclo de correcao"
  d=$(new_case sigint)
  rc=$(run_ralph "$d" sigint --engine claude --test-cmd "$d/test.sh")
  assert_eq 130 "$rc" "exit 130 (propaga o sinal)"
  assert_contains "$d/out.log" "Execucao interrompida (sinal 130)" "avisou a interrupcao"
  assert_not_contains "$d/out.log" "Ciclo de correcao" "nao abriu ciclo de correcao"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "so uma sessao de engine foi iniciada"
  assert_eq 1 "$(commits "$d")" "nenhum commit de fase (so o fixture)"
fi

# ---------------------------------------------------------------------------
# 25. Bloco TASK duplicado pelo codex nao reprova o gate 3 (patch local)
# ---------------------------------------------------------------------------
if case_enabled verify-duplicated; then
  header "25. codex duplica o bloco TASK -> gate 3 consolida por task"
  # Sem o -o gravado o veredito sai do log, onde o bloco aparece duas vezes.
  CASE_CODEX_NO_LAST=1
  d=$(new_case verify-duplicated)
  rc=$(run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (nao reprova por cobertura)"
  assert_contains "$d/out.log" "2/2 tasks confirmadas no codigo" "contou 2 tasks, nao 4"
  assert_not_contains "$d/out.log" "cobertura incompleta" "sem falso negativo de cobertura"
  assert_eq 3 "$(commits "$d")" "as 2 fases commitadas"

  # INCOMPLETE em uma das emissoes ainda reprova: na duvida, incompleto.
  d2=$(new_case verify-duplicated-incomplete)
  rc=$(run_ralph "$d2" verify-incomplete-once --engine codex --test-cmd "$d2/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 (INCOMPLETE vence DONE duplicado)"
  assert_contains "$d2/out.log" "tasks incompletas" "reportou a task incompleta"
  CASE_CODEX_NO_LAST=""
fi

# ---------------------------------------------------------------------------
# 26. Estado do run publicado em .phases/state/run.tsv (contrato do painel)
# ---------------------------------------------------------------------------
if case_enabled state-publish; then
  header "26. run verde publica o estado completo"
  d=$(new_case state-publish)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  state="$d/repo/.phases/state/run.tsv"

  assert_eq 0 "$rc" "exit 0"
  if [ -f "$state" ]; then ok "run.tsv publicado"; else bad "run.tsv publicado"; fi

  assert_contains "$state" "$(printf 'META\tstatus\tdone')" "META marca o run como concluido"
  assert_contains "$state" "$(printf 'META\ttotal\t2')" "META tem o total de fases"
  assert_contains "$state" "$(printf 'META\tengine\tclaude')" "META tem a engine"
  assert_contains "$state" "$(printf 'PHASE\t1\t1\tdone')" "fase 1 done"
  assert_contains "$state" "$(printf 'PHASE\t2\t2\tdone')" "fase 2 done"
  assert_contains "$state" "$(printf 'TASK\t1\t1\tdone')" "task 1 da fase 1 done"
  assert_contains "$state" "$(printf 'TASK\t2\t1\tdone')" "task 1 da fase 2 done"
  assert_contains "$state" "2:pass:" "gate 2 verde no estado"
  assert_contains "$state" "3:pass:" "gate 3 verde no estado"
  assert_contains "$state" "$(printf 'WAIT\t0')" "sem espera de limite pendente"

  # As 3 tasks do fixture (2 na fase 1, 1 na fase 2) viram 3 linhas TASK.
  assert_eq 3 "$(grep -c '^TASK' "$state")" "uma linha TASK por task do plano"
fi

# ---------------------------------------------------------------------------
# 27. Gate vermelho aparece no estado como fase failed + gate fail
# ---------------------------------------------------------------------------
if case_enabled state-red; then
  header "27. fase reprovada publica gate vermelho"
  d=$(new_case state-red)
  rc=$(run_ralph "$d" stall-after-red --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  state="$d/repo/.phases/state/run.tsv"

  assert_eq 1 "$rc" "exit 1"
  assert_contains "$state" "$(printf 'META\tstatus\tfailed')" "META marca o run como falho"
  assert_contains "$state" "$(printf 'PHASE\t1\t1\tfailed')" "fase 1 failed"
  assert_contains "$state" "2:fail:" "gate 2 vermelho no estado"
  assert_not_contains "$state" "$(printf 'PHASE\t1\t1\tdone')" "fase falha nao vira done"
fi

# ---------------------------------------------------------------------------
# 28. ralph-watch.sh --once renderiza o estado publicado
# ---------------------------------------------------------------------------
if case_enabled watch-once; then
  header "28. painel le o estado e desenha"
  d=$(new_case watch-once)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (setup)"

  wrc=0
  # RALPH_WATCH_COLS fixa a largura: sem isso o painel le o tamanho real do
  # terminal de quem roda a suite e as colunas truncam os titulos assertados.
  RALPH_WATCH_COLS=120 bash "$WATCH" --once --no-color "$d/repo" > "$d/watch.log" 2>&1 || wrc=$?
  assert_eq 0 "$wrc" "painel sai 0"
  assert_contains "$d/watch.log" "Foundation" "titulo da fase 1 na tabela"
  assert_contains "$d/watch.log" "Feature" "titulo da fase 2 na tabela"
  assert_contains "$d/watch.log" "cria o arquivo A" "task listada na tabela"
  assert_contains "$d/watch.log" "Concluído" "status do run no cabecalho"
  assert_contains "$d/watch.log" "2/2" "barra de fases em 2/2"
  assert_contains "$d/watch.log" "3/3" "barra de tasks em 3/3"
  assert_contains "$d/watch.log" "PROGRESSO" "box de progresso"
  assert_contains "$d/watch.log" "TRABALHO ATUAL" "box do trabalho atual"
  assert_contains "$d/watch.log" "Fase / Task" "cabecalho da tabela"

  # Sem estado nenhum o painel avisa em vez de estourar.
  rm -rf "$d/repo/.phases/state"
  wrc=0
  RALPH_WATCH_COLS=120 bash "$WATCH" --once --no-color "$d/repo" > "$d/watch-empty.log" 2>&1 || wrc=$?
  assert_eq 0 "$wrc" "painel sai 0 sem estado"
  assert_contains "$d/watch-empty.log" "sem run publicado" "avisa que nao ha run"
fi

# ---------------------------------------------------------------------------
# 29. --dashboard sem TTY nao aborta o run: cai no log linear
# ---------------------------------------------------------------------------
if case_enabled dashboard-no-tty; then
  header "29. --dashboard sem terminal degrada para log linear"
  d=$(new_case dashboard-no-tty)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --dashboard)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "dashboard exige um terminal" "avisou a degradacao"
  assert_contains "$d/out.log" "RELATORIO FINAL" "relatorio final continua na saida"
  assert_eq 3 "$(commits "$d")" "as 2 fases commitadas normalmente"
fi

# ---------------------------------------------------------------------------
# 30. Gate 3 e read-only DE VERDADE no claude
#     --dangerously-skip-permissions auto-aprova tudo, entao --allowedTools nao
#     restringe nada: o "verificador read-only" conseguia escrever. Se ele
#     consertasse a task que ia reprovar, o veredito viria DONE e o `git add -A`
#     commitaria codigo que o gate 2 — que roda ANTES do gate 3 — nunca testou.
# ---------------------------------------------------------------------------
if case_enabled verify-readonly; then
  header "30. gate 3 read-only no claude"
  d=$(new_case verify-readonly)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/state/verify_disallowed" "Write" "verificador recebe deny de Write"
  assert_contains "$d/state/verify_disallowed" "Edit" "verificador recebe deny de Edit"
  assert_contains "$d/state/verify_disallowed" "Bash" "verificador recebe deny de Bash"
  assert_not_contains "$d/state/verify_disallowed" "MultiEdit" "sem MultiEdit (o CLI rejeita: tool inexistente)"
  assert_eq 1 "$(cat "$d/state/verify_strict")" "verificador roda sem MCP (--strict-mcp-config)"
  assert_eq "Read,Glob,Grep" "$(cat "$d/state/verify_tools" 2>/dev/null)" "verificador so tem Read/Glob/Grep (--tools)"
  assert_eq 1 "$(cat "$d/state/verify_noskills" 2>/dev/null)" "verificador sem listagem de skills (--disable-slash-commands)"
fi

# ---------------------------------------------------------------------------
# 31. Memoria por fase: pagina no ai-memory, sem sessao de engine
#     `ai-memory write-page` e deterministico: nenhuma sessao a mais (impl_calls
#     nao muda), vale nas duas engines, e roda DEPOIS do commit — o SHA da
#     pagina e o da fase fechada.
# ---------------------------------------------------------------------------
if case_enabled memory-page; then
  header "31. pagina por fase no ai-memory, pos-commit, sem sessao extra"
  d=$(new_case memory-page)
  rc=$(CASE_MEMORY=1 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 2 "$(cat "$d/state/memory_calls" 2>/dev/null || echo 0)" "1 write-page por fase (2 fases)"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "memoria nao abre sessao de engine"
  assert_eq 3 "$(commits "$d")" "as 2 fases seguem commitadas"
  assert_contains "$d/state/memory_args-1" "--path ralph/init/phase-01.md" "pagina da fase 1 em ralph/<feature>/"
  assert_contains "$d/state/memory_args-2" "--path ralph/init/phase-02.md" "pagina da fase 2 em ralph/<feature>/"
  assert_contains "$d/state/memory_args-1" "--tier episodic" "tier episodic"
  assert_contains "$d/state/memory_args-1" "--tag ralph --tag init" "tags ralph + feature"
  assert_contains "$d/state/memory_args-1" "--body -" "corpo via stdin"
  assert_contains "$d/state/memory_body-1" "# init — Phase 1: Foundation" "titulo da pagina"
  assert_contains "$d/state/memory_body-1" "cria o arquivo A" "plano da fase no corpo"
  phase1=$(git -C "$d/repo" log --format=%h --grep='feat(phase-1)')
  assert_eq "$phase1" "$(cat "$d/state/memory_head-1" 2>/dev/null)" "gravada com a fase 1 ja commitada"
  assert_contains "$d/state/memory_body-1" "Commit: \`$phase1\`" "SHA da fase no corpo"
  assert_contains "$d/state/memory_body-1" "src/impl-1.txt" "arquivos da fase no corpo"

  d=$(new_case memory-page-codex)
  rc=$(CASE_MEMORY=1 run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "codex: exit 0"
  assert_eq 2 "$(cat "$d/state/memory_calls" 2>/dev/null || echo 0)" "codex tambem grava 1 pagina por fase"
fi

# ---------------------------------------------------------------------------
# 32. Contexto do prompt vem dos irmaos do input, nao de caminho fixo
#     Caminho hardcoded que nao existe faz TODA sessao — implementacao e cada
#     ciclo de correcao — queimar tool calls procurando arquivo fantasma.
# ---------------------------------------------------------------------------
if case_enabled sibling-docs; then
  header "32. docs irmaos do input entram no prompt"
  d=$(new_case sibling-docs)
  fd="$d/repo/docs/features/barcode"
  mkdir -p "$fd"
  cat > "$fd/project-phases.md" <<'PLAN'
# Barcode — Project Phases

<!-- inputs: x -->

## Phase 1: Foundation

**Read first:** `feature-description.md` next to this file, section "Overview"; rule BR-02; `database-schema.md`, table `sales`.

- [ ] **Task:** cria o arquivo A
- [ ] `tests/scan` (new file) covers these scenarios, one test case each:
  - cashier scans → item added (US-1.1)

## Phase 2: Feature

- [ ] **Task:** cria o arquivo C
PLAN
  cat > "$fd/user-stories.md" <<'DOC'
# User Stories

### 1. Barcode

**US-1.1** — As a cashier, I want to scan.

- Given a product
- Then it is added

**US-1.2** — As a manager, I want reports.

- Given sales
DOC
  cat > "$fd/feature-description.md" <<'DOC'
# Feature Description

## Overview

Visao geral da feature.

## Business Rules

1. **BR-01 — Scan unico:** um scan por item.
2. **BR-02 — Sem duplicado:** nada duplicado.

## UI

Tela de caixa.
DOC
  printf '# schema\n\n## New Tables\n\n```dbml\nTable sales {\n  id int [pk]\n}\n\nTable refunds {\n  id int [pk]\n}\n```\n' > "$fd/database-schema.md"
  echo "# brief" > "$fd/feature-brief.md"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: feature docs"

  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" docs/features/barcode/project-phases.md)
  assert_eq 0 "$rc" "exit 0"
  prompt="$d/repo/.phases/prompts/phase-01.cycle-1.txt"
  assert_contains "$prompt" "docs/features/barcode/user-stories.md" "user-stories irmao listado"
  assert_contains "$prompt" "docs/features/barcode/database-schema.md" "database-schema irmao listado"
  assert_not_contains "$prompt" "docs/features/barcode/project-phases.md" "o proprio plano nao se auto-lista"
  assert_not_contains "$prompt" ".spec/init/project-description.md" "sem caminho fantasma do layout antigo"

  # Contexto sob demanda: so o que a fase cita, recortado; o resto so por caminho.
  # Mandar ler os docs fazia 25 de 26 sessoes lerem todos, inteiros (~19k tokens).
  assert_contains "$prompt" "## Contexto desta fase" "recorte do que a fase cita"
  assert_contains "$prompt" "Visao geral da feature." "secao citada no Read first"
  assert_contains "$prompt" "**BR-02 — Sem duplicado:**" "regra citada"
  assert_not_contains "$prompt" "BR-01 — Scan unico" "regra nao citada fica fora"
  assert_contains "$prompt" "**US-1.1** — As a cashier" "story citada no cenario de teste"
  assert_not_contains "$prompt" "US-1.2** — As a manager" "story nao citada fica fora"
  assert_not_contains "$prompt" "Tela de caixa." "secao nao citada fica fora"
  assert_contains "$prompt" "Table sales {" "tabela citada: bloco DBML"
  assert_not_contains "$prompt" "Table refunds {" "tabela nao citada fica fora"
  assert_contains "$prompt" "Nao leia inteiros" "docs completos so para consulta pontual"
  assert_contains "$prompt" "O gate 2 executa" "implementacao delega suite completa ao gate 2"
  assert_not_contains "$prompt" "rode a suite completa UMA vez" "implementacao sem suite completa obrigatoria"
  assert_not_contains "$prompt" "docs/features/barcode/feature-brief.md" "brief fora da lista de consulta"
  p2="$d/repo/.phases/prompts/phase-02.cycle-1.txt"
  assert_not_contains "$p2" "## Contexto desta fase" "fase sem citacao: sem recorte"
  assert_contains "$p2" "## Documentos do plano" "fase sem citacao: caminhos para consulta"
fi

# ---------------------------------------------------------------------------
# 33. Re-rodar preserva os logs da execucao anterior
#     A mensagem de falha manda conferir .phases/logs/, e o caminho para
#     conferir passa por re-rodar o ralph: apagar tudo perdia o log no ato
#     de ir busca-lo.
# ---------------------------------------------------------------------------
if case_enabled logs-survive-rerun; then
  header "33. logs sobrevivem ao re-run"
  d=$(new_case logs-survive-rerun)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (1a execucao)"
  ls "$d/repo/.phases/logs/phase-01.cycle-1.log" > /dev/null 2>&1 \
    && ok "log da fase 1 existe apos a 1a execucao" \
    || bad "log da fase 1 existe apos a 1a execucao"

  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (re-run)"
  ls "$d/repo/.phases/logs/phase-01.cycle-1.log" > /dev/null 2>&1 \
    && ok "log da 1a execucao sobreviveu ao re-run" \
    || bad "log da 1a execucao sobreviveu ao re-run"
fi

# ---------------------------------------------------------------------------
# 34. "usage limit reached" citado numa sessao que terminou limpa nao dorme
#     No claude o log do modo impl e UMA linha de JSON: `tail -n 20` devolve o
#     arquivo inteiro, entao a frase citada pelo proprio agente cairia no grep
#     de limite e o ralph dormiria e re-rodaria a MESMA fase, ate 20x.
# ---------------------------------------------------------------------------
if case_enabled false-limit-json; then
  header "34. limite citado com is_error=false nao dispara espera"
  d=$(new_case false-limit-json)
  rc=$(run_ralph "$d" false-limit-json --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/out.log" "Limite de uso atingido" "nao tratou o texto citado como limite"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "1 sessao por fase, sem re-execucao por espera"
  assert_eq 3 "$(commits "$d")" "as 2 fases commitadas"
fi

# ---------------------------------------------------------------------------
# 35. geometria do quadro vivo do painel
#
# O --once (caso 28) nao serve para isto: ele nao rola, nao preenche a altura e
# nao emite \033[K nenhum. E o quadro vivo que tem geometria.
#
# O que esta sendo travado aqui ja quebrou de tres jeitos diferentes, e nenhum
# deles aparece lendo o texto da saida — so o DESENHO:
#   1. \033[K depois do conteudo comia o ultimo glifo da linha (a borda direita
#      inteira do painel sumia), porque com o autowrap desligado o cursor
#      ESTACIONA na ultima coluna e o EL apaga da posicao dele INCLUSIVE.
#   2. a sobra do corpo da tabela vinha como linha em branco, partindo a caixa
#      ao meio numa tela alta.
#   3. numa tela estreita a soma das colunas passava de COLS e o terminal
#      cortava a borda direita.
#
# Precisa de pty: sem TTY no stdout o painel cai em --once. O `script` do BSD
# exige tty no stdin (nao serve em pipe nem CI), entao o pty vem do python3.
# ---------------------------------------------------------------------------
if case_enabled watch-frame; then
  header "35. painel desenha o quadro na geometria da tela"
  d=$(new_case watch-frame)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (setup)"

  if ! command -v python3 > /dev/null 2>&1; then
    echo "  (pulado: sem python3 para abrir um pty)"
  else
    # NAO pode se chamar pty.py: sombrearia o modulo pty da stdlib.
    cat > "$d/frame-probe.py" <<'PTY_EOF'
import fcntl, os, pty, re, select, signal, struct, sys, termios, time

rows, cols, out_path, script, repo = (
    int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5])

pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ, RALPH_WATCH_LINES=str(rows), RALPH_WATCH_COLS=str(cols))
    os.execvpe("bash", ["bash", script, repo], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
buf, deadline = b"", time.time() + 3
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        continue
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
try:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
except OSError:
    pass

# O pty devolve CRLF. Sem normalizar, "\033[K\n" nunca casa e a contagem que
# distingue o EL depois do conteudo do EL antes dele da sempre zero.
data = buf.decode("utf-8", "replace").replace("\r\n", "\n")
# O quadro inteiro sai num printf so, comecando em \033[H.
frames = data.split("\033[H")
frame = frames[-1].split("\033[J")[0] if len(frames) > 1 else ""
# O pty devolve CRLF: sem tirar o \r toda linha mede uma coluna a mais e
# nenhuma delas "termina" na borda.
lines = frame.split("\n")
plain = [re.sub(r"\033\[[0-9;?]*[A-Za-z]", "", ln).replace("\r", "") for ln in lines]

# Borda direita: a ultima coluna de toda linha de caixa tem que sobreviver ao
# desenho. Linha de caixa e a que comeca com um glifo de moldura.
box = [ln for ln in plain if ln[:1] in "┌├└│"]
no_right_edge = [ln for ln in box if ln[-1:] not in "┐┤┘│█"]

with open(out_path, "w") as fh:
    fh.write("frame_lines=%d\n" % len(lines))
    fh.write("max_width=%d\n" % max([len(ln) for ln in plain] or [0]))
    # A invariante do EL: toda linha do quadro COMECA limpando a si mesma. Com o
    # \033[K no fim em vez do inicio, o cursor parado na ultima coluna faz o EL
    # apagar o glifo que acabou de ser escrito — a borda direita inteira. Contar
    # "\033[K\n" nao serve: uma linha em branco com o EL no inicio produz
    # exatamente a mesma sequencia.
    fh.write("linhas_com_el_no_inicio=%d\n" % len([ln for ln in lines if ln.startswith("\033[K")]))
    fh.write("linhas_sem_el_no_inicio=%d\n" % len([ln for ln in lines if not ln.startswith("\033[K")]))
    fh.write("box_lines=%d\n" % len(box))
    fh.write("sem_borda_direita=%d\n" % len(no_right_edge))
PTY_EOF

    # Duas geometrias: 90 colunas com a tabela folgada, e 78 — abaixo das 84 em
    # que COL_NAME bate no piso e a soma das colunas passava de COLS.
    probe_frame() { # <linhas> <colunas>
      local r="$1" c="$2" tag="${1}x${2}"
      frame_lines=0; max_width=0; box_lines=0; sem_borda_direita=1
      linhas_com_el_no_inicio=0; linhas_sem_el_no_inicio=1
      python3 "$d/frame-probe.py" "$r" "$c" "$d/frame-$tag.txt" "$WATCH" "$d/repo" \
        > "$d/probe-$tag.log" 2>&1 || true
      if [ ! -s "$d/frame-$tag.txt" ]; then
        bad "$tag: painel desenhou um quadro no pty (ver $d/probe-$tag.log)"
        return 0
      fi
      # shellcheck disable=SC1090
      . "$d/frame-$tag.txt"
      assert_eq "$r" "$frame_lines"       "$tag: o quadro ocupa as $r linhas da tela"
      assert_eq "$c" "$max_width"         "$tag: nenhuma linha passa das $c colunas"
      assert_eq 0   "$linhas_sem_el_no_inicio" "$tag: toda linha comeca limpando a si mesma"
      assert_eq 0   "$sem_borda_direita"  "$tag: toda linha de caixa fecha na borda direita"
      if [ "$linhas_com_el_no_inicio" -eq "$r" ]; then
        ok "$tag: as $r linhas do quadro levam o \\033[K no inicio"
      else
        bad "$tag: as $r linhas do quadro levam o \\033[K no inicio (veio $linhas_com_el_no_inicio)"
      fi
      if [ "$box_lines" -ge 10 ]; then
        ok "$tag: o quadro tem caixas desenhadas ($box_lines linhas)"
      else
        bad "$tag: o quadro tem caixas desenhadas (veio $box_lines)"
      fi
    }
    probe_frame 30 90
    probe_frame 30 78
  fi
fi

# ---------------------------------------------------------------------------
# 36. Memoria falha aberta: sem binario, servidor fora ou escrita recusada, o
#     run segue verde e as fases sao commitadas. Memoria e registro, nao gate.
# ---------------------------------------------------------------------------
if case_enabled memory-fail-open; then
  header "36. ai-memory ausente ou fora do ar nao derruba o run"
  d=$(new_case memory-missing)
  rc=$(CASE_MEMORY=1 CASE_MEMORY_BIN=/nao/existe/ai-memory \
       run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "sem binario: exit 0"
  assert_contains "$d/out.log" "ai-memory nao encontrado" "sem binario: memoria desligada no preflight"
  assert_eq 3 "$(commits "$d")" "sem binario: fases commitadas"

  d=$(new_case memory-down)
  rc=$(CASE_MEMORY=1 CASE_MEMORY_STATUS=1 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "servidor fora: exit 0"
  assert_contains "$d/out.log" "Servidor do ai-memory fora do ar" "servidor fora: aviso no preflight"
  assert_eq 0 "$(cat "$d/state/memory_calls" 2>/dev/null || echo 0)" "servidor fora: nenhuma escrita tentada"

  d=$(new_case memory-write-fails)
  rc=$(CASE_MEMORY=1 CASE_MEMORY_WRITE=1 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "escrita recusada: exit 0"
  assert_contains "$d/out.log" "Falha ao gravar no ai-memory" "escrita recusada: aviso por fase"
  assert_eq 3 "$(commits "$d")" "escrita recusada: fases commitadas"

  d=$(new_case memory-legacy-env)
  rc=$(CASE_MEM0_USER=alguem run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "variavel antiga: exit 0"
  assert_contains "$d/out.log" "RALPH_MEM0/RALPH_MEM0_USER foram removidas" "variavel antiga do mem0 avisa"
fi

# ---------------------------------------------------------------------------
# 37. Isolamento dos hooks do ai-memory no claude
#     O SessionStart do ai-memory consome handoffs (GET destrutivo) e injeta
#     contexto. Toda sessao do ralph — smoke, impl, gate 3 — roda sem a config
#     de usuario e recebe de volta essa mesma config MENOS os hooks do ai-memory:
#     model, plugins e os demais hooks do usuario continuam.
# ---------------------------------------------------------------------------
if case_enabled hook-isolation-claude; then
  header "37. claude: sessoes do ralph sem os hooks do ai-memory"
  d=$(new_case hook-isolation-claude)
  cat > "$d/claude-home/settings.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] },
      { "matcher": "", "hooks": [ { "type": "command", "command": "/bin/ai-memory hook --event pre-tool-use --agent claude-code" } ] }
    ],
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/bin/ai-memory hook --event session-start --agent claude-code" } ] }
    ]
  },
  "enabledPlugins": { "mktux@mktux-harness": true }
}
JSON
  rc=$(CASE_SMOKE=1 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "Hooks do ai-memory isolados" "preflight anuncia o isolamento"
  sessions=$(( $(cat "$d/state/impl_calls") + $(cat "$d/state/verify_calls" 2>/dev/null || echo 0) ))
  assert_eq "$sessions" "$(count_lines "$d/state/setting_sources")" "toda sessao (smoke, impl, gate 3) isolada"
  assert_eq "project,local" "$(sort -u "$d/state/setting_sources" 2>/dev/null)" "sem a camada user de settings"
  assert_not_contains "$d/state/settings_json" "ai-memory" "config devolvida sem os hooks do ai-memory"
  assert_not_contains "$d/state/settings_json" "SessionStart" "evento que so tinha ai-memory some"
  assert_contains "$d/state/settings_json" "rtk hook claude" "demais hooks do usuario continuam"
  assert_contains "$d/state/settings_json" '"model":"opus"' "model do usuario continua"
  assert_contains "$d/state/settings_json" "mktux@mktux-harness" "plugins do usuario continuam"
  settings_path=$(cat "$d/state/settings_path" 2>/dev/null)
  assert_eq "-rw-------" "$(cat "$d/state/settings_perm" 2>/dev/null)" "settings vai por arquivo 0600, nao por argv"
  case "$settings_path" in
    "$d/repo"/*) bad "settings fora do repo (veio $settings_path)" ;;
    *) ok "settings fora do repo" ;;
  esac
  if [ -n "$settings_path" ] && [ ! -e "$settings_path" ]; then
    ok "settings temporario apagado no fim do run"
  else
    bad "settings temporario apagado no fim do run (sobrou $settings_path)"
  fi

  d=$(new_case hook-isolation-claude-off)
  cp "$TMP/hook-isolation-claude/claude-home/settings.json" "$d/claude-home/"
  rc=$(CASE_HOOK_ISOLATION=0 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "RALPH_HOOK_ISOLATION=0: exit 0"
  assert_eq 0 "$(count_lines "$d/state/setting_sources")" "RALPH_HOOK_ISOLATION=0 desliga"

  d=$(new_case hook-isolation-claude-none)
  echo '{ "model": "opus", "statusLine": { "command": "echo ai-memory" } }' > "$d/claude-home/settings.json"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "sem hooks do ai-memory: exit 0"
  assert_eq 0 "$(count_lines "$d/state/setting_sources")" "nome fora dos hooks nao isola nada"
fi

# ---------------------------------------------------------------------------
# 38. Isolamento dos hooks do ai-memory no codex
#     Desliga por hooks.state so os handlers do ai-memory, com a chave que o
#     codex usa: <hooks.json>:<evento snake_case>:<grupo>:<handler>. Os outros
#     handlers do mesmo grupo continuam.
# ---------------------------------------------------------------------------
if case_enabled hook-isolation-codex; then
  header "38. codex: sessoes do ralph sem os hooks do ai-memory"
  d=$(new_case hook-isolation-codex)
  cat > "$d/codex-home/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/bin/ai-memory hook --event session-start --agent codex" } ] }
    ],
    "PreToolUse": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "echo meu-hook" },
        { "type": "command", "command": "/bin/ai-memory hook --event pre-tool-use --agent codex" }
      ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/bin/ai-memory hook --event user-prompt-submit --agent codex" } ] }
    ]
  }
}
JSON
  rc=$(run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  hooks_json="$d/codex-home/hooks.json"
  assert_eq 0 "$rc" "exit 0"
  sessions=$(( $(cat "$d/state/impl_calls") + $(cat "$d/state/verify_calls" 2>/dev/null || echo 0) ))
  assert_eq "$sessions" "$(count_lines "$d/state/hook_overrides")" "toda sessao (impl, gate 3) isolada"
  expected="hooks.state={\"$hooks_json:session_start:0:0\"={enabled=false},\"$hooks_json:pre_tool_use:0:1\"={enabled=false},\"$hooks_json:user_prompt_submit:0:0\"={enabled=false}}"
  assert_eq "$expected" "$(sort -u "$d/state/hook_overrides" 2>/dev/null)" "desliga so os handlers do ai-memory, chave no formato do codex"

  d=$(new_case hook-isolation-codex-off)
  cp "$TMP/hook-isolation-codex/codex-home/hooks.json" "$d/codex-home/"
  rc=$(CASE_HOOK_ISOLATION=0 run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "RALPH_HOOK_ISOLATION=0: exit 0"
  assert_eq 0 "$(count_lines "$d/state/hook_overrides")" "RALPH_HOOK_ISOLATION=0 desliga"
fi

# ---------------------------------------------------------------------------
# 39. Perfil de stack: so o diretorio atual; perfil resolve antes do manifest
# ---------------------------------------------------------------------------
if case_enabled profile-detect; then
  header "39. perfil de stack no diretorio atual; perfil resolve antes do manifest"
  d=$(new_case profile-laravel)
  touch "$d/repo/artisan"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: laravel"
  # nao roda ate o fim: so precisamos do preflight resolvendo o comando
  run_ralph "$d" empty-diff --engine claude --max-cycles 1 > /dev/null
  assert_contains "$d/out.log" "Perfil de stack: laravel" "artisan -> perfil laravel"
  assert_contains "$d/out.log" "comando de teste (detectado): php artisan test" "laravel sem Sail nem composer test -> php artisan test"

  d=$(new_case profile-node)
  printf '{ "scripts": { "test": "exit 0" } }\n' > "$d/repo/package.json"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: node"
  run_ralph "$d" empty-diff --engine claude --max-cycles 1 > /dev/null
  assert_contains "$d/out.log" "Perfil de stack: node" "package.json -> perfil node"
  assert_contains "$d/out.log" "comando de teste (detectado): npm test" "perfil node -> scripts.test"

  # O ralph nao sobe diretorios: os caminhos do perfil (vendor/bin/sail) sao
  # relativos a raiz, e Laravel numa subpasta nao e o projeto que ele commita.
  d=$(new_case profile-subdir)
  mkdir -p "$d/repo/backend" && touch "$d/repo/backend/artisan"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: monorepo"
  run_ralph "$d" empty-diff --engine claude --max-cycles 1 > /dev/null
  assert_not_contains "$d/out.log" "Perfil de stack" "artisan so em subpasta -> sem perfil na raiz"
fi

# ---------------------------------------------------------------------------
# 40. Comando do gate 2 exportado para as sessoes: o test-runner roda o mesmo
# ---------------------------------------------------------------------------
if case_enabled session-test-cmd; then
  header "40. RALPH_TEST_CMD chega a toda sessao (impl e gate 3)"
  for engine in claude codex; do
    d=$(new_case "session-test-cmd-$engine")
    rc=$(run_ralph "$d" ok --engine "$engine" --test-cmd "$d/test.sh")
    assert_eq 0 "$rc" "$engine: exit 0"
    assert_eq "$d/test.sh" "$(sort -u "$d/state/session_test_cmd" 2>/dev/null)" "$engine: toda sessao recebeu o comando do gate 2"
  done
fi

# ---------------------------------------------------------------------------
# 41. Copia avulsa do ralph.sh (RALPH_BIN) acha a lib por MKTUX_HARNESS_ROOT
# ---------------------------------------------------------------------------
if case_enabled ralph-copy; then
  header "41. copia avulsa do ralph.sh acha a lib de perfis por MKTUX_HARNESS_ROOT"
  d=$(new_case ralph-copy)
  mkdir -p "$d/copy" && cp "$RALPH" "$d/copy/ralph.sh"
  rc=$(MKTUX_HARNESS_ROOT="" RALPH="$d/copy/ralph.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "sem MKTUX_HARNESS_ROOT: exit 1"
  assert_contains "$d/out.log" "Aponte MKTUX_HARNESS_ROOT" "diz como apontar para o plugin"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao iniciada sem a lib" || ok "nenhuma sessao iniciada sem a lib"
  rc=$(RALPH="$d/copy/ralph.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "com MKTUX_HARNESS_ROOT: exit 0"
fi

# ---------------------------------------------------------------------------
# 42. Prompt de implementacao: teste focado durante, suite completa uma vez,
#     e nenhum convite a consultar memoria (sessao fria).
#     "Rode a suite SEMPRE com <cmd>" fez um run real rodar 20 suites completas
#     numa sessao, sem nenhuma execucao filtrada.
# ---------------------------------------------------------------------------
if case_enabled impl-prompt; then
  header "42. prompt: teste focado, suite pelo gate 2, sem memoria"
  d=$(new_case impl-prompt)
  rc=$(run_ralph "$d" test-red-once --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  for p in "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "$d/repo/.phases/prompts/phase-01.cycle-2.txt"; do
    kind=$(basename "$p" .txt)
    assert_contains "$p" "rode os testes afetados" "$kind: teste focado durante o trabalho"
    assert_contains "$p" "O gate 2 roda o comando completo" "$kind: suite completa no gate 2"
    assert_not_contains "$p" "rode o comando acima UMA vez" "$kind: sem suite completa obrigatoria"
    assert_not_contains "$p" "Rode a suite SEMPRE" "$kind: sem a ordem de suite a cada item"
    assert_not_contains "$p" "use-a para entender o historico" "$kind: sem convite a memoria"
    assert_contains "$p" "nao consulte memoria de sessoes anteriores" "$kind: sessao fria declarada"
  done

  # Cada perfil diz como rodar o teste focado no runner dele.
  d=$(new_case impl-prompt-node)
  printf '{ "scripts": { "test": "exit 0" } }\n' > "$d/repo/package.json"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: node"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "node: exit 0"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Teste focado: 'npm test -- " "node: teste focado pelo script de teste"

  d=$(new_case impl-prompt-python)
  printf '[project]\nname = "x"\n\n[tool.pytest.ini_options]\n' > "$d/repo/pyproject.toml"
  touch "$d/repo/uv.lock"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: python"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "python: exit 0"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Teste focado: 'uv run pytest " "python: teste focado pelo runner do projeto"
fi

# ---------------------------------------------------------------------------
# 43. Prompt do verificador: tasks numeradas pelo ralph e ponto de partida.
#     Contando sozinho o verificador emitiu TASK 9 numa fase de 8; sem ponto
#     de partida explorou o repo inteiro (1,3M tokens por sessao).
# ---------------------------------------------------------------------------
if case_enabled verify-prompt; then
  header "43. verificador recebe tasks numeradas e arquivos alterados"
  d=$(new_case verify-prompt)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  vp="$d/repo/.phases/prompts/phase-01.verify-1.txt"
  assert_contains "$vp" "1. **Task:** cria o arquivo A" "task 1 numerada pelo ralph"
  assert_contains "$vp" "2. **Task:** cria o arquivo B" "task 2 numerada pelo ralph"
  assert_contains "$vp" "de 1 a 2" "faixa de indices explicita"
  assert_contains "$vp" "src/impl-1.txt" "arquivo alterado na fase listado"
  assert_not_contains "$vp" ".phases/" "estado do run fora da lista"
  assert_contains "$vp" "NAO rode build, testes, typecheck nem lint" "proibe rodar build e teste"
  assert_contains "$vp" "node_modules" "proibe ler dependencias de terceiros"
  # Task de teste: lista de cenarios fechada. Sem isso o verificador inventa a
  # lista a cada ciclo e o alvo da correcao muda sem o plano mudar.
  assert_contains "$vp" "Nao exija cenario, classe ou camada" "task de teste: so os cenarios listados"
  assert_contains "$vp" "INCOMPLETE cita o cenario que falta" "task de teste: INCOMPLETE aponta o bullet"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "de teste por cenario listado" "impl: um caso de teste por cenario"

  d=$(new_case verify-prompt-head)
  mkdir -p "$d/repo/src"
  echo "impl previo" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: trabalho previo"
  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "ja implementada: exit 0"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "Nenhum arquivo alterado nesta fase" "sem diff: aponta para HEAD"
fi

# ---------------------------------------------------------------------------
# 44. Codex: veredito pela mensagem final (-o), nunca por uma de run anterior
# ---------------------------------------------------------------------------
if case_enabled verify-last-message; then
  header "44. codex: gate 3 le a mensagem final gravada com -o"
  d=$(new_case verify-last-message)
  rc=$(run_ralph "$d" verify-last-only --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (veredito so no -o)"
  assert_contains "$d/state/verify_last_path" ".phases/logs/phase-02.verify-1.last.txt" "-o ao lado do log do verificador"
  assert_eq 3 "$(commits "$d")" "as 2 fases commitadas"

  # Arquivo de um run anterior com tudo DONE; a engine deste run nao grava o
  # -o e reprova no log. Ler o arquivo velho aprovaria a fase.
  d=$(new_case verify-last-stale)
  mkdir -p "$d/repo/.phases/logs"
  printf 'TASK 1: DONE\nTASK 2: DONE\n' > "$d/repo/.phases/logs/phase-01.verify-1.last.txt"
  CASE_CODEX_NO_LAST=1
  rc=$(run_ralph "$d" verify-incomplete-once --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  CASE_CODEX_NO_LAST=""
  assert_eq 1 "$rc" "exit 1 (arquivo velho descartado, veredito do log)"
  assert_contains "$d/out.log" "TASK 1: INCOMPLETE" "reprovou pelo veredito deste run"
fi

# ---------------------------------------------------------------------------
# 45. Codex: memoria nativa desligada em toda sessao do ralph
#     Com features.memories ligado na config do usuario, fases e verificador
#     liam o historico das fases anteriores num MEMORY.md de 60 KB.
# ---------------------------------------------------------------------------
if case_enabled codex-memories; then
  header "45. codex: features.memories=false em toda sessao"
  d=$(new_case codex-memories)
  rc=$(CASE_SMOKE=1 run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  sessions=$(( $(cat "$d/state/impl_calls") + $(cat "$d/state/verify_calls" 2>/dev/null || echo 0) ))
  # O smoke roda com --sandbox read-only: o mock o conta em verify_calls.
  assert_eq "$sessions" "$(count_lines "$d/state/codex_memories")" "smoke, impl e gate 3 com a memoria desligada"
  assert_eq "features.memories=false" "$(sort -u "$d/state/codex_memories" 2>/dev/null)" "flag no formato do -c"

  d=$(new_case codex-memories-claude)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "claude: exit 0"
  assert_eq 0 "$(count_lines "$d/state/codex_memories")" "claude nao recebe flag do codex"
fi

# ---------------------------------------------------------------------------
# 46. .harness/ (telemetria dos hooks) fora do git e fora dos gates
#     Visivel, ela muda a cada tool call: toda sessao "escreve", o ciclo
#     travado nunca e detectado e a telemetria entra no commit da fase.
# ---------------------------------------------------------------------------
if case_enabled harness-exclude; then
  header "46. .harness/ excluido: nao conta como escrita nem entra no commit"
  d=$(new_case harness-exclude)
  rc=$(CASE_HARNESS=1 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/repo/.git/info/exclude" "/.harness/" ".harness/ no info/exclude"
  assert_contains "$d/repo/.git/info/exclude" "/.phases/" ".phases/ no info/exclude"
  assert_not_contains <(git -C "$d/repo" log --name-only --format=) ".harness" "nenhum commit leva telemetria"

  # Fase ja em HEAD, sessao so gera telemetria: e "nao escreveu", sem commit.
  d=$(new_case harness-already-done)
  mkdir -p "$d/repo/src"
  echo "impl previo" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: trabalho previo"
  before=$(commits "$d")
  rc=$(CASE_HARNESS=1 run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "ja implementada: exit 0"
  assert_contains "$d/out.log" "a sessao nao escreveu nada" "telemetria nao conta como escrita (gate 1)"
  assert_contains "$d/out.log" "JA IMPLEMENTADA" "reconheceu a fase feita"
  assert_eq "$before" "$(commits "$d")" "nenhum commit so de telemetria"

  # Ja versionada: o exclude nao vale, aborta antes de gastar sessao.
  d=$(new_case harness-tracked)
  mkdir -p "$d/repo/.harness" && echo '{}' > "$d/repo/.harness/events.jsonl"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: telemetria versionada"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "versionada: exit 1"
  assert_contains "$d/out.log" "git rm -r --cached .harness" "diz como tirar do git"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao iniciada" || ok "nenhuma sessao iniciada"
fi

# ---------------------------------------------------------------------------
# 47. Task (manual): fora do gate 3 por construcao. Mantem a posicao (o <n> do
#     veredito e do painel nao muda), veredito para ela e descartado, e ela sai
#     no relatorio final como pendencia de quem conduz o PR.
# ---------------------------------------------------------------------------
MANUAL_FIXTURE='# Test Project — Project Phases

<!-- inputs: project-description.md@sha256:000000000000 -->

## Phase 1: Foundation

- [ ] **Task:** cria o arquivo A
- [ ] (manual) rode o formatador do projeto
- [ ] **Task:** cria o arquivo B

## Phase 2: Close out

- [ ] **(manual)** confira a tela num aparelho real
'

if case_enabled manual-task; then
  header "47. task (manual) fica fora do gate 3 e vira pendencia no relatorio"
  d=$(new_case manual-task)
  printf '%s' "$MANUAL_FIXTURE" > "$d/repo/.spec/init/project-phases.md"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: fixture manual"
  rc=$(run_ralph "$d" verify-manual-incomplete --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "INCOMPLETE numa task (manual) nao reprova: exit 0"
  assert_contains "$d/repo/.phases/logs/phase-01.verify-1.log" "TASK 2: INCOMPLETE" "o verificador julgou a (manual) e o ralph descartou"
  vp="$d/repo/.phases/prompts/phase-01.verify-1.txt"
  assert_contains "$vp" "Julgue EXATAMENTE estes 2 numeros: 1, 3." "verificador recebe so as posicoes julgadas"
  assert_contains "$vp" "3. **Task:** cria o arquivo B" "posicao mantida depois da lacuna"
  assert_not_contains "$vp" "2. (manual)" "(manual) fora da lista numerada"
  assert_contains "$d/out.log" "(+1 manual, fora do gate)" "gate 3 conta a manual a parte"
  assert_contains "$d/out.log" "toda task da fase (1) e (manual)" "fase so de (manual): gate 3 pulado"
  assert_contains "$d/out.log" "Pendencias manuais (2)" "relatorio final lista as pendencias"
  assert_contains "$d/out.log" "Phase 1: rode o formatador do projeto" "pendencia com fase e texto, sem o prefixo"
  assert_contains "$d/out.log" "Phase 2: confira a tela num aparelho real" "pendencia da fase so de (manual)"
  state="$d/repo/.phases/state/run.tsv"
  assert_contains "$state" "$(printf 'TASK\t1\t2\tmanual')" "painel: (manual) continua manual apos o commit"
  assert_contains "$state" "$(printf 'TASK\t1\t3\tdone')" "painel: task julgada vira done"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" 'Item "(manual)" e procedimento' "impl: sabe o que fazer com (manual)"
fi

# ---------------------------------------------------------------------------
# 48. **Check-only phase**: gates 2 e 3 contra HEAD, sem sessao. Verde fecha a
#     fase sem sessao; vermelho abre o ciclo 1 ja como correcao, com a causa.
# ---------------------------------------------------------------------------
CHECK_FIXTURE='# Test Project — Project Phases

<!-- inputs: project-description.md@sha256:000000000000 -->

## Phase 1: Foundation

- [ ] **Task:** cria o arquivo A

## Phase 2: Prove nothing else moved

**Check-only phase**

- [ ] **Task:** nenhum arquivo fora de src/ mudou
- [ ] (manual) rode o formatador do projeto
'

if case_enabled check-only; then
  header "48. fase **Check-only**: verde sem sessao; vermelho abre correcao"
  d=$(new_case check-only)
  printf '%s' "$CHECK_FIXTURE" > "$d/repo/.spec/init/project-phases.md"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: fixture check-only"
  before=$(commits "$d")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "fase check-only verde nao abre sessao"
  assert_eq 2 "$(cat "$d/state/verify_calls")" "gate 3 rodou nas duas fases"
  assert_contains "$d/out.log" "VERIFICADA sem sessao" "fase fechada pelos gates contra HEAD"
  assert_eq $((before + 1)) "$(commits "$d")" "so a fase 1 commita"
  assert_contains "$d/repo/.phases/.progress" "phase-02.md" "progresso registra a fase check-only"
  test -f "$d/repo/.phases/logs/phase-02.verify-0.log" && ok "verificacao previa loga como ciclo 0" || bad "verificacao previa loga como ciclo 0"
  assert_contains "$d/state/session_env" "2 0 verify" "verificacao previa exporta ciclo 0, sem herdar o da fase anterior"
  assert_contains "$d/out.log" "Pendencias manuais (1)" "(manual) da fase check-only segue no relatorio"

  d=$(new_case check-only-red)
  printf '%s' "$CHECK_FIXTURE" | sed '/^## Phase 1:/,/^## Phase 2:/{/^## Phase 2:/!d;}' \
    | sed 's/^## Phase 2:/## Phase 1:/' > "$d/repo/.spec/init/project-phases.md"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: fixture check-only red"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 depois da correcao"
  assert_contains "$d/out.log" "Fase so de verificacao reprovou contra HEAD" "reprovacao previa reportada"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "uma sessao, ja como correcao"
  fp="$d/repo/.phases/prompts/phase-01.cycle-1.txt"
  assert_contains "$fp" "Motivo da falha (gate 3" "ciclo 1 usa o prompt de correcao"
  assert_contains "$fp" "TASK 1: INCOMPLETE" "com o veredito da verificacao previa"
  assert_contains "$d/out.log" "COMPLETA" "fase corrigida e commitada"
fi

# ---------------------------------------------------------------------------
# 49. Sessao travada: o watchdog encerra no RALPH_SESSION_TIMEOUT, o gate 0
#     reprova com a causa e o ciclo de correcao segue. Na fase 9 de
#     pub-email-alerts a sessao esperou 2h por um prompt de confirmacao.
# ---------------------------------------------------------------------------
if case_enabled session-timeout; then
  header "49. sessao travada -> encerrada no timeout, ciclo de correcao"
  d=$(new_case session-timeout)
  started=$(date +%s)
  rc=$(CASE_SESSION_TIMEOUT=2 run_ralph "$d" hang-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0 depois do ciclo de correcao"
  [ $(($(date +%s) - started)) -lt 30 ] && ok "encerrou antes do sleep da sessao (37s)" || bad "encerrou antes do sleep da sessao (37s)"
  assert_contains "$d/out.log" "Gate 0 vermelho" "gate 0 reprovou a sessao encerrada"
  fp="$d/repo/.phases/prompts/phase-01.cycle-2.txt"
  assert_contains "$fp" "passou de RALPH_SESSION_TIMEOUT (2s)" "causa do ciclo diz que foi o timeout"
  assert_contains "$fp" "stdin fechado" "causa diz como nao travar de novo"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" "[ralph] sessao encerrada" "log da sessao marca o encerramento"
  pgrep -f 'sleep 37' > /dev/null && bad "arvore da sessao encerrada (sem sleep orfao)" || ok "arvore da sessao encerrada (sem sleep orfao)"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "com stdin fechado" "prompt manda rodar comandos sem stdin"
  assert_not_contains "$d/out.log" "Terminated" "sem aviso de job control do bash na tela"

  d=$(new_case session-timeout-bad)
  rc=$(CASE_SESSION_TIMEOUT=1h run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "valor invalido: exit 1"
  assert_contains "$d/out.log" "Valor invalido para RALPH_SESSION_TIMEOUT" "diz o que esta errado"
fi

# ---------------------------------------------------------------------------
# 50. Sinal durante a sessao: a engine roda em background (watchdog), e comando
#     assincrono nao recebe o sinal do terminal. O ralph encerra a arvore e
#     aborta, em vez de morrer e deixar a engine escrevendo na arvore.
# ---------------------------------------------------------------------------
if case_enabled session-signal; then
  header "50. SIGTERM durante a sessao -> engine encerrada, run abortado"
  d=$(new_case session-signal)
  ( CASE_SESSION_TIMEOUT=0 run_ralph "$d" hang-once --engine claude --test-cmd "$d/test.sh" > "$d/rc.txt" ) &
  bg=$!
  for _ in $(seq 1 50); do [ -s "$d/state/engine_ppid" ] && break; sleep 0.2; done
  kill -TERM "$(cat "$d/state/engine_ppid")"
  wait "$bg"
  assert_eq 143 "$(cat "$d/rc.txt")" "exit 143"
  assert_contains "$d/out.log" "Execucao interrompida (sinal 143)" "tratado como interrupcao, nao como falha da fase"
  pgrep -f 'sleep 37' > /dev/null && bad "engine encerrada junto" || ok "engine encerrada junto"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "nenhum ciclo de correcao aberto"
fi

# ---------------------------------------------------------------------------
# 51. RALPH-CONTEST: a sessao contesta a task e o verificador confere a
#     evidencia. Nada para o run — o ralph roda a noite sem contato humano. Na
#     fase 9 de pub-email-alerts o verificador, sem a contestacao, cobrou um
#     token de CSS que nao existia e o ciclo de correcao obedeceu.
# ---------------------------------------------------------------------------
if case_enabled contest; then
  header "51. contestacao vai para o verificador, que confere a evidencia"
  for engine in claude codex; do
    d=$(new_case "contest-$engine")
    rc=$(run_ralph "$d" contest-verified --engine "$engine" --test-cmd "$d/test.sh" --max-cycles 3)
    assert_eq 0 "$rc" "$engine: exit 0, sem parar o run"
    assert_eq 2 "$(cat "$d/state/impl_calls")" "$engine: uma sessao por fase, sem ciclo de correcao"
    vp="$d/repo/.phases/prompts/phase-01.verify-1.txt"
    assert_contains "$vp" "## Contestacoes da sessao de implementacao" "$engine: verificador recebe a contestacao"
    assert_contains "$vp" "RALPH-CONTEST: TASK 1 — o token border-border nao existe (tailwind.config.js:26)" "$engine: com a evidencia"
    assert_contains "$d/out.log" "Contestacoes aceitas pelo verificador (1)" "$engine: aceita vai para o relatorio"
    assert_contains "$d/out.log" "Phase 1: TASK 1 — o token border-border nao existe" "$engine: com a fase e o texto"
    assert_eq 3 "$(commits "$d")" "$engine: as 2 fases commitadas"
  done
  assert_contains "$d/state/impl_last_path" ".cycle-1.last.txt" "codex: sessao de implementacao grava a mensagem final com -o"
  assert_not_contains "$d/repo/.phases/prompts/phase-02.verify-1.txt" "Contestacoes da sessao" "contestacao nao vaza para a fase seguinte"

  cp="$d/repo/.phases/prompts/phase-01.cycle-1.txt"
  assert_contains "$cp" "RALPH-CONTEST: TASK <n>" "prompt de implementacao ensina a contestar"
  assert_contains "$cp" "2. Task: cria o arquivo B" "prompt numera as tasks como o verificador"
  assert_contains "$cp" "Suite vermelha nunca e aceita" "prompt: contestar nao libera suite vermelha"
  assert_not_contains "$cp" "para a fase" "prompt nao promete parada"

  # Verificador recusa a evidencia: ciclo de correcao normal, com a recusa e a
  # contestacao anterior no prompt.
  d=$(new_case contest-rejected)
  rc=$(run_ralph "$d" contest-rejected --engine claude --test-cmd "$d/test.sh" --max-cycles 3)
  assert_eq 0 "$rc" "recusada: exit 0 depois da correcao"
  assert_eq 3 "$(cat "$d/state/impl_calls")" "recusada: ciclo de correcao aberto"
  fp="$d/repo/.phases/prompts/phase-01.cycle-2.txt"
  assert_contains "$fp" "contestacao recusada: border-border esta definido" "correcao recebe a recusa"
  assert_contains "$fp" "## Contestacoes de sessoes anteriores desta fase" "correcao sabe o que foi contestado"
  assert_contains "$fp" "conteste em vez de obedecer" "correcao lembra que o verificador le so a fase"

  # Gate 2 vermelho com contestacao: ciclo normal, nunca parada.
  d=$(new_case contest-test-red)
  rc=$(run_ralph "$d" contest-test-red --engine claude --test-cmd "$d/test.sh" --max-cycles 3)
  assert_eq 0 "$rc" "gate 2 + contestacao: exit 0 depois da correcao"
  assert_eq 3 "$(cat "$d/state/impl_calls")" "gate 2 + contestacao: ciclo de correcao"

  # Correcao que nao escreve nada mas traz evidencia nova: re-julga em vez de
  # repetir o veredito memoizado.
  d=$(new_case contest-late)
  rc=$(run_ralph "$d" contest-late --engine claude --test-cmd "$d/test.sh" --max-cycles 3)
  assert_eq 0 "$rc" "contestacao tardia: exit 0"
  assert_eq 3 "$(cat "$d/state/verify_calls")" "contestacao nova re-julga (sem memo)"
  assert_not_contains "$d/out.log" "parando em vez de repetir" "nao tratou como ciclo travado"
fi

# ---------------------------------------------------------------------------
# 52. Fase que falha mostra a ultima mensagem da sessao: na fase 3 de
#     pub-email-alerts ela dizia por que travou, e so o log guardava.
# ---------------------------------------------------------------------------
if case_enabled last-message; then
  header "52. fase que falha mostra a ultima mensagem da sessao"
  for engine in claude codex; do
    d=$(new_case "last-message-$engine")
    rc=$(run_ralph "$d" empty-diff --engine "$engine" --test-cmd "$d/test.sh" --max-cycles 2)
    assert_eq 1 "$rc" "$engine: exit 1"
    assert_contains "$d/out.log" "Ultima mensagem da sessao (fim):" "$engine: bloco da mensagem final"
    assert_contains "$d/out.log" "SendPubReportsTest so passa tocando o comando" "$engine: com o texto da sessao"
  done
fi

# ---------------------------------------------------------------------------
# 53. Fase ja commitada no branch (feat(phase-N): <titulo>) -> gates contra HEAD
#     sem sessao. Na fase 3 de pub-email-alerts o trabalho foi commitado a mao
#     depois de travar, e a retomada abriu uma sessao inteira que nao escreveu
#     nada.
# ---------------------------------------------------------------------------
if case_enabled committed-phase; then
  header "53. fase commitada a mao -> revalidada contra HEAD, sem sessao"
  d=$(new_case committed-phase)
  mkdir -p "$d/repo/src" && echo "feito a mao" > "$d/repo/src/impl-manual.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat(phase-1): Foundation"
  before=$(commits "$d")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "Fase ja commitada neste branch (feat(phase-1))" "reconheceu o commit da fase"
  assert_contains "$d/out.log" "Phase 1: Foundation — VERIFICADA sem sessao" "fechada pelos gates contra HEAD"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "so a fase 2 abriu sessao"
  assert_eq $((before + 1)) "$(commits "$d")" "so a fase 2 commita"

  # Commit com a mensagem da fase, mas sem o codigo: a mensagem escolhe o
  # caminho, quem aprova sao os gates.
  d=$(new_case committed-phase-red)
  echo "anotacao" > "$d/repo/notes.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat(phase-1): Foundation"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "commit sem o codigo: exit 0 depois da correcao"
  assert_contains "$d/out.log" "Fase ja commitada neste branch reprovou contra HEAD" "reprovacao contra HEAD reportada"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Motivo da falha (gate 3" "ciclo 1 ja como correcao"

  # wip(phase-N) e trabalho incompleto: segue o fluxo normal.
  d=$(new_case committed-phase-wip)
  mkdir -p "$d/repo/src" && echo "parcial" > "$d/repo/src/impl-wip.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "wip(phase-1): incomplete — see .phases/logs/"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "wip: exit 0"
  assert_not_contains "$d/out.log" "Fase ja commitada" "wip nao conta como fase commitada"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "wip: as duas fases abrem sessao"
fi

# ---------------------------------------------------------------------------
# 54. Logs de uma execucao anterior da fase vao para logs/archive/<run>/ antes
#     dela reabrir. Os nomes se repetem entre runs e features: o ciclo 3 de uma
#     feature antiga aparecia ao lado do ciclo 1 de hoje.
# ---------------------------------------------------------------------------
if case_enabled log-archive; then
  header "54. logs antigos da fase arquivados quando ela reabre"
  d=$(new_case log-archive)
  mkdir -p "$d/repo/.phases/logs"
  echo "run velho" > "$d/repo/.phases/logs/phase-01.cycle-3.log"
  echo "outra fase" > "$d/repo/.phases/logs/phase-09.cycle-1.log"
  for i in $(seq 1 11); do mkdir -p "$d/repo/.phases/logs/archive/20000101-0000$(printf '%02d' "$i")"; done
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  test -f "$d/repo/.phases/logs/phase-01.cycle-3.log" && bad "log velho saiu de logs/" || ok "log velho saiu de logs/"
  assert_eq 1 "$(ls "$d/repo/.phases/logs/archive"/*/phase-01.cycle-3.log 2>/dev/null | wc -l | tr -d ' ')" "log velho arquivado"
  test -f "$d/repo/.phases/logs/phase-01.cycle-1.log" && ok "log deste run no lugar de sempre" || bad "log deste run no lugar de sempre"
  # phase-09 nao existe neste plano de 2 fases: sobra de uma feature anterior.
  test -f "$d/repo/.phases/logs/phase-09.cycle-1.log" && bad "log de fase fora do plano saiu de logs/" || ok "log de fase fora do plano saiu de logs/"
  assert_eq 1 "$(ls "$d/repo/.phases/logs/archive"/*/phase-09.cycle-1.log 2>/dev/null | wc -l | tr -d ' ')" "log de fase fora do plano arquivado"
  assert_contains "$d/out.log" "Logs de fases fora deste plano (1 arquivo(s))" "avisa dos logs fora do plano"
  assert_eq 10 "$(ls -1d "$d/repo/.phases/logs/archive"/*/ | wc -l | tr -d ' ')" "archive guarda os 10 mais recentes"
  test -d "$d/repo/.phases/logs/archive/20000101-000001" && bad "o mais antigo saiu" || ok "o mais antigo saiu"
  assert_contains "$d/out.log" "Logs anteriores de phase-01 arquivados" "avisa onde foram parar"

  # Fase do plano que nao reabre (--from 2) fica onde esta.
  d=$(new_case log-archive-from)
  mkdir -p "$d/repo/.phases/logs"
  echo "fase pulada" > "$d/repo/.phases/logs/phase-01.cycle-1.log"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --from 2)
  assert_eq 0 "$rc" "--from 2: exit 0"
  test -f "$d/repo/.phases/logs/phase-01.cycle-1.log" && ok "fase do plano que nao reabriu fica onde esta" || bad "fase do plano que nao reabriu fica onde esta"
  assert_not_contains "$d/out.log" "Logs de fases fora deste plano" "fase do plano nao conta como fora dele"
fi

# ---------------------------------------------------------------------------
# 55. Contestacao com o gate 2 vermelho vai para um juiz. O gate 3 so roda com a
#     suite verde: nas fases 6 e 10 de social-proof a contestacao estava certa,
#     o ciclo de correcao respeitou a trava, nao escreveu nada e o run parou.
# ---------------------------------------------------------------------------
if case_enabled contest-judge; then
  header "55. contestacao com a suite vermelha vai para o juiz"
  for engine in claude codex; do
    d=$(new_case "contest-judge-$engine")
    rc=$(run_ralph "$d" contest-protected --engine "$engine" --test-cmd "$d/test.sh" --max-cycles 3)
    assert_eq 0 "$rc" "$engine: exit 0, sem parar o run"
    assert_eq 1 "$(cat "$d/state/judge_calls")" "$engine: um juiz"
    assert_eq 1 "$(cat "$d/state/judge_readonly")" "$engine: juiz read-only"
    assert_eq 3 "$(cat "$d/state/impl_calls")" "$engine: 2 ciclos na fase 1 + fase 2"
    jp="$d/repo/.phases/prompts/phase-01.judge-1.txt"
    assert_contains "$jp" "RALPH-CONTEST: TASK 1 — src/protected.txt:3" "$engine: juiz recebe a contestacao"
    assert_contains "$jp" "ProtectedTypeTest" "$engine: e o fim da saida da suite"
    fp="$d/repo/.phases/prompts/phase-01.cycle-2.txt"
    assert_contains "$fp" "## Travas liberadas pelo juiz" "$engine: correcao recebe a trava liberada"
    assert_contains "$fp" "TASK 1: liberado pelo juiz — src/protected.txt: aceitar o tipo" "$engine: com a mudanca autorizada"
    assert_contains "$d/repo/.phases/prompts/phase-01.verify-2.txt" "## Travas liberadas pelo juiz" "$engine: gate 3 sabe da trava liberada"
    assert_not_contains "$d/repo/.phases/prompts/phase-02.cycle-1.txt" "Travas liberadas" "trava nao vaza para a fase seguinte"
    assert_contains "$d/out.log" "Travas liberadas pelo juiz (1)" "$engine: relatorio lista a trava"
    assert_contains "$d/out.log" "Phase 1: TASK 1: liberado pelo juiz" "$engine: com a fase"
    assert_eq 3 "$(commits "$d")" "$engine: as 2 fases commitadas"
  done
  test -s "$d/state/judge_model" && ok "juiz recebe modelo explicito" || bad "juiz recebe modelo explicito"
  assert_eq "$(cat "$d/state/verify_model")" "$(cat "$d/state/judge_model")" "juiz usa o modelo do verificador"

  # Juiz recusa: a correcao recebe a recusa; a mesma contestacao nao volta ao
  # juiz, e a correcao que nao escreve nada continua sendo fase travada.
  d=$(new_case contest-judge-rejected)
  rc=$(run_ralph "$d" contest-protected-rejected --engine claude --test-cmd "$d/test.sh" --max-cycles 3)
  assert_eq 1 "$rc" "recusada: fase travada encerra o run"
  assert_eq 1 "$(cat "$d/state/judge_calls")" "recusada: mesma contestacao nao volta ao juiz"
  fp="$d/repo/.phases/prompts/phase-01.cycle-2.txt"
  assert_contains "$fp" "## Contestacoes recusadas pelo juiz" "recusada: correcao recebe a recusa"
  assert_contains "$fp" "TASK 1: contestacao recusada pelo juiz — a suite fica verde" "recusada: com o motivo"
  assert_not_contains "$fp" "## Travas liberadas pelo juiz" "recusada: nada liberado"
  assert_contains "$d/out.log" "Julgamento das contestacoes (juiz, suite vermelha):" "recusada: julgamento no relatorio de falha"
  assert_contains "$d/out.log" "parando em vez de repetir" "recusada: correcao sem escrita e travada"

  # Contestacao na correcao que nao escreveu nada: a trava liberada muda o
  # prompt seguinte, entao nao e fase travada.
  d=$(new_case contest-judge-late)
  rc=$(run_ralph "$d" contest-protected-late --engine claude --test-cmd "$d/test.sh" --max-cycles 3)
  assert_eq 0 "$rc" "tardia: liberada, exit 0"
  assert_eq 4 "$(cat "$d/state/impl_calls")" "tardia: 3 ciclos na fase 1 + fase 2"
  assert_not_contains "$d/out.log" "parando em vez de repetir" "tardia: nao tratou como ciclo travado"

  # Ultimo ciclo: nao ha correcao que use o veredito.
  d=$(new_case contest-judge-last)
  rc=$(run_ralph "$d" contest-protected --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "ultimo ciclo: fase falha"
  test -f "$d/state/judge_calls" && bad "ultimo ciclo nao chama o juiz" || ok "ultimo ciclo nao chama o juiz"

  # --no-verify desliga o juiz junto com o gate 3.
  d=$(new_case contest-judge-off)
  rc=$(run_ralph "$d" contest-protected --engine claude --test-cmd "$d/test.sh" --max-cycles 3 --no-verify)
  test -f "$d/state/judge_calls" && bad "--no-verify nao chama o juiz" || ok "--no-verify nao chama o juiz"

  # Suite vermelha sem contestacao: ciclo de correcao normal, sem juiz.
  d=$(new_case contest-judge-none)
  rc=$(run_ralph "$d" test-red-once --engine claude --test-cmd "$d/test.sh" --max-cycles 3)
  assert_eq 0 "$rc" "sem contestacao: exit 0"
  test -f "$d/state/judge_calls" && bad "sem contestacao nao chama o juiz" || ok "sem contestacao nao chama o juiz"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}TODOS VERDES: $PASS asserts${NC}"
else
  echo -e "${RED}FALHAS: $FAIL${NC} / verdes: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))
