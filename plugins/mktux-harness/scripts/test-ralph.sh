#!/usr/bin/env bash
#
# test-ralph.sh — suite red/green do scripts/ralph.sh com engine mock.
#
# Nenhuma chamada de rede, nenhum token gasto: binarios fake `claude` e `codex`
# entram no PATH e o comportamento e escolhido por MOCK_SCENARIO.
#
# Uso: scripts/test-ralph.sh [nome-do-caso]   (exit 0 = tudo verde)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# RALPH_BIN permite apontar para uma copia patchada (prova red dos testes).
RALPH="${RALPH_BIN:-$ROOT/ralph.sh}"
WATCH="${WATCH_BIN:-$ROOT/ralph-watch.sh}"
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
  if grep -qF "$needle" "$haystack_file"; then ok "$msg"; else bad "$msg (nao achou '$needle')"; fi
}

assert_not_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF "$needle" "$haystack_file"; then bad "$msg (achou '$needle')"; else ok "$msg"; fi
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

if [ "$name" = "claude" ]; then
  # claude -p real le stdin quando nao e TTY: se o ralph nao redirecionar
  # < /dev/null, o mock engole o stream de quem chamou (ex: manifest do loop).
  [ -t 0 ] || cat > /dev/null
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --allowedTools) verify=1; shift 2 ;;
      --disallowedTools) disallowed="$2"; shift 2 ;;
      --strict-mcp-config) strict=1; shift ;;
      --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --output-format) shift 2 ;;
      *) shift ;;
    esac
  done
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sandbox) [ "$2" = "read-only" ] && verify=1; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      -c) case "$2" in model_reasoning_effort=*) effort="${2#*=}" ;; esac; shift 2 ;;
      *) shift ;;
    esac
  done
  prompt=$(cat)
fi

grep -q '^RALPH_VERIFY' <<< "$prompt" && verify=1

# --- sessao de memoria (mem0) ------------------------------------------------
# Sessao propria, uma tool call so: nao e implementacao e nao pode contar como
# tal. O nome da tool e o gatilho — se o ralph pedir uma tool que nao existe,
# este ramo nao dispara e o teste fica vermelho.
if grep -q 'mcp__mem0__add_memory' <<< "$prompt"; then
  echo "$model" > "$state/mem0_model"
  echo "$disallowed" > "$state/mem0_disallowed"
  bump mem0_calls > /dev/null
  echo "DONE"
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

  if [ "$implemented" -eq 0 ]; then
    for i in $(seq 1 "$tasks"); do echo "TASK $i: INCOMPLETE — nenhum codigo encontrado"; done
    exit 0
  fi

  emit_tasks() {
    if [ "$scenario" = "verify-incomplete-once" ] && [ "$n" -eq 1 ]; then
      echo "TASK 1: INCOMPLETE — o arquivo nao foi criado"
      for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE"; done
    else
      for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE"; done
    fi
  }

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

emit_claude_ok()    { echo '{"type":"result","subtype":"success","is_error":false,"result":"implementado"}'; }
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

if [ "$write" -eq 1 ]; then
  mkdir -p src
  echo "impl $n" > "src/impl-$n.txt"
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

if [ "$name" = "claude" ]; then emit_claude_ok; else echo "Done."; fi
exit 0
MOCK

  chmod +x "$bin/mock-engine"
  cp "$bin/mock-engine" "$bin/claude"
  cp "$bin/mock-engine" "$bin/codex"
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

if [ "$scenario" = "test-red-once" ] || [ "$scenario" = "stall-after-red" ]; then
  if [ "$n" -eq 1 ]; then
    echo "1 failing test: ExpectedFooTest"
    exit 1
  fi
fi
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
  mkdir -p "$dir/repo" "$dir/state" "$dir/bin"
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
    RALPH_MEM0="${CASE_MEM0:-0}" \
      bash "$RALPH" "$@" > "$dir/out.log" 2>&1
  ) || rc=$?
  echo "$rc"
}

commits() { git -C "$1/repo" rev-list --count HEAD; }

case_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

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
  assert_eq $((before + 4)) "$(commits "$d")" "3 fases re-executadas + commit da mutacao"
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
# 22. Patches locais: smoke test da engine + memoria no mem0 por fase
# ---------------------------------------------------------------------------
if case_enabled local-patches; then
  header "22. smoke test + mem0 (patches locais)"

  CASE_SMOKE=1
  CASE_MEM0=1
  d=$(new_case local-patches)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 com smoke e mem0 ligados"
  assert_contains "$d/out.log" "Smoke test OK" "smoke test rodou no preflight"
  assert_contains "$d/out.log" "Memoria gravada no mem0" "mem0 gravou a fase"
  assert_eq 3 "$(commits "$d")" "fases commitadas normalmente (1 fixture + 2 fases)"

  d=$(new_case local-patches-nosmoke)
  rc=$(run_ralph "$d" ok --engine claude --no-smoke --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 com --no-smoke"
  assert_contains "$d/out.log" "Smoke test pulado" "--no-smoke pula o smoke"
  assert_not_contains "$d/out.log" "Smoke test OK" "nenhuma sessao gasta no smoke"

  CASE_SMOKE=0
  CASE_MEM0=0
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
fi

# ---------------------------------------------------------------------------
# 31. Sessao de memoria: tool que existe, no modelo barato
#     O ramo mem0 do mock so dispara com o nome exato da tool. Modelo tem de
#     ser o do verificador: gravar 2 frases nao vale o modelo de implementacao.
# ---------------------------------------------------------------------------
if case_enabled mem0-session; then
  header "31. mem0 usa tool existente e modelo do verificador"
  d=$(new_case mem0-session)
  rc=$(CASE_MEM0=1 CASE_VERIFY_MODEL=modelo-barato \
       run_ralph "$d" ok --engine claude --model modelo-caro --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 2 "$(cat "$d/state/mem0_calls" 2>/dev/null || echo 0)" "1 sessao de mem0 por fase (2 fases)"
  assert_eq "modelo-barato" "$(cat "$d/state/mem0_model" 2>/dev/null || echo VAZIO)" "mem0 no modelo do verificador, nao no de implementacao"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "sessao de mem0 nao conta como implementacao"
  assert_eq 3 "$(commits "$d")" "as 2 fases seguem commitadas"
fi

# ---------------------------------------------------------------------------
# 32. Contexto do prompt vem dos irmaos do input, nao de caminho fixo
#     Caminho hardcoded que nao existe faz TODA sessao — implementacao e cada
#     ciclo de correcao — queimar tool calls procurando arquivo fantasma.
# ---------------------------------------------------------------------------
if case_enabled sibling-docs; then
  header "32. docs irmaos do input entram no prompt"
  d=$(new_case sibling-docs)
  mkdir -p "$d/repo/docs/features/barcode"
  printf '%s' "$PHASES_FIXTURE" > "$d/repo/docs/features/barcode/project-phases.md"
  echo "# stories" > "$d/repo/docs/features/barcode/user-stories.md"
  echo "# schema" > "$d/repo/docs/features/barcode/database-schema.md"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: feature docs"

  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" docs/features/barcode/project-phases.md)
  assert_eq 0 "$rc" "exit 0"
  prompt="$d/repo/.phases/prompts/phase-01.cycle-1.txt"
  assert_contains "$prompt" "docs/features/barcode/user-stories.md" "user-stories irmao listado"
  assert_contains "$prompt" "docs/features/barcode/database-schema.md" "database-schema irmao listado"
  assert_not_contains "$prompt" "docs/features/barcode/project-phases.md" "o proprio plano nao se auto-lista"
  assert_not_contains "$prompt" ".spec/init/project-description.md" "sem caminho fantasma do layout antigo"
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

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}TODOS VERDES: $PASS asserts${NC}"
else
  echo -e "${RED}FALHAS: $FAIL${NC} / verdes: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))
