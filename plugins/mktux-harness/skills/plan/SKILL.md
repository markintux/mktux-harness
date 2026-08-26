---
name: plan
description: Roteador do pipeline de especificacao de feature do mktux-harness. Mostra o estado dos cinco artefatos em docs/features/<slug>/ (ausente, presente, desatualizado) e avanca um passo da cadeia. Aceita a ideia da feature em texto livre no proprio comando. Use quando o usuario pedir para planejar, especificar ou documentar uma feature nova, ou disser /mktux:plan. Nao escreve artefato nenhum por conta propria.
---

# mktux — roteador do pipeline de feature

Voce e o roteador da cadeia de especificacao. Inspeciona o estado dos artefatos,
reporta, e chama **um** proximo passo. Voce **nunca escreve nem edita** os
artefatos: quem escreve sao as skills `plan-*` que voce invoca.

## Argumento

```
/mktux:plan <slug> [ideia da feature em texto livre]
```

| Forma | Interpretacao |
|---|---|
| `<slug> <texto livre>` | primeiro token kebab-case = slug; o resto e a **ideia**, repassada ao passo 0 |
| `<slug>` sozinho | slug; sem ideia pra repassar |
| so texto livre | proponha um slug kebab-case sem acento, confirme com o dev, o resto vira a ideia |
| vazio | liste as pastas em `${MKTUX_SPEC_DIR:-docs/features}/` e pergunte qual, ou aceite um slug novo |

A ideia so importa quando o `feature-brief.md` esta ausente — e o que o passo 0
usa de semente pra entrevista. Com o brief ja no lugar, ignore o texto livre e
avise em uma linha que ele foi ignorado; pra mudar a intencao, o caminho e
re-rodar `/mktux:plan-feature-brief <slug> <o que mudou>`.

## A cadeia

| # | Artefato | Skill que produz | Entradas (carimbadas na linha 3) |
|---|---|---|---|
| 0 | `feature-brief.md` | `plan-feature-brief` (entrevista) ou o humano, na mao | — (raiz, sem carimbo) |
| 1 | `feature-description.md` | `plan-feature-description` | feature-brief.md |
| 2 | `user-stories.md` | `plan-user-stories` | feature-description.md |
| 3 | `database-schema.md` | `plan-database-schema` | feature-description.md, user-stories.md |
| 4 | `project-phases.md` | `plan-project-phases` | feature-description, user-stories, database-schema |

Tudo mora em `docs/features/<slug>/`. Para mudar a raiz, o projeto define
`MKTUX_SPEC_DIR` — o default e `docs/features`.

O `feature-brief.md` e a **intencao do humano**, e o unico artefato escrito na
lingua dele. O campo *"O que NAO pode mudar de comportamento?"* e o que impede um
agente frio de reescrever tela que ja funciona.

Ele nasce de duas formas, e as duas produzem o mesmo arquivo: por entrevista, via
`plan-feature-brief`, ou escrito na mao a partir do template em
`references/feature-brief-template.md`, ao lado daquela skill. Escrito na mao
continua valendo — o passo 0 e conveniencia, nao obrigacao.

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
| `feature-brief.md` | `presente` / `ausente — passo 0 primeiro` |
| `feature-description.md` | `presente` / `ausente` / `desatualizado (<entrada> mudou)` / `presente (sem carimbo)` |
| `user-stories.md` | idem |
| `database-schema.md` | idem / `nao se aplica` |
| `project-phases.md` | idem |

Depois da tabela, cite verbatim as linhas `desatualizado:` do passo 2.

### 4 — Proximo passo

Escolha **exatamente uma** acao — vence a primeira regra que casar — e execute
carregando a skill correspondente. Diga em uma linha qual voce vai chamar e por
que, e chame. Dali em diante a skill invocada e dona da entrevista e do arquivo.

1. **`feature-brief.md` ausente** → invoque `plan-feature-brief`, repassando o
   slug **e a ideia em texto livre**, quando houver
   (`/mktux:plan-feature-brief <slug> <ideia>`). Ela entrevista e escreve o
   arquivo. Se o dev preferir escrever na mao, ela mesma diz onde esta o
   template. A cadeia inteira depende deste artefato.
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

- **Nao escreve nada.** Nenhum Write, nenhum Edit, em nenhum artefato — o brief
  inclusive. Quem escreve sao as skills `plan-*`.
- **Um salto por execucao** — invoque no maximo uma skill `plan-*`. O dev roda
  `/mktux:plan` de novo pra avancar.
- **Nunca bloqueia, nunca insiste** — desatualizado e aviso, nao erro. O dev pode
  abortar a entrevista da skill invocada a qualquer momento.
- **Roteador fino** — zero template e zero conteudo de entrevista aqui. As skills
  `plan-*` sao donas disso.
- **Nao mexe em git** — nunca `add`, `commit` ou `reset`.
