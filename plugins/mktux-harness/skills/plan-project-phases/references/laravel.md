# Perfil Laravel — project phases

Carregado pela skill `plan-project-phases` quando existe `artisan` na raiz do
projeto. Cada secao completa a parte da skill indicada no titulo. Onde o
`CLAUDE.md` / `AGENTS.md` do projeto define outra coisa, o projeto vence.

## Procedimentos NOT-CODE (Parte 1.6)

Comandos exatos dos procedimentos tipicos num projeto Laravel com Sail:

- formatador: `vendor/bin/sail bin pint --dirty --format agent`;
- build de assets: `vendor/bin/sail npm run build`.

## Caminho de teste no template (Parte 2)

```markdown
  Automated tests to generate:
    - `tests/Feature/[Context]/[Resource]/SomeTest.php` — the scenarios it covers (US-N.N)
```

## Ordem das fases (Parte 3)

1. **Foundations** — enums, flags, classes de suporte compartilhadas, tudo de que
   as fases seguintes dependem
2. **Database** — migrations, models, factories, seeders
3. **Backend core** — policies, actions, services (so quando justificado), form
   requests
4. **Controllers + Routes** — um contexto por vez
5. **Views** — views e componentes Blade, mais `vendor/bin/sail npm run build`
6. **Regression** — formatador, suite completa, e afirmacoes legiveis de que nada
   mais se moveu

## Granularidade de task (Parte 4)

- Para cada task de controller, nomeie o Single Action Controller e a rota que ele
  atende.

## Testes (Parte 5)

Testes sao **PHPUnit** — Feature preferencialmente, Unit so pra logica isolada.
Crie arquivos com `vendor/bin/sail artisan make:test --phpunit {name}`.

O caminho de cada teste fica sob `tests/Feature/` ou `tests/Unit/`.

## Arquivo de referencia (Parte 6)

A instrucao de leitura termina adaptando para Blade/PHP:

```
- Before writing any code, read the full contents of `path/to/reference.html`
  and reproduce its structure faithfully, adapting to Blade/PHP syntax.
```
