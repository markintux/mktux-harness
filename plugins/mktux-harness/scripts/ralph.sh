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
#   ...) entram no prompt: o recorte do que a fase cita (secoes, regras BR,
#   tabelas, stories US — scripts/lib/phase-context.sh) e os caminhos, para
#   consulta pontual.
#
# Contrato de formato do input (validado no preflight):
#   - >= 1 heading `## Phase N: <titulo>`
#   - nenhum heading `## Phase ...` fora desse formato
#   - sub-fases em `### Phase N.M:` (nao viram sessao propria)
#   - qualquer outro `## ` encerra a captura da fase anterior
#   - `**Operational phase**` numa linha sozinha marca fase de close out: o
#     gate 3 reporta mas nao reprova (as tasks nao sao afirmacoes sobre codigo)
#   - `**Check-only phase**` numa linha sozinha marca fase que so afirma estado:
#     gates 2 e 3 rodam contra HEAD antes de abrir sessao; so abre se reprovar
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
#      modelo de implementacao. Recebe as tasks ja numeradas pelo ralph e os
#      arquivos alterados na fase como ponto de partida. Ferramentas: claude so
#      tem Read/Glob/Grep; codex roda em sandbox read-only, instruido a nao
#      rodar build nem teste.
#
# Contestacao: a sessao que confirma um erro no plano (task que cita o que nao
# existe, contradiz uma BR/US, ou exige quebrar teste que a fase proibe tocar)
# termina a resposta com
#   RALPH-CONTEST: TASK <n> — <evidencia>
# Gate 3 reprovando uma task contestada, ou gate 2 vermelho com contestacao,
# para a fase para decisao humana, sem outro ciclo. Fase que fecha verde com
# contestacao segue, e a contestacao sai no relatorio final.
#
# Sessoes frias de verdade: os hooks do ai-memory ficam de fora
# (RALPH_HOOK_ISOLATION) e, no codex, a memoria nativa (features.memories).
# .phases/ e .harness/ entram no .git/info/exclude.
#
# Gates verdes com a arvore limpa => a fase ja estava implementada em HEAD:
# marcada como feita, sem commit (nao ha o que commitar).
#
# Comando de teste (gate 2), primeira regra que resolver:
#   1. --test-cmd "<cmd>"
#   2. RALPH_TEST_CMD
#   3. o perfil de stack do diretorio atual (profiles/<nome>/profile.sh, que
#      define o comando). O que resolve num projeto, sem rodar nada:
#      scripts/mktux-profile.sh test-cmd
#   4. deteccao por manifest:
#        composer.json com scripts.test            -> composer test
#        package.json com scripts.test             -> npm test
#        pytest.ini / pyproject [tool.pytest]      -> pytest (uv run pytest com
#                                                     uv.lock, poetry run pytest
#                                                     com poetry.lock)
#        go.mod                                    -> go test ./...
#        Cargo.toml                                -> cargo test
#   5. nada resolvido -> aviso alto + gate 2 pulado (o gate 3 segura sozinho)
#
# O perfil tambem valida o ambiente no preflight (ex: containers parados ->
# abort, todo gate 2 falharia queimando ciclos de correcao) e acrescenta notas
# ao prompt. Contrato em scripts/lib/profile.sh.
#
# Variaveis de ambiente:
#   RALPH_TEST_CMD           comando de teste (gate 2); --test-cmd tem prioridade
#   RALPH_VERIFY             gate 3: always (default) | auto | off
#   RALPH_VERIFY_MODEL       modelo das sessoes auxiliares (gate 3)
#                            (default: haiku no claude, gpt-5.6-luna no codex)
#   RALPH_VERIFY_EFFORT      esforco dessas sessoes (default: low no codex; no
#                            claude fica com o default do modelo)
#   RALPH_MAX_CYCLES         ciclos de correcao por fase (default: 3)
#   RALPH_SESSION_TIMEOUT    segundos que uma sessao de engine pode durar antes
#                            de o ralph encerra-la (default: 3600; 0 desliga).
#                            Sessao encerrada = gate 0 vermelho, com a causa
#   RALPH_MAX_LIMIT_WAITS    esperas consecutivas por limite, por fase (default: 20)
#   RALPH_LIMIT_WAIT_DEFAULT fallback de espera em segundos (default: 1800)
#   RALPH_LIMIT_BUFFER       segundos extras apos o reset (default: 60)
#   RALPH_SMOKE              0 desliga o smoke test da engine (default: 1)
#   RALPH_MEMORY             0 desliga a pagina por fase no ai-memory (default: 1;
#                            sem o binario ou com o servidor fora do ar, desliga
#                            sozinha com aviso no preflight)
#   RALPH_MEMORY_BIN         binario do ai-memory (default: ai-memory no PATH)
#   RALPH_HOOK_ISOLATION     0 deixa os hooks do ai-memory rodarem nas sessoes do
#                            ralph (default: 1 — isola quando os detecta na config
#                            de usuario do claude ou do codex)
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
#   RALPH_PHASE_ATTEMPT      ciclo corrente (1 = implementacao inicial; 0 = gates
#                            contra HEAD antes da sessao, fase check-only ou ja
#                            commitada)
#   RALPH_SESSION_MODE       impl | verify — o log-tokens grava fase, ciclo e
#                            modo em cada linha do tokens.jsonl
#   RALPH_PHASE_MAX_ATTEMPTS igual a RALPH_MAX_CYCLES
#   RALPH_TEST_CMD           o comando do gate 2 (vazio quando desabilitado): o
#                            subagent test-runner roda o mesmo que o gate
#
# Exit code: 0 = todas as fases verdes; 1 = alguma falhou ou abortou.
#
# Pre-requisitos:
#   - Codex: npm install -g @openai/codex + OPENAI_API_KEY
#   - Claude: npm install -g @anthropic-ai/claude-code + ANTHROPIC_API_KEY
#   - Raiz de um repo git, com a arvore de trabalho limpa
#   - Opcional: ai-memory (pagina por fase) — github.com/akitaonrails/ai-memory

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
MEMORY_ENABLED="${RALPH_MEMORY:-1}"
MEMORY_BIN="${RALPH_MEMORY_BIN:-ai-memory}"
HOOK_ISOLATION="${RALPH_HOOK_ISOLATION:-1}"
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
    -h|--help)     sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
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
SESSION_TIMEOUT="${RALPH_SESSION_TIMEOUT:-3600}"
# 1 quando o watchdog encerrou a ultima sessao (run_logged). Lido pelo gate 0.
SESSION_TIMED_OUT=0

TEST_CMD=""
PROFILE=""
LIMIT_WAITS=0
# Flags de modelo/effort montadas uma vez: o smoke test e o loop usam as MESMAS,
# entao o que passa no smoke e literalmente o que roda em cada fase.
ENGINE_IMPL_ARGS=()
# Flags das sessoes auxiliares (gate 3): modelo barato, nunca o de
# implementacao. Sao leitura + checklist, nao valem opus/xhigh por fase.
ENGINE_VERIFY_ARGS=()
# Flags que tiram os hooks do ai-memory de TODA sessao do ralph (smoke, impl,
# gate 3). Montadas no preflight por resolve_hook_isolation.
ENGINE_ISOLATION_ARGS=()
# Settings filtrado do claude. Arquivo 0600 fora do repo, nao argv: o
# settings.json pode ter segredo no bloco env, e argv aparece no `ps`.
ISOLATION_SETTINGS_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] $1${NC}"; }
fail()    { echo -e "${RED}[$(date '+%H:%M:%S')] $1${NC}"; }

# Perfis de stack: o ralph pergunta ao perfil do projeto o comando de teste, o
# preflight do ambiente e as notas do prompt, em vez de conhecer cada stack.
# A lib mora ao lado deste script; uma copia avulsa dele (ex: RALPH_BIN nos
# testes) acha o plugin por MKTUX_HARNESS_ROOT, o mesmo do wrapper do PATH.
RALPH_LIB="$(cd "$(dirname "$0")" && pwd)/lib/profile.sh"
[ -f "$RALPH_LIB" ] || RALPH_LIB="${MKTUX_HARNESS_ROOT:-}/scripts/lib/profile.sh"
if [ ! -f "$RALPH_LIB" ]; then
  fail "Nao achei scripts/lib/profile.sh ao lado do ralph.sh."
  fail "Rodando uma copia avulsa do ralph.sh? Aponte MKTUX_HARNESS_ROOT para a raiz do plugin."
  exit 1
fi
# shellcheck disable=SC1090
. "$RALPH_LIB"
# shellcheck disable=SC1091
. "$(dirname "$RALPH_LIB")/phase-context.sh"

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

# .phases/ e o estado do run; .harness/ e a telemetria que os hooks do plugin
# gravam a cada tool call. Fora do git os dois: .harness/ visivel faz toda sessao
# "escrever" (o gate 1 perde o sinal e o ciclo travado nunca e detectado) e entra
# no commit de toda fase. --git-path resolve o exclude certo tambem em worktree.
exclude_run_dirs() {
  local exclude_file entry
  exclude_file="$(git rev-parse --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude_file")"
  for entry in /.phases/ /.harness/; do
    if ! grep -qxF "$entry" "$exclude_file" 2>/dev/null; then
      echo "$entry" >> "$exclude_file"
      log "Registrado $entry em .git/info/exclude (nao mexe no .gitignore do projeto)"
    fi
  done

  # Exclude nao vale para arquivo ja versionado.
  if [ -n "$(git ls-files -- .harness | head -n 1)" ]; then
    fail ".harness/ esta versionado neste repo. A telemetria dos hooks muda a cada tool"
    fail "call: entraria no commit de toda fase e o gate 1 veria escrita em toda sessao."
    fail "Tire do git antes de rodar:"
    fail "    git rm -r --cached .harness && git commit -m 'chore: untrack .harness'"
    exit 1
  fi
}

# O perfil do diretorio atual. Nao sobe: o ralph roda na raiz do projeto, e os
# caminhos que o perfil devolve (ex: wrapper do container) sao relativos a ela.
resolve_profile() {
  PROFILE="$(mktux_profile_at "$PWD" || true)"
  [ -n "$PROFILE" ] || return 0
  mktux_load_profile "$PROFILE"
  log "Perfil de stack: $PROFILE"
}

# Gate 2 so tem valor se rodar de verdade: o perfil checa, antes da 1a sessao,
# que o ambiente roda o comando (ex: containers de pe).
check_test_env() {
  [ -n "$PROFILE" ] || return 0
  profile_preflight "$TEST_CMD"
}

resolve_test_cmd() {
  resolve_profile

  if [ -n "$TEST_CMD_FLAG" ]; then
    TEST_CMD="$TEST_CMD_FLAG"
    log "Gate 2 — comando de teste (--test-cmd): $TEST_CMD"
    check_test_env
    return 0
  fi

  if [ -n "${RALPH_TEST_CMD:-}" ]; then
    TEST_CMD="$RALPH_TEST_CMD"
    log "Gate 2 — comando de teste (RALPH_TEST_CMD): $TEST_CMD"
    check_test_env
    return 0
  fi

  # O perfil vem ANTES da deteccao por manifest: num projeto cujos testes rodam
  # em container o host nao tem runtime nem banco, e o comando do manifest
  # mentiria como gate.
  if [ -n "$PROFILE" ]; then
    TEST_CMD="$(profile_test_cmd)"
  fi
  if [ -z "$TEST_CMD" ]; then
    TEST_CMD="$(mktux_generic_test_cmd)"
  fi

  if [ -n "$TEST_CMD" ]; then
    log "Gate 2 — comando de teste (detectado): $TEST_CMD"
    check_test_env
  else
    warn "Gate 2 DESABILITADO: nenhum comando de teste resolvido."
    if [ "$VERIFY_MODE" = "off" ]; then
      warn "--no-verify tambem desligou o gate 3: NENHUMA validacao mecanica ativa."
    else
      warn "Passe --test-cmd '<cmd>' ou defina RALPH_TEST_CMD. O gate 3 (verificador) roda em toda fase."
    fi
  fi
}

# Tira os hooks do ai-memory das sessoes do ralph. O SessionStart deles faz um
# GET destrutivo em /handoff e injeta o resultado como contexto: sem isto a fase
# 1 consome o handoff que o humano deixou, cada sessao recebe o "onde parou" da
# anterior (quebra a sessao fria e contamina o juiz do gate 3 — o
# --strict-mcp-config nao ajuda, hook nao e MCP) e o fim do run deixa como
# handoff a sessao do verificador. O registro do run vai por save_memory.
#
# Os hooks ficam na config de USUARIO e o ai-memory nao tem variavel de ambiente
# que os desligue, entao a engine recebe a config sem eles:
#   claude: --setting-sources project,local + --settings com o settings.json do
#           usuario MENOS os hooks do ai-memory. Sem o --settings a sessao perde
#           model, effortLevel, plugins e os demais hooks do usuario.
#   codex:  -c hooks.state={"<hooks.json>:<evento>:<grupo>:<handler>"={enabled=false}}
#           so para os handlers do ai-memory. O -c faz merge em hooks.state: a
#           confianca gravada dos outros hooks (inclusive os do mktux) continua.
resolve_hook_isolation() {
  ENGINE_ISOLATION_ARGS=()
  [ "$HOOK_ISOLATION" = "0" ] && return 0

  local hooks_file
  if [[ "$ENGINE" == "claude" ]]; then
    hooks_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  else
    hooks_file="${CODEX_HOME:-$HOME/.codex}/hooks.json"
  fi
  grep -qs 'ai-memory' "$hooks_file" || return 0

  if ! command -v jq &> /dev/null; then
    fail "Hooks do ai-memory em $hooks_file, mas sem jq nao da para isola-los das sessoes."
    fail "Instale o jq, ou rode com RALPH_HOOK_ISOLATION=0 (a fase 1 consome seus handoffs)."
    exit 1
  fi

  local out rc=0
  if [[ "$ENGINE" == "claude" ]]; then
    # O nome pode estar fora dos hooks (statusLine, env...): so isola se algum
    # handler de hook e do ai-memory.
    out=$(jq -r '[(.hooks // {})[][] | .hooks[]? | .command // "" | select(contains("ai-memory"))]
      | length' "$hooks_file") || rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" != "0" ]; then
      out=$(jq -c '.hooks |= (with_entries(.value |= (
          map(.hooks |= map(select((.command // "") | contains("ai-memory") | not)))
          | map(select(.hooks | length > 0))))
        | with_entries(select(.value | length > 0)))' "$hooks_file") || rc=$?
    else
      out=""
    fi
  else
    out=$(jq -r --arg src "$hooks_file" '
      [ (.hooks // {}) | to_entries[] | .key as $ev
        | ($ev | gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase) as $event
        | .value | to_entries[] | .key as $group
        | .value.hooks // [] | to_entries[]
        | select((.value.command // "") | contains("ai-memory"))
        | "\"\($src):\($event):\($group):\(.key)\"={enabled=false}" ]
      | if length == 0 then "" else "hooks.state={" + join(",") + "}" end' "$hooks_file") || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    fail "Nao consegui ler $hooks_file para isolar os hooks do ai-memory."
    fail "Corrija o arquivo, ou rode com RALPH_HOOK_ISOLATION=0."
    exit 1
  fi
  # O nome aparece no arquivo, mas em nenhum handler de hook: nada a isolar.
  [ -n "$out" ] || return 0

  if [[ "$ENGINE" == "claude" ]]; then
    ISOLATION_SETTINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/ralph-settings.XXXXXX")
    trap 'cleanup_run' EXIT
    printf '%s\n' "$out" > "$ISOLATION_SETTINGS_FILE"
    ENGINE_ISOLATION_ARGS=(--setting-sources project,local --settings "$ISOLATION_SETTINGS_FILE")
  else
    ENGINE_ISOLATION_ARGS=(-c "$out")
  fi
  log "Hooks do ai-memory isolados das sessoes do ralph ($hooks_file)"
}

cleanup_run() {
  [ -z "$ISOLATION_SETTINGS_FILE" ] || rm -f "$ISOLATION_SETTINGS_FILE"
}

# Memoria nativa do codex (features.memories): com ela ligada na config do
# usuario, cada sessao do ralph le o historico de sessoes anteriores — num run
# real, as fases e o verificador faziam grep num MEMORY.md de 60 KB com o
# resumo das fases passadas. Quebra a sessao fria pelo mesmo motivo do handoff
# do ai-memory, e as sessoes do ralph ainda poluem a memoria do uso interativo.
# Vai junto das flags de isolamento: smoke, impl e gate 3 recebem.
resolve_engine_memory() {
  [[ "$ENGINE" == "codex" ]] || return 0
  ENGINE_ISOLATION_ARGS+=(-c features.memories=false)
}

# Pagina da wiki por fase: ralph/<feature>/phase-NN.md. A feature e a pasta do
# input (docs/features/<slug>/project-phases.md -> <slug>).
memory_feature_slug() {
  local slug
  slug=$(basename "$(cd "$(dirname "$INPUT_FILE")" && pwd)" | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//')
  printf '%s\n' "${slug:-projeto}"
}

# Decide UMA vez se o run grava memoria. Sem o binario e silencioso (quem nao usa
# ai-memory nao precisa de aviso a cada run); binario presente com o servidor
# fora do ar e aviso alto — cada fase falharia a gravacao em silencio.
resolve_memory() {
  if [ -n "${RALPH_MEM0:-}${RALPH_MEM0_USER:-}" ]; then
    warn "RALPH_MEM0/RALPH_MEM0_USER foram removidas: a memoria agora e o ai-memory (RALPH_MEMORY)."
  fi

  [ "$MEMORY_ENABLED" = "1" ] || return 0

  if ! command -v "$MEMORY_BIN" &> /dev/null; then
    log "ai-memory nao encontrado — pagina por fase desligada (fora do PATH? defina RALPH_MEMORY_BIN)"
    MEMORY_ENABLED=0
    return 0
  fi
  if ! "$MEMORY_BIN" status < /dev/null > /dev/null 2>&1; then
    warn "Servidor do ai-memory fora do ar ('$MEMORY_BIN status' falhou) — pagina por fase desligada neste run."
    MEMORY_ENABLED=0
    return 0
  fi
  log "Memoria por fase: ai-memory, paginas ralph/$(memory_feature_slug)/phase-NN.md"
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
      ${ENGINE_ISOLATION_ARGS[@]+"${ENGINE_ISOLATION_ARGS[@]}"} \
      --color never --sandbox read-only - 2>&1) || rc=$?
  else
    out=$(env -u CLAUDECODE claude ${ENGINE_IMPL_ARGS[@]+"${ENGINE_IMPL_ARGS[@]}"} \
      ${ENGINE_ISOLATION_ARGS[@]+"${ENGINE_ISOLATION_ARGS[@]}"} \
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

  if ! [[ "$SESSION_TIMEOUT" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para RALPH_SESSION_TIMEOUT: '$SESSION_TIMEOUT'. Use segundos (0 desliga)."
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
  exclude_run_dirs

  # Arvore limpa: 'git add -A' da primeira fase engoliria trabalho nao commitado.
  if [ -n "$(git status --porcelain)" ]; then
    fail "Arvore de trabalho suja. ralph commita por fase e engoliria suas mudancas."
    fail "Commite ou stashe antes de rodar:"
    git status --short | sed 's/^/    /'
    exit 1
  fi

  resolve_test_cmd
  resolve_hook_isolation
  resolve_engine_memory
  resolve_memory

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
      # (manual) nasce pendente de quem conduz: nenhum gate vai julga-la.
      case "$line" in "(manual)"*) TSK_STATUS[$TSK_N]="manual" ;; esac
      TSK_TEXT[$TSK_N]="$(printf '%s' "${line:0:200}" | tr '\t' ' ')"
    done < <(phase_task_lines "$file" | sed 's/\*\*//g')
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
# Pendencia manual ((manual) ou NOT-CODE) nao vira "done" com o commit: o
# codigo fechou, o procedimento continua por fazer.
state_tasks_all() {
  local seq="$1" status="$2" i
  [ "$TSK_N" -gt 0 ] || return 0
  for ((i = 1; i <= TSK_N; i++)); do
    if [ "${TSK_SEQ[$i]}" = "$seq" ]; then
      if [ "$status" = "done" ] && [ "${TSK_STATUS[$i]}" = "manual" ]; then
        continue
      fi
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
  # Append, com cabecalho: um run retomado 3 vezes deixava so a ultima invocacao
  # no run.log, e a evidencia das anteriores sumia. Rotaciona em 5 MB.
  if [ -f "$RUN_LOG" ] && [ "$(wc -c < "$RUN_LOG")" -gt 5242880 ]; then
    mv -f "$RUN_LOG" "$RUN_LOG.1"
  fi
  printf '\n===== ralph %s — %s =====\n' "$(date '+%d/%m/%Y %H:%M:%S')" "$INPUT_FILE" >> "$RUN_LOG"

  # fd 9/10 guardam o terminal: o relatorio final volta para a tela depois que
  # o painel morre.
  exec 9>&1 10>&2
  exec >> "$RUN_LOG" 2>&1

  bash "$watch" --embedded "$PWD" < /dev/tty > /dev/tty 2>&1 &
  DASHBOARD_PID=$!

  trap 'stop_dashboard; cleanup_run' EXIT
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
  local phase_file="$1"

  cat <<'PREAMBLE'
## Descubra a stack e as convencoes antes de escrever codigo
Este projeto pode ser de qualquer linguagem ou framework. NAO assuma nenhuma
stack. Antes de comecar, LEIA:
1. AGENTS.md ou CLAUDE.md — convencoes, comandos e regras do projeto
2. o contexto desta fase, recortado abaixo pelo ralph, se houver
Use os comandos de build, teste e execucao definidos por esses documentos e pelo
tooling ja presente no repositorio.

Esta sessao e fria de proposito: nao consulte memoria de sessoes anteriores
(ferramentas ou servidores de memoria, memorias da engine). O estado do projeto
e o codigo, o git e os documentos acima.
PREAMBLE

  # Os documentos de contexto vivem ao lado do plano de fases (ex:
  # docs/features/<slug>/{feature-description,user-stories,database-schema}.md).
  # Listar os que EXISTEM de verdade, derivados do input, em vez de caminhos
  # fixos: um caminho hardcoded que nao existe faz TODA sessao — implementacao e
  # cada ciclo de correcao — queimar tool calls procurando arquivo fantasma.
  #
  # "Leia antes de escrever codigo" fazia a sessao ler todos, inteiros, e o
  # arquivo de fases junto: ~19k tokens no contexto de cada turno, em 25 de 26
  # sessoes de um run real. Agora o ralph recorta o que a fase cita, e os
  # caminhos ficam para consulta pontual. O feature-brief e o rascunho humano
  # que o feature-description substitui: entra no recorte quando citado, fora da
  # lista de consulta.
  local doc_dir sibling extract docs=""
  doc_dir="$(dirname "$INPUT_FILE")"
  for sibling in "$doc_dir"/*.md; do
    [ -f "$sibling" ] || continue
    case "$(basename "$sibling")" in
      "$(basename "$INPUT_FILE")"|feature-brief.md) continue ;;
    esac
    docs="${docs}  - ${sibling}"$'\n'
  done

  extract=$(phase_context "$PHASES_DIR/$phase_file" "$doc_dir" "$INPUT_FILE")
  if [ -n "$extract" ]; then
    echo
    echo "## Contexto desta fase"
    echo "O ralph recortou dos documentos do plano o que esta fase cita — secoes,"
    echo "regras, tabelas, stories. Parta daqui."
    printf '%s\n' "$extract"
  fi

  if [ -n "$docs" ]; then
    echo
    echo "## Documentos do plano (consulta pontual)"
    echo "Nao leia inteiros, e nao abra o arquivo de fases: a fase abaixo e toda a sua"
    echo "tarefa. Precisou de algo que nao esta no contexto acima? Busque pelo id ou"
    echo "pelo titulo (ex: rg -n 'US-2.3' <arquivo>) e leia so aquele trecho."
    printf '%s' "$docs"
  fi

  # O gate 2 roda ESTE comando. Se o agente rodar outro (ex: o runner no host em
  # vez de dentro do container), ele ve verde e o gate ve vermelho.
  #
  # Suite completa so no fim. "Rode a suite SEMPRE com <cmd>" fazia o agente
  # rodar o comando inteiro a cada item: num run real, 20 suites completas de
  # ~2 min numa unica sessao, e nenhuma execucao filtrada em fase nenhuma. O
  # runner e o mesmo; o que muda e o recorte.
  if [ -n "$TEST_CMD" ]; then
    echo
    echo "## Comando de teste deste projeto"
    echo "A fase e validada pelo ralph, depois da sessao, com:"
    echo
    echo "    $TEST_CMD"
    echo
    echo "- Durante o trabalho, rode so os testes afetados, pelo MESMO runner (filtro"
    echo "  por nome ou caminho de arquivo). Suite completa a cada item custa minutos"
    echo "  e nao prova nada a mais."
    echo "- Ao terminar, rode o comando acima UMA vez. Nao troque de runner: fora dele"
    echo "  voce pode ver verde onde a validacao ve vermelho."
    # Stdin fechado: nao ha humano na sessao. Na fase 9 de pub-email-alerts um
    # teste pediu confirmacao, o runner via container anexou o TTY da sessao, e
    # a sessao esperou a resposta por 2h.
    echo "- Rode testes e comandos do projeto com stdin fechado (\`<comando> < /dev/null\`)"
    echo "  e nunca em modo interativo ou watch: nao ha ninguem para responder um prompt."
    if [ "$SESSION_TIMEOUT" -gt 0 ]; then
      echo "  A sessao que passar de $(format_duration "$SESSION_TIMEOUT") e encerrada pelo ralph."
    fi
    if [ -n "$PROFILE" ]; then
      profile_prompt_notes
    fi
  fi
}

# Saida para plano errado. A sessao que achava a task errada nao tinha como
# dizer. Na fase 9 de pub-email-alerts ela confirmou no config do CSS que o
# token pedido nao existia e usou o certo; o verificador, que le so a fase,
# reprovou; o ciclo de correcao obedeceu e a borda saiu branca. Na fase 4 o
# mesmo caminho tirou um filtro correto. Na fase 3 a sessao explicou o impasse
# em prosa, que o ralph nao le. A linha RALPH-CONTEST e lida da mensagem final
# (session_contests) e para a fase quando um gate reprova o que ela contestou.
contest_instructions() {
  local phase_file="$1"
  cat <<'CONTEST'

## Quando a fase manda algo errado
A fase foi escrita antes do codigo e pode errar. Se cumprir uma task como esta
escrita exige algo que voce CONFIRMOU ser errado — cita classe, metodo, rota,
token ou arquivo que nao existe; contradiz uma regra (BR) ou story (US); obriga
a quebrar um teste de codigo que esta fase proibe tocar — nao obedeca e nao
desvie em silencio. Faca o resto da fase e termine a resposta com uma linha por
task contestada:

RALPH-CONTEST: TASK <n> — <o que esta errado, com a evidencia (arquivo:linha)>

Se um gate reprovar uma task contestada, o ralph para a fase para uma pessoa
decidir; se tudo passar, a contestacao vai para o relatorio do run. Contestar
nao e saida para task dificil ou trabalhosa: sem evidencia no codigo, cumpra a
task.
CONTEST
  echo
  echo "Numeracao das tasks desta fase (a mesma do verificador):"
  phase_task_lines "$phase_file" | awk '{ t = $0; gsub(/\*\*/, "", t); if (length(t) > 120) t = substr(t, 1, 120) "..."; print NR ". " t }'
}

build_impl_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior implementando uma fase deste projeto."
    echo
    context_preamble "$phase_file"
    cat <<'TASK'

## Sua tarefa agora
Implemente COMPLETAMENTE a fase descrita abaixo.

Para cada item:
1. Implemente o codigo completo (nao deixe TODOs ou placeholders)
2. Crie os testes listados, seguindo o framework de testes do projeto: um caso
   de teste por cenario listado, com nome que descreva o cenario
3. Rode SO os testes desse item (teste focado, pelo runner do projeto)
4. Se um teste falhar, corrija o codigo e rode novamente
5. So passe pro proximo item quando esses testes passarem

Com todos os itens prontos, rode a suite completa UMA vez e corrija o que
quebrar.

## Regras obrigatorias
- Use SEMPRE os comandos, o runner de testes e as ferramentas ja adotados pelo
  projeto (nao introduza uma stack ou ferramenta nova por conta propria)
- Testes e fixtures/factories devem criar todas as dependencias necessarias
- Nomes de classes, arquivos e metodos devem seguir EXATAMENTE o que esta descrito
- Nao pule nenhum item marcado com [ ]
- Item "(manual)" e procedimento de quem conduz o PR e nenhum gate o verifica.
  Rode-o se for um comando deste repositorio que voce consegue rodar aqui; se
  exige uma pessoa ou um aparelho, siga em frente
TASK
    contest_instructions "$phase_file"
    echo
    echo "## Fase a implementar"
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
    context_preamble "$phase_file"
    cat <<'INTRO'

## Situacao
Uma sessao anterior tentou implementar a fase abaixo e NAO passou na verificacao.
Voce esta numa sessao nova: nao tem memoria do que foi feito. Leia o codigo atual
antes de mudar qualquer coisa.

## Regras obrigatorias
- Corrija APENAS o que falta. Nao reimplemente o que ja esta correto e testado.
- Nao deixe TODOs, placeholders ou testes pulados.
- Durante a correcao, rode so os testes afetados. Ao final, rode a suite
  completa UMA vez e garanta que ela passa.
- Motivo do gate 3 vem de um verificador que le so a fase, nao os documentos
  do plano: se o que ele pede e justamente o erro, conteste em vez de obedecer.
INTRO
    contest_instructions "$phase_file"
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

# Primeira linha de cada task da fase (`- [ ]` / `- [x]`, em qualquer nivel de
# indentacao), na ordem. O mesmo padrao do gate 3 e do painel: a posicao aqui e
# o <n> do veredito.
phase_task_lines() {
  sed -n 's/^[[:space:]]*- \[[ x]\][[:space:]]*//p' "$PHASES_DIR/$1"
}

# Task `- [ ] (manual) ...`: procedimento de quem conduz o PR (formatador, build,
# aparelho real). Tipada no plano, fica fora do gate 3 por construcao: nenhum
# veredito pedido, nenhum aceito. Deixar o verificador classificar NOT-CODE
# sozinho fazia o destino da fase depender dele acertar toda vez — e com o codigo
# byte-identico ele ja trocou NOT-CODE por INCOMPLETE ("aguardando a suite").
# Mantem a posicao na fase: o <n> do veredito, do painel e do prompt de correcao
# continua o mesmo, so com lacunas.
# Negrito fora antes de casar, como no painel: `**(manual)**` tambem vale.
phase_judged_positions() {
  phase_task_lines "$1" | sed 's/\*\*//g' | awk '!/^\(manual\)/ { print NR }'
}

phase_manual_positions() {
  phase_task_lines "$1" | sed 's/\*\*//g' | awk '/^\(manual\)/ { print NR }'
}

# Arquivos que a fase mexeu ate aqui: a arvore contra HEAD, que e o commit da
# fase anterior. Vazio quando a fase ja estava implementada.
phase_changed_files() {
  git status --porcelain --untracked-files=all 2> /dev/null | cut -c4-
}

build_verify_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.verify-${cycle}.txt"
  local tasks n n_all judged changed n_changed

  # O ralph numera as tasks. Contando sozinho, lendo o markdown, o verificador
  # errava: num run real emitiu TASK 9 numa fase de 8, e o ralph reprovou uma
  # fase completa, com a suite verde, por indice fora da faixa.
  tasks=$(phase_task_lines "$phase_file")
  n_all=$(printf '%s\n' "$tasks" | grep -c . || true)
  judged=$(phase_judged_positions "$phase_file")
  n=$(printf '%s\n' "$judged" | grep -c . || true)
  changed=$(phase_changed_files)
  n_changed=$(printf '%s\n' "$changed" | grep -c . || true)

  {
    cat <<'VERIFY'
RALPH_VERIFY

Voce e um verificador independente. NAO escreva, edite ou crie nenhum arquivo.
Seu unico trabalho e ler o codigo real e dizer o que esta feito e o que nao esta.
VERIFY
    echo
    echo "## Tasks a julgar"
    if [ "$n" -eq "$n_all" ]; then
      echo "O ralph numerou as $n tasks da fase abaixo, na ordem em que aparecem. Use"
      echo "EXATAMENTE estes numeros, de 1 a $n: um veredito por numero, nem mais nem menos."
    else
      echo "O ralph numerou as tasks da fase abaixo, na ordem em que aparecem, e tirou"
      echo "desta lista as marcadas (manual): sao procedimento de quem conduz o PR, sem"
      echo "veredito. Julgue EXATAMENTE estes $n numeros: $(printf '%s\n' "$judged" | paste -sd, - | sed 's/,/, /g')."
      echo "Um veredito por numero, nem mais nem menos."
    fi
    echo
    printf '%s\n' "$tasks" | awk '{ l = $0; gsub(/\*\*/, "", l) } l ~ /^\(manual\)/ { next } { t = $0; if (length(t) > 300) t = substr(t, 1, 300) "..."; print NR ". " t }'
    cat <<'VERIFY'

Para cada uma, confira os acceptance criteria (na fase completa, abaixo) contra
o codigo real — arquivos, classes, testes, rotas, migrations, o que a task
exigir — e emita EXATAMENTE UMA linha:

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

Task de teste com cenarios listados (sub-bullets "situacao → resultado"): a
lista e fechada. DONE quando cada cenario listado tem um caso de teste que monta
aquela situacao e verifica aquele resultado. Nao exija cenario, classe ou camada
que a lista nao pede. INCOMPLETE cita o cenario que falta pelo texto do bullet.
VERIFY
    # Sem lista fechada o verificador monta a dele a cada ciclo: num run real, a
    # mesma task de teste reprovou no ciclo 1 por tres gates e, com eles
    # cobertos, no ciclo 2 por um teste "direto" de outra classe que o plano
    # nunca pediu. Citar o bullet da a correcao um alvo que nao se move.
    cat <<'VERIFY'

## Onde olhar
VERIFY
    # Sem ponto de partida o verificador explora o repo inteiro: num run real,
    # 1,3M tokens de input por sessao, cada arquivo lido duas vezes, tipos de
    # dependencia de terceiros e um typecheck — mais do que a implementacao.
    if [ "$n_changed" -gt 0 ]; then
      echo "Arquivos alterados nesta fase (ponto de partida, nao limite):"
      printf '%s\n' "$changed" | head -n 80 | sed 's/^/  /'
      if [ "$n_changed" -gt 80 ]; then
        echo "  ... e mais $((n_changed - 80))"
      fi
    else
      echo "Nenhum arquivo alterado nesta fase: o codigo pode ja estar em HEAD. Procure"
      echo "pelos caminhos e nomes que as tasks citam."
    fi
    cat <<'VERIFY'

- Comece pelos arquivos acima. Abra outro so quando a task o citar ou o codigo o
  importar.
- Leia cada arquivo uma vez.
- NAO rode build, testes, typecheck nem lint: outro gate ja cuida disso.
- NAO leia codigo de dependencias de terceiros (node_modules, vendor, .venv) nem
  lockfiles.

## Regras
- Uma linha TASK para cada numero da lista acima, sem excecao, sem agrupar.
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

# Encerra um processo e todos os descendentes. Coleta os filhos ANTES de matar o
# pai: depois, orfaos sao adotados pelo init e `pgrep -P` nao os acha mais.
kill_tree() {
  local pid="$1" kid kids
  kids=$(pgrep -P "$pid" 2> /dev/null || true)
  kill -TERM "$pid" 2> /dev/null || true
  for kid in $kids; do
    kill_tree "$kid"
  done
}

# Roda o comando da engine mandando TUDO para o log. O codex streama raciocinio,
# patches e tool calls no stdout; espelhar isso na tela enterra as linhas do
# proprio ralph (fases, gates, causa de falha). Com --verbose / RALPH_VERBOSE=1
# o comportamento antigo volta.
#
# run_logged <log_file> <stdin_file> <cmd...>
#
# A engine roda em background sob um watchdog: passou de RALPH_SESSION_TIMEOUT,
# o ralph encerra a arvore inteira e devolve 124. Na fase 9 de pub-email-alerts
# um teste pediu confirmacao a um TTY que nunca respondeu, e a sessao ficou 2h
# "aguardando o codigo de saida" ate alguem matar na mao.
#
# O stdin vai explicito: comando assincrono sem redirecionamento proprio le de
# /dev/null, e o codex perderia o prompt.
#
# Comando assincrono tambem ignora SIGINT. Sem o trap, Ctrl-C matava o ralph e
# deixava a engine escrevendo na arvore. O trap encerra a arvore e devolve o
# codigo do sinal, que o run_engine ja trata como interrupcao.
run_logged() {
  local log_file="$1" stdin_file="$2"
  shift 2

  local flag="${log_file%.log}.timeout"
  rm -f "$flag"
  SESSION_TIMED_OUT=0

  if [ "$VERBOSE" -eq 1 ]; then
    ( "$@" < "$stdin_file" 2>&1 | tee "$log_file" ) &
  else
    "$@" < "$stdin_file" > "$log_file" 2>&1 &
  fi
  local pid=$! rc=0 signal=0 watchdog=""

  if [ "$SESSION_TIMEOUT" -gt 0 ]; then
    (
      elapsed=0
      while kill -0 "$pid" 2> /dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$SESSION_TIMEOUT" ]; then
          touch "$flag"
          kill_tree "$pid"
          break
        fi
      done
    ) &
    watchdog=$!
  fi

  local saved_int saved_term
  saved_int=$(trap -p INT)
  saved_term=$(trap -p TERM)
  trap 'signal=130' INT
  trap 'signal=143' TERM

  wait "$pid" || rc=$?
  if [ "$signal" -ne 0 ]; then
    kill_tree "$pid"
    wait "$pid" 2> /dev/null || true
    rc=$signal
  fi
  # Com a flag gravada o watchdog esta no meio do kill_tree: espera, nunca mata.
  # Mata-lo ali o interrompia depois do pai e antes dos filhos, e o comando que
  # travou a sessao ficava orfao. Sem flag, mata: esperar o `sleep 1` dele
  # custava ate 1s por sessao.
  if [ -n "$watchdog" ]; then
    [ -f "$flag" ] || kill "$watchdog" 2> /dev/null || true
    wait "$watchdog" 2> /dev/null || true
  fi

  if [ -n "$saved_int" ]; then eval "$saved_int"; else trap - INT; fi
  if [ -n "$saved_term" ]; then eval "$saved_term"; else trap - TERM; fi

  if [ "$signal" -eq 0 ] && [ -f "$flag" ]; then
    rm -f "$flag"
    SESSION_TIMED_OUT=1
    echo "[ralph] sessao encerrada: passou de RALPH_SESSION_TIMEOUT (${SESSION_TIMEOUT}s)" >> "$log_file"
    return 124
  fi
  rm -f "$flag"
  return "$rc"
}

# run_engine <prompt_file> <log_file> <mode: impl|verify>
# Loop de resiliencia a limite de uso: nao consome ciclo de correcao.
run_engine() {
  local prompt_file="$1" log_file="$2" mode="$3"

  export RALPH_ENGINE="$ENGINE"
  export RALPH_PHASE_MAX_ATTEMPTS="$MAX_CYCLES"
  export RALPH_SESSION_MODE="$mode"
  # O subagent test-runner resolve o comando por mktux-profile.sh, que le isto
  # primeiro: dentro de um run ele roda exatamente o comando do gate 2.
  export RALPH_TEST_CMD="$TEST_CMD"

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
        # -o: so a mensagem final, sem o transcript nem o bloco que o `codex
        # exec` reimprime depois do resumo de tokens. O gate 3 le dali.
        run_logged "$log_file" "$prompt_file" codex exec --color never --sandbox read-only \
          ${ENGINE_ISOLATION_ARGS[@]+"${ENGINE_ISOLATION_ARGS[@]}"} \
          ${model_args[@]+"${model_args[@]}"} \
          -o "$(last_message_file "$log_file")" - || rc=$?
      else
        # -o tambem aqui: a mensagem final carrega as contestacoes da sessao e
        # e o que o relatorio de falha mostra.
        rm -f "$(last_message_file "$log_file")"
        run_logged "$log_file" "$prompt_file" codex exec --color never --sandbox danger-full-access \
          ${ENGINE_ISOLATION_ARGS[@]+"${ENGINE_ISOLATION_ARGS[@]}"} \
          ${ENGINE_IMPL_ARGS[@]+"${ENGINE_IMPL_ARGS[@]}"} \
          -o "$(last_message_file "$log_file")" - || rc=$?
      fi
    else
      # stdin /dev/null: claude -p le stdin quando nao e TTY. Sem o redirect ele
      # consome o stream de quem chamou (ex: o manifest do loop de fases).
      if [[ "$mode" == "verify" ]]; then
        # --disallowedTools, nao --allowedTools: sob --dangerously-skip-permissions
        # a allowlist nao restringe nada (tudo ja esta auto-aprovado), e o
        # "verificador read-only" conseguia escrever. Se ele consertasse a task
        # que ia reprovar, o veredito viria DONE e o `git add -A` commitaria
        # codigo que o gate 2 — que roda ANTES do gate 3 — nunca testou.
        # --strict-mcp-config: le codigo com Read/Glob/Grep, nao precisa de
        # nenhum MCP server; carregar os schemas custa ~4k tokens por fase.
        # --tools: so essas tres existem na sessao (nem Agent, que abriria um
        # subagent com escrita); o deny fica como segunda trava.
        # --disable-slash-commands: sem a listagem de skills no contexto.
        run_logged "$log_file" /dev/null env -u CLAUDECODE claude --dangerously-skip-permissions \
          --strict-mcp-config --disable-slash-commands \
          --tools "Read,Glob,Grep" \
          ${ENGINE_ISOLATION_ARGS[@]+"${ENGINE_ISOLATION_ARGS[@]}"} \
          ${model_args[@]+"${model_args[@]}"} \
          -p "$(cat "$prompt_file")" \
          --disallowedTools "Write,Edit,NotebookEdit,Bash" \
          --output-format text || rc=$?
      else
        # JSON: o exit code do CLI e sinal fraco; o gate 0 le is_error.
        run_logged "$log_file" /dev/null env -u CLAUDECODE claude --dangerously-skip-permissions \
          ${ENGINE_ISOLATION_ARGS[@]+"${ENGINE_ISOLATION_ARGS[@]}"} \
          ${ENGINE_IMPL_ARGS[@]+"${ENGINE_IMPL_ARGS[@]}"} \
          -p "$(cat "$prompt_file")" \
          --output-format json || rc=$?
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
        fail "    commite como 'feat(phase-${RALPH_PHASE_NUM:-N}): ${RALPH_PHASE_TITLE:-<titulo>}' (o ralph revalida a fase contra HEAD, sem sessao)"
        fail "    ou 'git checkout -- . && git clean -fd' (descarta)"
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

session_timeout_cause() {
  printf '%s' "A sessao passou de RALPH_SESSION_TIMEOUT ($(format_duration "$SESSION_TIMEOUT")) e o ralph a encerrou. Causa mais comum: um comando esperando input que nunca chega (prompt de confirmacao, modo watch, servidor em primeiro plano). Rode testes e comandos do projeto com stdin fechado (< /dev/null) e nunca em modo interativo."
}

gate0_engine_finished() {
  local log_file="$1" rc="$2"

  # Antes do JSON do claude: a sessao morta pelo watchdog nunca emite resultado,
  # e "terminou sem emitir um resultado" esconderia o motivo.
  if [ "$SESSION_TIMED_OUT" -eq 1 ]; then
    GATE_CAUSE="$(session_timeout_cause) Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
    state_gate 0 fail
    return 1
  fi

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
  # < /dev/null: teste via container (docker compose exec) anexa stdin e
  # consumiria o stream de quem chamou, alem de poder travar esperando input.
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

# Onde o codex grava a mensagem final da sessao (-o), impl ou verificador. Ao
# lado do log.
last_message_file() {
  printf '%s\n' "${1%.log}.last.txt"
}

# Mensagem final da sessao: o -o do codex, o .result do JSON do claude. Vazio
# quando a engine nao deixou nenhuma (crash, timeout, claude sem jq).
session_final_message() {
  local log_file="$1" last
  last=$(last_message_file "$log_file")
  if [ -s "$last" ]; then
    cat "$last"
  elif [[ "$ENGINE" == "claude" ]] && command -v jq > /dev/null 2>&1; then
    jq -r 'select(.type == "result") | .result // empty' "$log_file" 2> /dev/null || true
  fi
}

# Linhas RALPH-CONTEST da sessao. Sem mensagem final, le o log: o exemplo do
# prompt (`TASK <n>`) nao casa com `TASK [0-9]+`. No JSON do claude (sem jq) a
# linha termina no primeiro \n escapado ou na aspa que fecha a string.
session_contests() {
  local log_file="$1" msg
  msg=$(session_final_message "$log_file")
  {
    if [ -n "$msg" ]; then
      printf '%s\n' "$msg" | grep -oE 'RALPH-CONTEST: TASK [0-9]+.*'
    elif [[ "$ENGINE" == "claude" ]]; then
      grep -oE 'RALPH-CONTEST: TASK [0-9]+[^"]*' "$log_file" 2> /dev/null | sed -E 's/\\n.*//; s/\\$//'
    else
      grep -oE 'RALPH-CONTEST: TASK [0-9]+.*' "$log_file" 2> /dev/null
    fi
  } | awk '!seen[$0]++' | head -n 20 || true
}

# A contestacao para a fase quando o gate reprova o que foi contestado. Gate 3:
# alguma task contestada voltou INCOMPLETE. Gate 2 vermelho nao se atribui a uma
# task: com contestacao na mesa, para tambem — foi o caso da fase 3 de
# pub-email-alerts, que so ficava verde tocando um arquivo proibido.
contest_blocks() {
  local contests="$1" nums n
  [ -n "$contests" ] || return 1
  case "$LAST_GATE" in
    "gate 2"*) return 0 ;;
    "gate 3"*)
      nums=$(printf '%s\n' "$contests" | sed -nE 's/^RALPH-CONTEST: TASK ([0-9]+).*/\1/p')
      for n in $nums; do
        printf '%s\n' "$GATE_CAUSE" | grep -qE "^TASK $n: INCOMPLETE" && return 0
      done
      ;;
  esac
  return 1
}

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

  local total expected judged manual n_manual=0
  total=$(grep -cE '^[[:space:]]*- \[[ x]\]' "$PHASES_DIR/$phase_file" || true)
  judged=$(phase_judged_positions "$phase_file")
  expected=$(printf '%s\n' "$judged" | grep -c . || true)
  manual=$(phase_manual_positions "$phase_file")
  [ -n "$manual" ] && n_manual=$(printf '%s\n' "$manual" | grep -c .)

  if [ "$total" -eq 0 ]; then
    warn "Gate 3 pulado: a fase nao declara nenhuma task '- [ ]'"
    state_gate 3 skip
    return 0
  fi

  if [ "$expected" -eq 0 ]; then
    warn "Gate 3 pulado: toda task da fase ($total) e (manual) — nada no codigo a julgar"
    state_gate 3 skip
    return 0
  fi

  GATE3_RAN=1
  log "Gate 3 — sessao verificadora independente ($expected tasks${VERIFY_MODEL:+, modelo: $VERIFY_MODEL}${VERIFY_EFFORT:+, effort: $VERIFY_EFFORT})"
  state_gate 3 run

  local prompt_file verdict_src last_msg
  prompt_file=$(build_verify_prompt "$phase_file" "$cycle")
  # Logs sobrevivem ao re-run com o mesmo nome: a mensagem final de um run
  # anterior nao pode passar pelo veredito deste.
  last_msg=$(last_message_file "$verify_log")
  rm -f "$last_msg"
  run_engine "$prompt_file" "$verify_log" verify || true

  # A mensagem final quando a engine a grava (codex -o); o log inteiro senao.
  verdict_src="$verify_log"
  [ -s "$last_msg" ] && verdict_src="$last_msg"

  local task_lines
  task_lines=$(sed 's/^[[:space:]]*//' "$verdict_src" | grep -E '^TASK [0-9]+: (DONE|INCOMPLETE|NOT-CODE)' || true)

  if [ -z "$task_lines" ]; then
    GATE_CAUSE=""
    [ "$SESSION_TIMED_OUT" -eq 1 ] && GATE_CAUSE="$(session_timeout_cause)"$'\n'
    GATE_CAUSE="${GATE_CAUSE}O verificador independente nao emitiu nenhuma linha 'TASK <n>: DONE|INCOMPLETE|NOT-CODE' — nao foi possivel confirmar que a fase esta completa. Ultimas linhas do verificador:"$'\n'"$(engine_tail "$verify_log" 40)"
    state_gate 3 fail
    return 1
  fi

  # Consolida por NUMERO da task, nao por linha. Sem o -o (codex antigo, ou
  # engine que falhou antes de gravar) o veredito sai do log, onde o `codex
  # exec` reimprime a ultima mensagem depois do resumo de tokens: o bloco TASK
  # aparece duas vezes, e contar linhas cruas reprovaria toda fase por
  # "cobertura incompleta". INCOMPLETE em qualquer emissao vence DONE — na
  # duvida, incompleto, igual a instrucao dada ao verificador.
  local verdicts
  verdicts=$(printf '%s\n' "$task_lines" | awk '{
      n = $2; sub(":", "", n);
      v = ($0 ~ /INCOMPLETE/) ? "INCOMPLETE" : ($0 ~ /NOT-CODE/) ? "NOT-CODE" : "DONE";
      if (!(n in seen) || v == "INCOMPLETE") { seen[n] = v }
    }
    END { for (n in seen) { print n": "seen[n] } }' | sort -n)

  # Veredito para task (manual) nao foi pedido: descarta, nunca reprova. Mesmo
  # listada fora, o verificador ve a fase inteira e as vezes julga assim mesmo.
  if [ -n "$manual" ]; then
    verdicts=$(printf '%s\n' "$verdicts" | awk -v man=" $(printf '%s ' $manual)" '{
        n = $1; sub(":", "", n);
        if (index(man, " " (n + 0) " ") == 0) { print }
      }')
  fi

  local parsed
  parsed=$(printf '%s\n' "$verdicts" | grep -c . || true)

  # Task fora da lista pedida e emissao malformada: o verificador inventou indice.
  local out_of_range
  out_of_range=$(printf '%s\n' "$verdicts" | awk -v ok=" $(printf '%s ' $judged)" '{
      n = $1; sub(":", "", n);
      if (n != "" && index(ok, " " (n + 0) " ") == 0) { print }
    }')

  if [ -n "$out_of_range" ]; then
    local asked="1..$total"
    [ "$n_manual" -gt 0 ] && asked=$(printf '%s\n' "$judged" | paste -sd, - | sed 's/,/, /g')
    GATE_CAUSE="O verificador emitiu indices de task fora da lista pedida ($asked):"$'\n'"$out_of_range"$'\n'"Linhas originais:"$'\n'"$task_lines"
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

  local manual_note=""
  [ "$n_manual" -gt 0 ] && manual_note=" (+$n_manual manual, fora do gate)"

  if [ -n "$not_code" ]; then
    success "Gate 3 — $((parsed - n_not_code))/$expected tasks confirmadas no codigo$manual_note"
    warn "Gate 3 — $n_not_code task(s) fora do codigo, pendentes de quem conduz:"
    local task_num
    while read -r task_num; do
      [ -n "$task_num" ] || continue
      printf '%s\n' "$task_lines" | grep -m1 -E "^TASK $task_num: NOT-CODE" | sed 's/^/    /' || true
    done <<< "$not_code"
  else
    success "Gate 3 — $parsed/$expected tasks confirmadas no codigo$manual_note"
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

# Fase so de verificacao: `**Check-only phase**` numa linha sozinha. E a fase de
# fechamento que so afirma estado ("nenhuma migration a mais", "o sw.js nao cita
# storage"): o codigo ja esta em HEAD e nao ha o que escrever. O ralph roda os
# gates 2 e 3 contra HEAD antes de abrir sessao; so abre se reprovar. Na fase 8
# de pub-icon-and-logo a sessao nao escreveu nada e custou 2,4M tokens de input,
# subagents inclusive, para chegar no mesmo veredito.
#
# Declarado, nao inferido, pelo mesmo motivo da fase operacional. Diferente
# dela, o gate 3 mantem o poder de reprovar: a fase so pula a sessao.
phase_is_check_only() {
  grep -qE '^[[:space:]]*\*\*Check-only phase\*\*' "$PHASES_DIR/$1" 2>/dev/null
}

# Fase ja commitada neste branch com a mensagem que o ralph usa. Acontece quando
# o run e retomado depois de uma fase fechada fora dele — alguem commitou a mao o
# trabalho de uma fase que travou —, ou quando o plano mudou e zerou o
# .progress. Na fase 3 de pub-email-alerts o commit manual estava la e o ralph
# abriu uma sessao inteira para ela nao escrever nada. Os gates contra HEAD
# decidem: a mensagem do commit so escolhe o caminho, nunca aprova.
# Sem -q: com pipefail, o grep que sai no primeiro match mata o git log com
# SIGPIPE e o pipeline "falha" justamente quando achou.
phase_committed() {
  git log -n 500 --format=%s 2> /dev/null | grep -xF "feat(phase-$1): $2" > /dev/null
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

# Grava a fase como pagina da wiki do projeto no ai-memory, FORA do run agentico
# e sem LLM: `ai-memory write-page` e um POST deterministico, sem sessao extra
# nem tool call que o agente pode esquecer de fazer. A pagina e upsert por
# caminho (ralph/<feature>/phase-NN.md): re-rodar com --from atualiza, nao
# duplica. Vale para as duas engines — as sessoes rodam isoladas dos hooks do
# ai-memory (resolve_hook_isolation), entao esta pagina e o registro do run.
#
# Chamada DEPOIS do commit: o SHA e o `git show --stat` sao da fase fechada.
save_memory() {
  local phase_file="$1" phase_num="$2" phase_title="$3" cycles="$4" duration="$5"

  [ "$MEMORY_ENABLED" = "1" ] || return 0

  local feature page mem_log
  feature=$(memory_feature_slug)
  page="ralph/$feature/$phase_file"
  mem_log="$LOG_DIR/${phase_file%.md}.memory.log"

  local body
  body="# $feature — Phase $phase_num: $phase_title

- Feature: \`$feature\` (plano: \`$INPUT_FILE\`)
- Commit: \`$(git rev-parse --short HEAD)\` em \`$(git rev-parse --abbrev-ref HEAD)\`
- Engine: $ENGINE (model: ${MODEL:-default}, effort: ${EFFORT:-default})
- Ciclos: $cycles de $MAX_CYCLES, $(format_duration "$duration")
- Registrado pelo ralph em $(date '+%Y-%m-%d %H:%M')

## Arquivos alterados

\`\`\`
$(git show --stat --format= HEAD | tail -n 41)
\`\`\`

## Plano da fase

$(cat "$PHASES_DIR/$phase_file")"

  if printf '%s\n' "$body" | "$MEMORY_BIN" write-page --path "$page" --tier episodic \
       --tag ralph --tag "$feature" --body - > "$mem_log" 2>&1; then
    success "Memoria gravada no ai-memory: $page"
  else
    warn "Falha ao gravar no ai-memory (log: $mem_log) — fase segue valida"
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

# Contestacoes de fases que fecharam verdes: a sessao desviou da task e os gates
# aceitaram. Saem no relatorio final para alguem conferir antes do PR.
CONTEST_NOTES=()

record_contests() {
  local phase_num="$1" contests="$2" line
  [ -n "$contests" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] && CONTEST_NOTES+=("Phase $phase_num: ${line#RALPH-CONTEST: }")
  done <<< "$contests"
}

# Logs de uma execucao anterior desta fase saem do caminho antes dela reabrir.
# Os nomes se repetem entre runs e entre features (phase-03.cycle-2.log), entao
# o ciclo 3 de uma feature de semana passada aparecia ao lado do ciclo 1 de hoje
# e parecia parte do run. Vao para logs/archive/<inicio deste run>/; ficam os 10
# arquivos mais recentes.
LOG_ARCHIVE_KEEP=10

archive_phase_logs() {
  local phase_file="$1" dest old
  compgen -G "$LOG_DIR/${phase_file%.md}.*" > /dev/null || return 0
  dest="$LOG_DIR/archive/$RUN_STAMP"
  mkdir -p "$dest"
  mv -f "$LOG_DIR/${phase_file%.md}."* "$dest"/
  ls -1d "$LOG_DIR/archive"/*/ 2> /dev/null | sort -r | tail -n +$((LOG_ARCHIVE_KEEP + 1)) \
    | while IFS= read -r old; do rm -rf "$old"; done
  log "Logs anteriores de ${phase_file%.md} arquivados em $dest/"
}

# run_phase <phase_file> <phase_num> <phase_title> <seq> <total>
run_phase() {
  local phase_file="$1" phase_num="$2" phase_title="$3" seq="$4" total="$5"
  local phase_start contests="" phase_contests="" contested="" log_file=""
  phase_start=$(date +%s)

  export RALPH_PHASE_TITLE="$phase_title"
  export RALPH_PHASE_NUM="$phase_num"
  export RALPH_PHASE_TOTAL="$total"
  # 0 ate o loop de ciclos: a verificacao contra HEAD antes da sessao e o
  # ciclo 0 (test-0, verify-0), e o valor da fase anterior nao pode vazar.
  export RALPH_PHASE_ATTEMPT=0

  LIMIT_WAITS=0
  GATE_CAUSE=""
  gate3_memo_reset
  CUR_SEQ="$seq"
  state_phase "$seq" running

  echo ""
  log "[$seq/$total] Phase $phase_num: $phase_title"
  archive_phase_logs "$phase_file"

  # Fase so de verificacao, ou ja commitada neste branch: gates 2 e 3 contra
  # HEAD, sem sessao. Verde fecha a fase como "ja implementada"; vermelho abre o
  # ciclo 1 ja como correcao, com a causa. Sem gate 3 (--no-verify) nao ha quem
  # confirme as afirmacoes: segue o fluxo normal. Logs deste passo levam o
  # numero 0 (test-0, verify-0).
  local precheck_failed=0 precheck_what=""
  if [ "$VERIFY_MODE" != "off" ]; then
    if phase_is_check_only "$phase_file"; then
      precheck_what="Fase so de verificacao"
      log "Fase so de verificacao (**Check-only phase**) — gates contra HEAD, sem sessao"
    elif phase_committed "$phase_num" "$phase_title"; then
      precheck_what="Fase ja commitada neste branch"
      log "Fase ja commitada neste branch (feat(phase-$phase_num)) — gates contra HEAD, sem sessao"
    fi
  fi
  if [ -n "$precheck_what" ]; then
    state_cycle "$seq" 1
    state_gate 0 skip
    state_gate 1 skip
    if ! gate2_tests_pass "$LOG_DIR/${phase_file%.md}.test-0.log"; then
      LAST_GATE="gate 2 — suite de testes do projeto"
      precheck_failed=1
    elif ! gate3_independent_verify "$phase_file" 0 0; then
      LAST_GATE="gate 3 — verificacao independente"
      precheck_failed=1
    elif [ -z "$(git status --porcelain)" ]; then
      success "Phase $phase_num: $phase_title — VERIFICADA sem sessao ($(format_duration $(($(date +%s) - phase_start))))"
      log "Gates 2 e 3 verdes contra o codigo em HEAD; nenhum commit criado."
      mark_phase_done "$phase_file"
      state_tasks_all "$seq" done
      state_phase "$seq" done
      return 0
    fi
    if [ "$precheck_failed" -eq 1 ]; then
      fail "$precheck_what reprovou contra HEAD ($LAST_GATE) — abrindo sessao de correcao"
      GATE_CAUSE="$precheck_what: o ralph rodou os gates contra o codigo em HEAD, sem sessao de implementacao, e eles reprovaram. Corrija o que falta."$'\n'"$GATE_CAUSE"
    fi
  fi

  local cycle=1 cycles_run=0
  while [ "$cycle" -le "$MAX_CYCLES" ]; do
    cycles_run="$cycle"
    export RALPH_PHASE_ATTEMPT="$cycle"
    [ "$cycle" -gt 1 ] && warn "Ciclo de correcao $cycle/$MAX_CYCLES..."
    state_cycle "$seq" "$cycle"

    local prompt_file rc=0 sig_before
    log_file="$LOG_DIR/${phase_file%.md}.cycle-${cycle}.log"

    if [ "$cycle" -eq 1 ] && [ "$precheck_failed" -eq 0 ]; then
      prompt_file=$(build_impl_prompt "$phase_file" "$cycle")
    else
      prompt_file=$(build_fix_prompt "$phase_file" "$cycle" "$LAST_GATE" "$GATE_CAUSE")
    fi

    sig_before=$(tree_signature)
    run_engine "$prompt_file" "$log_file" impl || rc=$?

    GATE_CAUSE=""
    contests=$(session_contests "$log_file")
    if [ -n "$contests" ]; then
      warn "A sessao contestou a fase:"
      printf '%s\n' "$contests" | sed 's/^/    /'
      phase_contests=$(printf '%s\n%s\n' "$phase_contests" "$contests" | awk 'NF && !seen[$0]++')
    fi

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
        record_contests "$phase_num" "$phase_contests"
        state_tasks_all "$seq" done
        state_phase "$seq" done
        return 0
      fi

      success "Phase $phase_num: $phase_title — COMPLETA ($(format_duration "$phase_duration"))"

      if ! commit_phase "$phase_num" "$phase_title"; then
        LAST_GATE="commit"
        state_phase "$seq" failed
        return 1
      fi
      save_memory "$phase_file" "$phase_num" "$phase_title" "$cycles_run" "$phase_duration"
      mark_phase_done "$phase_file"
      record_contests "$phase_num" "$phase_contests"
      state_tasks_all "$seq" done
      state_phase "$seq" done
      return 0
    fi

    # Gate vermelho sobre o que a sessao contestou: outro ciclo so obedeceria o
    # verificador (ou repetiria o impasse). Quem decide e uma pessoa.
    if contest_blocks "$contests"; then
      contested="$contests"
      break
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
  if [ -n "$contested" ]; then
    fail "Phase $phase_num: $phase_title — PARADA no ciclo $cycles_run: a sessao contestou a fase e o gate reprovou ($(format_duration "$phase_duration"))"
    fail "Contestacao da sessao:"
    printf '%s\n' "$contested" | sed 's/^/    /'
    fail "Veredito ($LAST_GATE):"
    printf '%s\n' "$GATE_CAUSE" | head -n 20 | sed 's/^/    /'
    warn "Decida antes de re-rodar. A sessao tem razao: corrija a fase (e os docs do plano)"
    warn "e rode com --from $phase_num. A task esta certa: deixe isso explicito nela, com o porque."
  else
    fail "Phase $phase_num: $phase_title — FALHOU apos $cycles_run ciclo(s) ($(format_duration "$phase_duration"))"
    fail "Ultima causa ($LAST_GATE):"
    printf '%s\n' "$GATE_CAUSE" | head -n 20 | sed 's/^/    /'
    # A sessao costuma saber por que travou — na fase 3 de pub-email-alerts ela
    # disse que o comando que quebrava era proibido nesta fase — e so o log
    # guardava isso.
    local final_msg=""
    [ -n "$log_file" ] && final_msg=$(session_final_message "$log_file")
    if [ -n "$final_msg" ]; then
      fail "Ultima mensagem da sessao (fim):"
      printf '%s\n' "$final_msg" | grep -v '^[[:space:]]*$' | tail -n 12 | sed 's/^/    /'
    fi
  fi
  fail "Logs em: $LOG_DIR/${phase_file%.md}.*"

  # O trabalho parcial fica na arvore; o preflight da proxima execucao exige
  # arvore limpa. Diga o que fazer em vez de deixar o dev descobrir no abort.
  if [ -n "$(git status --porcelain)" ]; then
    warn "O trabalho parcial desta fase ficou na arvore. Antes de re-rodar o ralph:"
    warn "    commite como 'feat(phase-$phase_num): $phase_title' (o ralph revalida a fase contra HEAD, sem sessao)"
    warn "    ou 'git checkout -- . && git clean -fd' (descarta)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

LAST_GATE=""
RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"

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

  # fd 3, nunca stdin: comandos do corpo (claude -p, teste via docker compose
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

  # Checklist de quem abre o PR: tasks (manual) do plano e vereditos NOT-CODE,
  # so das fases concluidas. Sem isto elas ficavam espalhadas no log por fase.
  local i pending=()
  for ((i = 1; i <= TSK_N; i++)); do
    [ "${TSK_STATUS[$i]}" = "manual" ] || continue
    [ "${PH_STATUS[${TSK_SEQ[$i]}]}" = "done" ] || continue
    pending+=("Phase ${PH_NUM[${TSK_SEQ[$i]}]}: ${TSK_TEXT[$i]#(manual) }")
  done
  if [ ${#pending[@]} -gt 0 ]; then
    echo ""
    warn "Pendencias manuais (${#pending[@]}) — de quem conduz, antes do PR:"
    for phase in "${pending[@]}"; do printf '    %s\n' "$phase"; done
  fi

  if [ ${#CONTEST_NOTES[@]} -gt 0 ]; then
    echo ""
    warn "Contestacoes que passaram nos gates (${#CONTEST_NOTES[@]}) — a sessao desviou da task; confira antes do PR:"
    for phase in "${CONTEST_NOTES[@]}"; do printf '    %s\n' "$phase"; done
  fi

  echo ""
  log "Inicio: $(fmt_ts "$start_time")"
  log "Fim:    $(fmt_ts "$end_time")"
  log "Duracao total: $(format_duration "$total_duration")"
  echo ""

  [ ${#failed_phases[@]} -eq 0 ] || exit 1
}

main
