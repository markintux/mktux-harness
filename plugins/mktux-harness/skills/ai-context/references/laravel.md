# Perfil Laravel — ai-context

Carregado pela skill `ai-context` quando existe `artisan` na raiz do projeto.
Completa o digest e as regras dos escritores; onde o `CLAUDE.md` / `AGENTS.md`
do projeto define outra coisa, o projeto vence.

## Ambiente de execucao

- Detecte Sail por `vendor/bin/sail` ou pelo pacote `laravel/sail` no
  `composer.json`.
- Quando presente, registre em `execution` o wrapper `vendor/bin/sail`, com as
  evidencias, e prefixe todos os comandos PHP, Artisan, Composer e Node.
- Registre `docker-compose.yml` e o servico `laravel.test` quando existirem.

## Territorio do CLAUDE.md

- O Laravel Boost (`boost:install`) e dono do `CLAUDE.md`.
- Preserve verbatim o bloco `<laravel-boost-guidelines>...</laravel-boost-guidelines>`.
- Se `CLAUDE.md` nao existir, nao o crie; para `CLAUDE_POINTER`, reporte
  `skipped (N/A)` e sugira `vendor/bin/sail artisan boost:install`.
- As guidelines customizadas do Boost ficam em `.ai/guidelines/*.md`. Quando um
  arquivo real existir ali, registre-o como regra do time e cite o caminho
  verbatim; nunca invente `record-rule` ou outro nome de ferramenta.

## Sinais do stack

- Entrypoints: `artisan`, `routes/*.php`, kernels, comandos e scheduler.
- API: rotas, Controllers, FormRequests e Resources.
- Async: queues, Horizon, Redis, SQS e `routes/console.php` / `app/Console`.
- Persistencia: migrations, Eloquent models e config de banco.
- Dominio: Actions, Services, Policies, Enums e state machines.
- Testes: Pest ou PHPUnit; factories e seeders quando existirem.
- Lint: Pint, PHPStan, Rector e configuracoes PHP equivalentes.
