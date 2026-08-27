#!/usr/bin/env bash
#
# ralph.sh
#
# Orquestrador que le um documento de fases, quebra em fases, e alimenta cada
# uma ao Codex CLI ou Claude Code para implementacao automatica.
#
# Invariantes:
#   1. Cada fase E cada ciclo de correcao roda em sessao NOVA, com prompt
#      auto-contido. Nunca reutiliza sessao.
#   2. Zero perguntas. Do inicio ao fim sem interacao humana.
#   3. Fase so e "completa" quando passa por 4 gates mecanicos, nunca pelo
#      exit code do engine.
#   4. Limite de uso -> espera o reset e re-executa a MESMA fase, sem consumir
#      ciclo de correcao.
#   5. Um commit por fase concluida.
#
# Agnostico de stack: a fase e o CLAUDE.md/AGENTS.md do projeto definem
# linguagem, framework, comandos e convencoes.
#
# Uso:
#   ralph [opcoes] [caminho-do-arquivo]
#
# Opcoes:
#   --engine codex|claude    engine de implementacao (default: codex)
#   --model <nome>           modelo da engine (default: o configurado na engine)
#   --effort <nivel>         raciocinio (codex: low..ultra | claude: low..max)
#   --no-smoke               pula o smoke test da engine no preflight
#   --verbose                espelha a saida da engine na tela (default: so no log)
#   --dashboard              painel ao vivo NESTE terminal; o log linear vai
#                            para .phases/logs/run.log. Sem a flag nada muda:
#                            log linear de sempre, e o painel roda em outro
#                            terminal com `ralph-watch`
#   --from N                 comeca na fase N (limpa do progresso as fases >= N)
#   --keep-going             continua apos uma fase falhar (default: para)
#   --max-cycles N           ciclos de correcao por fase (default: 3)
#   --no-verify              desliga o gate 3 (equivale a RALPH_VERIFY=off)
#   --test-cmd "<cmd>"       comando de teste do projeto (gate 2)
#
# Input (primeiro arquivo posicional). O caso normal e passar o caminho:
#     ralph docs/features/<slug>/project-phases.md
#
#   Sem argumento, resolve nesta ordem (fallback da cadeia /init:project-phases):
#     1. .spec/init/project-phases.md
#     2. .spec/project-phases.md         (repos pre-init, com aviso)
#
#   Os .md irmaos do input (feature-description, user-stories, database-schema,
#   ...) entram automaticamente no prompt como documentos de contexto.
#
# Contrato de formato do input (validado no preflight):
#   - >= 1 heading `## Phase N: <titulo>`
#   - nenhum heading `## Phase ...` fora desse formato
#   - sub-fases em `### Phase N.M:` (nao viram sessao propria)
#   - qualquer outro `## ` encerra a captura da fase anterior
#   - `**Operational phase**` numa linha sozinha marca fase de close out: o
#     gate 3 reporta mas nao reprova (as tasks nao sao afirmacoes sobre codigo)
#
# Gates por fase (todos verdes -> commit; qualquer vermelho -> ciclo de correcao):
#   0. engine terminou de verdade (claude: is_error no JSON; codex: exit code)
#   1. a sessao escreveu codigo? SINAL, nao veredito — uma fase ja implementada
#      faz o engine (corretamente) nao escrever nada. Alimenta a causa do ciclo
#      de correcao quando um gate posterior reprova.
#   2. suite de testes do projeto, rodada PELO ralph (fora da sessao do agente)
#   3. sessao verificadora independente, read-only, task a task — o gate final,
#      roda em toda fase (RALPH_VERIFY=always, default). RALPH_VERIFY=auto
#      economiza: so roda quando o veredito do gate 2 nao basta — sessao que
#      nao escreveu nada (claim "ja implementada"), ciclo de correcao, ou
#      gate 2 desabilitado. --no-verify / RALPH_VERIFY=off desliga. O
#      verificador usa modelo barato por default (claude: haiku; codex:
#      gpt-5.6-luna com esforco baixo) — e leitura + checklist, nao precisa do
#      modelo de implementacao.
#
# Gates verdes com a arvore limpa => a fase ja estava implementada em HEAD:
# marcada como feita, sem commit (nao ha o que commitar).
#
# Comando de teste (gate 2), primeira regra que resolver:
#   1. --test-cmd "<cmd>"
#   2. RALPH_TEST_CMD
#   3. deteccao por manifest:
#        Laravel Sail (artisan + vendor/bin/sail)  -> vendor/bin/sail test
#        composer.json com scripts.test            -> composer test
#        artisan                                   -> php artisan test
#        package.json com scripts.test             -> npm test
#        pytest.ini / pyproject [tool.pytest]      -> pytest
#        go.mod                                    -> go test ./...
#        Cargo.toml                                -> cargo test
#   4. nada resolvido -> aviso alto + gate 2 pulado (o gate 3 segura sozinho)
#
# Laravel Sail: a suite roda dentro do container, entao Sail tem precedencia
# sobre `composer test`. Containers parados -> abort no preflight (todo gate 2
# falharia, queimando ciclos de correcao).
#
# Variaveis de ambiente:
#   RALPH_TEST_CMD           comando de teste (gate 2); --test-cmd tem prioridade
#   RALPH_VERIFY             gate 3: always (default) | auto | off
#   RALPH_VERIFY_MODEL       modelo das sessoes auxiliares — gate 3 e mem0
#                            (default: haiku no claude, gpt-5.6-luna no codex)
#   RALPH_VERIFY_EFFORT      esforco dessas sessoes (default: low no codex; no
#                            claude fica com o default do modelo)
#   RALPH_MAX_CYCLES         ciclos de correcao por fase (default: 3)
#   RALPH_MAX_LIMIT_WAITS    esperas consecutivas por limite, por fase (default: 20)
#   RALPH_LIMIT_WAIT_DEFAULT fallback de espera em segundos (default: 1800)
#   RALPH_LIMIT_BUFFER       segundos extras apos o reset (default: 60)
#   RALPH_SMOKE              0 desliga o smoke test da engine (default: 1)
#   RALPH_MEM0               0 desliga a gravacao de memoria no mem0 (default: 1)
#   RALPH_MEM0_USER          userId do mem0. SEM default: nao definida, a gravacao
#                            no mem0 fica desligada (o plugin mem0, quando instalado,
#                            ja captura por hooks — isto aqui e so o resumo por fase)
#   RALPH_VERBOSE            1 espelha a saida da engine na tela (default: 0)
#   RALPH_DASHBOARD          1 liga o painel embutido (igual a --dashboard)
#
# Estado do run (sempre publicado, com ou sem --dashboard):
#   .phases/state/run.tsv    snapshot TSV reescrito de forma atomica a cada
#                            transicao. Contrato lido pelo ralph-watch.sh:
#                              META  <chave>  <valor>
#                              PHASE <seq> <num> <status> <ciclo> <inicio> <dur> <gates> <titulo>
#                              TASK  <seq> <idx> <status> <texto>
#                              WAIT  <ativo> <ate_epoch> <n> <max>
#                              LOG   <kind> <caminho>
#                            gates = "0:pass:3,1:pass:0,2:run:0,3:pend:0"
#                            status de fase: pending running done failed skipped
#                            status de gate:  pend run pass fail skip
#
# Exportadas para hooks (ex: notify-n8n.sh) durante cada sessao de engine:
#   RALPH_ENGINE             codex | claude
#   RALPH_PHASE_TITLE        titulo da fase corrente
#   RALPH_PHASE_NUM          numero da fase corrente
#   RALPH_PHASE_TOTAL        total de fases do run
#   RALPH_PHASE_ATTEMPT      ciclo corrente (1 = implementacao inicial)
#   RALPH_PHASE_MAX_ATTEMPTS igual a RALPH_MAX_CYCLES
#
# Exit code: 0 = todas as fases verdes; 1 = alguma falhou ou abortou.
#
# Pre-requisitos:
#   - Codex: npm install -g @openai/codex + OPENAI_API_KEY
#   - Claude: npm install -g @anthropic-ai/claude-code + ANTHROPIC_API_KEY
#   - Raiz de um repo git, com a arvore de trabalho limpa

set -euo pipefail

ENGINE="codex"
INPUT_FILE=""
FROM_PHASE=0
KEEP_GOING=false
TEST_CMD_FLAG=""
MAX_CYCLES="${RALPH_MAX_CYCLES:-3}"
VERIFY_MODE="${RALPH_VERIFY:-always}"
VERIFY_MODEL=""
VERIFY_EFFORT=""
MODEL=""
EFFORT=""
SKIP_SMOKE=0
if [ "${RALPH_SMOKE:-1}" = "0" ]; then SKIP_SMOKE=1; fi
MEM0_ENABLED="${RALPH_MEM0:-1}"
MEM0_USER_ID="${RALPH_MEM0_USER:-}"
VERBOSE=0
if [ "${RALPH_VERBOSE:-0}" = "1" ]; then VERBOSE=1; fi
DASHBOARD=0
if [ "${RALPH_DASHBOARD:-0}" = "1" ]; then DASHBOARD=1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)      ENGINE="$2"; shift 2 ;;
    --engine=*)    ENGINE="${1#*=}"; shift ;;
    --from)        FROM_PHASE="$2"; shift 2 ;;
    --from=*)      FROM_PHASE="${1#*=}"; shift ;;
    --max-cycles)  MAX_CYCLES="$2"; shift 2 ;;
    --max-cycles=*) MAX_CYCLES="${1#*=}"; shift ;;
    --test-cmd)    TEST_CMD_FLAG="$2"; shift 2 ;;
    --test-cmd=*)  TEST_CMD_FLAG="${1#*=}"; shift ;;
    --keep-going)  KEEP_GOING=true; shift ;;
    --no-verify)   VERIFY_MODE="off"; shift ;;
    --model)       MODEL="$2"; shift 2 ;;
    --model=*)     MODEL="${1#*=}"; shift ;;
    --effort)      EFFORT="$2"; shift 2 ;;
    --effort=*)    EFFORT="${1#*=}"; shift ;;
    --no-smoke)    SKIP_SMOKE=1; shift ;;
    --verbose)     VERBOSE=1; shift ;;
    --dashboard)   DASHBOARD=1; shift ;;
    -h|--help)     sed -n '2,135p' "$0"; exit 0 ;;
    *)             INPUT_FILE="$1"; shift ;;
  esac
done

PHASES_DIR=".phases"
LOG_DIR=".phases/logs"
PROMPT_DIR=".phases/prompts"
STATE_DIR=".phases/state"
MANIFEST="$PHASES_DIR/manifest.txt"
PROGRESS_FILE="$PHASES_DIR/.progress"
STATE_FILE="$STATE_DIR/run.tsv"
RUN_LOG="$LOG_DIR/run.log"

MAX_LIMIT_WAITS="${RALPH_MAX_LIMIT_WAITS:-20}"
LIMIT_WAIT_DEFAULT="${RALPH_LIMIT_WAIT_DEFAULT:-1800}"
LIMIT_BUFFER="${RALPH_LIMIT_BUFFER:-60}"

TEST_CMD=""
SAIL_BIN=""
LIMIT_WAITS=0
# Flags de modelo/effort montadas uma vez: o smoke test e o loop usam as MESMAS,
# entao o que passa no smoke e literalmente o que roda em cada fase.
ENGINE_IMPL_ARGS=()
# Flags das sessoes auxiliares (gate 3 e mem0): modelo barato, nunca o de
# implementacao. Sao leitura + uma tool call, nao valem opus/xhigh por fase.
ENGINE_VERIFY_ARGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] $1${NC}"; }
fail()    { echo -e "${RED}[$(date '+%H:%M:%S')] $1${NC}"; }

format_duration() {
  local total_seconds=$1
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if [ "$hours" -gt 0 ]; then
    printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
  elif [ "$minutes" -gt 0 ]; then
    printf "%dm %ds" "$minutes" "$seconds"
  else
    printf "%ds" "$seconds"
  fi
}

# Formata um epoch de forma portavel: GNU date usa `-d @TS`, BSD/macOS usa `-r TS`.
# Sem isso o script imprime "illegal option -- d" e horario vazio no macOS.
fmt_ts() {
  local ts="$1"
  date -r "$ts" '+%d/%m/%Y %H:%M:%S' 2>/dev/null \
    || date -d "@$ts" '+%d/%m/%Y %H:%M:%S' 2>/dev/null \
    || echo "?"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

resolve_input_file() {
  if [ -n "$INPUT_FILE" ]; then
    return 0
  fi

  if [ -f ".spec/init/project-phases.md" ]; then
    INPUT_FILE=".spec/init/project-phases.md"
  elif [ -f ".spec/project-phases.md" ]; then
    INPUT_FILE=".spec/project-phases.md"
    warn "Usando .spec/project-phases.md (layout pre-init). O padrao atual e .spec/init/project-phases.md."
  else
    fail "Nenhum documento de fases encontrado."
    fail "Passe o caminho como argumento, ex:"
    fail "    ralph docs/features/<slug>/project-phases.md"
    fail "Sem argumento, o fallback e .spec/init/project-phases.md (cadeia /init:project-phases)."
    exit 1
  fi
}

validate_input_format() {
  local top_level
  top_level=$(grep -cE '^## Phase [0-9]+: ' "$INPUT_FILE" || true)

  if [ "$top_level" -lt 1 ]; then
    fail "Contrato de formato violado: nenhum heading '## Phase N: <titulo>' em $INPUT_FILE"
    fail "ralph quebra o documento por esse heading. Corrija o documento antes de rodar."
    exit 1
  fi

  local malformed
  malformed=$(grep -E '^## Phase' "$INPUT_FILE" | grep -vE '^## Phase [0-9]+: ' || true)
  if [ -n "$malformed" ]; then
    fail "Contrato de formato violado: headings '## Phase' fora do formato '## Phase N: <titulo>':"
    echo "$malformed" | sed 's/^/    /'
    fail "Uma fase com heading torto some silenciosamente do run. Corrija antes de gastar tokens."
    exit 1
  fi

  log "Formato do input OK ($top_level fases declaradas)"
}

exclude_phases_dir() {
  local exclude_file
  exclude_file="$(git rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  if ! grep -qxF '/.phases/' "$exclude_file" 2>/dev/null; then
    echo '/.phases/' >> "$exclude_file"
    log "Registrado /.phases/ em .git/info/exclude (nao mexe no .gitignore do projeto)"
  fi
}

# Laravel Sail: a suite roda DENTRO do container. Rodar `composer test` /
# `php artisan test` no host falha (sem PHP, sem banco, sem rede do compose).
# Ecoa o caminho do binario sail quando o projeto usa Sail.
detect_sail() {
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
sail_running() {
  local out rc=0
  out=$("$SAIL_BIN" ps 2>&1) || rc=$?
  grep -qiF 'is not running' <<< "$out" && return 1
  [ "$rc" -ne 0 ] && return 1
  grep -qiE '(^|[[:space:]])(Up|running)([[:space:]]|$)' <<< "$out"
}

# O comando de teste invoca o sail? Olha o executavel (1o token), nao a string
# inteira: um caminho como /tmp/sail-fixture/test.sh nao usa sail.
test_cmd_uses_sail() {
  local first="${TEST_CMD%% *}"
  [ "$(basename -- "$first")" = "sail" ]
}

# Gate 2 so tem valor se rodar de verdade. Sail com containers parados falha
# toda fase e queima ciclos de correcao inuteis — aborta antes da 1a sessao.
check_sail_running() {
  [ -n "$SAIL_BIN" ] || return 0
  test_cmd_uses_sail || return 0

  if [ ! -x "$SAIL_BIN" ]; then
    fail "Laravel Sail detectado, mas $SAIL_BIN nao existe."
    fail "Rode a instalacao de dependencias do projeto (ex: composer install) antes."
    exit 1
  fi

  if ! sail_running; then
    fail "Laravel Sail detectado, mas os containers nao estao de pe."
    fail "A suite de testes (gate 2) roda dentro do container e falharia em toda fase."
    fail "Suba o ambiente antes de rodar o ralph:"
    fail "    $SAIL_BIN up -d"
    exit 1
  fi

  log "Sail: containers de pe"
}

resolve_test_cmd() {
  SAIL_BIN="$(detect_sail || true)"

  if [ -n "$TEST_CMD_FLAG" ]; then
    TEST_CMD="$TEST_CMD_FLAG"
    log "Gate 2 — comando de teste (--test-cmd): $TEST_CMD"
    check_sail_running
    return 0
  fi

  if [ -n "${RALPH_TEST_CMD:-}" ]; then
    TEST_CMD="$RALPH_TEST_CMD"
    log "Gate 2 — comando de teste (RALPH_TEST_CMD): $TEST_CMD"
    check_sail_running
    return 0
  fi

  # Sail vem ANTES de composer/npm: num projeto Laravel dockerizado o host nao
  # tem PHP nem acesso ao banco, e `composer test` mentiria como gate.
  if [ -n "$SAIL_BIN" ]; then
    # --compact: a saida do gate 2 vira prompt de correcao (tail -200). O formato
    # verboso do PHPUnit enche esse orcamento com ruido em vez de falhas.
    TEST_CMD="$SAIL_BIN artisan test --compact"
  elif [ -f composer.json ] && grep -qE '"test"[[:space:]]*:' composer.json; then
    TEST_CMD="composer test"
  elif [ -f artisan ]; then
    TEST_CMD="php artisan test"
  elif [ -f package.json ] && grep -qE '"test"[[:space:]]*:' package.json; then
    TEST_CMD="npm test"
  elif [ -f pytest.ini ] || { [ -f pyproject.toml ] && grep -qF '[tool.pytest' pyproject.toml; }; then
    TEST_CMD="pytest"
  elif [ -f go.mod ]; then
    TEST_CMD="go test ./..."
  elif [ -f Cargo.toml ]; then
    TEST_CMD="cargo test"
  fi

  if [ -n "$TEST_CMD" ]; then
    log "Gate 2 — comando de teste (detectado): $TEST_CMD"
    check_sail_running
  else
    warn "Gate 2 DESABILITADO: nenhum comando de teste resolvido."
    if [ "$VERIFY_MODE" = "off" ]; then
      warn "--no-verify tambem desligou o gate 3: NENHUMA validacao mecanica ativa."
    else
      warn "Passe --test-cmd '<cmd>' ou defina RALPH_TEST_CMD. O gate 3 (verificador) roda em toda fase."
    fi
  fi
}

# Chama a engine uma vez com as flags reais e um prompt trivial, antes do loop.
# Pega o que a validacao estatica nao pega: modelo inexistente, effort nao
# suportado POR AQUELE modelo, auth expirada, quota zerada. Sem isso o erro so
# aparece na fase 1, ja com o split feito e o progresso em jogo.
engine_smoke_test() {
  local out rc=0

  log "Validando comando da engine (smoke test)..."

  if [[ "$ENGINE" == "codex" ]]; then
    out=$(echo 'Responda apenas: OK' | codex exec ${ENGINE_IMPL_ARGS[@]+"${ENGINE_IMPL_ARGS[@]}"} \
      --color never --sandbox read-only - 2>&1) || rc=$?
  else
    out=$(env -u CLAUDECODE claude ${ENGINE_IMPL_ARGS[@]+"${ENGINE_IMPL_ARGS[@]}"} \
      -p 'Responda apenas: OK' --output-format text < /dev/null 2>&1) || rc=$?
  fi

  if [ $rc -ne 0 ]; then
    fail "$ENGINE rejeitou o comando (exit $rc). Nada foi executado. Saida:"
    echo "$out" | tail -n 15 | sed 's/^/    /'
    exit 1
  fi

  # Claude nao falha com effort invalido: avisa e usa o default, saindo com 0.
  # Sem esta checagem o loop inteiro rodaria no effort errado achando que passou.
  if echo "$out" | grep -qi 'unknown --effort value'; then
    fail "$ENGINE nao aceitou o effort '$EFFORT' e cairia no default. Saida:"
    echo "$out" | grep -i 'unknown --effort value' | head -n 1 | sed 's/^/    /'
    exit 1
  fi

  success "Smoke test OK"
}

preflight_checks() {
  if [[ "$ENGINE" != "codex" && "$ENGINE" != "claude" ]]; then
    fail "Engine invalida: $ENGINE. Use 'codex' ou 'claude'."
    exit 1
  fi

  # Lista estatica so pega erro de digitacao cedo; quem da a palavra final e a
  # propria engine no smoke test (um modelo pode nao suportar todos os niveis).
  local valid_efforts
  if [[ "$ENGINE" == "codex" ]]; then
    valid_efforts="low medium high xhigh max ultra"
  else
    valid_efforts="low medium high xhigh max"
  fi

  if [ -n "$EFFORT" ] && [[ " $valid_efforts " != *" $EFFORT "* ]]; then
    fail "Effort invalido para $ENGINE: '$EFFORT'. Use: ${valid_efforts// / | }"
    exit 1
  fi

  ENGINE_IMPL_ARGS=()
  if [ -n "$MODEL" ]; then
    ENGINE_IMPL_ARGS+=(--model "$MODEL")
  fi
  if [ -n "$EFFORT" ]; then
    if [[ "$ENGINE" == "codex" ]]; then
      ENGINE_IMPL_ARGS+=(-c "model_reasoning_effort=$EFFORT")
    else
      ENGINE_IMPL_ARGS+=(--effort "$EFFORT")
    fi
  fi

  if ! [[ "$FROM_PHASE" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para --from: '$FROM_PHASE'. Use um numero inteiro (ex: --from 5)."
    exit 1
  fi

  if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]] || [ "$MAX_CYCLES" -lt 1 ]; then
    fail "Valor invalido para --max-cycles: '$MAX_CYCLES'. Use um inteiro >= 1."
    exit 1
  fi

  case "$VERIFY_MODE" in
    auto|always|off) ;;
    *)
      fail "Valor invalido para RALPH_VERIFY: '$VERIFY_MODE'. Use auto, always ou off."
      exit 1
      ;;
  esac

  # Verificacao e leitura + checklist: nao precisa do modelo de implementacao.
  # No codex nao ha default seguro de modelo barato — so aplica se pedido.
  # O verificador le codigo e preenche um checklist: nao precisa do modelo de
  # implementacao. Sem um default barato por engine, o gate 3 rodaria no modelo
  # (e no effort) do config global — uma sessao cara por fase.
  if [ -n "${RALPH_VERIFY_MODEL:-}" ]; then
    VERIFY_MODEL="$RALPH_VERIFY_MODEL"
  elif [[ "$ENGINE" == "claude" ]]; then
    VERIFY_MODEL="haiku"
  else
    VERIFY_MODEL="gpt-5.6-luna"
  fi

  # No codex o effort vem do ~/.codex/config.toml quando nao passamos flag —
  # tipicamente xhigh, desperdicio para leitura + checklist. No claude o haiku
  # ja e barato o bastante; so aplica se pedido explicitamente.
  if [ -n "${RALPH_VERIFY_EFFORT:-}" ]; then
    VERIFY_EFFORT="$RALPH_VERIFY_EFFORT"
  elif [[ "$ENGINE" == "codex" ]]; then
    VERIFY_EFFORT="low"
  fi

  ENGINE_VERIFY_ARGS=()
  if [ -n "$VERIFY_MODEL" ]; then
    ENGINE_VERIFY_ARGS+=(--model "$VERIFY_MODEL")
  fi
  if [ -n "$VERIFY_EFFORT" ]; then
    if [[ "$ENGINE" == "codex" ]]; then
      ENGINE_VERIFY_ARGS+=(-c "model_reasoning_effort=$VERIFY_EFFORT")
    else
      ENGINE_VERIFY_ARGS+=(--effort "$VERIFY_EFFORT")
    fi
  fi

  if ! command -v "$ENGINE" &> /dev/null; then
    if [[ "$ENGINE" == "codex" ]]; then
      fail "codex CLI nao encontrado. Instale com: npm install -g @openai/codex"
    else
      fail "Claude Code CLI nao encontrado. Instale com: npm install -g @anthropic-ai/claude-code"
    fi
    exit 1
  fi

  if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
    fail "Requer um repositorio git."
    exit 1
  fi

  resolve_input_file

  if [ ! -f "$INPUT_FILE" ]; then
    fail "Arquivo nao encontrado: $INPUT_FILE"
    exit 1
  fi

  validate_input_format
  exclude_phases_dir

  # Arvore limpa: 'git add -A' da primeira fase engoliria trabalho nao commitado.
  if [ -n "$(git status --porcelain)" ]; then
    fail "Arvore de trabalho suja. ralph commita por fase e engoliria suas mudancas."
    fail "Commite ou stashe antes de rodar:"
    git status --short | sed 's/^/    /'
    exit 1
  fi

  resolve_test_cmd

  success "Pre-checks OK (engine: $ENGINE, input: $INPUT_FILE, model: ${MODEL:-default}, effort: ${EFFORT:-default})"

  if [ "$SKIP_SMOKE" -eq 1 ]; then
    warn "Smoke test pulado (--no-smoke / RALPH_SMOKE=0)"
  else
    engine_smoke_test
  fi
}

# ---------------------------------------------------------------------------
# Split + progresso
# ---------------------------------------------------------------------------

manifest_entries() { grep -v '^#' "$MANIFEST" || true; }

split_phases() {
  log "Quebrando $INPUT_FILE em fases..."

  local new_stamp old_stamp="" progress_backup=""
  new_stamp="$(basename "$INPUT_FILE")@sha256:$(sha256sum "$INPUT_FILE" | cut -c1-12)"

  if [ -f "$MANIFEST" ]; then
    old_stamp=$(sed -n '1s/^# stamp: //p' "$MANIFEST")
  fi
  if [ -f "$PROGRESS_FILE" ]; then
    progress_backup=$(cat "$PROGRESS_FILE")
  fi

  # Apaga so o que este split regenera. `rm -rf .phases` levava junto os logs —
  # exatamente a evidencia que a mensagem de falha manda conferir, e o caminho
  # para conferir passa por re-rodar o ralph, que passa por aqui: voce perdia o
  # log no ato de ir busca-lo.
  rm -f "$PHASES_DIR"/*.md "$MANIFEST" "$PROGRESS_FILE"
  rm -rf "$PROMPT_DIR" "$STATE_DIR"
  mkdir -p "$PHASES_DIR" "$LOG_DIR" "$PROMPT_DIR" "$STATE_DIR"

  # Progresso sobrevive entre execucoes, mas so vale para o MESMO input.
  if [ -n "$progress_backup" ]; then
    if [ -n "$old_stamp" ] && [ "$old_stamp" = "$new_stamp" ]; then
      printf '%s\n' "$progress_backup" > "$PROGRESS_FILE"
      log "Progresso anterior preservado (input inalterado)"
    else
      warn "O documento de fases mudou desde a ultima execucao — progresso zerado."
      warn "Fases marcadas como feitas pertenciam a outro plano."
    fi
  fi

  echo "# stamp: $new_stamp" > "$MANIFEST"

  local current_file=""
  local phase_count=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^##[[:space:]]+Phase[[:space:]]+([0-9]+):[[:space:]]*(.*)$ ]]; then
      phase_count=$((phase_count + 1))

      local phase_num="${BASH_REMATCH[1]}"
      local phase_title="${BASH_REMATCH[2]}"
      phase_title="$(echo "$phase_title" | sed 's/[[:space:]]*$//')"

      local slug
      slug=$(printf 'phase-%02d' "$phase_num")

      current_file="$PHASES_DIR/${slug}.md"
      echo "$line" > "$current_file"
      echo "${slug}.md|${phase_num}|${phase_title}" >> "$MANIFEST"
      continue
    fi

    # Heading nivel 2 que nao e "## Phase N:" (ex: "## Open Questions"):
    # encerra a captura para nao vazar a secao para a ultima fase.
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      current_file=""
      continue
    fi

    if [ -n "$current_file" ]; then
      echo "$line" >> "$current_file"
    fi
  done < "$INPUT_FILE"

  success "$phase_count fases extraidas"
}

is_phase_done() {
  local phase_file="$1"
  [ -f "$PROGRESS_FILE" ] && grep -qxF "$phase_file" "$PROGRESS_FILE"
}

mark_phase_done() {
  echo "$1" >> "$PROGRESS_FILE"
}

# --from N tambem limpa do progresso as fases >= N (re-rodar de proposito).
apply_from_override() {
  [ "$FROM_PHASE" -gt 1 ] || return 0
  [ -f "$PROGRESS_FILE" ] || return 0

  local kept="" file num _rest
  while IFS='|' read -r file num _rest; do
    if [ "$num" -lt "$FROM_PHASE" ] && grep -qxF "$file" "$PROGRESS_FILE"; then
      kept+="$file"$'\n'
    fi
  done < <(manifest_entries)

  printf '%s' "$kept" > "$PROGRESS_FILE"
  log "--from $FROM_PHASE: progresso das fases >= $FROM_PHASE limpo"
}

# ---------------------------------------------------------------------------
# Estado do run (.phases/state/run.tsv)
# ---------------------------------------------------------------------------
#
# O ralph e a unica fonte de verdade do run: o painel (ralph-watch.sh) so LE.
# Publicado sempre, com ou sem --dashboard, para que outro terminal possa
# acompanhar. Escrita atomica (tmp + mv): o painel nunca le arquivo pela metade.
#
# bash 3.2 (macOS) nao tem array associativo. Tudo aqui e array indexado por
# `seq` da fase (1..PH_TOTAL); os gates usam o indice composto seq*4+gate.

PH_TOTAL=0
TSK_N=0
CUR_SEQ=""
RUN_START=0
RUN_START_ISO=""
RUN_STATUS="starting"
WAIT_ACTIVE=0
WAIT_UNTIL=0
LOG_KIND=""
LOG_PATH=""
PH_NUM=(); PH_TITLE=(); PH_STATUS=(); PH_CYCLE=(); PH_START=(); PH_DUR=()
G_STATUS=(); G_START=(); G_DUR=()
TSK_SEQ=(); TSK_IDX=(); TSK_STATUS=(); TSK_TEXT=()

state_init() {
  local seq=0 file num title idx line

  RUN_START=$(date +%s)
  RUN_START_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  RUN_STATUS="running"

  while IFS='|' read -r file num title; do
    seq=$((seq + 1))
    PH_NUM[$seq]="$num"
    PH_TITLE[$seq]="$title"
    PH_STATUS[$seq]="pending"
    PH_CYCLE[$seq]=0
    PH_START[$seq]=0
    PH_DUR[$seq]=0
    state_reset_gates "$seq"

    # Mesmo padrao do gate 3 (`- [ ]` / `- [x]`): os indices publicados aqui sao
    # os mesmos que o verificador usa nas linhas "TASK <n>: DONE|INCOMPLETE".
    idx=0
    while IFS= read -r line; do
      idx=$((idx + 1))
      TSK_N=$((TSK_N + 1))
      TSK_SEQ[$TSK_N]="$seq"
      TSK_IDX[$TSK_N]="$idx"
      TSK_STATUS[$TSK_N]="pending"
      TSK_TEXT[$TSK_N]="$(printf '%s' "${line:0:200}" | tr '\t' ' ')"
    done < <(sed -n 's/^[[:space:]]*- \[[ x]\][[:space:]]*//p' "$PHASES_DIR/$file" | sed 's/\*\*//g')
  done < <(manifest_entries)

  PH_TOTAL=$seq
  state_publish
}

state_reset_gates() {
  local seq="$1" g gi
  for g in 0 1 2 3; do
    gi=$((seq * 4 + g))
    G_STATUS[$gi]="pend"
    G_START[$gi]=0
    G_DUR[$gi]=0
  done
}

state_publish() {
  [ "$PH_TOTAL" -gt 0 ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0

  local tmp="$STATE_FILE.tmp.$$" i g gi gates
  {
    printf 'META\t%s\t%s\n' \
      engine     "$ENGINE" \
      model      "${MODEL:-default}" \
      effort     "${EFFORT:-default}" \
      verify     "$VERIFY_MODE" \
      max_cycles "$MAX_CYCLES" \
      test_cmd   "${TEST_CMD:-}" \
      input      "${INPUT_FILE:-}" \
      repo       "$PWD" \
      branch     "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')" \
      pid        "$$" \
      total      "$PH_TOTAL" \
      start      "$RUN_START" \
      start_iso  "$RUN_START_ISO" \
      updated    "$(date +%s)" \
      status     "$RUN_STATUS" \
      run_log    "$RUN_LOG" \
      dashboard  "$DASHBOARD"

    for ((i = 1; i <= PH_TOTAL; i++)); do
      gates=""
      for g in 0 1 2 3; do
        gi=$((i * 4 + g))
        gates="${gates}${gates:+,}${g}:${G_STATUS[$gi]:-pend}:${G_DUR[$gi]:-0}"
      done
      printf 'PHASE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$i" "${PH_NUM[$i]}" "${PH_STATUS[$i]}" "${PH_CYCLE[$i]}" \
        "${PH_START[$i]}" "${PH_DUR[$i]}" "$gates" "${PH_TITLE[$i]}"
    done

    for ((i = 1; i <= TSK_N; i++)); do
      printf 'TASK\t%s\t%s\t%s\t%s\n' \
        "${TSK_SEQ[$i]}" "${TSK_IDX[$i]}" "${TSK_STATUS[$i]}" "${TSK_TEXT[$i]}"
    done

    printf 'WAIT\t%s\t%s\t%s\t%s\n' "$WAIT_ACTIVE" "$WAIT_UNTIL" "$LIMIT_WAITS" "$MAX_LIMIT_WAITS"
    printf 'LOG\t%s\t%s\n' "${LOG_KIND:-}" "${LOG_PATH:-}"
  } > "$tmp" 2> /dev/null && mv -f "$tmp" "$STATE_FILE" 2> /dev/null || rm -f "$tmp" 2> /dev/null

  return 0
}

state_phase() {
  local seq="$1" status="$2"
  [ "$PH_TOTAL" -gt 0 ] || return 0
  PH_STATUS[$seq]="$status"
  case "$status" in
    running)
      PH_START[$seq]=$(date +%s)
      ;;
    done|failed)
      if [ "${PH_START[$seq]:-0}" -gt 0 ]; then
        PH_DUR[$seq]=$(($(date +%s) - ${PH_START[$seq]}))
      fi
      ;;
  esac
  state_publish
}

state_cycle() {
  local seq="$1" cycle="$2"
  [ "$PH_TOTAL" -gt 0 ] || return 0
  PH_CYCLE[$seq]="$cycle"
  state_reset_gates "$seq"
  state_publish
}

# state_gate <0..3> <pend|run|pass|fail|skip> — sempre na fase corrente.
state_gate() {
  local g="$1" status="$2" gi now
  [ -n "$CUR_SEQ" ] || return 0
  [ "$PH_TOTAL" -gt 0 ] || return 0

  gi=$((CUR_SEQ * 4 + g))
  now=$(date +%s)
  if [ "$status" = "run" ]; then
    G_START[$gi]=$now
    G_DUR[$gi]=0
  elif [ "${G_START[$gi]:-0}" -gt 0 ]; then
    G_DUR[$gi]=$((now - ${G_START[$gi]}))
  fi
  G_STATUS[$gi]="$status"
  state_publish
}

state_log() {
  LOG_KIND="$1"
  LOG_PATH="$2"
  state_publish
}

state_wait() {
  WAIT_ACTIVE="$1"
  WAIT_UNTIL="$2"
  state_publish
}

state_run_status() {
  RUN_STATUS="$1"
  state_publish
}

# Marca todas as tasks de uma fase de uma vez (fase concluida ou re-iniciada).
state_tasks_all() {
  local seq="$1" status="$2" i
  [ "$TSK_N" -gt 0 ] || return 0
  for ((i = 1; i <= TSK_N; i++)); do
    if [ "${TSK_SEQ[$i]}" = "$seq" ]; then
      TSK_STATUS[$i]="$status"
    fi
  done
  state_publish
}

# Aplica o veredito do gate 3 ("<n>: DONE|INCOMPLETE" por linha) nas tasks da
# fase — a unica leitura task a task que o run produz.
state_tasks_verdicts() {
  local seq="$1" verdicts="$2" i n v
  [ "$TSK_N" -gt 0 ] || return 0

  while read -r n v; do
    [ -n "${n:-}" ] || continue
    n="${n%:}"
    for ((i = 1; i <= TSK_N; i++)); do
      if [ "${TSK_SEQ[$i]}" = "$seq" ] && [ "${TSK_IDX[$i]}" = "$n" ]; then
        case "$v" in
          DONE)     TSK_STATUS[$i]="done" ;;
          NOT-CODE) TSK_STATUS[$i]="manual" ;;
          *)        TSK_STATUS[$i]="failed" ;;
        esac
      fi
    done
  done <<< "$verdicts"

  state_publish
}

# ---------------------------------------------------------------------------
# Painel embutido (--dashboard)
# ---------------------------------------------------------------------------
#
# O ralph continua imprimindo o log linear de sempre — so que em run.log. O
# painel roda como filho, falando direto com /dev/tty. Sem TTY ou sem o script
# do painel, cai no comportamento normal em vez de abortar o run.

DASHBOARD_PID=""

start_dashboard() {
  [ "$DASHBOARD" -eq 1 ] || return 0

  local watch
  watch="$(cd "$(dirname "$0")" && pwd)/ralph-watch.sh"

  if [ ! -f "$watch" ]; then
    warn "--dashboard: $watch nao encontrado; seguindo com o log linear"
    DASHBOARD=0
    return 0
  fi
  if [ ! -t 1 ] || [ ! -e /dev/tty ]; then
    warn "--dashboard exige um terminal; seguindo com o log linear"
    DASHBOARD=0
    return 0
  fi

  mkdir -p "$LOG_DIR"
  : > "$RUN_LOG"

  # fd 9/10 guardam o terminal: o relatorio final volta para a tela depois que
  # o painel morre.
  exec 9>&1 10>&2
  exec >> "$RUN_LOG" 2>&1

  bash "$watch" --embedded "$PWD" < /dev/tty > /dev/tty 2>&1 &
  DASHBOARD_PID=$!

  trap 'stop_dashboard' EXIT
  trap 'stop_dashboard; exit 130' INT
  trap 'stop_dashboard; exit 143' TERM
}

stop_dashboard() {
  [ -n "$DASHBOARD_PID" ] || return 0
  kill "$DASHBOARD_PID" 2> /dev/null || true
  wait "$DASHBOARD_PID" 2> /dev/null || true
  DASHBOARD_PID=""
  exec 1>&9 2>&10
  exec 9>&- 10>&-
  log "Painel encerrado — log completo do run em $RUN_LOG"
}

# ---------------------------------------------------------------------------
# Prompts (auto-contidos — cada sessao e nova)
# ---------------------------------------------------------------------------

context_preamble() {
  cat <<'PREAMBLE'
## Descubra a stack e as convencoes antes de escrever codigo
Este projeto pode ser de qualquer linguagem ou framework. NAO assuma nenhuma
stack. Antes de comecar, LEIA os que existirem, nesta ordem:
1. AGENTS.md ou CLAUDE.md — convencoes, comandos e regras do projeto
2. os documentos de contexto listados abaixo, se houver
3. os documentos citados no proprio texto da fase
Use os comandos de build, teste e execucao definidos por esses documentos e pelo
tooling ja presente no repositorio. Se o projeto tiver uma ferramenta de memoria
ou contexto configurada, use-a para entender o historico.
PREAMBLE

  # Os documentos de contexto vivem ao lado do plano de fases (ex:
  # docs/features/<slug>/{feature-description,user-stories,database-schema}.md).
  # Listar os que EXISTEM de verdade, derivados do input, em vez de caminhos
  # fixos: um caminho hardcoded que nao existe faz TODA sessao — implementacao e
  # cada ciclo de correcao — queimar tool calls procurando arquivo fantasma.
  local doc_dir sibling found=0
  doc_dir="$(dirname "$INPUT_FILE")"
  for sibling in "$doc_dir"/*.md; do
    [ -f "$sibling" ] || continue
    if [ "$(basename "$sibling")" = "$(basename "$INPUT_FILE")" ]; then
      continue
    fi
    if [ "$found" -eq 0 ]; then
      echo
      echo "## Documentos de contexto deste plano"
      echo "Estao ao lado do arquivo de fases. Leia antes de escrever codigo:"
      found=1
    fi
    echo "  - $sibling"
  done

  # O gate 2 roda ESTE comando. Se o agente rodar outro (ex: `php artisan test`
  # no host de um projeto Sail), ele ve verde e o gate ve vermelho.
  if [ -n "$TEST_CMD" ]; then
    echo
    echo "## Comando de teste deste projeto"
    echo "Rode a suite SEMPRE com:"
    echo
    echo "    $TEST_CMD"
    echo
    echo "Este e o comando exato usado para validar a fase. Nao use outro runner"
    echo "nem rode os testes por fora dele."
    if [ -n "$SAIL_BIN" ]; then
      echo "O projeto usa Laravel Sail: artisan, composer, php e testes rodam DENTRO"
      echo "do container, via '$SAIL_BIN <cmd>'. Nunca rode essas ferramentas no host."
    fi
  fi
}

build_impl_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior implementando uma fase deste projeto."
    echo
    context_preamble
    cat <<'TASK'

## Sua tarefa agora
Implemente COMPLETAMENTE a fase descrita abaixo.

Para cada item:
1. Implemente o codigo completo (nao deixe TODOs ou placeholders)
2. Crie os testes listados, seguindo o framework de testes do projeto
3. Rode os testes com o comando de teste do projeto
4. Se um teste falhar, corrija o codigo e rode novamente
5. So passe pro proximo item quando os testes passarem

## Regras obrigatorias
- Use SEMPRE os comandos, o runner de testes e as ferramentas ja adotados pelo
  projeto (nao introduza uma stack ou ferramenta nova por conta propria)
- Testes e fixtures/factories devem criar todas as dependencias necessarias
- Nomes de classes, arquivos e metodos devem seguir EXATAMENTE o que esta descrito
- Nao pule nenhum item marcado com [ ]
- Ao final, valide que toda a suite de testes da fase passa

## Fase a implementar
TASK
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# Prompt de correcao: auto-contido. Carrega a fase inteira + a causa REAL
# da falha (nunca "os testes falharam" generico).
build_fix_prompt() {
  local phase_file="$1" cycle="$2" gate="$3" cause="$4"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior corrigindo uma fase parcialmente implementada."
    echo
    context_preamble
    cat <<'INTRO'

## Situacao
Uma sessao anterior tentou implementar a fase abaixo e NAO passou na verificacao.
Voce esta numa sessao nova: nao tem memoria do que foi feito. Leia o codigo atual
antes de mudar qualquer coisa.

## Regras obrigatorias
- Corrija APENAS o que falta. Nao reimplemente o que ja esta correto e testado.
- Nao deixe TODOs, placeholders ou testes pulados.
- Rode a suite de testes do projeto ao final e garanta que ela passa.
INTRO
    echo
    echo "## Motivo da falha ($gate)"
    echo '```'
    echo "$cause"
    echo '```'
    echo
    echo "## Fase a completar"
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

build_verify_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.verify-${cycle}.txt"

  {
    cat <<'VERIFY'
RALPH_VERIFY

Voce e um verificador independente. NAO escreva, edite ou crie nenhum arquivo.
Seu unico trabalho e ler o codigo real e dizer o que esta feito e o que nao esta.

Para CADA task marcada com `- [ ]` ou `- [x]` na fase abaixo, na ordem em que
aparecem, confira os acceptance criteria contra o codigo real (arquivos, classes,
testes, rotas, migrations — o que a task exigir) e emita EXATAMENTE UMA linha:

TASK <n>: DONE
TASK <n>: INCOMPLETE — <o que falta>
TASK <n>: NOT-CODE — <quem precisa fazer e como>

Antes de julgar, pergunte: esta task afirma algo sobre o codigo?

Task que afirma algo sobre o codigo descreve um ESTADO que voce pode confirmar
lendo arquivos: uma classe existe, uma coluna foi adicionada, um teste cobre um
caso. Julgue essa com DONE ou INCOMPLETE.

Task que NAO afirma nada sobre o codigo descreve uma ACAO de quem conduz o
trabalho, e depois de executada o codigo fica igual: rodar um formatador,
conferir algo num aparelho real, escrever na descricao do PR, decidir se roda a
suite inteira, perguntar algo a alguem. Nao ha o que ler. Emita NOT-CODE e diga
o que ela exige de quem for executa-la.

NOT-CODE e sobre a NATUREZA da task, nunca sobre a sua confianca: task de codigo
que voce nao conseguiu confirmar e INCOMPLETE, nao NOT-CODE.

Regras:
- <n> e o indice da task na fase, comecando em 1.
- Uma linha TASK para cada task, sem excecao, sem agrupar.
- Nao emita nenhum outro texto alem das linhas TASK.
- Codigo ausente, TODO, placeholder ou teste faltando => INCOMPLETE.
- Na duvida entre DONE e INCOMPLETE, INCOMPLETE.

## Fase a verificar
VERIFY
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# ---------------------------------------------------------------------------
# Limite de uso (item 5) — so olha o FIM do log, com padroes por engine
# ---------------------------------------------------------------------------

# Ecoa o epoch de reset se encontrado, "0" para limite sem horario.
# Retorna 0 quando detecta limite, 1 quando nao ha limite.
# Log de UMA linha so? No claude o modo impl usa --output-format json, que
# emite o objeto inteiro numa linha: ali `tail -n` nao isola fim nenhum.
log_is_single_line() {
  [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -le 1 ]
}

# Trecho final do log da engine, para virar causa de ciclo de correcao.
# Num log de uma linha so, `tail -n 40` devolveria o JSON completo — transcript
# da sessao inteira mais metadata de usage — para dentro do prompt de correcao.
# Cap por bytes limita a causa sem depender de um parser de JSON.
engine_tail() {
  local log_file="$1" n="${2:-40}"

  if log_is_single_line "$log_file"; then
    tail -c 4000 "$log_file" 2>/dev/null || true
  else
    tail -n "$n" "$log_file" 2>/dev/null || true
  fi
}

# "try again at 8:25 PM" -> epoch da proxima ocorrencia de 20:25.
# Ecoa vazio quando nao acha horario nenhum, para o chamador cair no fallback.
parse_wallclock_reset() {
  local txt="$1" hhmm h m ampm today_epoch now

  hhmm=$(grep -oiE 'try again at [0-9]{1,2}:[0-9]{2} ?(am|pm)?' <<< "$txt" | tail -1 || true)
  [ -n "$hhmm" ] || return 0

  h=$(grep -oE '[0-9]{1,2}:[0-9]{2}' <<< "$hhmm" | cut -d: -f1)
  m=$(grep -oE '[0-9]{1,2}:[0-9]{2}' <<< "$hhmm" | cut -d: -f2)
  ampm=$(grep -oiE '(am|pm)$' <<< "$hhmm" | tr '[:upper:]' '[:lower:]' || true)

  # 12h -> 24h. "12 AM" e meia-noite e "12 PM" e meio-dia: os dois quebram a
  # regra de somar 12, por isso o 12 e zerado antes.
  h=$((10#$h)); m=$((10#$m))
  if [ "$ampm" = "pm" ] || [ "$ampm" = "am" ]; then
    [ "$h" -eq 12 ] && h=0
    [ "$ampm" = "pm" ] && h=$((h + 12))
  fi
  [ "$h" -lt 24 ] && [ "$m" -lt 60 ] || return 0

  today_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date '+%Y-%m-%d') $(printf '%02d:%02d:00' "$h" "$m")" '+%s' 2>/dev/null \
    || date -d "$(date '+%Y-%m-%d') $(printf '%02d:%02d:00' "$h" "$m")" '+%s' 2>/dev/null || true)
  [ -n "$today_epoch" ] || return 0

  # Horario ja passado hoje significa o reset de amanha.
  now=$(date '+%s')
  if [ "$today_epoch" -le "$now" ]; then
    today_epoch=$((today_epoch + 86400))
  fi

  echo "$today_epoch"
}

detect_usage_limit() {
  local log_file="$1"
  local tail_txt pattern epoch

  # Limite real de uso sempre sai como erro. Sessao que terminou limpa
  # (is_error=false no JSON do claude) nao esta em limite, por mais que o
  # proprio agente tenha escrito "usage limit reached" no meio da resposta —
  # e nesse log de uma linha so o `tail` abaixo nao filtraria nada.
  if grep -qE '"is_error"[[:space:]]*:[[:space:]]*false' "$log_file" 2>/dev/null; then
    return 1
  fi

  # A mensagem de limite sai no FIM da execucao. Olhar o log inteiro faz output
  # de teste do projeto ("429", "Too Many Requests") disparar espera de 30min.
  tail_txt=$(engine_tail "$log_file" 20)

  # Os provedores nao escrevem a mesma frase duas vezes. O codex ja saiu com
  # "You've hit your usage limit. (...) try again at 8:25 PM", que nao casa com
  # nenhuma variante de "<algo> limit reached" — o invariante 4 nao disparou, a
  # fase queimou um ciclo de correcao e o relatorio culpou as tasks. Casar o
  # NUCLEO da frase ("usage limit", "rate limit") em vez da frase inteira.
  # Alargar so e seguro porque isto le o tail, nao o log todo: um "429" no meio
  # da saida de teste do projeto nao chega aqui.
  if [[ "$ENGINE" == "claude" ]]; then
    pattern='usage limit|rate limit'
  else
    pattern='usage limit|rate limit|quota exceeded|too many requests|insufficient_quota'
  fi

  grep -qiE "$pattern" <<< "$tail_txt" || return 1

  epoch=$(grep -oiE 'usage limit reached[^0-9]*[0-9]{10,13}' <<< "$tail_txt" \
    | grep -oE '[0-9]{10,13}' | tail -1 || true)

  if [ -z "$epoch" ]; then
    epoch=$(grep -oiE 'reset[a-z ]*[0-9]{10,13}' <<< "$tail_txt" \
      | grep -oE '[0-9]{10,13}' | tail -1 || true)
  fi

  # Nem todo provedor da o reset em epoch. O codex responde "try again at
  # 8:25 PM" — relogio de parede. Sem isto o epoch fica vazio e a espera cai no
  # fallback cego de 30min, que tanto pode acordar cedo demais (e queimar outra
  # tentativa) quanto tarde demais.
  if [ -z "$epoch" ]; then
    epoch=$(parse_wallclock_reset "$tail_txt")
  fi

  echo "${epoch:-0}"
  return 0
}

wait_for_reset() {
  local epoch="$1"
  local now wait_secs
  now=$(date +%s)

  LIMIT_WAITS=$((LIMIT_WAITS + 1))
  if [ "$LIMIT_WAITS" -gt "$MAX_LIMIT_WAITS" ]; then
    fail "Limite de uso atingido $LIMIT_WAITS vezes seguidas nesta fase (cap: $MAX_LIMIT_WAITS)."
    fail "Abortando em vez de dormir indefinidamente."
    exit 1
  fi

  if [[ "$epoch" =~ ^[0-9]+$ ]] && [ "$epoch" -gt 0 ]; then
    if [ "${#epoch}" -ge 13 ]; then
      epoch=$((epoch / 1000))
    fi
    wait_secs=$((epoch - now + LIMIT_BUFFER))
    if [ "$wait_secs" -lt "$LIMIT_BUFFER" ]; then
      wait_secs=$LIMIT_BUFFER
    fi
    warn "Limite de uso atingido. Reset previsto para $(fmt_ts "$epoch")."
  else
    wait_secs=$LIMIT_WAIT_DEFAULT
    warn "Limite de uso atingido. Sem horario de reset no output; aguardando fallback."
  fi

  warn "Espera $LIMIT_WAITS/$MAX_LIMIT_WAITS — aguardando $(format_duration "$wait_secs") ate retomar a MESMA fase..."
  state_wait 1 $((now + wait_secs))

  local remaining=$wait_secs chunk
  while [ "$remaining" -gt 0 ]; do
    chunk=60
    [ "$remaining" -lt 60 ] && chunk=$remaining
    sleep "$chunk"
    remaining=$((remaining - chunk))
    if [ "$remaining" -gt 0 ]; then
      log "Retomando em $(format_duration "$remaining")..."
      state_publish
    fi
  done

  state_wait 0 0
  success "Reset provavelmente concluido. Retomando execucao."
}

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

# Roda o comando da engine mandando TUDO para o log. O codex streama raciocinio,
# patches e tool calls no stdout; espelhar isso na tela enterra as linhas do
# proprio ralph (fases, gates, causa de falha). Com --verbose / RALPH_VERBOSE=1
# o comportamento antigo volta.
run_logged() {
  local log_file="$1"
  shift

  if [ "$VERBOSE" -eq 1 ]; then
    "$@" 2>&1 | tee "$log_file"
  else
    "$@" > "$log_file" 2>&1
  fi
}

# run_engine <prompt_file> <log_file> <mode: impl|verify>
# Loop de resiliencia a limite de uso: nao consome ciclo de correcao.
run_engine() {
  local prompt_file="$1" log_file="$2" mode="$3"

  export RALPH_ENGINE="$ENGINE"
  export RALPH_PHASE_MAX_ATTEMPTS="$MAX_CYCLES"

  local model_args=()
  if [[ "$mode" == "verify" ]]; then
    model_args=(${ENGINE_VERIFY_ARGS[@]+"${ENGINE_VERIFY_ARGS[@]}"})
  fi

  while true; do
    local rc=0

    if [ "$VERBOSE" -eq 0 ]; then
      log "Rodando $ENGINE ($mode) — output em $log_file"
    fi

    state_log "$mode" "$log_file"

    if [[ "$ENGINE" == "codex" ]]; then
      if [[ "$mode" == "verify" ]]; then
        run_logged "$log_file" codex exec --color never --sandbox read-only \
          ${model_args[@]+"${model_args[@]}"} - < "$prompt_file" || rc=$?
      else
        run_logged "$log_file" codex exec --color never --sandbox danger-full-access \
          ${ENGINE_IMPL_ARGS[@]+"${ENGINE_IMPL_ARGS[@]}"} - < "$prompt_file" || rc=$?
      fi
    else
      # < /dev/null: claude -p le stdin quando nao e TTY. Sem o redirect ele
      # consome o stream de quem chamou (ex: o manifest do loop de fases).
      if [[ "$mode" == "verify" ]]; then
        # --disallowedTools, nao --allowedTools: sob --dangerously-skip-permissions
        # a allowlist nao restringe nada (tudo ja esta auto-aprovado), e o
        # "verificador read-only" conseguia escrever. Se ele consertasse a task
        # que ia reprovar, o veredito viria DONE e o `git add -A` commitaria
        # codigo que o gate 2 — que roda ANTES do gate 3 — nunca testou.
        # --strict-mcp-config: le codigo com Read/Glob/Grep, nao precisa de
        # nenhum MCP server; carregar os schemas custa ~4k tokens por fase.
        run_logged "$log_file" env -u CLAUDECODE claude --dangerously-skip-permissions \
          --strict-mcp-config \
          ${model_args[@]+"${model_args[@]}"} \
          -p "$(cat "$prompt_file")" \
          --disallowedTools "Write,Edit,NotebookEdit,Bash" \
          --output-format text < /dev/null || rc=$?
      else
        # JSON: o exit code do CLI e sinal fraco; o gate 0 le is_error.
        run_logged "$log_file" env -u CLAUDECODE claude --dangerously-skip-permissions \
          ${ENGINE_IMPL_ARGS[@]+"${ENGINE_IMPL_ARGS[@]}"} \
          -p "$(cat "$prompt_file")" \
          --output-format json < /dev/null || rc=$?
      fi
    fi

    # Ctrl-C (130) ou SIGTERM (143) sao decisao de quem esta olhando a tela, nao
    # falha de implementacao. Sem isto o gate 0 trata a interrupcao como fase
    # ruim e abre um ciclo de correcao: o usuario aperta Ctrl-C e o ralph
    # responde subindo OUTRA sessao.
    if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
      echo
      fail "Execucao interrompida (sinal $rc). Abortando o run."
      if [ -n "$(git status --porcelain)" ]; then
        fail "O trabalho parcial ficou na arvore. Antes de rodar de novo:"
        fail "    commite (o ralph revalida a fase e segue) ou 'git checkout -- . && git clean -fd' (descarta)"
      fi
      exit "$rc"
    fi

    local reset_epoch
    if reset_epoch=$(detect_usage_limit "$log_file"); then
      wait_for_reset "$reset_epoch"
      continue
    fi

    return "$rc"
  done
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

# Gate 0 — o engine terminou de verdade?
# Preenche GATE_CAUSE quando vermelho.
GATE_CAUSE=""

gate0_engine_finished() {
  local log_file="$1" rc="$2"

  if [[ "$ENGINE" == "claude" ]]; then
    if ! grep -qF '"type":"result"' "$log_file" && ! grep -qF '"type": "result"' "$log_file"; then
      GATE_CAUSE="O engine terminou sem emitir um resultado. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
      state_gate 0 fail
      return 1
    fi
    if grep -qE '"is_error"[[:space:]]*:[[:space:]]*true' "$log_file"; then
      GATE_CAUSE="O engine reportou is_error=true. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
      state_gate 0 fail
      return 1
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="O engine saiu com codigo $rc. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
    state_gate 0 fail
    return 1
  fi

  state_gate 0 pass
  return 0
}

# Assinatura da arvore: rastreados (status + diff) e nao-rastreados (conteudo).
# Sem mutar o index.
tree_signature() {
  {
    git status --porcelain
    git diff HEAD
    git ls-files --others --exclude-standard -z | xargs -0 -r sha256sum 2> /dev/null
  } 2> /dev/null | sha256sum | cut -c1-16
}

# Gate 1 — esta sessao escreveu codigo?
#
# SINAL, nao veredito. Uma fase pode ja estar implementada antes da sessao
# (tasks `[x]`, run anterior commitada, dev implementou a mao). Nesse caso o
# engine correto NAO escreve nada, e reprovar aqui seria um falso negativo:
# so os gates 2 e 3 sabem se o codigo esta completo.
#
# O retorno alimenta a causa do ciclo de correcao ("a sessao nao escreveu
# nada") quando algum gate posterior reprova.
gate1_session_wrote() {
  local sig_before="$1"
  [ "$(tree_signature)" != "$sig_before" ]
}

# Gate 2 — a suite do projeto passa, rodada PELO ralph (fora da sessao do agente)?
gate2_tests_pass() {
  local test_log="$1"

  if [ -z "$TEST_CMD" ]; then
    state_gate 2 skip
    return 0
  fi

  log "Gate 2 — rodando a suite do projeto: $TEST_CMD"
  state_gate 2 run
  state_log test "$test_log"
  local rc=0
  # < /dev/null: sail test (docker compose exec) anexa stdin e consumiria o
  # stream de quem chamou, alem de poder travar esperando input.
  bash -c "$TEST_CMD" < /dev/null > "$test_log" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="O comando de teste do projeto ('$TEST_CMD') falhou com codigo $rc. Saida:"$'\n'"$(tail -n 200 "$test_log")"
    state_gate 2 fail
    return 1
  fi

  success "Gate 2 — suite verde"
  state_gate 2 pass
  return 0
}

# Gate 3 — sessao verificadora independente, read-only, task a task.
# O gate final: roda em toda fase por default (always). Modo auto economiza,
# rodando so quando o veredito do gate 2 nao basta:
#   - a sessao nao escreveu nada (claim "ja implementada" — so a verificacao
#     independente confirma isso sem confiar na palavra do engine)
#   - ciclo de correcao (a fase ja reprovou uma vez)
#   - gate 2 desabilitado (sem suite, o verificador e o unico gate)
# GATE3_RAN diz ao caminho "ja implementada" quais gates de fato validaram HEAD.
GATE3_RAN=0

gate3_verify_uncached() {
  local phase_file="$1" cycle="$2" session_wrote="$3"
  local verify_log="$LOG_DIR/${phase_file%.md}.verify-${cycle}.log"

  GATE3_RAN=0

  case "$VERIFY_MODE" in
    off)
      log "Gate 3 pulado (--no-verify)"
      state_gate 3 skip
      return 0
      ;;
    auto)
      if [ "$cycle" -eq 1 ] && [ "$session_wrote" -eq 1 ] && [ -n "$TEST_CMD" ]; then
        log "Gate 3 pulado: a sessao escreveu codigo e a suite passou (RALPH_VERIFY=always para rodar sempre)"
        state_gate 3 skip
        return 0
      fi
      ;;
  esac

  local expected
  expected=$(grep -cE '^[[:space:]]*- \[[ x]\]' "$PHASES_DIR/$phase_file" || true)

  if [ "$expected" -eq 0 ]; then
    warn "Gate 3 pulado: a fase nao declara nenhuma task '- [ ]'"
    state_gate 3 skip
    return 0
  fi

  GATE3_RAN=1
  log "Gate 3 — sessao verificadora independente ($expected tasks${VERIFY_MODEL:+, modelo: $VERIFY_MODEL}${VERIFY_EFFORT:+, effort: $VERIFY_EFFORT})"
  state_gate 3 run

  local prompt_file
  prompt_file=$(build_verify_prompt "$phase_file" "$cycle")
  run_engine "$prompt_file" "$verify_log" verify || true

  local task_lines
  task_lines=$(sed 's/^[[:space:]]*//' "$verify_log" | grep -E '^TASK [0-9]+: (DONE|INCOMPLETE|NOT-CODE)' || true)

  if [ -z "$task_lines" ]; then
    GATE_CAUSE="O verificador independente nao emitiu nenhuma linha 'TASK <n>: DONE|INCOMPLETE|NOT-CODE' — nao foi possivel confirmar que a fase esta completa. Ultimas linhas do verificador:"$'\n'"$(engine_tail "$verify_log" 40)"
    state_gate 3 fail
    return 1
  fi

  # Consolida por NUMERO da task, nao por linha. O `codex exec` reimprime a
  # ultima mensagem do agente depois do resumo de tokens, entao o bloco TASK
  # aparece duas vezes no log: contar linhas cruas reprovaria toda fase por
  # "cobertura incompleta". INCOMPLETE em qualquer emissao vence DONE — na
  # duvida, incompleto, igual a instrucao dada ao verificador.
  local verdicts
  verdicts=$(printf '%s\n' "$task_lines" | awk '{
      n = $2; sub(":", "", n);
      v = ($0 ~ /INCOMPLETE/) ? "INCOMPLETE" : ($0 ~ /NOT-CODE/) ? "NOT-CODE" : "DONE";
      if (!(n in seen) || v == "INCOMPLETE") { seen[n] = v }
    }
    END { for (n in seen) { print n": "seen[n] } }' | sort -n)

  local parsed
  parsed=$(printf '%s\n' "$verdicts" | grep -c . || true)

  # Task fora de 1..expected e emissao malformada: o verificador inventou indice.
  local out_of_range
  out_of_range=$(printf '%s\n' "$verdicts" | awk -v max="$expected" '{
      n = $1; sub(":", "", n);
      if (n + 0 < 1 || n + 0 > max) { print }
    }')

  if [ -n "$out_of_range" ]; then
    GATE_CAUSE="O verificador emitiu indices de task fora do intervalo 1..$expected:"$'\n'"$out_of_range"$'\n'"Linhas originais:"$'\n'"$task_lines"
    state_gate 3 fail
    return 1
  fi

  # Indices dentro do intervalo: da para espelhar o veredito task a task no painel.
  state_tasks_verdicts "${CUR_SEQ:-0}" "$verdicts"

  if [ "$parsed" -ne "$expected" ]; then
    GATE_CAUSE="O verificador cobriu $parsed de $expected tasks — cobertura incompleta. Veredito por task:"$'\n'"$verdicts"
    state_gate 3 fail
    return 1
  fi

  # Reporta a LINHA ORIGINAL da task incompleta, nao o veredito consolidado: o
  # texto depois do travessao ("— falta o teste X") e a causa que vai no prompt
  # de correcao.
  local incomplete
  incomplete=$(printf '%s\n' "$verdicts" \
    | awk '/INCOMPLETE/ { n = $1; sub(":", "", n); print n }' \
    | while read -r task_num; do
        [ -n "$task_num" ] || continue
        printf '%s\n' "$task_lines" | grep -m1 -E "^TASK $task_num: INCOMPLETE" || true
      done)

  # NOT-CODE nao reprova, mas tambem nao e um "confirmado": e trabalho que
  # continua pendente do lado de fora do repositorio. Sai no relatorio para que
  # quem abre o PR saiba o que ainda lhe cabe.
  local not_code n_not_code=0
  not_code=$(printf '%s\n' "$verdicts" | awk '/NOT-CODE/ { n = $1; sub(":", "", n); print n }')
  [ -n "$not_code" ] && n_not_code=$(printf '%s\n' "$not_code" | grep -c .)

  if [ -n "$incomplete" ]; then
    GATE_CAUSE="O verificador independente encontrou tasks incompletas:"$'\n'"$incomplete"
    state_gate 3 fail
    return 1
  fi

  if [ -n "$not_code" ]; then
    success "Gate 3 — $((parsed - n_not_code))/$expected tasks confirmadas no codigo"
    warn "Gate 3 — $n_not_code task(s) fora do codigo, pendentes de quem conduz:"
    local task_num
    while read -r task_num; do
      [ -n "$task_num" ] || continue
      printf '%s\n' "$task_lines" | grep -m1 -E "^TASK $task_num: NOT-CODE" | sed 's/^/    /' || true
    done <<< "$not_code"
  else
    success "Gate 3 — $parsed/$expected tasks confirmadas no codigo"
  fi

  state_gate 3 pass
  return 0
}

# Memo do gate 3, por assinatura de arvore. Invalidado a cada fase em run_phase:
# uma fase que fecha sem commitar deixa HEAD e arvore intactos, e sem o reset a
# fase seguinte herdaria o veredito da anterior.
GATE3_MEMO_SIG=""
GATE3_MEMO_RC=0
GATE3_MEMO_CAUSE=""
GATE3_MEMO_RAN=0

gate3_memo_reset() {
  GATE3_MEMO_SIG=""
  GATE3_MEMO_RC=0
  GATE3_MEMO_CAUSE=""
  GATE3_MEMO_RAN=0
}

# Fase operacional: a propria fase se declara com `**Operational phase**` numa
# linha sozinha. Sao as fases de close out — rodar formatador, build, a suite —
# em que quase nada e afirmacao sobre o codigo. Ali o gate 3 nao tem o que
# julgar, e reprovar abre um ciclo de correcao sem nada a corrigir: o veredito
# passaria a depender de o verificador classificar certo N vezes seguidas.
#
# Declarado, nao inferido: contar quantas tasks vieram NOT-CODE faria o destino
# da fase depender do mesmo verificador que ja se mostrou instavel. Quem escreve
# o plano sabe se a fase e operacional; o ralph so le a declaracao.
#
# O gate 3 continua rodando e reportando — perde o poder de reprovar, nao a voz.
# Quem garante corretude nessa fase e o gate 2, que roda a suite fora do agente.
phase_is_operational() {
  grep -qE '^[[:space:]]*\*\*Operational phase\*\*' "$PHASES_DIR/$1" 2>/dev/null
}

# O gate 3 e uma funcao do codigo: bytes identicos tem que dar o mesmo veredito.
# Sem memo, um ciclo de correcao que nao escreveu nada paga OUTRA sessao de
# verificacao para julgar exatamente os mesmos bytes — e verificador fraco muda
# de ideia. Na fase 12 de admin-area-users tres NOT-CODE viraram dois DONE e um
# INCOMPLETE sem uma linha mudar, e esse INCOMPLETE reprovou a fase.
gate3_independent_verify() {
  local phase_file="$1" cycle="$2" session_wrote="$3"
  local tree_sig rc=0

  tree_sig=$(tree_signature)

  if [ -n "$GATE3_MEMO_SIG" ] && [ "$tree_sig" = "$GATE3_MEMO_SIG" ]; then
    GATE_CAUSE="$GATE3_MEMO_CAUSE"
    GATE3_RAN="$GATE3_MEMO_RAN"
    if [ "$GATE3_MEMO_RC" -eq 0 ]; then
      success "Gate 3 — codigo identico ao do ciclo anterior; veredito mantido (aprovado)"
      state_gate 3 pass
    else
      warn "Gate 3 — codigo identico ao do ciclo anterior; veredito mantido (reprovado), sem re-julgar"
      state_gate 3 fail
    fi
    return "$GATE3_MEMO_RC"
  fi

  gate3_verify_uncached "$phase_file" "$cycle" "$session_wrote" || rc=$?

  if [ "$rc" -ne 0 ] && phase_is_operational "$phase_file"; then
    warn "Gate 3 — fase declarada operacional (**Operational phase**); reporta, nao reprova"
    warn "Gate 3 — corretude desta fase fica por conta do gate 2 (suite do projeto). Pendente:"
    printf '%s\n' "$GATE_CAUSE" | sed 's/^/    /'
    GATE_CAUSE=""
    rc=0
    state_gate 3 pass
  fi

  GATE3_MEMO_SIG="$tree_sig"
  GATE3_MEMO_RC="$rc"
  GATE3_MEMO_CAUSE="$GATE_CAUSE"
  GATE3_MEMO_RAN="$GATE3_RAN"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Execucao de fase
# ---------------------------------------------------------------------------

# Grava a memoria da fase no mem0 de forma deterministica, FORA do run agentico.
# No run grande o agente passa nos testes e encerra sem chamar o mem0, por mais
# que o prompt peca. Aqui e uma sessao dedicada, escopo de uma tool so — padrao
# ja testado e confiavel.
#
# SOMENTE no engine claude: no codex o plugin oficial do mem0 (config.toml) ja
# auto-captura via hooks, e duplicar geraria memoria redundante e custo extra.
save_memory() {
  local phase_file="$1" phase_title="$2"

  [ "$MEM0_ENABLED" = "1" ] || return 0
  [ -n "$MEM0_USER_ID" ] || return 0
  [[ "$ENGINE" == "claude" ]] || return 0

  log "Gravando resumo da fase no mem0..."

  local changed_files
  changed_files=$(git diff HEAD --name-only 2>/dev/null | head -40)
  [ -z "$changed_files" ] && changed_files="(sem diff disponivel)"

  local mem_prompt
  mem_prompt="You have one job: call the MCP tool \`mcp__mem0__add_memory\` exactly once. Do nothing else.

Params:
- userId: \"$MEM0_USER_ID\"
- content: a 2-3 sentence summary of the phase below, including non-obvious technical decisions.

Phase: $phase_title

Files changed in this phase:
$changed_files

After the tool call returns, reply with only the word DONE."

  # Modelo do verificador, nunca o de implementacao: isto e uma tool call e duas
  # frases. Com ENGINE_IMPL_ARGS a memoria de cada fase saia num opus/xhigh.
  # --disallowedTools porque sob --dangerously-skip-permissions a allowlist nao
  # restringe; sem MCP nao da, o mem0 E um MCP server.
  local mem_log="$LOG_DIR/${phase_file%.md}.mem0.log"
  if env -u CLAUDECODE claude ${ENGINE_VERIFY_ARGS[@]+"${ENGINE_VERIFY_ARGS[@]}"} \
       --dangerously-skip-permissions -p "$mem_prompt" \
       --disallowedTools "Write,Edit,NotebookEdit,Bash" \
       --output-format text < /dev/null > "$mem_log" 2>&1; then
    success "Memoria gravada no mem0 (log: $mem_log)"
  else
    warn "Falha ao gravar memoria no mem0 (log: $mem_log) — fase segue valida"
  fi
}

commit_phase() {
  local phase_num="$1" phase_title="$2"
  git add -A
  if git diff --cached --quiet; then
    fail "Nada para commitar apos os gates — estado inesperado."
    return 1
  fi
  git commit -q -m "feat(phase-${phase_num}): ${phase_title}"
  log "Commit criado: feat(phase-${phase_num}): ${phase_title}"
}

commit_wip() {
  local phase_num="$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git add -A
  git commit -q -m "wip(phase-${phase_num}): incomplete — see .phases/logs/"
  warn "Commit wip criado para a fase $phase_num — a proxima fase parte de arvore limpa"
}

# run_phase <phase_file> <phase_num> <phase_title> <seq> <total>
run_phase() {
  local phase_file="$1" phase_num="$2" phase_title="$3" seq="$4" total="$5"
  local phase_start
  phase_start=$(date +%s)

  export RALPH_PHASE_TITLE="$phase_title"
  export RALPH_PHASE_NUM="$phase_num"
  export RALPH_PHASE_TOTAL="$total"

  LIMIT_WAITS=0
  GATE_CAUSE=""
  gate3_memo_reset
  CUR_SEQ="$seq"
  state_phase "$seq" running

  echo ""
  log "[$seq/$total] Phase $phase_num: $phase_title"

  local cycle=1 cycles_run=0
  while [ "$cycle" -le "$MAX_CYCLES" ]; do
    cycles_run="$cycle"
    export RALPH_PHASE_ATTEMPT="$cycle"
    [ "$cycle" -gt 1 ] && warn "Ciclo de correcao $cycle/$MAX_CYCLES..."
    state_cycle "$seq" "$cycle"

    local prompt_file log_file rc=0 sig_before
    log_file="$LOG_DIR/${phase_file%.md}.cycle-${cycle}.log"

    if [ "$cycle" -eq 1 ]; then
      prompt_file=$(build_impl_prompt "$phase_file" "$cycle")
    else
      prompt_file=$(build_fix_prompt "$phase_file" "$cycle" "$LAST_GATE" "$GATE_CAUSE")
    fi

    sig_before=$(tree_signature)
    run_engine "$prompt_file" "$log_file" impl || rc=$?

    GATE_CAUSE=""

    # Gate 1 e sinal, nao veredito: uma fase ja implementada faz o engine
    # (corretamente) nao escrever nada. Quem decide sao os gates 2 e 3.
    # O sinal tambem alimenta o modo auto do gate 3: sessao sem escrita e
    # exatamente o caso em que a verificacao independente e obrigatoria.
    local no_change_note="" session_wrote=1
    if ! gate1_session_wrote "$sig_before"; then
      session_wrote=0
      no_change_note="A sessao anterior terminou sem alterar nenhum arquivo. "
      warn "Gate 1 — a sessao nao escreveu nada; validando o codigo existente"
      state_gate 1 skip
    else
      state_gate 1 pass
    fi

    if ! gate0_engine_finished "$log_file" "$rc"; then
      LAST_GATE="gate 0 — engine nao concluiu"
      fail "Gate 0 vermelho"
    elif ! gate2_tests_pass "$LOG_DIR/${phase_file%.md}.test-${cycle}.log"; then
      LAST_GATE="gate 2 — suite de testes do projeto"
      GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
      fail "Gate 2 vermelho — testes do projeto falharam"
    elif ! gate3_independent_verify "$phase_file" "$cycle" "$session_wrote"; then
      LAST_GATE="gate 3 — verificacao independente"
      GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
      fail "Gate 3 vermelho — implementacao incompleta"
    else
      local phase_duration=$(($(date +%s) - phase_start))

      # Gates verdes e nada a commitar => a fase ja estava implementada em HEAD
      # (run anterior commitada, tasks [x], codigo escrito a mao).
      if [ -z "$(git status --porcelain)" ]; then
        success "Phase $phase_num: $phase_title — JA IMPLEMENTADA (nada a commitar)"
        if [ "$GATE3_RAN" -eq 1 ]; then
          log "Gates 2 e 3 verdes contra o codigo em HEAD; nenhum commit criado."
        else
          log "Gate 2 verde contra o codigo em HEAD; nenhum commit criado."
        fi
        mark_phase_done "$phase_file"
        state_tasks_all "$seq" done
        state_phase "$seq" done
        return 0
      fi

      success "Phase $phase_num: $phase_title — COMPLETA ($(format_duration "$phase_duration"))"

      # Antes do commit: `git diff HEAD` ainda mostra os arquivos da fase.
      save_memory "$phase_file" "$phase_title"

      if ! commit_phase "$phase_num" "$phase_title"; then
        LAST_GATE="commit"
        state_phase "$seq" failed
        return 1
      fi
      mark_phase_done "$phase_file"
      state_tasks_all "$seq" done
      state_phase "$seq" done
      return 0
    fi

    # Chegar aqui significa gate vermelho. Se a sessao de correcao nao escreveu
    # nada, o proximo ciclo recebe o mesmo codigo e o mesmo prompt de correcao —
    # nao ha de onde vir um resultado diferente. A fase esta travada, nao
    # incompleta. (No ciclo 1 nao escrever e legitimo: a fase pode ja estar em
    # HEAD; por isso a condicao so vale da segunda tentativa em diante.)
    if [ "$cycle" -gt 1 ] && [ "$session_wrote" -eq 0 ]; then
      warn "Ciclo $cycle nao alterou nenhum arquivo — parando em vez de repetir"
      # Sessao que nao escreveu porque JULGOU e sessao que nao escreveu porque
      # MORREU pedem investigacao em lugares opostos. Culpar as tasks quando a
      # engine caiu por cota manda quem le auditar um plano que estava correto —
      # foi o que aconteceu na fase 9 de admin-area-users.
      case "$LAST_GATE" in
        "gate 0"*)
          GATE_CAUSE="A engine nao concluiu e nao deixou veredito nenhum. Isso quase sempre e falha de infra — cota estourada, rede, crash ou timeout — e nao um problema das tasks. Leia o fim do log da engine abaixo ANTES de suspeitar do plano."$'\n'"$GATE_CAUSE"
          ;;
        *)
          GATE_CAUSE="A sessao de correcao terminou sem alterar nenhum arquivo. Repetir daria o mesmo codigo e o mesmo prompt: a fase esta travada, nao incompleta. Revise as tasks abaixo — podem ser impossiveis, contraditorias ou nao ser sobre codigo."$'\n'"$GATE_CAUSE"
          ;;
      esac
      break
    fi

    cycle=$((cycle + 1))
  done

  local phase_duration=$(($(date +%s) - phase_start))
  state_phase "$seq" failed
  fail "Phase $phase_num: $phase_title — FALHOU apos $cycles_run ciclo(s) ($(format_duration "$phase_duration"))"
  fail "Ultima causa ($LAST_GATE):"
  printf '%s\n' "$GATE_CAUSE" | head -n 20 | sed 's/^/    /'
  fail "Logs em: $LOG_DIR/${phase_file%.md}.*"

  # O trabalho parcial fica na arvore; o preflight da proxima execucao exige
  # arvore limpa. Diga o que fazer em vez de deixar o dev descobrir no abort.
  if [ -n "$(git status --porcelain)" ]; then
    warn "O trabalho parcial desta fase ficou na arvore. Antes de re-rodar o ralph:"
    warn "    commite (o ralph revalida a fase e segue) ou 'git checkout -- . && git clean -fd' (descarta)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

LAST_GATE=""

main() {
  preflight_checks
  split_phases
  apply_from_override

  local total_phases
  total_phases=$(manifest_entries | wc -l)

  if [ "$total_phases" -eq 0 ]; then
    fail "Nenhuma fase extraida de $INPUT_FILE."
    exit 1
  fi

  if [ "$FROM_PHASE" -gt "$total_phases" ]; then
    fail "--from $FROM_PHASE excede o total de fases ($total_phases)."
    exit 1
  fi

  echo ""
  log "$total_phases fases para implementar (engine: $ENGINE, max-cycles: $MAX_CYCLES)"
  [ "$FROM_PHASE" -gt 1 ] && log "Iniciando a partir da fase $FROM_PHASE"
  echo ""

  state_init

  local file num title listed=0
  while IFS='|' read -r file num title; do
    listed=$((listed + 1))
    if [ "$num" -lt "$FROM_PHASE" ]; then
      echo -e "  ${BLUE}[$num] $title (pulada por --from)${NC}"
      PH_STATUS[$listed]="skipped"
    elif is_phase_done "$file"; then
      echo -e "  ${GREEN}[$num] $title (ja completada)${NC}"
      PH_STATUS[$listed]="done"
      state_tasks_all "$listed" done
    else
      echo -e "  ${YELLOW}[$num] $title${NC}"
    fi
  done < <(manifest_entries)
  state_publish
  start_dashboard

  local start_time
  start_time=$(date +%s)
  echo ""
  log "Inicio: $(date '+%d/%m/%Y %H:%M:%S')"

  local seq=0
  local failed_phases=() skipped_phases=() completed_phases=()

  # fd 3, nunca stdin: comandos do corpo (claude -p, sail test / docker compose
  # exec) leem stdin quando nao e TTY e engoliriam o resto do manifest — o run
  # pararia apos a primeira fase.
  while IFS='|' read -r -u 3 file num title; do
    seq=$((seq + 1))

    if [ "$num" -lt "$FROM_PHASE" ]; then
      log "Pulando Phase $num: $title (antes de --from $FROM_PHASE)"
      skipped_phases+=("$title")
      continue
    fi

    if is_phase_done "$file"; then
      log "Pulando Phase $num: $title (ja completada)"
      skipped_phases+=("$title")
      continue
    fi

    if run_phase "$file" "$num" "$title" "$seq" "$total_phases"; then
      completed_phases+=("$title")
    else
      failed_phases+=("$title")
      if $KEEP_GOING; then
        warn "--keep-going: seguindo para a proxima fase"
        commit_wip "$num"
      else
        warn "Parando na primeira fase que falhou (use --keep-going para continuar)"
        break
      fi
    fi
  done 3< <(manifest_entries)

  local end_time total_duration
  end_time=$(date +%s)
  total_duration=$((end_time - start_time))

  CUR_SEQ=""
  LOG_KIND=""
  LOG_PATH=""
  if [ ${#failed_phases[@]} -eq 0 ]; then
    state_run_status done
  else
    state_run_status failed
  fi

  # O relatorio final e do run inteiro: sai na tela, nao no run.log do painel.
  stop_dashboard

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "RELATORIO FINAL (engine: $ENGINE)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local phase
  if [ ${#completed_phases[@]} -gt 0 ]; then
    echo ""
    success "Completadas (${#completed_phases[@]}):"
    for phase in "${completed_phases[@]}"; do printf '    %b%s%b\n' "$GREEN" "$phase" "$NC"; done
  fi

  if [ ${#skipped_phases[@]} -gt 0 ]; then
    echo ""
    log "Puladas (${#skipped_phases[@]}):"
    for phase in "${skipped_phases[@]}"; do printf '    %s\n' "$phase"; done
  fi

  if [ ${#failed_phases[@]} -gt 0 ]; then
    echo ""
    fail "Falharam (${#failed_phases[@]}):"
    for phase in "${failed_phases[@]}"; do printf '    %b%s%b\n' "$RED" "$phase" "$NC"; done
    echo ""
    fail "Verifique os logs em $LOG_DIR/"
  fi

  echo ""
  log "Inicio: $(fmt_ts "$start_time")"
  log "Fim:    $(fmt_ts "$end_time")"
  log "Duracao total: $(format_duration "$total_duration")"
  echo ""

  [ ${#failed_phases[@]} -eq 0 ] || exit 1
}

main
