---
name: plan-user-stories
description: Passo 2 do pipeline mktux. Deriva user stories testaveis, com ids estaveis (US-N.N), a partir do feature-description.md, e grava docs/features/<slug>/user-stories.md. Use depois que a descricao da feature existe. Os ids viram interface publica citada pelos testes no plano de fases.
---

# mktux — user stories (passo 2 de 4)

Voce e um arquiteto de software senior.

Slug vem do argumento. Diretorio: `${MKTUX_SPEC_DIR:-docs/features}/<slug>/`.

## Antes de escrever

Leia `<dir>/feature-description.md` e a documentacao do projeto. Use
AskUserQuestion se algo na descricao da feature for ambiguo, **antes** de
escrever as stories.

## Saida

`<dir>/user-stories.md`, **em ingles**, com o carimbo na linha 3:

```markdown
# User Stories — <Nome>

<!-- inputs: feature-description.md@sha256:abc123def456 -->
```

## Como este documento e consumido

Todo teste listado no `project-phases.md` cita as stories que cobre, por id:

```
- `tests/Feature/Report/ExportProductsReportTest.php` — … (US-1.1, US-5.1)
```

Os ids sao **interface publica**. Tem que ser estaveis, unicos, e presos a
criterios concretos o suficiente pra um teste afirmar diretamente. Story com
criterio vago produz teste que nao afirma nada.

## Estrutura obrigatoria

### Overview
Um paragrafo curto resumindo a feature do ponto de vista do usuario, mais uma
frase dizendo o que as stories cobrem.

### User Types Involved
Uma tabela: tipo, e o que aquele tipo faz nesta feature.

| Type | Description |
|---|---|
| **Owner** | Admin do tenant. … |

Adicione uma linha para qualquer propriedade que decide comportamento sem ser
papel — o plano do tenant, um turno aberto, uma feature flag.

### User Stories
Agrupe por area funcional, numerado: `### 1. Export each report`,
`### 2. Plan gate`.

Cada story e uma linha de id em negrito seguida de criterios Given/When/Then como
bullets simples:

```markdown
**US-1.1** — As an owner on a **Business** plan, I want to download the report
for the period I selected, so I can work on the numbers in a spreadsheet.

- Given I am on `/reports/products` with a period selected
- When I click "Exportar para Excel"
- Then a file named `produtos-{inicio}-a-{fim}.csv` downloads
- And the rows are the same products, in the same order, the table renders
```

Regras dos criterios:

- Cada bullet e uma afirmacao. Se um teste nao pode falhar nela, nao e criterio.
- Nomeie rotas reais, nomes de arquivo reais, flash messages reais, labels de
  enum reais.
- Caminho de falha vive dentro da story relevante, nao como story separada.
- Nao use `- [ ]` — nada rastreia isso e envelhece.

### Grupos obrigatorios de story
Toda feature precisa, no minimo, de stories cobrindo:

- **Authorization** — o que cada papel pode e nao pode fazer, incluindo quem esta
  excluido.
- **Plan gate**, quando a feature e limitada por plano — o que um plano bloqueado
  ve, e que o backend recusa uma requisicao direta, nao so esconde o botao.
- **Tenant isolation** — o tenant A nunca alcanca o dado do tenant B. (Pule so se
  o projeto genuinamente nao for multi-tenant.)
- **Validation and error paths** — o que e recusado, e o que o usuario ve.
- **Regression** — um grupo final dizendo o que tem que continuar se comportando
  exatamente como antes. E isso que impede uma feature de reescrever em silencio
  uma tela vizinha.

## Instrucoes

- Derive as stories estritamente do `feature-description.md`. Nao adicione escopo
  que nao esta la.
- Todo criterio tem que ser testavel de forma independente — nunca "works
  correctly".
- Referencie convencoes existentes onde couber: escopo de propriedade, isolamento
  de tenant, 404 vs 403, flash messages, diretivas `@can`, labels de enum.
- Ids sao estaveis depois de escritos. O `project-phases.md` cita eles.
- Sem tabela de status, sem coluna de prioridade — envelhecem e nenhum agente le.
- Tudo em ingles.
