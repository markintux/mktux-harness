#!/usr/bin/env bash
#
# test-layout.sh — checa o layout do plugin: todo caminho que um manifest ou
# uma skill cita existe, e os hooks do perfil Laravel ainda se comportam.
#
# A test-ralph.sh cobre o ralph.sh; nada cobria hooks nem skills. Um hook movido
# sem atualizar o hooks.json some calado (o engine so loga o erro), e um
# references/*.md citado que nao existe faz a skill seguir sem as convencoes.
#
# Uso: scripts/test-layout.sh   (exit 0 = tudo verde)

set -uo pipefail

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
LARAVEL_HOOKS="$PLUGIN/profiles/laravel/hooks"

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

# ---------------------------------------------------------------------------
# 3. Nenhuma referencia aos caminhos antigos dos hooks Laravel
# ---------------------------------------------------------------------------
header "3. sem caminho antigo de hook Laravel"
# O caminho novo (profiles/laravel/hooks/...) contem o antigo como sufixo: so
# conta como antigo o `hooks/` que nao vem logo depois de `laravel/`.
old='(shared/sail-guard|claude/pint-and-test|codex/pint-and-test)'
stale=$(grep -rnE "(^|[^l])/hooks/$old|(^|[^/])hooks/$old" "$PLUGIN" \
          --exclude="$(basename "$0")" || true)
if [ -z "$stale" ]; then
  ok "nenhum caminho antigo"
else
  bad "caminho antigo ainda citado:"
  printf '%s\n' "$stale" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# 4. Hooks do perfil Laravel (smoke)
# ---------------------------------------------------------------------------
header "4. hooks do perfil Laravel"
if ! command -v jq > /dev/null 2>&1; then
  echo "  (sem jq: smoke dos hooks pulado — os hooks dependem dele)"
else
  # sail-guard: projeto com Sail bloqueia PHP no host e devolve a forma via Sail
  sail_proj="$TMP/sail-proj"
  mkdir -p "$sail_proj/vendor/bin" && touch "$sail_proj/vendor/bin/sail"
  guard_in() { jq -nc --arg cwd "$1" --arg cmd "$2" '{cwd: $cwd, tool_input: {command: $cmd}}'; }

  rc=0; guard_in "$sail_proj" "php artisan migrate" \
    | bash "$LARAVEL_HOOKS/shared/sail-guard.sh" 2> "$TMP/guard.err" || rc=$?
  assert_eq 2 "$rc" "sail-guard: php artisan no host de projeto Sail -> bloqueia"
  assert_contains "$TMP/guard.err" "./vendor/bin/sail artisan migrate" "sail-guard: sugere a forma via Sail"

  rc=0; guard_in "$sail_proj" "./vendor/bin/sail artisan migrate" \
    | bash "$LARAVEL_HOOKS/shared/sail-guard.sh" 2> /dev/null || rc=$?
  assert_eq 0 "$rc" "sail-guard: comando ja via Sail -> passa"

  plain_proj="$TMP/plain-proj"
  mkdir -p "$plain_proj"
  rc=0; guard_in "$plain_proj" "php artisan migrate" \
    | bash "$LARAVEL_HOOKS/shared/sail-guard.sh" 2> /dev/null || rc=$?
  assert_eq 0 "$rc" "sail-guard: projeto sem Sail -> passa"

  # pint-and-test (Claude): fora de .php, ou sem Sail de pe, nunca bloqueia
  edit_in() { jq -nc --arg f "$1" '{tool_input: {file_path: $f}}'; }

  rc=0; edit_in "$plain_proj/src/app.ts" \
    | CLAUDE_PROJECT_DIR="$plain_proj" bash "$LARAVEL_HOOKS/claude/pint-and-test.sh" 2> /dev/null || rc=$?
  assert_eq 0 "$rc" "pint-and-test (claude): arquivo nao-PHP -> passa"

  rc=0; edit_in "$plain_proj/app/Foo.php" \
    | CLAUDE_PROJECT_DIR="$plain_proj" bash "$LARAVEL_HOOKS/claude/pint-and-test.sh" 2> /dev/null || rc=$?
  assert_eq 0 "$rc" "pint-and-test (claude): PHP sem Sail de pe -> passa"

  # pint-and-test (Codex): sem Sail de pe, deixa o turno encerrar
  git -C "$plain_proj" init -q
  rc=0; out=$(cd "$plain_proj" && echo '{"stop_hook_active": false}' \
    | bash "$LARAVEL_HOOKS/codex/pint-and-test.sh" 2> /dev/null) || rc=$?
  assert_eq 0 "$rc" "pint-and-test (codex): exit 0"
  assert_eq '{"continue": true}' "$out" "pint-and-test (codex): sem Sail -> continue, sem block"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}TODOS VERDES: $PASS asserts${NC}"
else
  echo -e "${RED}FALHAS: $FAIL${NC} / verdes: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))
