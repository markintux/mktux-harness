# mktux Harness

> 🇺🇸 [Documentation in English](README.md)

Um plugin para **Claude Code** e **Codex CLI** que leva um projeto da ideia ao
código rodando de forma estruturada: especificação formal, planejamento em fases,
e execução autônoma com validação mecânica — mantendo um humano no controle em
cada ponto de decisão.

Um repositório, dois engines, zero arquivo copiado para dentro dos seus projetos.

Um núcleo agnóstico de stack, com perfis para Laravel (Sail), Node.js e Python;
projetos Go e Rust rodam pelo caminho genérico. Veja
[Perfis de stack](#perfis-de-stack).

---

## Índice

- [O problema](#o-problema)
- [Como funciona](#como-funciona)
- [Instalação](#instalação)
- [Começando: um exemplo real, do zero ao commit](#começando-um-exemplo-real-do-zero-ao-commit)
- [O pipeline em detalhe](#o-pipeline-em-detalhe)
- [O ralph em detalhe](#o-ralph-em-detalhe)
- [Hooks e telemetria](#hooks-e-telemetria)
- [Perfis de stack](#perfis-de-stack)
- [Memória de longo prazo (ai-memory)](#memória-de-longo-prazo-ai-memory)
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
  /mktux:plan <slug> "<ideia>"      roteador: mostra o estado e avança UM passo
        │
        ├──▶ 0. feature-brief.md          entrevista → sua intenção, em português
        │                                 ← o campo "o que NÃO pode mudar" é o mais importante
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
| **0** | a engine terminou de verdade, sem erro de protocolo, dentro de `RALPH_SESSION_TIMEOUT` | sim |
| **1** | a sessão escreveu código? É **sinal**, não veredito — uma fase já implementada corretamente não escreve nada | não |
| **2** | a suite de testes do projeto, rodada **pelo ralph**, fora da sessão do agente | sim |
| **3** | um verificador independente, read-only, que julga **task por task** | sim |

O portão 3 é o que segura a mentira. Ele roda numa sessão separada, com modelo
barato. O ralph entrega as tasks da fase já numeradas, mais os arquivos que a
fase alterou como ponto de partida. No Claude ele só tem `Read`, `Glob` e `Grep`
— **sem Bash, sem shell, sem git**; no Codex roda em sandbox read-only, instruído
a não rodar build nem teste. Para cada task do plano ele emite exatamente uma
linha:

```
TASK 1: DONE
TASK 2: INCOMPLETE — CsvDocument has no render() method
TASK 3: NOT-CODE — needs a human to run `sail npm run build`
```

`INCOMPLETE` reprova a fase e dispara um ciclo de correção. `NOT-CODE` não
reprova — vira pendência manual no relatório.

Task que o plano tipa como `- [ ] (manual) …` — rodar o formatador, o build de
assets, conferir num celular de verdade — nunca chega ao verificador. O ralph a
tira da lista numerada, descarta qualquer veredito sobre ela e a lista em
*Pendencias manuais* no fim do run: o checklist de quem abre o PR.

Fase marcada `**Check-only phase**` — o fechamento que só afirma estado — não
abre sessão de cara. O ralph roda os gates 2 e 3 contra HEAD: verde fecha a fase
sem sessão e sem commit; vermelho abre o ciclo 1 como correção, já com o
veredito. Num run real, uma fase assim abriu sessão, não escreveu nada e gastou
2,4M tokens de input para chegar no mesmo veredito.

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

As suites do próprio harness rodam offline, com engines mock e sem gastar token:

```bash
cd plugins/mktux-harness
scripts/test-ralph.sh      # ralph: portões, ciclos, limites, painel, perfis
scripts/test-layout.sh     # manifests, perfis, references das skills, hooks, mktux-profile, guarda do core
```

---

## Começando: um exemplo real, do zero ao commit

Vamos construir uma feature de verdade: **exportar a lista de clientes em CSV**,
num SaaS Laravel multi-tenant, com o export limitado ao plano Business.

### Passo 0 — o brief

Descreva a feature no próprio comando. Você não redige esse documento.

```
/mktux:plan customer-export "exportar a lista de clientes em CSV, só no plano Business"
```

O brief não existe, então o roteador entrega pro `plan-feature-brief`. Ele lê o
codebase **antes** de perguntar qualquer coisa — seu enum de papel, seu gating de
plano, as telas vizinhas à que você citou — e aí entrevista em bloco só sobre o
que não deu pra detectar. Ele insiste numa pergunta em especial: *o que não pode
mudar de comportamento?* Responder "nada" não é aceito enquanto ele não te levar
pelas telas vizinhas que encontrou.

Sai `docs/features/customer-export/feature-brief.md`, em português, preenchido —
sem colchete, sem checkbox por marcar:

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

- admin (dono) — exporta
- atendente — deliberadamente de fora; não vê o botão

## Mexe em dado pessoal?

Sim — nome, e-mail, telefone. Sai do sistema em arquivo: sim.
```

> A seção **"O que NÃO pode mudar de comportamento"** é a que mais trabalha.
> Ela vira o bloco `Do not touch` que o harness repete dentro de cada fase — é o
> que impede uma sessão cega de reescrever a listagem que já funciona.

Prefere escrever na mão? Continua valendo, mesmo arquivo e mesma forma — o
template mora ao lado da skill `plan-feature-brief`. A entrevista é conveniência,
não obrigação.

Mudou de ideia depois? Rode `/mktux:plan-feature-brief customer-export "<o que
mudou>"`. Ele relê o que já existe e pergunta só o delta; aí o carimbo fica
desatualizado e o `/mktux:plan` te manda regenerar o passo 1.

### Passo 1 — a descrição da feature

```
/mktux:plan customer-export
```

Agora o roteador mostra o estado e avança um passo:

```
| Artefato                 | Estado                    |
|--------------------------|---------------------------|
| feature-brief.md         | presente                  |
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
- [ ] `tests/Feature/Customer/ExportCustomersTest.php` (new file) covers these scenarios, one test case each:
  - Business tenant exports → CSV download with one row per customer (US-1.1)
  - export with a name filter → only the matching customers in the CSV (US-1.1)
  - Business tenant exports → header row has no `cpf` column (US-1.1)
- [ ] `tests/Feature/Customer/ExportCustomersPlanGateTest.php` (new file) covers these scenarios, one test case each:
  - Starter tenant POSTs to `customers.export` → 403 (US-3.1)
  - Pro tenant POSTs to `customers.export` → 403 (US-3.1)

**Completion criteria:** `ExportCustomersAction` exists and is covered.
`tests/Feature/Customer/CustomerListTest.php` still passes **unmodified** — if it
needs editing to go green, the list behavior changed and must be corrected
instead.

---
```

Note seis coisas, todas deliberadas:

1. **A fase repete os próprios guards.** O `Do not touch` está dentro da fase, não
   num preâmbulo — porque o `ralph` descarta tudo que não está entre headings de
   fase. Preâmbulo é invisível para o agente.

2. **A última task é um estado, não um comando.** "No file references `cpf`" o
   verificador consegue checar com Grep. "Confirme com `grep -rn cpf app/`" ele
   não consegue — sai `NOT-CODE` e vira pendência manual. Procedimento de
   verdade (formatador, build de assets) entra como `- [ ] (manual) …`, fora do
   portão 3 por construção.

3. **A primeira linha de cada task se sustenta sozinha.** O `ralph` conta os
   checkboxes e entrega ao verificador uma lista numerada com a primeira linha de
   cada task, então o verificador nunca conta lendo. Detalhe vai em sub-bullet
   `-` simples: todo `- [ ]`, em qualquer indentação, vira task com veredito
   próprio.

4. **Cada arquivo de teste é uma task, com lista fechada de cenários.** O
   verificador confere se cada cenário listado tem um caso de teste — e não pede
   nada fora da lista. "Tests prove every precondition" não dá o que fechar: num
   run real ele remontou a própria lista a cada ciclo, e a correção perseguiu um
   alvo que mudava sem o plano mudar.

5. **Regra que atravessa camadas é citada em toda fase onde cai.** "Escreva tudo
   antes de trocar a coluna; se falhar, mantenha a coluna e mostre ao admin um
   erro de validação" é uma cláusula da action *e* uma do controller. Cada fase
   que recebe uma cláusula cita a `BR-NN` e carrega task e cenário para ela. Num
   run real só a fase da action citou a regra: as duas fases passaram nos quatro
   gates, e o upload que falhava ainda chegava ao admin como erro 500. Regra
   que nomeia vários artefatos ("aniversários, recordes e o top 5") tem várias
   cláusulas, então uma faixa como `BR-10 through BR-16` só serve numa fase
   onde cada regra da faixa cai inteira. A auto-checagem do plano imprime o
   texto de cada regra embaixo das fases que a citam, para a lacuna aparecer.

6. **Toda fase fecha com a suíte verde sozinha.** O portão 2 roda a suíte
   inteira depois de cada fase. Fase que muda um contrato existente — lança
   exceção onde antes devolvia valor, muda assinatura — atualiza na mesma fase
   todo chamador que ela quebra, ou deixa a mudança para a fase que os religa. Um
   `Do not touch` nunca cobre chamador que a própria fase quebra: num run real,
   uma fase fez um método recusar o período diário enquanto o chamador dele
   estava proibido até três fases depois, e a sessão ficou sem saída.

O `ralph` lê a linha `Read first:` e os ids que a fase cita, e entrega à sessão
**só esses trechos** — a seção nomeada, a regra `BR-NN`, a story `US-N.N`, a
tabela — mais os caminhos dos documentos, para consulta pontual. Mandar a sessão
"ler os documentos de contexto" fazia 25 de 26 sessões de um run real lerem
todos, inteiros: uns 19k tokens no contexto de todo turno seguinte. Por isso
cite pelo título exato e pelo id: "veja a descrição" não é endereço.

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
manuais — tasks `(manual)` e vereditos `NOT-CODE` — que ficaram para você.

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
3. o **perfil de stack** do diretório de onde o ralph roda
   (`profiles/<nome>/profile.sh`; não sobe diretórios):

| Perfil | Detectado por | Comando |
|---|---|---|
| Laravel | `artisan` | `vendor/bin/sail artisan test --compact` com Sail; senão `composer test` se houver `scripts.test`; senão `php artisan test` |
| Node.js | `package.json` | `npm run check` quando existir; senão `npm test` |
| Python | `pyproject.toml` | `uv run pytest` com `uv.lock`; `poetry run pytest` com `poetry.lock`; senão `pytest` |

4. detecção por manifest:

| Detectado | Comando |
|---|---|
| `composer.json` com `scripts.test` | `composer test` |
| `package.json` com `scripts.test` | `npm test` |
| `pytest.ini` / `pyproject [tool.pytest]` | `pytest`; `uv run pytest` com `uv.lock`; `poetry run pytest` com `poetry.lock` |
| `go.mod` | `go test ./...` |
| `Cargo.toml` | `cargo test` |

5. nada resolvido → aviso alto e portão 2 pulado (o portão 3 segura sozinho)

O perfil também valida o ambiente no preflight — containers parados,
dependências Node.js ausentes ou pytest fora do ambiente do projeto → abort
antes que cada portão 2 queime um ciclo de correção — e acrescenta notas ao prompt de
implementação, incluindo como rodar um teste focado naquela stack. O prompt pede
teste focado durante o trabalho e o comando completo uma vez, no fim: rodar a
suite inteira a cada item custava minutos por item. O comando resolvido chega a
toda sessão como `RALPH_TEST_CMD`,
então o subagent `test-runner` roda exatamente o que o portão 2 roda. Para ver o
que o ralph vai resolver num projeto sem rodar nada:
`bash "$CLAUDE_PLUGIN_ROOT/scripts/mktux-profile.sh" test-cmd`.

### Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `RALPH_TEST_CMD` | comando do portão 2 |
| `RALPH_VERIFY` | `always` (default) / `auto` / `off` |
| `RALPH_VERIFY_MODEL` | modelo das sessões auxiliares |
| `RALPH_VERIFY_EFFORT` | esforço dessas sessões |
| `RALPH_MAX_CYCLES` | ciclos de correção por fase |
| `RALPH_SESSION_TIMEOUT` | segundos que uma sessão de engine pode durar antes de o ralph encerrá-la, com tudo o que ela abriu (default `3600`, `0` desliga). A sessão encerrada reprova no portão 0 com a causa |
| `RALPH_MAX_LIMIT_WAITS` | esperas consecutivas por limite, por fase |
| `RALPH_SMOKE` | `0` desliga o smoke test |
| `RALPH_MEMORY` | `0` desliga a página por fase no [ai-memory](#memória-de-longo-prazo-ai-memory). Sem o binário ou com o servidor fora do ar, desliga sozinha |
| `RALPH_MEMORY_BIN` | binário do ai-memory (default `ai-memory` no PATH) |
| `RALPH_HOOK_ISOLATION` | `0` deixa os hooks do ai-memory rodarem nas sessões do ralph (default `1`: isola). Independente disso, toda sessão Codex que o ralph abre roda com `-c features.memories=false`, para a memória nativa do Codex nunca trazer sessões anteriores para dentro de uma sessão fria |
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
    ├── phase-NN.verify-M.log      sessão do portão 3
    ├── phase-NN.verify-M.last.txt veredito final do portão 3 (Codex)
    └── phase-NN.memory.log        saída do `ai-memory write-page`
```

`.phases/` e `.harness/` (telemetria dos hooks) são registrados em
`.git/info/exclude` automaticamente — o ralph **não mexe** no `.gitignore` do
seu projeto. `.harness/` já versionado aborta o preflight: a telemetria muda a
cada tool call, então entraria no commit de toda fase e o portão 1 veria escrita
em toda sessão.

---

## Hooks e telemetria

Os hooks vêm do plugin. Não há nada para configurar por projeto.

| Hook | Quando | O que faz |
|---|---|---|
| `profile-hook` | antes de todo Bash · Claude: após Edit/Write · Codex: no fim do turno | acha o perfil de stack subindo do diretório do evento e repassa o evento ao script do perfil; sem perfil, não faz nada |
| `log-event` | todo evento | grava em `.harness/events.jsonl` com timestamp e branch |
| `log-tokens` | fim da sessão | grava consumo por modelo em `.harness/tokens.jsonl`, com campo `vendor` para comparar Claude e Codex no mesmo gráfico. Cada subagent ganha linha própria, com `parent` |

Scripts do perfil Laravel (`profiles/laravel/hooks/`), chamados pelo `profile-hook`:

| Script | Evento | O que faz |
|---|---|---|
| `sail-guard` | `pre-bash` | bloqueia comando que rodaria PHP/DB no host quando o projeto usa Sail, e devolve ao agente a forma correta |
| `pint-and-test` | `claude-post-edit` · `codex-stop` | roda Pint e os testes afetados |

`pint-and-test` e `log-tokens` existem em **duas versões, uma por engine**, e isso
é proposital: o Codex não tem hook de `Edit`, então roda no `Stop` com detecção
via git e devolve `decision:block`; e lê tokens do rollout em
`~/.codex/sessions/`, enquanto o Claude lê o transcript da sessão. São fontes de
dado diferentes. **Não unifique esses dois.**

Adicione ao `.gitignore` do seu projeto:

```gitignore
/.harness
```

O ralph exclui `.harness/` sozinho quando roda, mas os hooks gravam ali em toda
sessão, não só nas do ralph: ignore antes do seu primeiro commit.

---

## Perfis de stack

O núcleo do harness — as skills de planejamento, o `ralph`, os quatro portões, os
hooks, os subagents — não conhece stack nenhuma. O que pertence a uma stack mora
num **perfil de stack**: o comando de teste e como checar que o ambiente consegue
rodá-lo, as convenções que uma sessão fria tem que seguir em vez de inventar as
dela, os hooks que protegem o host, e o checklist de segurança da stack.

É essa divisão que deixa um harness só servir Laravel, Node e Python sem diluir
nenhum deles. As regras opinativas do Laravel — PHP Enum em vez de lookup table,
`created_by`/`updated_by`, nunca editar migration já executada, Sail para tudo —
são justamente o que impede a sessão fria de improvisar. Elas continuam
intactas; só passam a carregar onde se aplicam.

### O que um perfil decide

| Onde | Sem perfil | Com o perfil Laravel |
|---|---|---|
| portão 2 do ralph — comando de teste | detecção por manifest | `vendor/bin/sail artisan test --compact` com Sail; senão `composer test`; senão `php artisan test` |
| preflight do ralph | — | containers do Sail parados → abort antes da primeira sessão |
| prompt de implementação do ralph | o comando de teste | + "artisan, composer, php e testes rodam DENTRO do container" |
| hook antes de todo Bash | não faz nada | `sail-guard` bloqueia PHP/DB no host e devolve a forma via Sail |
| hook após edição (Claude) / fim do turno (Codex) | não faz nada | `pint-and-test`: Pint na mudança, depois os testes afetados |
| `plan-database-schema` | seu `CLAUDE.md`/`AGENTS.md` e o schema existente | + as convenções de banco do Laravel |
| `plan-project-phases` | seus comandos, framework de teste e layout | + comandos Sail, PHPUnit e caminhos `tests/Feature`, a ordem de fases do Laravel, Single Action Controllers, Blade |
| subagent `test-runner` | o comando resolvido | + sintaxe de arquivo/filtro do artisan, nunca no host, o erro exato "Sail is not running" |
| `security-auditor` / `review-phases` | o checklist web genérico | + `route:list`, FormRequest, `$fillable`, `$request->all()`, `@csrf`, Actions sem ler `request()` |

O `CLAUDE.md` / `AGENTS.md` do seu projeto sempre vence o perfil: se o Boost diz
que o projeto usa Pest, o plano usa Pest.

### Como um perfil é detectado

Um perfil vale quando o marcador dele está presente: `artisan` para Laravel,
`package.json` para Node.js e `pyproject.toml` para Python. Perfis mais
específicos vencem; o detector Node.js não assume uma raiz que também tenha o
marcador Laravel ou Python.

- O **ralph** olha só o diretório de onde roda: os caminhos que o perfil devolve
  (`vendor/bin/sail`) são relativos a essa raiz.
- **Hooks e subagents** sobem a partir do diretório atual, então um app Laravel
  numa subpasta de monorepo continua protegido enquanto você trabalha dentro dele.
- As **skills** procuram, na raiz do projeto, os marcadores da tabela de perfis
  delas (`artisan` → `references/laravel.md`) e carregam o reference que casar.

Para ver o que vale num projeto, sem rodar nada:

```bash
P="$CLAUDE_PLUGIN_ROOT"                          # Codex: $PLUGIN_ROOT
bash "$P/scripts/mktux-profile.sh" name          # laravel, node, python — ou exit 1
bash "$P/scripts/mktux-profile.sh" test-cmd      # o que o portão 2 e o test-runner rodam
bash "$P/scripts/mktux-profile.sh" notes test-runner
```

### Perfis Node.js e Python

- **Node.js:** prefere o gate completo `scripts.check` do projeto e cai para
  `npm test`; exige `node`, `npm`, o major declarado em `.node-version` /
  `.nvmrc` e dependências instaladas. As notas do
  `test-runner` preservam o separador `--` do npm e nunca trocam scripts por
  `npx` ou binário global.
- **Python:** preserva o wrapper do ambiente (`uv run`, `poetry run` ou o
  ambiente ativo), confere que pytest já está disponível sem instalar nada e
  aponta `uv sync --extra dev` quando o projeto declara pytest nesse extra.

Os dois perfis param de propósito na mecânica de teste/lint. Não impõem
framework, layout de diretório, banco ou arquitetura web.

### Projetos sem perfil (Go, Rust e outros)

Rodam pelo caminho genérico — o harness inteiro, menos as regras da stack:

- o portão 2 e o `test-runner` usam a detecção por manifest (veja
  [Comando de teste](#comando-de-teste-portão-2)): `go test ./...`,
  `cargo test` ou um script de manifest suportado. Sobreponha com `--test-cmd`
  ou `RALPH_TEST_CMD`;
- as skills de planejamento seguem só o seu `CLAUDE.md` / `AGENTS.md` e o código
  que existe — então é lá que suas convenções vão;
- o `security-auditor` aplica o checklist web genérico;
- os hooks de stack não fazem nada.

O `test-runner` nunca prepara ambiente: não instala dependência, não sincroniza
virtualenv, não sobe serviço. Dependência faltando volta como uma linha
`ERROR:` dizendo o que preparar (num projeto uv, `uv sync --extra dev`).

### Onde um perfil mora

```
plugins/mktux-harness/
├── profiles/laravel/
│   ├── profile.sh                 detecção, comando de teste, preflight, notas do prompt, mapa de hooks
│   ├── agents/test-runner.md      notas que só o test-runner lê
│   └── hooks/                     sail-guard, pint-and-test
├── profiles/node/
│   ├── profile.sh                 gate npm, preflight de dependências, notas do prompt
│   └── agents/test-runner.md      regras de argumentos npm e gate completo
├── profiles/python/
│   ├── profile.sh                 comando pytest, preflight do ambiente, notas do prompt
│   └── agents/test-runner.md      regras de arquivo/filtro pytest e wrapper
├── skills/<skill>/references/laravel.md
│                                  convenções que uma skill carrega (schema, fases, segurança)
└── scripts/
    ├── lib/profile.sh             o contrato, a detecção, o fallback por manifest
    └── mktux-profile.sh           o perfil, respondido para os subagents
```

Convenção que uma skill carrega mora **ao lado da skill**, não em `profiles/`: é
o único caminho que o Claude Code e o Codex resolvem os dois. Um subagent que
precisa do mesmo texto (o checklist de segurança) lê de lá.

### Criando um perfil

Um perfil é um `profiles/<nome>/profile.sh` que define cinco funções (o contrato
está em `scripts/lib/profile.sh`):

| Função | Responde |
|---|---|
| `profile_detect <dir>` | este perfil vale para `<dir>`? |
| `profile_test_cmd` | o comando de teste default, a partir da raiz do projeto |
| `profile_preflight <cmd>` | o ambiente consegue rodar `<cmd>`? `exit 1` com mensagem se não |
| `profile_prompt_notes` | linhas extras para o prompt de implementação do ralph |
| `profile_hook <evento>` | o script de `pre-bash`, `claude-post-edit` ou `codex-stop`, se houver |

Depois, conforme a stack pedir: scripts de hook em `profiles/<nome>/hooks/`,
notas de subagent em `profiles/<nome>/agents/`, e um `references/<nome>.md` ao
lado de cada skill que deve carregar convenções da stack, mais uma linha na
tabela de perfis dessa skill. As skills `ralph` e `setup` ganham um heading na
seção *Perfis de stack* de cada uma.

Nome de stack fica fora do núcleo. O `scripts/test-layout.sh` falha quando uma
skill, agent, hook ou script cita uma stack fora de `profiles/`, do reference de
perfil de uma skill, ou de um bloco de registro — a cerca em que ficam toda
tabela de perfis e toda seção *Perfis de stack*:

```markdown
<!-- perfis -->
| Perfil | Marcador na raiz | Reference |
|---|---|---|
| Laravel | `artisan` | `references/laravel.md` |
<!-- /perfis -->
```

Ele também checa que todo hook, reference e arquivo de notas que um perfil
aponta existe, e que todo reference citado num bloco de registro tem seu
`profiles/<nome>/`. A skill `ai-context` carrega do reference correspondente as
regras específicas de wrapper e posse, então seu núcleo entra na mesma guarda.

### Atualizando a partir da 0.3

Nada muda nos seus projetos. O que passa a se comportar diferente:

- **Hooks** passam pelo `profile-hook`, que chama os scripts Laravel só em
  projeto Laravel. Os outros projetos deixam de rodar `sail-guard` e
  `pint-and-test`.
- O **`test-runner`** resolve o comando em vez de ter `sail artisan test` fixo.
  Dentro de um run do ralph ele recebe o comando do portão 2 por
  `RALPH_TEST_CMD`, então os dois sempre concordam.
- As **skills de planejamento** param de empurrar convenções Laravel em projetos
  Node e Python. Num projeto Laravel os planos saem iguais — conferido em A/B numa
  feature real.
- O **`review-phases` no Codex** passa a auditar com o checklist de segurança do
  Laravel, em vez de um "agente equivalente" não especificado.
- Projetos **Python** com `uv.lock` ou `poetry.lock` passam a rodar
  `uv run pytest` / `poetry run pytest`, em vez de um `pytest` puro que falhava no
  host.
- **Node.js e Python** agora são perfis de primeira classe, com preflight de
  dependências, notas de implementação e sintaxe própria do runner.
- O **`ai-context`** não assume mais wrapper de container nem ferramenta dona do
  arquivo no núcleo; o contrato Laravel só carrega quando `artisan` casa.
- Um plugin instalado no **escopo de projeto** não acompanha o update do escopo
  de usuário. Liste as instalações com `claude plugin list` e atualize cada uma de
  escopo de projeto de dentro do projeto:
  `claude plugin update mktux@mktux-harness -s project`.

---

## Memória de longo prazo (ai-memory)

A memória do harness é o [ai-memory](https://github.com/akitaonrails/ai-memory):
um servidor local (`127.0.0.1:49374`), com a memória numa wiki markdown
versionada em git e hooks no Claude Code e no Codex. Ele é **opcional**: sem
ele, o ralph roda igual.

### Instalar (macOS, uma vez por máquina)

```bash
# binário nativo (Apple Silicon; Intel: troque aarch64 por x86_64)
mkdir -p ~/Applications/ai-memory && cd ~/Applications/ai-memory
gh release download -R akitaonrails/ai-memory -p 'ai-memory-macos-aarch64.tar.gz*'
shasum -a 256 -c ai-memory-macos-aarch64.tar.gz.sha256
tar -xzf ai-memory-macos-aarch64.tar.gz && ./ai-memory init
ln -sf "$PWD/ai-memory" ~/.local/bin/ai-memory

# servidor como serviço de login (launchd), em 127.0.0.1:49374
mkdir -p ~/Library/Logs/ai-memory
sed -e "s|__AI_MEMORY_BIN__|$PWD/ai-memory|" -e "s|__HOME__|$HOME|" \
  packaging/launchd/com.github.akitaonrails.ai-memory.plist \
  > ~/Library/LaunchAgents/com.github.akitaonrails.ai-memory.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.github.akitaonrails.ai-memory.plist

# hooks + MCP nas duas engines
ai-memory install-hooks --agent claude-code --project-strategy repo-root --apply
ai-memory install-hooks --agent codex       --project-strategy repo-root --apply
ai-memory install-mcp   --client claude-code --apply
ai-memory install-mcp   --client codex       --apply
```

- **Codex:** hook novo só roda depois de confiado. Abra o `codex` uma vez e
  escolha *Trust all* em `/hooks`.
- **`install-mcp --client codex` falhando com `invalid inline table`:** o
  parser TOML do ai-memory não aceita tabela inline multilinha (TOML 1.1) no
  seu `~/.codex/config.toml`. Adicione à mão:

  ```toml
  [mcp_servers.ai-memory]
  url = "http://127.0.0.1:49374/mcp"
  default_tools_approval_mode = "approve"
  ```

### O que o ralph faz com ele

- **Uma página por fase.** Depois do commit, o ralph roda `ai-memory
  write-page` e grava `ralph/<feature>/phase-NN.md` (tier `episodic`, tags
  `ralph` e `<feature>`). A página leva o SHA do commit, a engine, os ciclos,
  os arquivos alterados e o plano da fase. É um POST determinístico: não usa
  LLM nem abre sessão extra, e vale nas duas engines. Rodar de novo com
  `--from` atualiza a página em vez de duplicar.
- **Sessões isoladas dos hooks do ai-memory.** O `SessionStart` do ai-memory
  consome o handoff pendente (o GET é destrutivo) e o injeta como contexto.
  Sem isolamento, a fase 1 comeria o handoff que *você* deixou, cada sessão
  receberia o "onde parou" da anterior e o juiz do portão 3 deixaria de ser
  independente. Quando o preflight acha os hooks na config de usuário, toda
  sessão do ralph (smoke, implementação, portão 3) roda sem eles:
  - **Claude:** `--setting-sources project,local` mais `--settings` com o seu
    `settings.json` *menos* os hooks do ai-memory. Modelo, effort, plugins e
    os seus outros hooks continuam.
  - **Codex:** `-c hooks.state={...={enabled=false}}` só nos handlers do
    ai-memory. A confiança dos outros hooks continua.
  - Precisa de `jq`. Hooks do ai-memory instalados na config de **projeto**
    não são detectados.
- **Falha aberta.** Sem o binário, a memória desliga em silêncio. Com o
  servidor fora do ar, o preflight avisa. Se a escrita falhar, a fase avisa e
  segue válida. Memória é registro, não portão.

Para consultar depois, peça ao agente "busque na memória a fase 3 da feature
X" (MCP `memory_query`), ou rode `ai-memory search "..."`.

### `/mktux:ai-context` e o bloco do ai-memory

O `ai-memory install-instructions` grava um bloco
`<!-- ai-memory:start -->…<!-- ai-memory:end -->` no `CLAUDE.md`/`AGENTS.md`.
O `/mktux:ai-context` trata esse bloco como externo: preserva o bloco
intacto ao regenerar o `AGENTS.md` e nunca o semeia como conteúdo escrito à
mão.

---

## O que seu projeto precisa ter

**Obrigatório**

- Repositório git, com a árvore de trabalho **limpa** quando o ralph rodar.
- `CLAUDE.md` e/ou `AGENTS.md` com as convenções do projeto. As sessões do ralph
  são frias: o que não está ali não existe para elas.
- Suite de testes que roda por um comando só — detectado sozinho (veja
  [Perfis de stack](#perfis-de-stack)), ou definido com `--test-cmd` /
  `RALPH_TEST_CMD`.

**Recomendado**

- `docs/features/` para os specs.
- Perfil Laravel: containers do Sail de pé, e um `.env.testing` próprio.

  > ⚠️ Sem `.env.testing`, rodar a suite com `--env=testing` cai no `.env` de
  > desenvolvimento — e um `migrate:fresh` apaga o banco de dev. Confirme que o
  > arquivo existe **antes** do primeiro run.

- Outras stacks: o ambiente de desenvolvimento preparado uma vez (`npm install`,
  `uv sync --extra dev`, ...). O ralph e o `test-runner` rodam os testes; nunca
  instalam nada.

---

## Referência de comandos

No Claude Code, tudo sob o namespace `/mktux:`. No Codex, peça em linguagem
natural — a skill de mesmo nome carrega.

| Comando | Skill | O que faz |
|---|---|---|
| `/mktux:plan <slug> "<ideia>"` | `plan` | roteador: estado da cadeia + avança um passo |
| `/mktux:plan-feature-brief <slug> "<ideia>"` | `plan-feature-brief` | passo 0: entrevista → `feature-brief.md` |
| `/mktux:plan-feature-description <slug>` | `plan-feature-description` | passo 1 |
| `/mktux:plan-user-stories <slug>` | `plan-user-stories` | passo 2 |
| `/mktux:plan-database-schema <slug>` | `plan-database-schema` | passo 3 |
| `/mktux:plan-project-phases <slug>` | `plan-project-phases` | passo 4 |
| `/mktux:ralph` | `ralph` | referência operacional e diagnóstico |
| `/mktux:review-phases N` | `review-phases` | revisa o commit da fase N |
| `/mktux:setup` | `setup` | instala `ralph` no PATH, prepara o projeto |
| `/mktux:ai-context [caminho] [+id] [-id] [--adopt]` | `ai-context` | gera/atualiza `AGENTS.md` + `docs/agents/*.md` a partir do codigo implementado |

Subagents (Claude Code): `test-runner`, `security-auditor`, `ai-context-inspector`,
`ai-context-core`, `ai-context-docs`.

---

## Diagnóstico

| Sintoma | Causa provável |
|---|---|
| `Contrato de formato violado` no preflight | heading `## Phase` fora de `## Phase N: <título>`. Uma fase com heading torto **some silenciosamente** do run |
| portão 3 reprova por `cobertura incompleta` ou índice fora da faixa | o verificador ignorou a lista numerada do prompt. Leia o veredito (`verify-M.last.txt` no Codex, `verify-M.log` no Claude); se repetir, troque `RALPH_VERIFY_MODEL` |
| preflight aborta com `.harness/ esta versionado` | a telemetria foi commitada. `git rm -r --cached .harness` e commit |
| task sempre `NOT-CODE` | escrita como comando (`rode`, `confirme com git diff`). Reescreva como estado do código, ou marque `(manual)` se for mesmo procedimento |
| fase de fechamento reprova sem nada de errado no código | task de procedimento sem `(manual)`: o verificador tenta julgar o que não tem como ler. Marque `(manual)` |
| fase reprova em todo ciclo até esgotar | task com escape condicional (*"faça X, mas se ficar estranho, deixe"*). Na dúvida, o verificador escolhe INCOMPLETE |
| portão 2 sempre vermelho no primeiro run | Laravel: Sail parado, ou `.env.testing` ausente. Outras stacks: o ambiente de desenvolvimento nunca foi preparado (dependências, virtualenv) |
| o ralph ou o `test-runner` escolhe o comando de teste errado | confira com `mktux-profile.sh test-cmd` (veja [Perfis de stack](#perfis-de-stack)); sobreponha com `--test-cmd` ou `RALPH_TEST_CMD` |
| o `test-runner` devolve `ERROR:` de dependência faltando | o ambiente não está preparado. Ele nunca instala sozinho: rode o preparo que a linha cita (ex: `uv sync --extra dev`) |
| os hooks do Laravel não disparam | não há `artisan` no diretório atual nem acima dele — confira com `mktux-profile.sh name` |
| portão 0 vermelho com `passou de RALPH_SESSION_TIMEOUT` | um comando dentro da sessão esperou um input que nunca veio — prompt de confirmação, modo watch, servidor em primeiro plano. O prompt pede stdin fechado (`< /dev/null`); corrija o teste ou o comando que pergunta |
| o run reinicia da fase 1 depois de você editar o plano | editar o `project-phases.md` invalida o stamp. Use `--from N` |
| `ralph: command not found` | rode o passo 3 da instalação, e confira que `~/.local/bin` está no PATH |
| `mktux-harness: não encontrei ralph.sh` | o plugin não está instalado nessa máquina, ou aponte `MKTUX_HARNESS_ROOT` para um clone |
| preflight aborta com `Hooks do ai-memory em ... sem jq` | os hooks do ai-memory estão na config de usuário e o isolamento precisa do `jq`. Instale o `jq`. Use `RALPH_HOOK_ISOLATION=0` só se aceitar que as sessões consumam seus handoffs |
| `Falha ao gravar no ai-memory` | leia `.phases/logs/phase-NN.memory.log`. Se o servidor caiu: `ai-memory status` e `launchctl kickstart -k gui/$(id -u)/com.github.akitaonrails.ai-memory`. A fase continua válida |

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
    │   ├── plan/                       roteador
    │   ├── plan-feature-brief/          passo 0: entrevista + template do brief
    │   ├── plan-feature-description/
    │   ├── plan-user-stories/
    │   ├── plan-database-schema/      references/laravel.md: convenções de banco
    │   ├── plan-project-phases/        o contrato do ralph + references/laravel.md
    │   ├── ralph/                      operação e diagnóstico
    │   ├── review-phases/              references/laravel.md: auditoria de segurança
    │   ├── setup/
    │   └── ai-context/               arvore AGENTS a partir do codigo
    ├── agents/                         só Claude: test-runner, security-auditor,
    │                                   ai-context-{inspector,core,docs}
    ├── hooks/
    │   ├── hooks.json                  Claude   (${CLAUDE_PLUGIN_ROOT})
    │   ├── codex-hooks.json            Codex    (${PLUGIN_ROOT})
    │   ├── shared/                     profile-hook (dispatcher), log-event
    │   ├── claude/                     log-tokens
    │   └── codex/                      log-tokens
    ├── profiles/laravel/               o que só projeto Laravel usa
    │   ├── profile.sh                  detecção, comando de teste, preflight, mapa de hooks
    │   ├── agents/                     notas do test-runner
    │   └── hooks/                      sail-guard (shared/), pint-and-test
    │                                   (claude/, codex/)
    └── scripts/
        ├── lib/profile.sh              contrato do perfil, detecção, fallback por manifest
        ├── mktux-profile.sh            o perfil, para os agents: name, test-cmd, notes
        ├── ralph.sh                    o orquestrador
        ├── ralph-watch.sh              painel ao vivo, read-only
        ├── test-ralph.sh               suite do próprio ralph
        ├── test-layout.sh              manifests, perfis, references, hooks, mktux-profile
        └── mktux-setup.sh              instala os wrappers no PATH
```

---

## Créditos

O `ralph.sh`, o `ralph-watch.sh` e o `sail-guard.sh` descendem do
[**Beer and Code Harness**](https://github.com/beerandcodeteam/beer-and-code-harness)
(MIT © Beer and Code). A cadeia `/init` com stamps de frescor, a ideia do
roteador de pipeline e o `/ai-context` também vêm de lá — o `/mktux:ai-context`
é aquele comando portado e adaptado para que o `CLAUDE.md` continue sendo do
Laravel Boost e o `.ai/rules` continue sendo a camada de convenção do time.

Obrigado ao time do Beer and Code pela mentoria e pelo trabalho original.

O contrato dos quatro portões, o veredito `NOT-CODE` do portão 3, a parada por
ciclo sem progresso, o painel `ralph-watch` e as regras de escrita de fase da
skill `plan-project-phases` foram desenvolvidos e endurecidos em runs de produção
neste harness.

Licença: [MIT](LICENSE).
