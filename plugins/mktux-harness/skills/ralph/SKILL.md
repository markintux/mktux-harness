---
name: ralph
description: Referencia operacional do ralph, o orquestrador que executa um project-phases.md em sessoes frias com quatro gates mecanicos. Use quando o usuario perguntar como rodar o ralph, quando um run falhar e precisar de diagnostico, quando pedir para retomar de uma fase, ou quando perguntar o que significa um veredito de gate.
---

# mktux — ralph

`ralph` le um `project-phases.md`, quebra em fases, e alimenta cada uma ao Codex
CLI ou ao Claude Code para implementacao automatica.

**Voce nao roda o ralph por conta propria.** Ele consome tokens e faz commit. So
rode quando o usuario pedir explicitamente, e sempre em foreground para ele
acompanhar.

## Invariantes

1. Cada fase **e** cada ciclo de correcao roda em **sessao nova**, com prompt
   auto-contido. Nunca reutiliza sessao.
2. Zero perguntas. Do inicio ao fim sem interacao humana.
3. Fase so e "completa" quando passa por 4 gates mecanicos — **nunca** pelo exit
   code da engine.
4. Limite de uso → espera o reset e re-executa a MESMA fase, sem consumir ciclo
   de correcao.
5. Um commit por fase concluida.

## Uso

```bash
ralph docs/features/<slug>/project-phases.md            # run completo
ralph docs/features/<slug>/project-phases.md --from 3   # retoma da fase 3
ralph docs/features/<slug>/project-phases.md --dashboard # painel neste terminal
ralph-watch                                             # painel em outro terminal
ralph --help                                            # referencia completa
```

Opcoes que mais importam:

| Flag | Efeito |
|---|---|
| `--engine codex\|claude` | engine de implementacao (default: `codex`) |
| `--model <nome>` | modelo da engine |
| `--effort <nivel>` | raciocinio (codex: `low`..`ultra`, claude: `low`..`max`) |
| `--from N` | comeca na fase N, limpando do progresso as fases >= N |
| `--keep-going` | continua apos uma fase falhar (default: para) |
| `--max-cycles N` | ciclos de correcao por fase (default: 3) |
| `--no-verify` | desliga o gate 3 |
| `--test-cmd "<cmd>"` | comando de teste do projeto (gate 2) |
| `--verbose` | espelha a saida da engine na tela |

## Pre-requisitos

- Raiz de um repositorio git, com a **arvore de trabalho limpa**.
- Codex: `npm install -g @openai/codex` + `OPENAI_API_KEY`
- Claude: `npm install -g @anthropic-ai/claude-code` + `ANTHROPIC_API_KEY`
- Ambiente do perfil de stack **de pe** (ver *Perfis de stack*). Parado → abort
  no preflight, porque todo gate 2 falharia e queimaria os ciclos de correcao a
  toa.

## O que a sessao de uma fase recebe

Sessao fria, prompt auto-contido: preambulo de stack, o comando de teste do
gate 2, a fase, e o **recorte** dos documentos do plano.

O ralph le a linha `**Read first:**` da fase e os ids citados em qualquer ponto
dela, e recorta dos `.md` irmaos do plano so o que a fase aponta: secao pelo
titulo exato entre aspas, tabela pelo nome entre crases (o heading dela ou o
bloco DBML), regra por `BR-NN` e story por `US-N.N`, com as faixas
(`BR-07 through BR-14`) expandidas. Os
caminhos dos documentos continuam no prompt, para consulta pontual — a sessao e
instruida a nao ler nenhum inteiro, e a nao abrir o arquivo de fases.

Motivo: com "leia os documentos de contexto", 25 de 26 sessoes de um run real
leram todos os irmaos inteiros (~19k tokens, resident em todo turno seguinte).
Citacao vaga (*"all CLI-facing stories"*) nao e recortada — o contrato de como
citar esta na skill `plan-project-phases`.

## Os quatro gates

Por fase, em ordem. Todos verdes → commit. Qualquer vermelho → ciclo de correcao.

| Gate | O que e | Reprova? |
|---|---|---|
| **0** | a engine terminou de verdade (claude: `is_error` no JSON; codex: exit code), dentro de `RALPH_SESSION_TIMEOUT` | sim |
| **1** | a sessao escreveu codigo? **Sinal, nao veredito** — fase ja implementada faz a engine (corretamente) nao escrever nada | nao |
| **2** | suite de testes do projeto, rodada **pelo ralph**, fora da sessao do agente | sim |
| **3** | sessao verificadora independente, read-only, task a task | sim, em `INCOMPLETE` |

Gates verdes com a arvore limpa ⇒ a fase ja estava implementada em HEAD: marcada
como feita, sem commit.

### Gate 3 em detalhe

Roda em toda fase por default (`RALPH_VERIFY=always`). Usa modelo barato (claude:
haiku; codex: gpt-5.6-luna com esforco baixo) — e leitura e checklist, nao precisa
do modelo de implementacao.

O ralph numera as tasks da fase no prompt do verificador e lista os arquivos
alterados na fase como ponto de partida. As ferramentas dependem da engine:

- **claude:** so `Read`, `Glob` e `Grep` (`--tools`), sem MCP e sem skills.
  **Nao tem Bash, nem shell, nem git.**
- **codex:** shell em sandbox read-only, instruido a nao rodar build, teste,
  typecheck ou lint e a nao ler dependencias de terceiros. O veredito sai da
  mensagem final (`-o`, em `phase-NN.verify-M.last.txt`).

Para cada task ele emite exatamente uma linha:

- `TASK n: DONE`
- `TASK n: INCOMPLETE — <o que falta>` → **reprova a fase**
- `TASK n: NOT-CODE — <o que precisa de um humano>` → nao reprova, vira pendencia
  manual no relatorio

**Task `- [ ] (manual) ...` nao passa pelo gate 3.** E procedimento tipado no
plano (formatador, build, suite, aparelho real). O ralph a tira da lista
numerada do verificador, mantendo a posicao das outras (`1, 2, 4`), descarta
veredito que ele emita para ela, e a lista em **Pendencias manuais** no
relatorio final, junto com os `NOT-CODE`. No painel ela aparece como Manual e
nao conta na barra de tasks. Fase so com tasks `(manual)` pula o gate 3.

`RALPH_VERIFY=auto` economiza: so roda quando o veredito do gate 2 nao basta.
`--no-verify` / `RALPH_VERIFY=off` desliga.

**O veredito e memoizado por assinatura de arvore.** Ciclo de correcao que nao
alterou nenhum arquivo nao paga outra sessao de verificacao: o gate 3 e funcao do
codigo, e os mesmos bytes tem que dar o mesmo veredito. Sem isso um verificador
barato muda de ideia entre ciclos sobre codigo identico.

**Fase declarada `**Check-only phase**` nao abre sessao de cara.** E a fase de
fechamento que so afirma estado. O ralph roda os gates 2 e 3 contra HEAD
(`test-0.log`, `verify-0.log`): verde fecha a fase como **VERIFICADA sem
sessao**, sem commit; vermelho abre o ciclo 1 ja com o prompt de correcao e a
causa. O gate 3 mantem o poder de reprovar. Com `--no-verify` o marcador e
ignorado e a fase segue o fluxo normal.

**Fase ja commitada no branch segue o mesmo caminho.** Commit com a mensagem do
ralph (`feat(phase-N): <titulo>`, nao `wip(...)`) nos ultimos 500 do branch: o
ralph roda os gates contra HEAD antes de abrir sessao. E o caso de retomar
depois de commitar a mao o trabalho de uma fase que travou, ou de o plano mudar
e zerar o `.progress`. A mensagem escolhe o caminho; quem aprova sao os gates.

### Contestacao (`RALPH-CONTEST`)

O verificador le so a fase. Quando a fase erra — cita token, classe ou arquivo
que nao existe, contradiz uma BR/US, exige quebrar teste que ela mesma proibe
tocar — o ciclo de correcao obedecia o verificador e desfazia o que a sessao
tinha feito certo. Agora a sessao de implementacao (ou de correcao) pode
terminar a resposta com uma linha por task:

```
RALPH-CONTEST: TASK 4 — border-border nao existe (tailwind.config.js:26)
```

O ralph le a mensagem final da sessao (codex: `-o` em `cycle-M.last.txt`;
claude: o `result` do JSON) e:

- gate 3 reprovou uma task contestada, ou gate 2 vermelho com contestacao →
  **para a fase** (PARADA, nao FALHOU), sem outro ciclo, com a contestacao e o
  veredito lado a lado;
- gate reprovou outra task → ciclo de correcao normal;
- tudo verde → commit, e a contestacao sai em *Contestacoes que passaram nos
  gates* no relatorio final.

Fase parada pede decisao: sessao com razao → corrija a fase e os docs do plano,
e `--from N`; task certa → deixe explicito nela, com o porque.

Fase que falha por outro motivo mostra no relatorio o fim da mensagem final da
sessao — quase sempre ela ja diz por que travou.

**Fase declarada `**Operational phase**` nao e reprovada pelo gate 3.** Ele roda e
reporta, mas perde o poder de reprovar. Marcador de planos antigos, anterior ao
`(manual)`: continua valendo, mas desliga o gate 3 inclusive para as tasks de
estado da fase. Em plano novo, marque so os procedimentos com `(manual)`.

## Comando de teste (gate 2)

Primeira regra que resolver vence:

1. `--test-cmd "<cmd>"`
2. `RALPH_TEST_CMD`
3. o **perfil de stack** do diretorio de onde o ralph roda
   (`profiles/<nome>/profile.sh`; nao sobe diretorios). O comando de cada
   perfil esta em *Perfis de stack*, abaixo.
4. deteccao por manifest:

   | Detectado | Comando |
   |---|---|
   | `composer.json` com `scripts.test` | `composer test` |
   | `package.json` com `scripts.test` | `npm test` |
   | `pytest.ini` / `pyproject [tool.pytest]` | `pytest`; `uv run pytest` com `uv.lock`; `poetry run pytest` com `poetry.lock` |
   | `go.mod` | `go test ./...` |
   | `Cargo.toml` | `cargo test` |

5. nada resolvido → aviso alto e gate 2 pulado (o gate 3 segura sozinho)

O perfil tambem valida o ambiente no preflight e acrescenta notas ao prompt de
implementacao, incluindo como rodar um teste focado. O prompt pede teste focado
durante o trabalho e o comando completo uma vez, no fim: a suite inteira a cada
item custava minutos por item. O comando resolvido vai para as sessoes em
`RALPH_TEST_CMD`: o subagent `test-runner` roda exatamente o que o gate 2 roda.

Para ver o que o ralph vai resolver num projeto, sem rodar nada:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/mktux-profile.sh" test-cmd   # Codex: $PLUGIN_ROOT
```

## Perfis de stack

<!-- perfis -->
### Laravel

- **Detectado por:** `artisan` na raiz.
- **Comando (gate 2):** `vendor/bin/sail artisan test --compact` com Sail; senao
  `composer test` se houver `scripts.test`; senao `php artisan test`.
- **Preflight:** Sail parado → abort, porque a suite roda dentro do container.
- **Gate 2 sempre vermelho no primeiro run:** Sail parado, ou `.env.testing`
  ausente.

### Node.js

- **Detectado por:** `package.json` na raiz, sem marcador de perfil mais
  especifico.
- **Comando (gate 2):** `npm run check` quando o script existe; senao `npm test`.
- **Preflight:** `node`/`npm` ausente, major diferente de `.node-version` /
  `.nvmrc`, ou dependencias ainda nao instaladas → abort antes da primeira
  sessao; com lockfile, sugere `npm ci`.

### Python

- **Detectado por:** `pyproject.toml` na raiz.
- **Comando (gate 2):** `uv run pytest` com `uv.lock`; `poetry run pytest` com
  `poetry.lock`; senao `pytest`.
- **Preflight:** gerenciador ausente ou pytest fora do ambiente → abort antes da
  primeira sessao; quando pytest esta no extra `dev`, sugere
  `uv sync --extra dev`.
<!-- /perfis -->

## Variaveis de ambiente

| Variavel | Efeito |
|---|---|
| `RALPH_TEST_CMD` | comando do gate 2 (`--test-cmd` tem prioridade) |
| `RALPH_VERIFY` | `always` (default) / `auto` / `off` |
| `RALPH_VERIFY_MODEL` | modelo das sessoes auxiliares |
| `RALPH_VERIFY_EFFORT` | esforco dessas sessoes |
| `RALPH_MAX_CYCLES` | ciclos de correcao por fase (default: 3) |
| `RALPH_SESSION_TIMEOUT` | segundos que uma sessao de engine pode durar (default: 3600; `0` desliga). Passou, o ralph encerra a arvore da sessao e o gate 0 reprova com a causa |
| `RALPH_MAX_LIMIT_WAITS` | esperas consecutivas por limite, por fase (default: 20) |
| `RALPH_SMOKE` | `0` desliga o smoke test da engine |
| `RALPH_MEMORY` | pagina por fase no ai-memory (`ralph/<feature>/phase-NN.md`, pos-commit, sem LLM); `0` desliga. Sem o binario ou com o servidor fora do ar, desliga sozinha |
| `RALPH_MEMORY_BIN` | binario do ai-memory (default `ai-memory` no PATH) |
| `RALPH_HOOK_ISOLATION` | `0` deixa os hooks do ai-memory rodarem nas sessoes do ralph. Default `1`: isola, porque o SessionStart deles consome handoffs e contamina a sessao fria e o gate 3 |

No codex, toda sessao do ralph (smoke, implementacao, gate 3) roda com
`-c features.memories=false`: a memoria nativa traria o historico de sessoes
anteriores para dentro da sessao fria.
| `RALPH_VERBOSE` | `1` espelha a saida da engine na tela |
| `RALPH_DASHBOARD` | `1` liga o painel embutido |

## Onde o run deixa rastro

```
.phases/
├── phase-NN.md          uma fase por arquivo, gerada pelo split
├── manifest.txt         stamp do input
├── .progress            fases ja concluidas
├── state/run.tsv        snapshot do run, lido pelo ralph-watch
└── logs/
    ├── run.log                 log linear (--dashboard), um bloco por invocacao
    ├── phase-NN.cycle-M.log    sessao de implementacao
    ├── phase-NN.cycle-M.last.txt   mensagem final da sessao (codex)
    ├── phase-NN.test-M.log     saida do gate 2
    ├── phase-NN.verify-M.log   sessao do gate 3
    ├── phase-NN.verify-M.last.txt  veredito final do gate 3 (codex)
    ├── phase-NN.memory.log     saida do `ai-memory write-page`
    └── archive/<inicio do run>/    logs de um run anterior da fase, movidos
                                    quando ela reabre (ficam os 10 ultimos)
```

O que esta em `logs/` e do run mais recente de cada fase. Diagnostico de um run
antigo: `logs/archive/`.

`.phases/` e `.harness/` (telemetria dos hooks) sao registrados em
`.git/info/exclude` automaticamente — o ralph nao mexe no `.gitignore` do
projeto. `.harness/` ja versionado aborta o preflight: a telemetria muda a cada
tool call, entraria no commit de toda fase e o gate 1 veria escrita em toda
sessao.

## Diagnostico

| Sintoma | Causa provavel |
|---|---|
| `Contrato de formato violado` no preflight | heading `## Phase` fora de `## Phase N: <titulo>`. Uma fase com heading torto **some silenciosamente** do run |
| gate 3 reprova por `cobertura incompleta` ou indice fora da faixa | o verificador ignorou a lista numerada do prompt. Leia o veredito (`verify-M.last.txt` no codex, `verify-M.log` no claude); se repetir, troque `RALPH_VERIFY_MODEL` |
| o verificador julga sub-item como task propria | sub-bullet de detalhe escrito como `- [ ]`: o ralph conta todo checkbox como task. Troque por `-` simples |
| preflight aborta com `.harness/ esta versionado` | a telemetria foi commitada. `git rm -r --cached .harness` e commit |
| task sempre `NOT-CODE` | escrita como comando (`rode`, `confirme com git diff`). Reescreva como estado do codigo, ou marque `(manual)` se ela for mesmo procedimento |
| fase de fechamento reprova sem nada de errado no codigo | task procedural sem `(manual)`: o verificador tenta julgar o que nao tem como ler. Marque os procedimentos com `(manual)` |
| `gate 0 vermelho` e o relatorio manda revisar as tasks | leia o FIM do `phase-NN.cycle-M.log` antes de mexer no plano: engine que morre por cota, rede ou crash cai no mesmo lugar. Task correta nao e a causa mais provavel |
| gate 0 vermelho com `passou de RALPH_SESSION_TIMEOUT` | um comando da sessao esperou input que nunca veio (prompt de confirmacao, modo watch, servidor em primeiro plano). O prompt ja pede stdin fechado; ache e corrija o teste ou comando que pergunta — o fim do `cycle-M.log` mostra o ultimo comando |
| fase `PARADA ... a sessao contestou a fase` | a task pede algo que a sessao confirmou ser errado. Leia a evidencia da linha `RALPH-CONTEST`; se procede, corrija a fase e os docs e rode `--from N` |
| fase reprova em todo ciclo ate esgotar | task com escape condicional (*"faca X, mas se ficar estranho, deixe"*). O verificador escolhe INCOMPLETE na duvida |
| gate 2 sempre vermelho no primeiro run | ambiente do perfil incompleto. A causa de cada perfil esta em *Perfis de stack* |
| o run reinicia da fase 1 depois de voce editar o plano | editar o `project-phases.md` invalida o stamp e zera `.progress`. Fase ja commitada como `feat(phase-N): <titulo>` e revalidada contra HEAD sem sessao; `--from N` pula de vez as anteriores |
| preflight aborta com `Hooks do ai-memory em ... sem jq` | os hooks do ai-memory estao na config de usuario e o isolamento precisa do `jq`. Instale o `jq`; `RALPH_HOOK_ISOLATION=0` so se aceitar que as sessoes consumam handoffs |
| `Falha ao gravar no ai-memory` | leia `.phases/logs/phase-NN.memory.log`. Servidor caiu no meio do run: `ai-memory status`; no macOS, `launchctl kickstart -k gui/$(id -u)/com.github.akitaonrails.ai-memory`. A fase continua valida |

Quando uma fase falhar, leia nesta ordem:
`.phases/logs/phase-NN.verify-M.log` (o que o verificador reprovou; no codex, o
veredito limpo esta em `phase-NN.verify-M.last.txt`) →
`.phases/logs/phase-NN.test-M.log` (o que a suite reprovou) →
`.phases/logs/phase-NN.cycle-M.log` (o que a sessao tentou fazer).

Depois de fechar uma fase, revise com a skill `review-phases`.

## Escrever o plano

A mecanica que o plano precisa respeitar esta na skill `plan-project-phases`.
Carregue ela antes de escrever ou corrigir um `project-phases.md`.
