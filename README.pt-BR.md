# mktux Harness

> 🇺🇸 [Documentation in English](README.md)

Um plugin para **Claude Code** e **Codex CLI** que leva um projeto da ideia ao
código rodando de forma estruturada: especificação formal, planejamento em fases,
e execução autônoma com validação mecânica — mantendo um humano no controle em
cada ponto de decisão.

Um repositório, dois engines, zero arquivo copiado para dentro dos seus projetos.

---

## Índice

- [O problema](#o-problema)
- [Como funciona](#como-funciona)
- [Instalação](#instalação)
- [Começando: um exemplo real, do zero ao commit](#começando-um-exemplo-real-do-zero-ao-commit)
- [O pipeline em detalhe](#o-pipeline-em-detalhe)
- [O ralph em detalhe](#o-ralph-em-detalhe)
- [Hooks e telemetria](#hooks-e-telemetria)
- [O que seu projeto precisa ter](#o-que-seu-projeto-precisa-ter)
- [Referência de comandos](#referência-de-comandos)
- [Diagnóstico](#diagnóstico)
- [O que tem na caixa](#o-que-tem-na-caixa)
- [Créditos](#créditos)

---

## O problema

Você pede uma feature grande a um agente. Ele começa bem, e lá pela metade
reescreve uma tela que já funcionava, inventa uma migration que ninguém pediu, ou
declara "implementado" algo que não existe. Você descobre três dias depois.

A causa não é o modelo. É que **uma feature inteira não cabe numa sessão**, e
sessão longa perde o contexto do que não pode ser tocado.

O mktux Harness ataca isso com duas ideias:

1. **Especificação antes de código.** Quatro artefatos versionados que registram
   decisões — inclusive as negativas, o que *não* pode mudar. Cada um carimba de
   qual versão do anterior nasceu, então você sabe quando um ficou velho.

2. **Uma sessão fria por fase, e quatro portões mecânicos.** O `ralph` quebra o
   plano em fases, roda cada uma numa sessão nova e isolada, e só considera a fase
   pronta quando ela passa por quatro verificações — nenhuma delas sendo "o agente
   disse que terminou".

---

## Como funciona

```
  feature-brief.md          você escreve, na mão, em português
        │                   ← o campo "o que NÃO pode mudar" é o mais importante
        ▼
  /mktux:plan <slug>        roteador: mostra o estado e avança UM passo
        │
        ├──▶ 1. feature-description.md    escopo, regras, o que é reusado
        ├──▶ 2. user-stories.md           critérios testáveis, ids US-N.N
        ├──▶ 3. database-schema.md        DBML, ou "esta feature não tem migration"
        └──▶ 4. project-phases.md         o plano que o ralph executa
        │
        ▼
  ralph docs/features/<slug>/project-phases.md
        │
        ├── Fase 1 ─▶ sessão fria ─▶ gate 0 ─ 1 ─ 2 ─ 3 ─▶ commit
        ├── Fase 2 ─▶ sessão fria ─▶ gate 0 ─ 1 ─ 2 ─ 3 ─▶ commit
        └── Fase N ─▶ ...
        │
        ▼
  /mktux:review-phases N    convenções + auditoria de segurança do commit
```

Cada seta para baixo é uma decisão sua. O harness nunca pula duas etapas de uma
vez, e nunca começa a escrever código sem um plano que você leu.

### Os quatro portões

Uma fase só vira commit quando passa por todos. **Nenhum deles é o exit code do
agente.**

| Portão | O que verifica | Reprova? |
|---|---|---|
| **0** | a engine terminou de verdade, sem erro de protocolo | sim |
| **1** | a sessão escreveu código? É **sinal**, não veredito — uma fase já implementada corretamente não escreve nada | não |
| **2** | a suite de testes do projeto, rodada **pelo ralph**, fora da sessão do agente | sim |
| **3** | um verificador independente, read-only, que julga **task por task** | sim |

O portão 3 é o que segura a mentira. Ele roda numa sessão separada, com modelo
barato, com acesso só a `Read`, `Glob` e `Grep` — **sem Bash, sem shell, sem
git**. Para cada task do plano ele emite exatamente uma linha:

```
TASK 1: DONE
TASK 2: INCOMPLETE — CsvDocument has no render() method
TASK 3: NOT-CODE — needs a human to run `sail npm run build`
```

`INCOMPLETE` reprova a fase e dispara um ciclo de correção. `NOT-CODE` não
reprova — vira pendência manual no relatório.

---

## Instalação

São três passos. O primeiro e o segundo você faz uma vez por máquina; o terceiro
também.

### 1. Claude Code

```bash
# no prompt do Claude Code, não no terminal
/plugin marketplace add markintux/mktux-harness
/plugin install mktux@mktux-harness
```

Confirme:

```
/plugin
```

Deve listar `mktux` como *installed, enabled*. Os comandos ficam sob o namespace
`/mktux:` — `/mktux:plan`, `/mktux:ralph`, `/mktux:review-phases`.

### 2. Codex CLI

```bash
# no terminal
codex plugin marketplace add markintux/mktux-harness
codex plugin add mktux@mktux-harness
```

Confirme:

```bash
codex plugin list
```

O Codex não tem slash commands de plugin. Lá o harness aparece como **skills** —
você pede em linguagem natural ("gere o plano de fases da feature X") e a skill
correspondente carrega.

### 3. `ralph` no PATH

Nem o Claude Code nem o Codex expõem binário de plugin no PATH. O harness gera um
wrapper que resolve o caminho do plugin em tempo de execução — assim
`plugin update` atualiza o `ralph` junto, sem você rodar nada de novo.

```bash
# Claude Code (dentro de uma sessão, a variável já existe)
bash "$CLAUDE_PLUGIN_ROOT/scripts/mktux-setup.sh"

# Codex
bash "$PLUGIN_ROOT/scripts/mktux-setup.sh"
```

Não sabe onde o plugin caiu? Ache:

```bash
ls -d ~/.claude/plugins/*/mktux*/scripts 2>/dev/null
ls -d ~/.codex/plugins/cache/*/mktux*/*/scripts 2>/dev/null
```

Saída esperada:

```
mktux-harness — instalando comandos:
  instalado: /Users/você/.local/bin/ralph
  instalado: /Users/você/.local/bin/ralph-watch

PATH ok. Teste com: ralph --help
```

Se avisar que `~/.local/bin` não está no PATH, adicione ao `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Abra um terminal novo e confirme:

```bash
ralph --help
```

### Pré-requisitos das engines

```bash
# Codex (engine default do ralph)
npm install -g @openai/codex
export OPENAI_API_KEY=...

# Claude
npm install -g @anthropic-ai/claude-code
export ANTHROPIC_API_KEY=...
```

### Desenvolvendo o próprio harness

Para apontar o `ralph` para um clone seu em vez do plugin instalado:

```bash
export MKTUX_HARNESS_ROOT=~/Documents/Code/ai/mktux-harness/plugins/mktux-harness
```

---

## Começando: um exemplo real, do zero ao commit

Vamos construir uma feature de verdade: **exportar a lista de clientes em CSV**,
num SaaS Laravel multi-tenant, com o export limitado ao plano Business.

### Passo 0 — o brief

Nenhuma skill escreve esse arquivo. Você escreve, em português, com suas palavras.

```bash
mkdir -p docs/features/customer-export
```

Peça o template ao harness:

```
/mktux:plan customer-export
```

Como o brief não existe, o roteador copia o template e para. Abra
`docs/features/customer-export/feature-brief.md` e preencha:

```markdown
# Feature Brief — Exportar clientes

## O que é essa feature?

Quero um botão na listagem de clientes que baixa um CSV com os clientes daquele
tenant, respeitando os filtros que a pessoa já aplicou na tela.

## Por que estamos construindo isso?

O dono do bar pede a lista pro contador todo mês e hoje copia da tela na mão.

## O que DEVE entrar nessa feature?

- Botão "Exportar CSV" na listagem de clientes
- O CSV respeita busca e filtro de período já aplicados na tela
- Colunas: nome, e-mail, telefone, data de cadastro, total gasto

## O que NÃO entra nessa feature (por hora)?

- Export em Excel/xlsx
- Export agendado por e-mail

## O que NÃO pode mudar de comportamento?

- A listagem de clientes em si: paginação, busca e ordenação continuam idênticas
- O cálculo de "total gasto" — já existe e é usado no dashboard

## Regras de negócio que você já sabe?

- Só plano Business exporta. Starter e Pro veem o botão desabilitado com upgrade.
- CPF nunca sai no arquivo.

## Quem usa essa feature?

- [x] admin (dono)
- [ ] atendente

## Mexe em dado pessoal?

- [x] Sim — nome, e-mail, telefone
- Sai do sistema em arquivo? sim
```

> A seção **"O que NÃO pode mudar de comportamento"** é a que mais trabalha.
> Ela vira o bloco `Do not touch` que o harness repete dentro de cada fase — é o
> que impede uma sessão cega de reescrever a listagem que já funciona.

### Passo 1 — a descrição da feature

```
/mktux:plan customer-export
```

Agora o roteador mostra o estado e avança um passo:

```
| Artefato                 | Estado                    |
|--------------------------|---------------------------|
| feature-brief.md         | presente (manual)         |
| feature-description.md   | ausente                   |
| user-stories.md          | ausente                   |
| database-schema.md       | ausente                   |
| project-phases.md        | ausente                   |

Invocando plan-feature-description: primeiro artefato ausente da cadeia.
```

A skill lê o brief, **inspeciona o codebase** (models, rotas, policies, o
`PlanConfig` que já existe) e escreve
`docs/features/customer-export/feature-description.md` em inglês, com as seções
`Scope`, `Business Rules` numeradas, `What exists and is reused`, `Data & Format
Decisions` (encoding, separador, nome do arquivo), e `Out of Scope`.

Se o brief for ambíguo em algo que muda o desenho, a skill **pergunta** com
AskUserQuestion antes de escrever. Ela não resolve bifurcação real com chute.

Leia o resultado. É o momento mais barato de corrigir rumo.

### Passo 2 — as user stories

```
/mktux:plan customer-export
```

O roteador vê a descrição pronta e avança sozinho para `plan-user-stories`. Sai
`user-stories.md` com ids estáveis:

```markdown
**US-1.1** — As an owner on a **Business** plan, I want to download the customer
list filtered exactly as I see it on screen, so I can hand it to my accountant.

- Given I am on `/customers?search=maria&from=2026-01-01`
- When I click "Exportar CSV"
- Then a file named `clientes-2026-01-01-a-2026-08-26.csv` downloads
- And it contains the same rows, in the same order, the table renders
- And no column contains a CPF

**US-3.1** — As an owner on a **Starter** plan, I want to understand why I cannot
export, so I know what to upgrade to.

- Given I am on `/customers` on a Starter plan
- When I look at the export button
- Then it is disabled with an upgrade tooltip
- And a direct POST to `customers.export` returns 403
```

Esses ids viram **interface pública**: cada teste no plano de fases vai citar
quais stories cobre.

### Passo 3 — o schema

```
/mktux:plan customer-export
```

Essa feature não cria tabela. A skill **não** gera um documento vazio — ela abre
com o veredito:

```markdown
## Summary

**This feature adds no migration.** It reads from existing tables only.
If any step of the implementation leads to a migration, the step is wrong —
re-read `feature-description.md`.

## New Tables
None.

## Modified Tables
None.
```

Isso não é burocracia. Uma sessão fria que não consegue dizer se a feature tem
migration **vai inventar uma**.

### Passo 4 — o plano de fases

```
/mktux:plan customer-export
```

Aqui mora o valor do harness. Sai `project-phases.md` no contrato exato que o
`ralph` executa:

```markdown
## Phase 2: Export action and plan gate

**Goal:** Build the CSV export action behind a Business-plan gate.

**Read first:** `feature-description.md` next to this file, section
"Data & Format Decisions".

**Do not touch in this phase:** `CustomerListController`, the customer index
Blade view, and `CustomerTotalSpentQuery` — the list, its pagination and the
total-spent calculation must behave exactly as before.

**Conventions here, to follow rather than "fix":** actions live in
`app/Actions/Customer/`, one class per use case, constructor property promotion.

**This phase has exactly 4 tasks.** Emit one verdict line per task, numbered 1 to
4 in the order they appear. The sub-bullets under "Automated tests to generate"
are part of the task above them, not tasks of their own.

**Tasks:**
- [ ] Create `App\Actions\Customer\ExportCustomersAction` returning a
      `CsvDocument`, reading through the existing `CustomerQuery`.
  - accepts the same filter DTO the list screen already builds
  - never selects the `cpf` column
- [ ] `App\Policies\CustomerPolicy` gains an `export` ability that returns false
      unless the tenant's plan is Business.
- [ ] Register `POST /customers/export` as `customers.export`, behind the
      `auth` and `tenant` middleware, declared **before** the
      `customers/{customer}` wildcard route.
  - a cold session will otherwise append it at the end, where the wildcard
    swallows the literal segment
- [ ] No file under `app/`, `routes/` or `resources/views/` references the
      identifier `cpf` in the export path.

  Automated tests to generate:
    - `tests/Feature/Customer/ExportCustomersTest.php` — Business downloads,
      filters respected, CPF absent (US-1.1)
    - `tests/Feature/Customer/ExportCustomersPlanGateTest.php` — Starter and Pro
      get 403 on direct POST (US-3.1)

**Completion criteria:** `ExportCustomersAction` exists and is covered.
`tests/Feature/Customer/CustomerListTest.php` still passes **unmodified** — if it
needs editing to go green, the list behavior changed and must be corrected
instead.

---
```

Note três coisas, todas deliberadas:

1. **A fase repete os próprios guards.** O `Do not touch` está dentro da fase, não
   num preâmbulo — porque o `ralph` descarta tudo que não está entre headings de
   fase. Preâmbulo é invisível para o agente.

2. **A última task é um estado, não um comando.** "No file references `cpf`" o
   verificador consegue checar com Grep. "Confirme com `grep -rn cpf app/`" ele
   não consegue — sai `NOT-CODE` e vira pendência manual.

3. **A contagem de tasks está declarada.** O `ralph` conta com `grep`, o
   verificador conta lendo. Se divergirem, a fase é reprovada mesmo com tudo
   verde. Num run real isso custou dois ciclos e 30 minutos.

**Leia esse arquivo com atenção.** É o último ponto barato de correção. Depois
daqui, cada erro custa uma sessão.

### Passo 5 — executar

Árvore de trabalho limpa, Sail de pé:

```bash
git status --short          # tem que estar vazio
vendor/bin/sail up -d

ralph docs/features/customer-export/project-phases.md
```

Com painel ao vivo neste terminal:

```bash
ralph docs/features/customer-export/project-phases.md --dashboard
```

Ou o painel num terminal separado, enquanto o run corre no primeiro:

```bash
ralph-watch
```

Trocando de engine e modelo:

```bash
ralph docs/features/customer-export/project-phases.md --engine claude --effort high
```

O run vai fase a fase. A cada fase: sessão fria → 4 portões → commit. Se uma fase
reprovar, ele abre um ciclo de correção com a causa (até 3 por default) e, se
esgotar, para — a menos que você passe `--keep-going`.

Retomando da fase 3, depois de corrigir o plano na mão:

```bash
ralph docs/features/customer-export/project-phases.md --from 3
```

> Editar o `project-phases.md` invalida o stamp e zera o progresso. Use `--from N`
> para não re-rodar fase já commitada.

### Passo 6 — revisar

```
/mktux:review-phases 2
```

Sai um relatório com três seções: violações de convenção contra o `CLAUDE.md` do
projeto, auditoria de segurança do subagent `security-auditor`, e as pendências
`NOT-CODE` que o portão 3 deixou para você.

---

## O pipeline em detalhe

Cada artefato carimba na **linha 3** o hash das entradas de que nasceu:

```markdown
# User Stories — Customer Export

<!-- inputs: feature-description.md@sha256:a1b2c3d4e5f6 -->
```

Quando você edita a descrição da feature, o `/mktux:plan` recalcula e avisa:

```
desatualizado: user-stories.md nasceu de uma versão antiga de feature-description.md
```

Re-rodar é **upsert**: a skill entrevista só sobre o delta e renova o carimbo.

| Skill | Produz | Lê |
|---|---|---|
| `plan` | nada (roteador) | o estado da pasta |
| `plan-feature-description` | `feature-description.md` | `feature-brief.md` + codebase |
| `plan-user-stories` | `user-stories.md` | feature-description |
| `plan-database-schema` | `database-schema.md` | description + stories + schema real |
| `plan-project-phases` | `project-phases.md` | os três anteriores + codebase |

Para mudar a raiz `docs/features/`, defina `MKTUX_SPEC_DIR`.

---

## O ralph em detalhe

### Invariantes

1. Cada fase **e** cada ciclo de correção roda em **sessão nova**, com prompt
   auto-contido. Nunca reutiliza sessão.
2. Zero perguntas. Do início ao fim sem interação humana.
3. Fase só é "completa" quando passa pelos 4 portões.
4. Bateu limite de uso → espera o reset e re-executa a **mesma** fase, sem
   consumir ciclo de correção.
5. Um commit por fase concluída.

### Flags

| Flag | Efeito |
|---|---|
| `--engine codex\|claude` | engine de implementação (default: `codex`) |
| `--model <nome>` | modelo da engine |
| `--effort <nível>` | codex: `low`..`ultra` · claude: `low`..`max` |
| `--from N` | começa na fase N |
| `--keep-going` | continua após uma fase falhar |
| `--max-cycles N` | ciclos de correção por fase (default: 3) |
| `--no-verify` | desliga o portão 3 |
| `--test-cmd "<cmd>"` | comando de teste do projeto |
| `--dashboard` | painel ao vivo neste terminal |
| `--verbose` | espelha a saída da engine na tela |
| `--no-smoke` | pula o smoke test da engine no preflight |

### Comando de teste (portão 2)

Vence a primeira regra que resolver:

1. `--test-cmd "<cmd>"`
2. `RALPH_TEST_CMD`
3. detecção por manifest:

| Detectado | Comando |
|---|---|
| Laravel Sail (`artisan` + `vendor/bin/sail`) | `vendor/bin/sail test` |
| `composer.json` com `scripts.test` | `composer test` |
| `artisan` | `php artisan test` |
| `package.json` com `scripts.test` | `npm test` |
| `pytest.ini` / `pyproject [tool.pytest]` | `pytest` |
| `go.mod` | `go test ./...` |
| `Cargo.toml` | `cargo test` |

4. nada resolvido → aviso alto e portão 2 pulado (o portão 3 segura sozinho)

Sail tem precedência sobre `composer test`, porque a suite roda no container.
Containers parados → abort no preflight: todo portão 2 falharia e queimaria os
ciclos de correção à toa.

### Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `RALPH_TEST_CMD` | comando do portão 2 |
| `RALPH_VERIFY` | `always` (default) / `auto` / `off` |
| `RALPH_VERIFY_MODEL` | modelo das sessões auxiliares |
| `RALPH_VERIFY_EFFORT` | esforço dessas sessões |
| `RALPH_MAX_CYCLES` | ciclos de correção por fase |
| `RALPH_MAX_LIMIT_WAITS` | esperas consecutivas por limite, por fase |
| `RALPH_SMOKE` | `0` desliga o smoke test |
| `RALPH_MEM0` / `RALPH_MEM0_USER` | resumo por fase no mem0. **Desligado** enquanto `RALPH_MEM0_USER` não for definida |
| `RALPH_VERBOSE` | `1` espelha a saída da engine |
| `RALPH_DASHBOARD` | `1` liga o painel embutido |
| `MKTUX_SPEC_DIR` | raiz dos specs (default `docs/features`) |
| `MKTUX_HARNESS_ROOT` | usa um clone local em vez do plugin |
| `MKTUX_BIN_DIR` | onde instalar os wrappers (default `~/.local/bin`) |

### Onde o run deixa rastro

```
.phases/
├── phase-NN.md              uma fase por arquivo, gerada pelo split
├── manifest.txt             stamp do input
├── .progress                fases já concluídas
├── state/run.tsv            snapshot do run, lido pelo ralph-watch
└── logs/
    ├── run.log                    log linear do run inteiro
    ├── phase-NN.cycle-M.log       sessão de implementação
    ├── phase-NN.test-M.log        saída do portão 2
    └── phase-NN.verify-M.log      veredito task a task do portão 3
```

`.phases/` é registrado em `.git/info/exclude` automaticamente — o ralph **não
mexe** no `.gitignore` do seu projeto.

---

## Hooks e telemetria

Os hooks vêm do plugin. Não há nada para configurar por projeto.

| Hook | Quando | O que faz |
|---|---|---|
| `sail-guard` | antes de todo Bash | bloqueia comando que rodaria PHP/DB no host quando o projeto usa Sail, e devolve ao agente a forma correta |
| `log-event` | todo evento | grava em `.harness/events.jsonl` com timestamp e branch |
| `pint-and-test` | Claude: após Edit/Write · Codex: no fim do turno | roda Pint e os testes afetados |
| `log-tokens` | fim da sessão | grava consumo por modelo em `.harness/tokens.jsonl`, com campo `vendor` para comparar Claude e Codex no mesmo gráfico |

`pint-and-test` e `log-tokens` existem em **duas versões, uma por engine**, e isso
é proposital: o Codex não tem hook de `Edit`, então roda no `Stop` com detecção
via git e devolve `decision:block`; e lê tokens do rollout em
`~/.codex/sessions/`, enquanto o Claude lê o transcript da sessão. São fontes de
dado diferentes. **Não unifique esses dois.**

Adicione ao `.gitignore` do seu projeto:

```gitignore
/.harness
```

---

## O que seu projeto precisa ter

**Obrigatório**

- Repositório git, com a árvore de trabalho **limpa** quando o ralph rodar.
- `CLAUDE.md` e/ou `AGENTS.md` com as convenções do projeto. As sessões do ralph
  são frias: o que não está ali não existe para elas.
- Suite de testes que roda por um comando só.

**Recomendado**

- `docs/features/` para os specs.
- Laravel: containers do Sail de pé, e um `.env.testing` próprio.

  > ⚠️ Sem `.env.testing`, rodar a suite com `--env=testing` cai no `.env` de
  > desenvolvimento — e um `migrate:fresh` apaga o banco de dev. Confirme que o
  > arquivo existe **antes** do primeiro run.

---

## Referência de comandos

No Claude Code, tudo sob o namespace `/mktux:`. No Codex, peça em linguagem
natural — a skill de mesmo nome carrega.

| Comando | Skill | O que faz |
|---|---|---|
| `/mktux:plan <slug>` | `plan` | roteador: estado da cadeia + avança um passo |
| `/mktux:plan-feature-description <slug>` | `plan-feature-description` | passo 1 |
| `/mktux:plan-user-stories <slug>` | `plan-user-stories` | passo 2 |
| `/mktux:plan-database-schema <slug>` | `plan-database-schema` | passo 3 |
| `/mktux:plan-project-phases <slug>` | `plan-project-phases` | passo 4 |
| `/mktux:ralph` | `ralph` | referência operacional e diagnóstico |
| `/mktux:review-phases N` | `review-phases` | revisa o commit da fase N |
| `/mktux:setup` | `setup` | instala `ralph` no PATH, prepara o projeto |

Subagents (Claude Code): `test-runner` e `security-auditor`.

---

## Diagnóstico

| Sintoma | Causa provável |
|---|---|
| `Contrato de formato violado` no preflight | heading `## Phase` fora de `## Phase N: <título>`. Uma fase com heading torto **some silenciosamente** do run |
| fase reprova com todos os vereditos `DONE` | contagem de tasks divergente. A fase precisa da linha `**This phase has exactly N tasks.**` |
| task sempre `NOT-CODE` | escrita como comando (`rode`, `confirme com git diff`). Reescreva como estado do código |
| fase reprova em todo ciclo até esgotar | task com escape condicional (*"faça X, mas se ficar estranho, deixe"*). Na dúvida, o verificador escolhe INCOMPLETE |
| portão 2 sempre vermelho no primeiro run | Sail parado, ou `.env.testing` ausente |
| o run reinicia da fase 1 depois de você editar o plano | editar o `project-phases.md` invalida o stamp. Use `--from N` |
| `ralph: command not found` | rode o passo 3 da instalação, e confira que `~/.local/bin` está no PATH |
| `mktux-harness: não encontrei ralph.sh` | o plugin não está instalado nessa máquina, ou aponte `MKTUX_HARNESS_ROOT` para um clone |

Quando uma fase falhar, leia nesta ordem:

1. `.phases/logs/phase-NN.verify-M.log` — o que o verificador reprovou
2. `.phases/logs/phase-NN.test-M.log` — o que a suite reprovou
3. `.phases/logs/phase-NN.cycle-M.log` — o que a sessão tentou fazer

---

## O que tem na caixa

```
mktux-harness/
├── .claude-plugin/marketplace.json     manifesto do Claude Code
├── .codex-plugin/marketplace.json      manifesto do Codex
├── .agents/plugins/marketplace.json    manifesto padrão
└── plugins/mktux-harness/
    ├── .claude-plugin/plugin.json
    ├── .codex-plugin/plugin.json       skills + hooks
    ├── skills/                         ← FONTE ÚNICA, os dois engines leem
    │   ├── plan/                       roteador + template do brief
    │   ├── plan-feature-description/
    │   ├── plan-user-stories/
    │   ├── plan-database-schema/
    │   ├── plan-project-phases/        o contrato do ralph
    │   ├── ralph/                      operação e diagnóstico
    │   ├── review-phases/
    │   └── setup/
    ├── agents/                         só Claude: test-runner, security-auditor
    ├── hooks/
    │   ├── hooks.json                  Claude   (${CLAUDE_PLUGIN_ROOT})
    │   ├── codex-hooks.json            Codex    (${PLUGIN_ROOT})
    │   ├── shared/                     sail-guard, log-event
    │   ├── claude/                     pint-and-test, log-tokens
    │   └── codex/                      pint-and-test, log-tokens
    └── scripts/
        ├── ralph.sh                    o orquestrador
        ├── ralph-watch.sh              painel ao vivo, read-only
        ├── test-ralph.sh               suite do próprio ralph
        └── mktux-setup.sh              instala os wrappers no PATH
```

---

## Créditos

O `ralph.sh`, o `ralph-watch.sh` e o `sail-guard.sh` descendem do
[**Beer and Code Harness**](https://github.com/beerandcodeteam/beer-and-code-harness)
(MIT © Beer and Code). A cadeia `/init` com stamps de frescor e a ideia do
roteador de pipeline também vêm de lá.

Obrigado ao time do Beer and Code pela mentoria e pelo trabalho original.

O contrato dos quatro portões, o veredito `NOT-CODE` do portão 3, a parada por
ciclo sem progresso, o painel `ralph-watch` e as regras de escrita de fase da
skill `plan-project-phases` foram desenvolvidos e endurecidos em runs de produção
neste harness.

Licença: [MIT](LICENSE).
