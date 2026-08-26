---
name: plan-feature-brief
description: Passo 0 do pipeline mktux. Transforma uma ideia solta em docs/features/<slug>/feature-brief.md por entrevista, sem o humano precisar escrever o documento na mao. Re-rodar e upsert: pergunta so o delta. Use quando o brief nao existe, quando o usuario descreve uma feature nova em uma frase, ou disser /mktux:plan-feature-brief.
---

# mktux — feature brief (passo 0 de 4)

Voce transforma uma ideia solta na **intencao registrada** de uma feature. Este e
o unico artefato da cadeia escrito na lingua do humano, e o unico sem carimbo de
frescor — ele e a raiz.

A ideia do dev chega no argumento (pode vir vazia):

```
$ARGUMENTS
```

## Parsing do argumento

| Forma | Interpretacao |
|---|---|
| `<slug> <texto livre>` | primeiro token em kebab-case = slug; o resto = ideia |
| `<slug>` sozinho | slug; ideia vem da entrevista |
| so texto livre | proponha um slug em kebab-case sem acento, **confirme com o dev**, o resto = ideia |
| vazio | liste as pastas em `${MKTUX_SPEC_DIR:-docs/features}/` e pergunte slug + ideia |

Diretorio de saida: `${MKTUX_SPEC_DIR:-docs/features}/<slug>/`.

## Por que este arquivo existe

Toda fase do ralph roda em **sessao fria**. O que nao esta em artefato nao existe:
nem a sessao de implementacao, nem o verificador do gate 3 veem a conversa que
produziu este documento.

Consequencia direta: a secao **"O que NAO pode mudar de comportamento?"** e o que
vira o bloco `Do not touch` de cada fase. Sem ela preenchida, um agente cego
reescreve tela que ja funcionava. Voce **nao entrega** este documento com essa
secao em branco ou com placeholder — veja a regra de fechamento.

Este documento tambem e o que carimba o passo 1: o `feature-description.md` grava
o sha256 dele na linha 3. Editar o brief depois deixa a cadeia stale de propria
conta, e o `/mktux:plan` avisa. Por isso ele e arquivo, e nao conversa.

## Processo

### 1 — Descubra o ambiente antes de perguntar

Nao pergunte o que da pra detectar. Antes da primeira pergunta, leia:

- `CLAUDE.md` / `AGENTS.md` do projeto — convencoes, arquitetura, stack.
- `docs/agents/*.md`, se existir — o que o codigo ja faz.
- Papeis do dominio: enums de role, tabela de usuarios, policies, middleware de
  gating. Voce vai propor a lista de papeis, nao pedir pro dev inventar.
- Sinal de plano / feature flag: config, middleware, colunas de assinatura.
- Telas e fluxos vizinhos ao que a ideia toca — a materia-prima do `Do not touch`.

Projeto vazio ou pre-codigo: registre isso e derive tudo da intencao declarada.

### 2 — Re-run e upsert, nunca reconstrucao

Se `<dir>/feature-brief.md` ja existe:

- Leia ele **antes** de perguntar qualquer coisa. Toda decisao registrada la e
  fonte de verdade, inclusive as que voce discordaria.
- Entreviste so o **delta**: o que a ideia nova acrescenta, o que contradiz o
  documento, o que o codebase mudou desde entao. Nunca re-pergunte o que o
  arquivo ja responde.
- Atualize via `Edit`, nao reescreva o arquivo. Item que o dev apagou fica
  apagado — so restaure se ele confirmar.
- Avise em uma linha, no fechamento, que editar o brief deixa o
  `feature-description.md` stale, e que o proximo `/mktux:plan <slug>` vai
  mandar regenerar o passo 1.

### 3 — Entrevista

Objetivo: sair daqui conseguindo preencher toda secao do template sem enrolacao.

- Use `AskUserQuestion` para decisao discreta com opcoes claras (papeis, gating
  de plano, dado pessoal sai do sistema ou nao).
- Use pergunta aberta em texto plano quando a resposta nao e menu.
- **Agrupe.** Mande blocos de perguntas relacionadas; nao pingue uma de cada vez.
- Proponha resposta baseada no que voce detectou e peca confirmacao — e mais
  rapido pro dev corrigir do que redigir do zero.
- Quando algo continuar indefinido, registre como pergunta em aberto no proprio
  documento em vez de inventar.

Cubra, nesta ordem de prioridade:

1. **O que e** — a feature em linguagem natural.
2. **O que NAO pode mudar** — puxe daqui uma lista concreta. Se o dev disser
   "nada", pergunte pelas telas e calculos vizinhos que voce detectou no passo 1;
   quase sempre aparece alguma coisa. So aceite `nada` depois de checar.
3. **Escopo** — o que entra e o que fica pra depois.
4. **Papeis** — confirme a lista que voce detectou, e quem esta deliberadamente
   de fora.
5. **Regras de negocio ja conhecidas** — nao precisa ser completo; o passo 1
   completa com o codebase.
6. **Plano / feature flag** e **dado pessoal** — as duas viram guard de fase.
7. **Referencias** — mockup, HTML, print. Peca o **caminho exato do arquivo**, e
   sem espaco no nome (`login panel.html` → renomeie para `login-panel.html`).

### 4 — Escreva o documento

Escreva `<dir>/feature-brief.md` (crie o diretorio se faltar). A forma esta em
`references/feature-brief-template.md`, ao lado desta skill.

Duas linguas, de proposito:

- **Titulos de secao: fixos, em portugues, como no template.** Sao endereco — o
  passo 1 e os self-checks leem o brief por eles. Nunca traduza um titulo.
- **Conteudo: na lingua do dev.** Este e o artefato dele, nao do ralph. Ingles
  so a partir do passo 1.

Diferenca do template: voce entrega **preenchido**. Sem `[colchete]`, sem linha
de exemplo, sem checkbox por marcar. Checkbox vira o valor decidido:

```markdown
## Tem limite por plano / feature flag?

Sim — planos `pro` e `business`. Quem nao tem ve o card com botao de upgrade.
```

Secao que a entrevista concluiu nao se aplicar: mantenha o titulo e escreva a
conclusao em uma linha (`Nao mexe em dado pessoal.`). Nao apague a secao — o
passo 1 conta com o endereco.

Linha 3 nao carrega carimbo. Este arquivo e a raiz da cadeia.

Perguntas que ficaram em aberto: secao `## Perguntas em aberto` no fim, so
quando houver.

### 5 — Self-checks (rode ate ficar verde)

```bash
F="${MKTUX_SPEC_DIR:-docs/features}/<slug>/feature-brief.md"
test -f "$F"
head -1 "$F" | grep -qE '^# Feature Brief — .+'
grep -Fq '## O que é essa feature?' "$F"
grep -Fq '## Por que estamos construindo isso?' "$F"
grep -Fq '## O que DEVE entrar nessa feature?' "$F"
grep -Fq '## O que NÃO entra nessa feature (por hora)?' "$F"
grep -Fq '## O que NÃO pode mudar de comportamento?' "$F"
grep -Fq '## Quem usa essa feature?' "$F"

# nenhum placeholder do template sobrevivendo
! grep -qE '^\s*[-*]?\s*\[(item|regra|papel|ex:|Descreva|Liste|Qual|Telas|\.\.\.)' "$F"
! grep -qE '^\s*- \[ \] ' "$F"

# a secao critica tem conteudo real, nao so o titulo e o aviso
awk '/^## O que NÃO pode mudar de comportamento\?/{f=1;next} /^## /{f=0} f' "$F" \
  | grep -vE '^\s*$|^>' | grep -q '[a-zA-Z]'
```

Qualquer check vermelho → conserte via `Edit` e rode de novo. Nunca reporte
conclusao com check vermelho.

## Fechamento

Reporte:

- Caminho escrito, e se foi `criado` ou `atualizado`.
- Resumo de 3 a 5 linhas da feature como ficou registrada.
- **A lista `Do not touch`** que saiu da secao critica, verbatim. E o que o dev
  mais precisa conferir antes de deixar o ralph rodar.
- Self-checks: verde; para cada um que falhou primeiro, a transicao vermelho → verde.
- Perguntas em aberto que ainda precisam de decisao.
- Proximo passo, literal: `/mktux:plan <slug>`.

## Regras

- **Nao escreve nenhum outro artefato.** So `feature-brief.md`. O passo 1 e dono
  do `feature-description.md`.
- **Nao inventa regra de negocio.** O que voce nao conseguiu confirmar vira
  pergunta em aberto, nao uma frase afirmativa.
- **Nao redige em nome do dev sem confirmar.** Voce propoe, ele decide. Proposta
  que ele nao viu nao entra no arquivo.
- **Titulo de secao nunca muda de lingua.** Conteudo segue o dev; titulo segue o template. Ingles no documento inteiro so a partir do passo 1.
- **Nao gera codigo, migration, schema nem fase.** Isso e passo 1 a 4.
- **Nao mexe em git** — nunca `add`, `commit` ou `reset`.
