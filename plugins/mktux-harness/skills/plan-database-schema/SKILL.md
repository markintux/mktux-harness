---
name: plan-database-schema
description: Passo 3 do pipeline mktux. Inspeciona o schema existente e gera docs/features/<slug>/database-schema.md em DBML, incluindo o veredito explicito de "esta feature nao tem migration" quando for o caso. Use depois que feature-description.md e user-stories.md existem.
---

# mktux — database schema (passo 3 de 4)

Voce e um arquiteto de software senior.

Slug vem do argumento. Diretorio: `${MKTUX_SPEC_DIR:-docs/features}/<slug>/`.

## Antes de escrever

Leia `<dir>/feature-description.md`, `<dir>/user-stories.md` e a documentacao do
projeto. Depois inspecione o banco **que ja existe**:

- Use a ferramenta `database-schema` (Laravel Boost) quando disponivel; senao leia
  as migrations em `database/migrations/`.
- Identifique de quais tabelas existentes a feature le ou em quais escreve.
- **Nunca redefina tabela existente.** So documente tabelas novas ou colunas novas
  adicionadas a tabelas existentes.

## Saida

`<dir>/database-schema.md`, **em ingles**, com o carimbo na linha 3:

```markdown
# Database Schema — <Nome>

<!-- inputs: feature-description.md@sha256:aaa111bbb222 user-stories.md@sha256:ccc333ddd444 -->
```

## Como este documento e consumido

O `ralph` passa o caminho deste arquivo para toda sessao de implementacao. Uma
sessao fria que nao consegue dizer se a feature tem migration **vai inventar
uma**.

Por isso a **primeira secao e um veredito, nao um preambulo**:

- Se a feature nao tem migration, abra com um `## Summary` dizendo isso em
  **negrito**, e acrescente a frase que as fases vao ecoar: *"If any step of the
  implementation leads to a migration, the step is wrong — re-read
  `feature-description.md`."* Depois preencha `New Tables`, `Modified Tables` e
  `Seed Data` com `None.` mesmo assim. Secao vazia e ambigua; `None.` e decisao.
- Se tem migration, abra com um resumo de uma linha do que muda, e siga com as
  secoes abaixo.

## Estrutura obrigatoria

### Summary
O veredito acima.

### New Tables
Cada tabela nova em formato DBML.

### Modified Tables
So as colunas **novas** adicionadas a uma tabela existente, em DBML. Referencie a
tabela existente pelo nome e deixe claro que sao adicoes apenas.

### Seed Data
Qualquer seed/dado inicial necessario para dado de referencia introduzido pela
feature. `None.` quando nao houver.

### Relationships
Tabela de todos os relacionamentos novos. `None added.` quando a feature so
percorre relacionamentos que ja existem — e diga quais percorre.

### Existing Tables Read
Uma tabela por fonte: qual tabela, quais colunas ou agregados, e sob qual filtro.
Agrupe pela action ou query que le. E o que prova que a feature nao introduz query
que a aplicacao ja nao roda — e e sobre isso que a alegacao "sem query nova" de
uma fase posterior se apoia.

### Tables Written
Toda tabela em que a feature escreve, incluindo tabela de log de atividade, com
quando e o que. Anote explicitamente quando a tabela alvo e o pacote dela ja
existem, pra ninguem migrar de novo.

### Fields Never Exported / Never Exposed
So quando a feature move dado pessoal ou sensivel. Tabela de campo x tratamento:
mascarado, omitido, nunca lido. Nomeie o formato exato do mascaramento.

### Notes / Performance
Decisoes de indice, constraints, e os limites de toda leitura ilimitada (teto de
periodo, paginacao, limite de linhas). Quando uma leitura for genuinamente
ilimitada, diga, e diga por que e aceitavel.

## Convencoes de banco (Laravel)

Ajuste ao que o `CLAUDE.md` / `AGENTS.md` do projeto define. Na ausencia de regra
do projeto, siga estas:

- **Use PHP Enums, nao lookup table.** Cast do enum no model, enum em
  `app/Enums/`. Nao crie tabela auxiliar para campo de status.
- Toda tabela tem `created_by bigint [null, ref: > users.id]` e
  `updated_by bigint [null, ref: > users.id]` — **exceto** tabela de ledger
  imutavel, que tem so `created_by`.
- Tabela de ledger imutavel (transacoes, log de resgate) **nunca** tem coluna
  `updated_at`. So `created_at`.
- Se o projeto e multi-tenant, toda tabela escopada por tenant tem
  `tenant_id bigint [not null, ref: > tenants.id]` com indice em `tenant_id`.
- Dinheiro: `decimal(10,2)` — **nunca** `float`. Se o projeto usa centavos
  inteiros, siga o projeto e diga isso no documento.
- Quantidade inteira e sempre `integer`.
- `varchar(255)` para string padrao, salvo comprimento diferente justificado.
- Nome de coluna de chave estrangeira segue Laravel: `{model}_id`.
- Sempre defina indice explicito para chave estrangeira e para coluna usada em
  `WHERE`.
- **Nunca edite migration ja executada** — sempre adicione outra.
- Ao modificar uma coluna, a migration nova tem que reafirmar **todos** os
  atributos que a coluna ja tinha, ou eles sao descartados.

## Instrucoes

- Inspecione o schema existente primeiro. Nao redefina nada que ja esta la.
- Baseie o schema estritamente em `feature-description.md` e `user-stories.md`.
  Nao adicione tabela para funcionalidade fora de escopo.
- Se uma decisao de design nao for obvia, adicione nota explicando o raciocinio.
- Documento conciso. Sem enchimento.
- Tudo em ingles.
