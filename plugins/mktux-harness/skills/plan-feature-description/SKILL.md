---
name: plan-feature-description
description: Passo 1 do pipeline mktux. Le o feature-brief.md escrito pelo humano e o codebase existente, e gera docs/features/<slug>/feature-description.md — o documento de contexto que toda sessao do ralph recebe. Use quando o brief existe e a descricao da feature ainda nao, ou quando ela precisa ser regenerada.
---

# mktux — feature description (passo 1 de 4)

Voce e um arquiteto de software senior. Escreve o documento que todas as sessoes
frias do ralph vao consultar.

Slug vem do argumento. Diretorio: `${MKTUX_SPEC_DIR:-docs/features}/<slug>/`.

## Antes de escrever

Leia:

- `<dir>/feature-brief.md` — **a fonte primaria de intencao**. Sem ele, pare e
  peca ao humano para preencher o template.
- O `CLAUDE.md` / `AGENTS.md` do projeto — convencoes, arquitetura, stack.
- `docs/project-description.md`, se existir.

Depois inspecione o codebase para entender o que ja existe:

- Models, migrations, rotas e controllers no lugar
- Enums ja definidos
- Actions e Services ja justificados
- Middleware, policies e gates atras dos quais a feature vai sentar

## Saida

`<dir>/feature-description.md`, **em ingles**.

Linha 3 do arquivo carrega o carimbo das entradas:

```markdown
# Feature Description — <Nome>

<!-- inputs: feature-brief.md@sha256:abc123def456 -->
```

Calcule com `shasum -a 256 <arquivo> | cut -c1-12`.

## Como este documento e consumido

Nao e documento que humano le uma vez e arquiva. E **documento de contexto do
ralph**: o `ralph.sh` passa o caminho dele para toda sessao de implementacao, e o
`project-phases.md` cita ele por nome de secao
(`**Read first:** feature-description.md next to this file, section "PII Rules"`).

Duas consequencias:

- **Titulo de secao e endereco.** De nomes estaveis e especificos que uma fase
  consiga apontar. Uma fase nunca deve dizer "veja a descricao da feature" sem
  nomear onde.
- **Decisao tem que ficar registrada, nao implicita.** A sessao verificadora
  (gate 3) nunca ve este arquivo, e toda sessao de implementacao e fria. Decisao
  que so existe na conversa que produziu este documento nao existe.

## Estrutura obrigatoria

### Overview
O que a feature faz e por que existe. Um ou dois paragrafos curtos.
Se a feature tem que deixar comportamento existente intocado, diga aqui, numa
frase seca — e a frase que toda fase posterior herda.

### Scope
Duas listas: **In scope** e **Out of scope**. Concreto. O "Out of scope" e
estrutural: e de onde sai a linha `Do not touch` de cada fase.

### User Roles Involved
Quais papeis interagem com a feature e como. Inclua decisao de gating de papel —
quem esta deliberadamente de fora, e por que.

### System Context
Em qual contexto da aplicacao a feature vive (area administrativa, area
autenticada do cliente, area publica). Se for mais de um, liste cada um com sua
finalidade.

### Plan Gating
So quando a feature e limitada por plano ou feature flag. Tabela de
plano x capacidade, mais o metodo/config exato e a chave de middleware
envolvidos, e o que um plano bloqueado ve.

### Business Rules
Lista **numerada** das regras de dominio que governam a feature — numerada para
que stories e fases possam citar. Explicito: edge cases, restricoes, limites,
regras de validacao. Referencie conceitos existentes do dominio quando couber.

### Key Concepts
Defina qualquer termo de dominio ou entidade nova que a feature introduz e que
ainda nao esta documentado no projeto.

### What exists vs what is added
Duas listas explicitas:

- **What already exists and is reused** — toda classe que a feature le, chama ou
  estende, cada uma marcada como read-only onde nao pode mudar. E a materia-prima
  do guard `Do not touch` de cada fase.
- **What this feature adds** — toda classe, rota, view e componente novo, com
  namespace e pasta.

### Data & Format Decisions
So quando a feature produz ou consome artefato concreto (arquivo, export,
payload, mensagem). Fixe todo detalhe que um teste vai afirmar: encoding,
separadores, formato de numero e data, nome de arquivo, cabecalhos, comportamento
de estado vazio.

### Audit
Quando a feature escreve em log de atividade: tabela de gatilho x nome do log x
evento x propriedades.

### UI
O que muda na tela, por estado e por papel. Nomeie os design tokens e o componente
ou markup existente que a UI nova segue. Gating de exibicao e gating de exibicao —
diga explicitamente que o enforcement vive no backend.

### Out of Scope
Lista final explicita do que NAO sera construido nesta iteracao, incluindo o
trabalho adjacente que alguem vai ser tentado a embutir.

## Instrucoes

- O `feature-brief.md` e a fonte primaria de intencao. Respeite cada decisao que
  o humano tomou la.
- Preencha lacunas com a documentacao do projeto e o codebase existente — nunca
  invente regra.
- Se o brief for ambiguo, ou contradisser o codebase, use a ferramenta
  AskUserQuestion para esclarecer **antes** de escrever. Nao resolva uma
  bifurcacao real com um chute e uma nota de rodape.
- Quando voce discordar de uma decisao do brief, implemente como escrito e
  registre o tradeoff em uma ou duas frases na secao relevante, rotulado como
  limitacao deliberada e aceita. Nao redesenhe em silencio.
- Documento conciso. Toda frase carrega informacao.
- Nao gere codigo, migration ou detalhe de implementacao aqui — isso e o
  `project-phases.md`.
- Escreva tudo em ingles.
