#!/usr/bin/env bash
# Stop hook — porte do pint-and-test.sh do Claude, adaptado de "por arquivo
# editado" para "ao fim do turno" (Codex não dispara em Edit/Write).
#
# Semântica do Stop no Codex (IMPORTANTE):
#   decision:block  => NÃO encerra: cria um prompt de continuação com `reason`.
#   sem block       => deixa o turno encerrar.
# Logo: vermelho -> emitimos block (Codex corrige); verde -> não bloqueia.
set -euo pipefail

input=$(cat)

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root"

emit_continue() { printf '{"continue": true}\n'; exit 0; }

# Evita loop infinito: se este turno já foi continuado por um Stop anterior, não re-bloqueia.
already=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[[ "$already" == "true" ]] && emit_continue

# Sail precisa estar up; se não, encerra sem bloquear (igual ao Claude saía silenciosamente).
vendor/bin/sail ps 2>/dev/null | grep -q "Up" || emit_continue

# 1) Pint só no que mudou (git-driven). Não bloqueia por formatação, igual ao Claude.
vendor/bin/sail bin pint --dirty --format agent >&2 || true

# 2) Arquivos de teste alterados neste turno (tracked + untracked).
changed_tests=$(
  {
    git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -E '^tests/.*\.php$' || true
)

# Nenhum teste mudou -> só Pint, encerra (comportamento idêntico ao do Claude).
[[ -z "$changed_tests" ]] && emit_continue

# Monta filtro com os nomes-base dos testes alterados (PlanTest, MoneyTest, ...).
filters=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  filters+=("$(basename "$f" .php)")
done <<< "$changed_tests"
filter_arg=$(IFS='|'; echo "${filters[*]}")

# 3) Roda só os testes afetados. Captura saída pra devolver como motivo da continuação.
if out=$(vendor/bin/sail artisan test --compact --filter="$filter_arg" 2>&1); then
  emit_continue
else
  reason=$(printf 'Affected tests are RED after this turn (filter: %s). Fix them before finishing:\n\n%s' \
    "$filter_arg" "$out" | tail -c 4000)
  jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
  exit 0
fi
