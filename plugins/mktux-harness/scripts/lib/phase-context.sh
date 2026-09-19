# lib/phase-context.sh — recorte, dos documentos do plano, do que uma fase cita.
#
# Sourced pelo ralph.sh. So define funcoes.
#
# Mandar a sessao "ler os documentos de contexto" fazia ela ler TODOS, inteiros:
# num run real (x-cleaner), 25 de 26 sessoes — correcao inclusive — abriram
# feature-brief, feature-description, user-stories e database-schema (~76 KB,
# ~19k tokens) e ainda trechos do project-phases.md, e esse texto fica no
# contexto em todo turno seguinte. A fase ja diz o que precisa: a linha
# **Read first:** cita secoes, regras, tabelas e stories, e os cenarios de teste
# citam US-N.N. O ralph recorta so isso, mecanicamente.
#
# Formato dos documentos (o que as skills plan-* geram):
#   secao:  "## Nome" / "### 3. Nome"       citada como "Nome"
#   tabela: "### `nome`" ou "Table nome {"  citada como `nome`
#   story:  "**US-2.1** — ..."              citada como US-2.1 (ou faixa)
#   regra:  "3. **BR-03 — ...:** ..."       citada como BR-03 (ou faixa)

# phase_context_refs <fase.md> -> "doc<TAB>nome" por secao/tabela citada no
# paragrafo **Read first:**. doc e o ultimo `arquivo.md` citado antes do nome;
# "*" quando nenhum veio antes.
phase_context_refs() {
  awk '
    /^\*\*Read first:\*\*/ { on = 1 }
    on && /^[[:space:]]*$/ { exit }
    on { para = para " " $0 }
    END {
      doc = "*"
      while (match(para, /`[^`]+`|"[^"]+"/)) {
        tok = substr(para, RSTART + 1, RLENGTH - 2)
        para = substr(para, RSTART + RLENGTH)
        if (tok ~ /\.md$/) { doc = tok; continue }
        print doc "\t" tok
      }
    }
  ' "$1"
}

# phase_context_ids <fase.md> <prefixo: US|BR> -> um id por linha, faixas
# ("US-2.1 through US-2.5", "BR-07 to BR-14") expandidas, sem repeticao.
# `|| true` no grep: o ralph roda sob pipefail, e fase sem id nenhum e normal.
phase_context_ids() {
  local file="$1" pfx="$2"
  if [ "$pfx" = "US" ]; then
    { grep -oE 'US-[0-9]+\.[0-9]+( (through|to|-|–) US-[0-9]+\.[0-9]+)?' "$file" 2> /dev/null || true; } \
      | awk '{
          split($1, a, /[-.]/); print $1
          if (NF == 3) {
            split($3, b, /[-.]/)
            if (a[2] == b[2]) for (i = a[3] + 1; i <= b[3]; i++) print "US-" a[2] "." i
          }
        }'
  else
    { grep -oE 'BR-[0-9]+( (through|to|-|–) BR-[0-9]+)?' "$file" 2> /dev/null || true; } \
      | awk '{
          print $1
          if (NF == 3) {
            w = length($1) - 3; x = substr($1, 4) + 0; y = substr($3, 4) + 0
            for (i = x + 1; i <= y; i++) printf "BR-%0" w "d\n", i
          }
        }'
  fi | awk '!seen[$0]++'
}

# phase_context_extract <doc.md> <nomes, 1 por linha> <US ids> <BR ids>
# Imprime, na ordem do documento, as linhas das secoes, stories e regras
# pedidas. Trecho repetido sai uma vez (story dentro de secao ja recortada).
# Listas via ambiente: o awk do macOS recusa quebra de linha em -v.
phase_context_extract() {
  PC_NAMES="$2" PC_US="$3" PC_BR="$4" awk '
    function norm(s) {
      gsub(/`/, "", s); gsub(/\*\*/, "", s)
      sub(/^[0-9]+\.[ \t]+/, "", s); sub(/[ \t]+$/, "", s); sub(/^[ \t]+/, "", s)
      return tolower(s)
    }
    function mark(a, b,   k) { for (k = a; k < b; k++) keep[k] = 1 }
    BEGIN {
      names = ENVIRON["PC_NAMES"]; us = ENVIRON["PC_US"]; br = ENVIRON["PC_BR"]
      n = split(names, t, "\n"); for (i = 1; i <= n; i++) if (t[i] != "") W[norm(t[i])] = 1
      n = split(us, t, "\n");    for (i = 1; i <= n; i++) if (t[i] != "") U[t[i]] = 1
      n = split(br, t, "\n");    for (i = 1; i <= n; i++) if (t[i] != "") B[t[i]] = 1
    }
    { L[NR] = $0; lvl[NR] = 0; if (match($0, /^#+ /)) lvl[NR] = RLENGTH - 1 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lvl[i] > 0) {
          k = norm(substr(L[i], lvl[i] + 2))
          if (k in W) {
            for (j = i + 1; j <= NR && !(lvl[j] > 0 && lvl[j] <= lvl[i]); j++) ;
            mark(i, j)
          }
        } else if (match(L[i], /^\*\*US-[0-9]+\.[0-9]+\*\*/)) {
          id = substr(L[i], 3, RLENGTH - 4)
          if (id in U) {
            for (j = i + 1; j <= NR && lvl[j] == 0 && L[j] !~ /^\*\*US-/; j++) ;
            mark(i, j)
          }
        } else if (L[i] ~ /^Table [^ {]+[ {]/) {
          # Bloco DBML sem titulo proprio: da linha "Table x {" ate a "}".
          k = L[i]; sub(/^Table /, "", k); sub(/[ {].*$/, "", k); gsub(/"/, "", k)
          if (norm(k) in W) {
            for (j = i + 1; j <= NR && L[j] !~ /^}/; j++) ;
            mark(i, j + 1)
          }
        } else if (L[i] ~ /^[0-9]+\. \*\*BR-[0-9]+/) {
          id = substr(L[i], index(L[i], "BR-"))
          match(id, /^BR-[0-9]+/); id = substr(id, 1, RLENGTH)
          if (id in B) {
            for (j = i + 1; j <= NR && lvl[j] == 0 && L[j] !~ /^[0-9]+\. / && L[j] !~ /^[ \t]*$/; j++) ;
            mark(i, j)
          }
        }
      }
      gap = 0
      for (i = 1; i <= NR; i++) {
        if (i in keep) {
          if (gap && printed) print "[...]"
          print L[i]; printed = 1; gap = 0
        } else gap = 1
      }
    }
  ' "$1"
}

# phase_context <fase.md> <dir dos documentos> <arquivo de fases> [limite bytes]
# O bloco de contexto recortado, pronto para o prompt. Vazio quando a fase nao
# cita nada que exista nos documentos.
phase_context() {
  local phase="$1" dir="$2" plan="$3" limit="${4:-40000}"
  local refs us br doc base names out="" chunk

  refs=$(phase_context_refs "$phase")
  us=$(phase_context_ids "$phase" US)
  br=$(phase_context_ids "$phase" BR)
  [ -n "$refs$us$br" ] || return 0

  for doc in "$dir"/*.md; do
    [ -f "$doc" ] || continue
    base=$(basename "$doc")
    [ "$base" = "$(basename "$plan")" ] && continue
    names=$(printf '%s\n' "$refs" | awk -F'\t' -v d="$base" '$1 == d || $1 == "*" { print $2 }')
    chunk=$(phase_context_extract "$doc" "$names" "$us" "$br")
    [ -n "$chunk" ] || continue
    out="${out}"$'\n'"### ${base}"$'\n'"~~~~markdown"$'\n'"${chunk}"$'\n'"~~~~"$'\n'
  done

  [ -n "$out" ] || return 0
  if [ "${#out}" -gt "$limit" ]; then
    out="${out:0:$limit}"$'\n'"~~~~"$'\n'"(recorte truncado em $limit bytes pelo ralph: o resto esta nos documentos)"
  fi
  printf '%s\n' "$out"
}
