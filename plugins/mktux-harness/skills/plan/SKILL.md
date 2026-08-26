---
name: plan
description: Roteador do pipeline de especificacao de feature do mktux-harness. Mostra o estado dos quatro artefatos em docs/features/<slug>/ (ausente, presente, desatualizado) e avanca um passo da cadeia. Use quando o usuario pedir para planejar, especificar ou documentar uma feature nova, ou disser /mktux:plan. Nao escreve artefato nenhum por conta propria.
---

# mktux — roteador do pipeline de feature

Voce e o roteador da cadeia de especificacao. Inspeciona o estado dos artefatos,
reporta, e chama **um** proximo passo. Voce **nunca escreve nem edita** os
artefatos: quem escreve sao as skills `plan-*` que voce invoca.

O slug da feature vem do argumento (`/mktux:plan radar-de-sumidos`). Sem
argumento, liste as pastas em `docs/features/` e pergunte qual, ou aceite um slug
novo. Slug e kebab-case, sem acento.

## A cadeia

| # | Artefato | Skill que produz | Entradas (carimbadas na linha 3) |
|---|---|---|---|
| 0 | `feature-brief.md` | **humano**, na mao | — |
| 1 | `feature-description.md` | `plan-feature-description` | feature-brief.md |
| 2 | `user-stories.md` | `plan-user-stories` | feature-description.md |
| 3 | `database-schema.md` | `plan-database-schema` | feature-description.md, user-stories.md |
| 4 | `project-phases.md` | `plan-project-phases` | feature-description, user-stories, database-schema |

Tudo mora em `docs/features/<slug>/`. Para mudar a raiz, o projeto define
`MKTUX_SPEC_DIR` — o default e `docs/features`.

O `feature-brief.md` e **sempre manual**. Nenhuma skill escreve nele. E o
documento onde o humano decide a intencao, e o campo *"O que NAO pode mudar de
comportamento?"* dele e o que impede um agente frio de reescrever tela que ja
funciona. O template esta em `references/feature-brief-template.md`, ao lado
desta skill.

Uma feature que nao mexe em banco pode nao ter `database-schema.md`. Trate o
passo 3 como pulavel quando o `feature-description.md` nao introduz nem altera
tabela — diga isso explicitamente no relatorio em vez de gerar um documento
vazio.

## Fluxo

### 1 — Presenca

```bash
slug="<slug>"
dir="${MKTUX_SPEC_DIR:-docs/features}/$slug"
for f in feature-brief feature-description user-stories database-schema project-phases; do
  test -f "$dir/$f.md" && echo "presente: $f.md" || echo "ausente: $f.md"
done
```

### 2 — Frescor

A linha 3 de cada artefato gerado registra de quais entradas ele nasceu, no
formato `arquivo.md@sha256:<12 chars>`. Recalcule e compare:

```bash
slug="<slug>"
dir="${MKTUX_SPEC_DIR:-docs/features}/$slug"

# `sha256sum` nao existe no macOS. `shasum -a 256` existe nos dois.
hash12() { shasum -a 256 "$1" | cut -c1-12; }

for doc in user-stories database-schema project-phases; do
  [ -f "$dir/$doc.md" ] || continue
  for pair in $(sed -n '3p' "$dir/$doc.md" | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
    input="${pair%%@*}"
    [ -f "$dir/$input" ] || continue
    [ "$(hash12 "$dir/$input")" = "${pair##*:}" ] \
      || echo "desatualizado: $doc.md nasceu de uma versao antiga de $input"
  done
done
```

Silencio = cadeia fresca. Artefato presente cuja linha 3 nao tem carimbo e
anterior ao mecanismo: frescor desconhecido, reporte assim.

### 3 — Relatorio

Uma tabela so:

| Artefato | Estado |
|---|---|
| `feature-brief.md` | `presente (manual)` / `ausente — bloqueia a cadeia` |
| `feature-description.md` | `presente` / `ausente` / `desatualizado (<entrada> mudou)` / `presente (sem carimbo)` |
| `user-stories.md` | idem |
| `database-schema.md` | idem / `nao se aplica` |
| `project-phases.md` | idem |

Depois da tabela, cite verbatim as linhas `desatualizado:` do passo 2.

### 4 — Proximo passo

Escolha **exatamente uma** acao — vence a primeira regra que casar — e execute
carregando a skill correspondente. Diga em uma linha qual voce vai chamar e por
que, e chame. Dali em diante a skill invocada e dona da entrevista e do arquivo.

1. **`feature-brief.md` ausente** → nao invoque nada. Copie
   `references/feature-brief-template.md` para `$dir/feature-brief.md` e peca ao
   humano para preencher. A cadeia inteira depende dele.
2. **Um artefato ausente** → invoque a skill do primeiro ausente na ordem 1 → 4.
   Artefato anterior tem que existir antes do seguinte fazer sentido.
3. **Um artefato desatualizado** → re-invoque a skill do primeiro desatualizado
   na ordem. Re-rodar e upsert: a skill entrevista so sobre o delta e renova o
   carimbo. Regenerar um artefato costuma deixar os de baixo desatualizados —
   rode `/mktux:plan <slug>` de novo depois.
4. **Tudo presente e fresco** → nao invoque nada. Reporte
   `Cadeia completa e fresca — nada a fazer.` e mostre o comando do ralph:
   `ralph docs/features/<slug>/project-phases.md`.
   Se algum artefato estiver `presente (sem carimbo)`, adicione uma linha: o
   frescor dele so da pra verificar depois de re-rodar a skill dele uma vez.

No Claude Code, invoque via SlashCommand quando disponivel
(`/mktux:plan-user-stories <slug>`). No Codex, carregue a skill pelo nome. Se a
invocacao falhar, recomende a skill por nome — nunca deixe o dev sem proximo
passo.

## Regras

- **Nao escreve nada** — a unica excecao e copiar o template do brief quando ele
  falta. Nenhum Write ou Edit em artefato gerado.
- **Um salto por execucao** — invoque no maximo uma skill `plan-*`. O dev roda
  `/mktux:plan` de novo pra avancar.
- **Nunca bloqueia, nunca insiste** — desatualizado e aviso, nao erro. O dev pode
  abortar a entrevista da skill invocada a qualquer momento.
- **Roteador fino** — zero template e zero conteudo de entrevista aqui. As skills
  `plan-*` sao donas disso.
- **Nao mexe em git** — nunca `add`, `commit` ou `reset`.
