#!/usr/bin/env bash
#
# mktux-setup.sh — instala `ralph` e `ralph-watch` no PATH.
#
# Roda UMA vez por maquina, nao por projeto. Nem Claude Code nem Codex expoem
# binario de plugin no PATH, entao geramos um wrapper em ~/.local/bin que
# resolve o caminho do plugin em tempo de execucao. Assim `plugin update`
# atualiza o ralph junto, sem precisar rodar este script de novo.
set -euo pipefail

BIN_DIR="${MKTUX_BIN_DIR:-$HOME/.local/bin}"

# O resolvedor abaixo e embutido em cada wrapper. Ordem de busca:
#   1. MKTUX_HARNESS_ROOT (escape hatch: clone proprio, fork, dev local)
#   2. plugin do Claude Code (cache versionado e clone do marketplace)
#   3. plugin do Codex (idem). Entre candidatos, ganha o de mtime mais novo.
read -r -d '' RESOLVER <<'RESOLVER_EOF' || true
resolve_script() {
  local name="$1" c

  if [[ -n "${MKTUX_HARNESS_ROOT:-}" && -x "$MKTUX_HARNESS_ROOT/scripts/$name" ]]; then
    printf '%s\n' "$MKTUX_HARNESS_ROOT/scripts/$name"; return 0
  fi

  # Caminhos reais, verificados nas duas CLIs. Os dois usam dois layouts cada:
  # o cache versionado (<root>/cache/<marketplace>/<plugin>/<versao>/) e o clone
  # do marketplace (<root>/marketplaces/<marketplace>/plugins/<plugin>/).
  c=$(ls -dt \
        "$HOME"/.claude/plugins/cache/*/mktux*/*/scripts/"$name" \
        "$HOME"/.claude/plugins/marketplaces/*/plugins/mktux*/scripts/"$name" \
        "$HOME"/.codex/plugins/cache/*/mktux*/*/scripts/"$name" \
        "$HOME"/.codex/.tmp/marketplaces/*/plugins/mktux*/scripts/"$name" \
        2>/dev/null | head -1)

  [[ -n "$c" ]] && { printf '%s\n' "$c"; return 0; }

  echo "mktux-harness: nao encontrei $name." >&2
  echo "Instale o plugin, ou aponte MKTUX_HARNESS_ROOT para o repo clonado." >&2
  return 1
}
RESOLVER_EOF

install_wrapper() {
  local cmd="$1" script="$2"
  cat > "$BIN_DIR/$cmd" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
$RESOLVER
exec bash "\$(resolve_script "$script")" "\$@"
WRAPPER
  chmod +x "$BIN_DIR/$cmd"
  echo "  instalado: $BIN_DIR/$cmd"
}

mkdir -p "$BIN_DIR"
echo "mktux-harness — instalando comandos:"
install_wrapper ralph       ralph.sh
install_wrapper ralph-watch ralph-watch.sh

echo
case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo "PATH ok. Teste com: ralph --help"
    ;;
  *)
    echo "AVISO: $BIN_DIR nao esta no PATH."
    echo "Adicione ao seu ~/.zshrc (ou ~/.bashrc):"
    echo
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo
    echo "Depois abra um terminal novo e teste com: ralph --help"
    ;;
esac
