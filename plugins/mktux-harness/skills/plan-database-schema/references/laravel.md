# Perfil Laravel — database schema

Carregado pela skill `plan-database-schema` quando existe `artisan` na raiz do
projeto.

## Como inspecionar o schema existente

- Use a ferramenta `database-schema` (Laravel Boost) quando disponivel; senao leia
  as migrations em `database/migrations/`.

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
