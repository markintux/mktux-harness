#!/usr/bin/env bash
#
# test-layout.sh — checa o layout do plugin: todo caminho que um manifest, um
# perfil ou uma skill cita existe; os hooks, pelo dispatcher de perfil, ainda se
# comportam; o mktux-profile.sh responde o que os agents perguntam; e o core nao
# cita nome de stack fora de profiles/ e do registro de perfis.
#
# A test-ralph.sh cobre o ralph.sh; nada cobria hooks nem skills. Um hook movido
# sem atualizar o hooks.json some calado (o engine so loga o erro), e um
# references/*.md citado que nao existe faz a skill seguir sem as convencoes.
#
# Uso: scripts/test-layout.sh   (exit 0 = tudo verde)

set -uo pipefail

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()     { PASS=$((PASS + 1)); echo -e "  ${GREEN}ok${NC}   $1"; }
bad()    { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1"; }
header() { echo -e "\n${YELLOW}== $1${NC}"; }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then ok "$msg"; else bad "$msg (esperado '$expected', veio '$actual')"; fi
}

assert_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" "$haystack_file"; then ok "$msg"; else bad "$msg (nao achou '$needle')"; fi
}

# ---------------------------------------------------------------------------
# 1. Todo script citado nos manifests de hook existe
# ---------------------------------------------------------------------------
header "1. caminhos dos manifests de hook"
for manifest in "$PLUGIN/hooks/hooks.json" "$PLUGIN/hooks/codex-hooks.json"; do
  name="${manifest#"$PLUGIN/"}"
  paths=$(grep -oE '\$\{(CLAUDE_)?PLUGIN_ROOT\}/[^"\\]+' "$manifest" | sed -E 's#^\$\{(CLAUDE_)?PLUGIN_ROOT\}/##' | sort -u)
  if [ -z "$paths" ]; then
    bad "$name: nenhum caminho de script encontrado"
    continue
  fi
  while IFS= read -r p; do
    if [ -f "$PLUGIN/$p" ]; then ok "$name -> $p"; else bad "$name -> $p (nao existe)"; fi
  done <<< "$paths"
done

# Eventos do contrato (scripts/lib/profile.sh). Um evento com erro de digitacao
# no manifest nunca casa com o perfil e o hook some calado.
EVENTS="pre-bash claude-post-edit codex-stop"
for manifest in "$PLUGIN/hooks/hooks.json" "$PLUGIN/hooks/codex-hooks.json"; do
  name="${manifest#"$PLUGIN/"}"
  events=$(grep -oE 'profile-hook\.sh\\" [A-Za-z0-9_-]+' "$manifest" | awk '{print $2}')
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    if [[ " $EVENTS " == *" $e "* ]]; then ok "$name: evento $e"; else bad "$name: evento desconhecido '$e' (contrato: $EVENTS)"; fi
  done <<< "$events"
done

# O dispatcher so acha o script de um evento pelo profile_hook do perfil.
for profile_sh in "$PLUGIN"/profiles/*/profile.sh; do
  pname=$(basename "$(dirname "$profile_sh")")
  for event in $EVENTS; do
    rel=$( . "$profile_sh" && profile_hook "$event" )
    [ -z "$rel" ] && continue
    if [ -f "$PLUGIN/profiles/$pname/$rel" ]; then ok "perfil $pname: $event -> $rel"; else bad "perfil $pname: $event -> $rel (nao existe)"; fi
  done
done

# ---------------------------------------------------------------------------
# 2. Todo references/*.md citado numa skill existe ao lado dela
# ---------------------------------------------------------------------------
header "2. references citadas pelas skills"
# A referencia mora ao lado da skill que a cita. Unica excecao: o roteador
# `plan` cita o template do brief "ao lado daquela skill" (plan-feature-brief).
ref_owner() { if [ "$1" = plan ]; then echo plan-feature-brief; else echo "$1"; fi; }

for skill in "$PLUGIN"/skills/*/SKILL.md; do
  name=$(basename "$(dirname "$skill")")
  refs=$(grep -oE 'references/[A-Za-z0-9._-]+\.md' "$skill" | sort -u)
  [ -z "$refs" ] && continue
  owner=$(ref_owner "$name")
  while IFS= read -r r; do
    if [ -f "$PLUGIN/skills/$owner/$r" ]; then
      ok "$name -> $owner/$r"
    else
      bad "$name -> $owner/$r (nao existe)"
    fi
  done <<< "$refs"
done

# Agents (so Claude) leem arquivos do plugin por ${CLAUDE_PLUGIN_ROOT}. Caminho
# com variavel ($p = perfil) e resolvido em runtime; o fixo tem que existir.
for agent in "$PLUGIN"/agents/*.md; do
  aname=$(basename "$agent" .md)
  paths=$(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/$-]+' "$agent" | sed 's#^\${CLAUDE_PLUGIN_ROOT}/##' | grep -v '\$' | sort -u)
  [ -z "$paths" ] && continue
  while IFS= read -r p; do
    if [ -f "$PLUGIN/$p" ]; then ok "agent $aname -> $p"; else bad "agent $aname -> $p (nao existe)"; fi
  done <<< "$paths"
done

# ---------------------------------------------------------------------------
# 3. Nenhuma referencia aos caminhos antigos dos hooks Laravel
# ---------------------------------------------------------------------------
header "3. sem caminho antigo de hook Laravel"
# O caminho novo (profiles/laravel/hooks/...) contem o antigo como sufixo: so
# conta como antigo o `hooks/` que nao vem logo depois de `laravel/`. O
# profile.sh cita os scripts relativos ao proprio perfil — esse e o caminho novo.
old='(shared/sail-guard|claude/pint-and-test|codex/pint-and-test)'
stale=$(grep -rnE "(^|[^l])/hooks/$old|(^|[^/])hooks/$old" "$PLUGIN" \
          --exclude="$(basename "$0")" --exclude=profile.sh || true)
if [ -z "$stale" ]; then
  ok "nenhum caminho antigo"
else
  bad "caminho antigo ainda citado:"
  printf '%s\n' "$stale" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# 4. Hooks pelo dispatcher de perfil (o caminho real: hooks.json -> dispatcher)
# ---------------------------------------------------------------------------
header "4. hooks pelo dispatcher de perfil"
DISPATCH="$PLUGIN/hooks/shared/profile-hook.sh"
if ! command -v jq > /dev/null 2>&1; then
  echo "  (sem jq: smoke dos hooks pulado — os hooks dependem dele)"
else
  # Laravel com Sail, Laravel sem Sail de pe, projeto sem perfil, e Laravel numa
  # subpasta de monorepo.
  sail_proj="$TMP/sail-proj"
  mkdir -p "$sail_proj/vendor/bin" && touch "$sail_proj/artisan" "$sail_proj/vendor/bin/sail"
  laravel_proj="$TMP/laravel-proj"
  mkdir -p "$laravel_proj" && touch "$laravel_proj/artisan" && git -C "$laravel_proj" init -q
  plain_proj="$TMP/plain-proj"
  mkdir -p "$plain_proj" && git -C "$plain_proj" init -q
  mono="$TMP/mono"
  mkdir -p "$mono/backend/vendor/bin" "$mono/backend/app" && touch "$mono/backend/artisan" "$mono/backend/vendor/bin/sail"

  guard_in() { jq -nc --arg cwd "$1" --arg cmd "$2" '{cwd: $cwd, tool_input: {command: $cmd}}'; }
  pre_bash() { # pre_bash <cwd> <cmd> -> exit code; stderr em $TMP/guard.err
    local rc=0
    guard_in "$1" "$2" | bash "$DISPATCH" pre-bash 2> "$TMP/guard.err" > /dev/null || rc=$?
    echo "$rc"
  }

  # pre-bash -> sail-guard
  assert_eq 2 "$(pre_bash "$sail_proj" "php artisan migrate")" "pre-bash: php artisan no host de projeto Sail -> bloqueia"
  assert_contains "$TMP/guard.err" "./vendor/bin/sail artisan migrate" "pre-bash: sugere a forma via Sail"
  assert_eq 0 "$(pre_bash "$sail_proj" "./vendor/bin/sail artisan migrate")" "pre-bash: comando ja via Sail -> passa"
  assert_eq 0 "$(pre_bash "$plain_proj" "php artisan migrate")" "pre-bash: projeto sem perfil -> passa"
  assert_eq 2 "$(pre_bash "$mono/backend/app" "php artisan migrate")" "pre-bash: Laravel em subpasta de monorepo -> bloqueia"
  assert_eq 0 "$(pre_bash "$mono" "php artisan migrate")" "pre-bash: raiz do monorepo, fora do Laravel -> passa"

  # claude-post-edit -> pint-and-test (Claude): fora de .php ou sem Sail de pe, nunca bloqueia
  edit_in() { jq -nc --arg f "$1" '{tool_input: {file_path: $f}}'; }
  post_edit() { # post_edit <projeto> <arquivo> -> exit code
    local rc=0
    edit_in "$1/$2" | CLAUDE_PROJECT_DIR="$1" bash "$DISPATCH" claude-post-edit > /dev/null 2>&1 || rc=$?
    echo "$rc"
  }
  assert_eq 0 "$(post_edit "$laravel_proj" src/app.ts)" "claude-post-edit: arquivo nao-PHP -> passa"
  assert_eq 0 "$(post_edit "$laravel_proj" app/Foo.php)" "claude-post-edit: PHP sem Sail de pe -> passa"
  assert_eq 0 "$(post_edit "$plain_proj" app/Foo.php)" "claude-post-edit: projeto sem perfil -> passa"

  # codex-stop -> pint-and-test (Codex): o Codex le JSON do stdout do Stop
  codex_stop() { # codex_stop <projeto> -> stdout (exit code em $TMP/stop.rc)
    local rc=0 out
    out=$(cd "$1" && echo '{"stop_hook_active": false}' | env -u CLAUDE_PROJECT_DIR bash "$DISPATCH" codex-stop 2> /dev/null) || rc=$?
    echo "$rc" > "$TMP/stop.rc"
    printf '%s' "$out"
  }
  assert_eq '{"continue": true}' "$(codex_stop "$laravel_proj")" "codex-stop: Laravel sem Sail de pe -> continue, sem block"
  assert_eq 0 "$(cat "$TMP/stop.rc")" "codex-stop: exit 0"
  assert_eq "" "$(codex_stop "$plain_proj")" "codex-stop: projeto sem perfil -> sem saida"
  assert_eq 0 "$(cat "$TMP/stop.rc")" "codex-stop sem perfil: exit 0"
fi

# ---------------------------------------------------------------------------
# 5. mktux-profile.sh: o que os agents perguntam sobre o projeto
# ---------------------------------------------------------------------------
header "5. mktux-profile.sh"
MP="$PLUGIN/scripts/mktux-profile.sh"
fx="$TMP/fx"
mkdir -p "$fx/sail/vendor/bin" "$fx/sail/app/Http" "$fx/comp" "$fx/bare" "$fx/node" "$fx/node-check" "$fx/none" \
         "$fx/node-version/node_modules" "$fx/node-nested" "$fx/node-pytool" \
         "$fx/mono repo/backend/vendor/bin" "$fx/mono repo/backend/app"
touch "$fx/sail/artisan" "$fx/comp/artisan" "$fx/bare/artisan" "$fx/mono repo/backend/artisan"
printf '#!/bin/sh\n' > "$fx/sail/vendor/bin/sail"
chmod +x "$fx/sail/vendor/bin/sail"
cp "$fx/sail/vendor/bin/sail" "$fx/mono repo/backend/vendor/bin/sail"
printf '{ "scripts": { "test": "phpunit" } }\n' > "$fx/comp/composer.json"
printf '{ "scripts": { "test": "vitest" } }\n' > "$fx/node/package.json"
printf '{ "scripts": { "check": "tsc && vitest" }, "devDependencies": { "vitest": "1" } }\n' > "$fx/node-check/package.json"
printf '{ "scripts": { "test": "vitest" }, "devDependencies": { "check": "1" } }\n' > "$fx/node-nested/package.json"
printf '{ "scripts": { "test": "vitest" } }\n' > "$fx/node-pytool/package.json"
printf '[tool.ruff]\nline-length = 100\n' > "$fx/node-pytool/pyproject.toml"
touch "$fx/node-check/package-lock.json"
cp "$fx/node-check/package.json" "$fx/node-version/package.json"
printf '24.21.0\n' > "$fx/node-version/.node-version"
# Python: pytest.ini, ou pyproject.toml com [tool.pytest...]. pyproject sem
# config de pytest nao basta (pode ser so empacotamento).
mkdir -p "$fx/py-ini" "$fx/py-proj" "$fx/py-pytestonly" "$fx/py-noconf" "$fx/py-uv" "$fx/py-poetry"
printf '[pytest]\ntestpaths = tests\n' > "$fx/py-ini/pytest.ini"
printf '[project]\nname = "x"\n\n[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$fx/py-proj/pyproject.toml"
printf '[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$fx/py-pytestonly/pyproject.toml"
printf '[project]\nname = "x"\n\n[tool.ruff]\nline-length = 100\n' > "$fx/py-noconf/pyproject.toml"
# Com lock do uv/poetry o pytest mora no virtualenv do projeto, nao no host.
cat > "$fx/py-uv/pyproject.toml" <<'EOF'
[project]
name = "x"

[project.optional-dependencies]
"dev" = [
  "pytest>=8",
]

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
touch "$fx/py-uv/uv.lock"
cp "$fx/py-ini/pytest.ini" "$fx/py-poetry/pytest.ini" && touch "$fx/py-poetry/poetry.lock"

mp() { env -u RALPH_TEST_CMD bash "$MP" --dir "$fx/$1" "${@:2}" 2> /dev/null; }

assert_eq "laravel" "$(mp sail name)" "name: artisan -> laravel"
assert_eq "vendor/bin/sail artisan test --compact" "$(mp sail test-cmd)" "test-cmd: Laravel com Sail"
assert_eq "composer test" "$(mp comp test-cmd)" "test-cmd: Laravel sem Sail, com composer test"
assert_eq "php artisan test" "$(mp bare test-cmd)" "test-cmd: Laravel sem Sail nem composer test"
assert_eq "node" "$(mp node name)" "name: package.json -> node"
assert_eq "npm test" "$(mp node test-cmd)" "test-cmd: Node com scripts.test"
assert_eq "npm run check" "$(mp node-check test-cmd)" "test-cmd: Node prefere o gate scripts.check"
assert_eq "npm test" "$(mp node-nested test-cmd)" "test-cmd: chave check fora de scripts nao engana o perfil"
assert_eq "node" "$(mp node-pytool name)" "name: pyproject apenas de ferramenta nao toma projeto Node"
assert_eq "pytest" "$(mp py-ini test-cmd)" "test-cmd: Python com pytest.ini -> pytest"
assert_eq "python" "$(mp py-proj name)" "name: pyproject.toml -> python"
assert_eq "pytest" "$(mp py-proj test-cmd)" "test-cmd: Python com [tool.pytest] no pyproject -> pytest"
assert_eq "python" "$(mp py-pytestonly name)" "name: pyproject apenas com config pytest -> python"
rc=0; mp py-noconf test-cmd > /dev/null || rc=$?
assert_eq 1 "$rc" "test-cmd: pyproject sem config de pytest -> nada resolvido"
assert_eq "uv run pytest" "$(mp py-uv test-cmd)" "test-cmd: Python com uv.lock -> uv run pytest"
assert_eq "poetry run pytest" "$(mp py-poetry test-cmd)" "test-cmd: Python com poetry.lock -> poetry run pytest"
rc=0; mp none test-cmd > /dev/null || rc=$?
assert_eq 1 "$rc" "test-cmd: nada resolvido -> exit 1"
assert_eq "cd $(printf '%q' "$fx/sail") && vendor/bin/sail artisan test --compact" "$(mp sail/app/Http test-cmd)" \
  "test-cmd: de uma subpasta, roda na raiz do perfil"
assert_eq "laravel" "$(mp "mono repo/backend/app" name)" "name: Laravel em subpasta de monorepo (com espaco)"
rc=0; mp "mono repo" name > /dev/null || rc=$?
assert_eq 1 "$rc" "name: raiz do monorepo nao herda o perfil da subpasta"
assert_eq "make t" "$(RALPH_TEST_CMD="make t" bash "$MP" --dir "$fx/sail" test-cmd)" "test-cmd: RALPH_TEST_CMD (sessao do ralph) vence"
assert_eq "$PLUGIN/profiles/laravel/hooks/shared/sail-guard.sh" "$(mp sail hook pre-bash)" "hook: evento -> script do perfil"
rc=0; mp sail hook evento-inexistente > /dev/null || rc=$?
assert_eq 1 "$rc" "hook: evento sem script -> exit 1"
mp sail notes test-runner > "$TMP/notes.out"
assert_contains "$TMP/notes.out" "Sail is not running" "notes: perfil com notas para o agent -> conteudo"
mp node notes test-runner > "$TMP/notes.out"
assert_contains "$TMP/notes.out" "separator" "notes: Node ensina passagem de argumentos do npm"
mp py-proj notes test-runner > "$TMP/notes.out"
assert_contains "$TMP/notes.out" "pytest syntax" "notes: Python ensina arquivo e filtro do pytest"

# Preflight nao prepara ambiente: para antes da 1a sessao e diz qual setup falta.
preflight() { # preflight <perfil> <projeto> <comando> -> exit code; stderr em $TMP/preflight.err
  local rc=0
  (
    cd "$2" || exit 1
    # shellcheck disable=SC1090
    . "$PLUGIN/profiles/$1/profile.sh"
    fail() { echo "$*" >&2; }
    profile_preflight "$3"
  ) 2> "$TMP/preflight.err" || rc=$?
  echo "$rc"
}

assert_eq 1 "$(preflight node "$fx/node-check" "npm run check")" "preflight Node: dependencias ausentes -> aborta"
assert_contains "$TMP/preflight.err" "npm ci" "preflight Node: lockfile -> sugere npm ci"
mkdir -p "$fx/node-check/node_modules"
assert_eq 0 "$(preflight node "$fx/node-check" "npm run check")" "preflight Node: dependencias presentes -> passa"

mkdir -p "$TMP/node-bin"
cat > "$TMP/node-bin/node" <<'EOF'
#!/bin/sh
echo "${NODE_FAKE_MAJOR:-22}"
EOF
chmod +x "$TMP/node-bin/node"
assert_eq 1 "$(PATH="$TMP/node-bin:/usr/bin:/bin" preflight node "$fx/node" "npm test")" \
  "preflight Node: npm ausente -> aborta"
assert_contains "$TMP/preflight.err" "npm nao esta no PATH" "preflight Node: explica npm ausente"
assert_eq 1 "$(PATH="$TMP/node-bin:$PATH" NODE_FAKE_MAJOR=22 preflight node "$fx/node-version" "npm run check")" \
  "preflight Node: major diferente do .node-version -> aborta"
assert_contains "$TMP/preflight.err" "pede Node 24" "preflight Node: informa o major exigido"
assert_eq 0 "$(PATH="$TMP/node-bin:$PATH" NODE_FAKE_MAJOR=24 preflight node "$fx/node-version" "npm run check")" \
  "preflight Node: major do projeto -> passa"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/uv" <<'EOF'
#!/bin/sh
[ "${UV_OK:-0}" = 1 ]
EOF
chmod +x "$TMP/bin/uv"
PATH="$TMP/bin:$PATH" assert_eq 1 "$(PATH="$TMP/bin:$PATH" preflight python "$fx/py-uv" "uv run pytest")" \
  "preflight Python: pytest fora do ambiente uv -> aborta"
assert_contains "$TMP/preflight.err" "uv sync --extra dev" "preflight Python: extra dev -> instrucao exata"
PATH="$TMP/bin:$PATH" UV_OK=1 assert_eq 0 "$(PATH="$TMP/bin:$PATH" UV_OK=1 preflight python "$fx/py-uv" "uv run pytest")" \
  "preflight Python: ambiente uv pronto -> passa"
assert_eq 0 "$(PATH="$TMP/bin:$PATH" preflight python "$fx/py-uv" "uv run unittest")" \
  "preflight Python: override sem pytest nao exige o extra dev"
assert_eq 1 "$(PATH="/usr/bin:/bin" preflight python "$fx/py-poetry" "poetry run pytest")" \
  "preflight Python: poetry ausente -> aborta"
assert_contains "$TMP/preflight.err" "poetry nao esta no PATH" "preflight Python: explica poetry ausente"

# ---------------------------------------------------------------------------
# 6. Core sem nome de stack
# ---------------------------------------------------------------------------
header "6. core sem nome de stack"
# Convencao de stack mora em profiles/<nome>/ e em skills/*/references/<nome>.md.
# Citada no core, vaza para projeto de outro stack (o Laravel vazava no plano
# de um projeto Node). Unica excecao: o registro de perfis, num .md, entre
# <!-- perfis --> e <!-- /perfis -->. `composer` fica de fora de proposito: e
# manifest, par de npm e cargo nas listas que cobrem varios stacks.
STACK_TERMS='laravel|artisan|sail|php[a-z]*|pint|pest|eloquent|blade|livewire|inertia|horizon'
CORE_SKIP=''

# core_stack_leaks <raiz do plugin> -> "arquivo:linha:texto" de cada nome de
# stack fora do bloco de perfis, e "arquivo: bloco ... sem fechamento" (bloco
# aberto liberaria o resto do arquivo).
core_stack_leaks() {
  local root="$1" f rel
  while IFS= read -r f; do
    rel="${f#"$root/"}"
    case " $CORE_SKIP " in *" $rel "*) continue ;; esac
    if [[ "$rel" =~ ^skills/[^/]+/references/([^/]+)\.md$ ]] && [ -d "$root/profiles/${BASH_REMATCH[1]}" ]; then
      continue
    fi
    if awk '/^<!-- perfis -->$/{f=1} /^<!-- \/perfis -->$/{f=0} END{exit !f}' "$f"; then
      echo "$rel: bloco <!-- perfis --> sem fechamento"
    fi
    awk '/^<!-- perfis -->$/{f=1} {print (f ? "" : $0)} /^<!-- \/perfis -->$/{f=0}' "$f" \
      | grep -nwiE "$STACK_TERMS" | awk -v f="$rel" '{print f ":" $0}'
  done < <(find "$root/skills" "$root/agents" "$root/hooks" "$root/scripts" \
             -type f ! -name '.*' ! -name 'test-*.sh' 2> /dev/null | LC_ALL=C sort)
}

leaks=$(core_stack_leaks "$PLUGIN")
if [ -z "$leaks" ]; then
  ok "nenhum nome de stack fora de profiles/, references de perfil e bloco de perfis"
else
  bad "nome de stack no core:"
  printf '%s\n' "$leaks" | sed 's/^/         /'
fi

# Todo reference citado num bloco de perfis leva o nome de um perfil existente:
# sem profiles/<nome>/ nao ha deteccao, e a linha do registro nunca casa.
while IFS= read -r skill; do
  name=$(basename "$(dirname "$skill")")
  refs=$(awk '/^<!-- perfis -->$/{f=1} f{print} /^<!-- \/perfis -->$/{f=0}' "$skill" \
           | grep -oE 'references/[A-Za-z0-9._-]+\.md' | sort -u)
  [ -z "$refs" ] && continue
  while IFS= read -r r; do
    pname=$(basename "$r" .md)
    if [ -d "$PLUGIN/profiles/$pname" ]; then ok "$name: bloco de perfis -> profiles/$pname"; else bad "$name: bloco de perfis cita $r, sem profiles/$pname/"; fi
  done <<< "$refs"
done < <(find "$PLUGIN/skills" -name SKILL.md | sort)

for skill in ai-context plan-database-schema plan-project-phases review-phases; do
  assert_contains "$PLUGIN/skills/$skill/SKILL.md" \
    '**nao leia nenhum' \
    "$skill: sem marcador nao abre reference de perfil"
done

# O proprio guard: pega o vazamento, poupa o bloco de perfis, o reference de
# perfil e a fixture de teste, e acusa bloco sem fechamento.
gx="$TMP/guard"
mkdir -p "$gx/skills/a/references" "$gx/profiles/laravel" "$gx/agents" "$gx/scripts"
printf 'linha neutra\nRode php artisan test.\n<!-- perfis -->\n| Laravel | `artisan` |\n<!-- /perfis -->\n' > "$gx/skills/a/SKILL.md"
printf 'Sail no reference do perfil\n' > "$gx/skills/a/references/laravel.md"
printf 'Sail num template\n' > "$gx/skills/a/references/template.md"
printf '<!-- perfis -->\nLaravel\n' > "$gx/agents/aberto.md"
printf '# Laravel na fixture\n' > "$gx/scripts/test-x.sh"
assert_eq "agents/aberto.md: bloco <!-- perfis --> sem fechamento
skills/a/SKILL.md:2:Rode php artisan test.
skills/a/references/template.md:1:Sail num template" "$(core_stack_leaks "$gx")" "guard: acha vazamento, poupa o permitido, acusa bloco aberto"

# ---------------------------------------------------------------------------
# 7. log-tokens conta os subagents
# ---------------------------------------------------------------------------
# Subagent grava transcript/rollout proprio; o do pai nao inclui o consumo dele.
# Num run real eram 28 subagents, +26% de input fora do tokens.jsonl.
header "7. log-tokens conta os subagents"

# Codex: pai, filho, neto, um filho de outra sessao e um rollout anterior ao pai.
cx="$TMP/codex" && mkdir -p "$cx/sessions/2026/09/19" "$cx/repo"
git -C "$cx/repo" init -q
rollout() { # <hora> <id> <parent|-> <input>
  local src='"exec"'
  [ "$3" != "-" ] && src="{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"$3\",\"depth\":1}}}"
  printf '%s\n' \
    "{\"timestamp\":\"t\",\"type\":\"session_meta\",\"payload\":{\"id\":\"$2\",\"source\":$src}}" \
    '{"type":"turn_context","payload":{"model":"gpt-x"}}' \
    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1,\"total_tokens\":2}}}}" \
    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":$4,\"cached_input_tokens\":0,\"output_tokens\":1,\"total_tokens\":$(($4 + 1))}}}}" \
    > "$cx/sessions/2026/09/19/rollout-2026-09-19T$1-$2.jsonl"
}
rollout 20-00-00 old-kid    pai -   5
rollout 21-00-00 pai        -       100
rollout 21-01-00 filho      pai     20
rollout 21-02-00 neto       filho   3
rollout 21-03-00 outro      -       7
rollout 21-04-00 alheio     outro   9
(cd "$cx/repo" && echo '{"session_id":"pai"}' | CODEX_HOME="$cx" bash "$PLUGIN/hooks/codex/log-tokens.sh")
assert_eq "pai - 100
filho pai 20
neto filho 3" "$(jq -r '"\(.session_id) \(.parent // "-") \(.input)"' "$cx/repo/.harness/tokens.jsonl")" \
  "codex: pai, filho e neto com o ultimo token_count; ignora outra arvore e rollout anterior"

# Claude: transcript principal + <transcript>/subagents/agent-*.jsonl
cl="$TMP/claude" && mkdir -p "$cl/proj" "$cl/t/sess/subagents"
msg() { printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":1}}}\n' "$1" "$2"; }
{ msg opus 10; msg opus 5; } > "$cl/t/sess.jsonl"
{ msg haiku 3; msg haiku 4; } > "$cl/t/sess/subagents/agent-abc.jsonl"
echo "{\"transcript_path\":\"$cl/t/sess.jsonl\",\"session_id\":\"sess\"}" \
  | CLAUDE_PROJECT_DIR="$cl/proj" bash "$PLUGIN/hooks/claude/log-tokens.sh"
assert_eq "sess - opus 15
abc sess haiku 7" "$(jq -r '"\(.session_id) \(.parent // "-") \(.model) \(.input)"' "$cl/proj/.harness/tokens.jsonl")" \
  "claude: sessao e subagent, cada um com a propria soma"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}TODOS VERDES: $PASS asserts${NC}"
else
  echo -e "${RED}FALHAS: $FAIL${NC} / verdes: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))
