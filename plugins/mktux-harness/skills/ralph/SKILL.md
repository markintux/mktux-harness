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
- Laravel Sail: containers **de pe**. Parados → abort no preflight, porque todo
  gate 2 falharia e queimaria os ciclos de correcao a toa.

## Os quatro gates

Por fase, em ordem. Todos verdes → commit. Qualquer vermelho → ciclo de correcao.

| Gate | O que e | Reprova? |
|---|---|---|
| **0** | a engine terminou de verdade (claude: `is_error` no JSON; codex: exit code) | sim |
| **1** | a sessao escreveu codigo? **Sinal, nao veredito** — fase ja implementada faz a engine (corretamente) nao escrever nada | nao |
| **2** | suite de testes do projeto, rodada **pelo ralph**, fora da sessao do agente | sim |
| **3** | sessao verificadora independente, read-only, task a task | sim, em `INCOMPLETE` |

Gates verdes com a arvore limpa ⇒ a fase ja estava implementada em HEAD: marcada
como feita, sem commit.

### Gate 3 em detalhe

Roda em toda fase por default (`RALPH_VERIFY=always`). Usa modelo barato (claude:
haiku; codex: gpt-5.6-luna com esforco baixo) — e leitura e checklist, nao precisa
do modelo de implementacao.

O verificador tem `Read`, `Glob` e `Grep`. **Nao tem Bash, nem shell, nem git.**
Para cada task ele emite exatamente uma linha:

- `TASK n: DONE`
- `TASK n: INCOMPLETE — <o que falta>` → **reprova a fase**
- `TASK n: NOT-CODE — <o que precisa de um humano>` → nao reprova, vira pendencia
  manual no relatorio

`RALPH_VERIFY=auto` economiza: so roda quando o veredito do gate 2 nao basta.
`--no-verify` / `RALPH_VERIFY=off` desliga.

## Comando de teste (gate 2)

Primeira regra que resolver vence:

1. `--test-cmd "<cmd>"`
2. `RALPH_TEST_CMD`
3. deteccao por manifest:

   | Detectado | Comando |
   |---|---|
   | Laravel Sail (`artisan` + `vendor/bin/sail`) | `vendor/bin/sail test` |
   | `composer.json` com `scripts.test` | `composer test` |
   | `artisan` | `php artisan test` |
   | `package.json` com `scripts.test` | `npm test` |
   | `pytest.ini` / `pyproject [tool.pytest]` | `pytest` |
   | `go.mod` | `go test ./...` |
   | `Cargo.toml` | `cargo test` |

4. nada resolvido → aviso alto e gate 2 pulado (o gate 3 segura sozinho)

Sail tem precedencia sobre `composer test` porque a suite roda dentro do
container.

## Variaveis de ambiente

| Variavel | Efeito |
|---|---|
| `RALPH_TEST_CMD` | comando do gate 2 (`--test-cmd` tem prioridade) |
| `RALPH_VERIFY` | `always` (default) / `auto` / `off` |
| `RALPH_VERIFY_MODEL` | modelo das sessoes auxiliares |
| `RALPH_VERIFY_EFFORT` | esforco dessas sessoes |
| `RALPH_MAX_CYCLES` | ciclos de correcao por fase (default: 3) |
| `RALPH_MAX_LIMIT_WAITS` | esperas consecutivas por limite, por fase (default: 20) |
| `RALPH_SMOKE` | `0` desliga o smoke test da engine |
| `RALPH_MEM0` / `RALPH_MEM0_USER` | resumo por fase no mem0; **desligado** enquanto `RALPH_MEM0_USER` nao for definida |
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
    ├── run.log                 log linear do run inteiro
    ├── phase-NN.cycle-M.log    sessao de implementacao
    ├── phase-NN.test-M.log     saida do gate 2
    └── phase-NN.verify-M.log   veredito task a task do gate 3
```

`.phases/` e registrado em `.git/info/exclude` automaticamente — o ralph nao mexe
no `.gitignore` do projeto.

## Diagnostico

| Sintoma | Causa provavel |
|---|---|
| `Contrato de formato violado` no preflight | heading `## Phase` fora de `## Phase N: <titulo>`. Uma fase com heading torto **some silenciosamente** do run |
| fase reprova com todos os vereditos `DONE` | contagem de tasks divergente. A fase precisa da linha `**This phase has exactly N tasks.**` |
| task sempre `NOT-CODE` | escrita como comando (`rode`, `confirme com git diff`). Reescreva como estado do codigo |
| fase reprova em todo ciclo ate esgotar | task com escape condicional (*"faca X, mas se ficar estranho, deixe"*). O verificador escolhe INCOMPLETE na duvida |
| gate 2 sempre vermelho no primeiro run | Sail parado, ou `.env.testing` ausente |
| o run reinicia da fase 1 depois de voce editar o plano | editar o `project-phases.md` invalida o stamp e zera `.progress`. Use `--from N` |

Quando uma fase falhar, leia nesta ordem:
`.phases/logs/phase-NN.verify-M.log` (o que o verificador reprovou) →
`.phases/logs/phase-NN.test-M.log` (o que a suite reprovou) →
`.phases/logs/phase-NN.cycle-M.log` (o que a sessao tentou fazer).

Depois de fechar uma fase, revise com a skill `review-phases`.

## Escrever o plano

A mecanica que o plano precisa respeitar esta na skill `plan-project-phases`.
Carregue ela antes de escrever ou corrigir um `project-phases.md`.
<!-- marcador-de-teste-sem-bump -->
