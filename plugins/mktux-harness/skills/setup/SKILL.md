---
name: setup
description: Instala os comandos ralph e ralph-watch no PATH e prepara um projeto para o harness mktux. Use quando o usuario instalar o plugin pela primeira vez, quando ralph nao for encontrado no terminal, ou quando pedir para configurar o harness em um projeto novo.
---

# mktux — setup

Duas coisas separadas. Faca a que o usuario precisa.

## 1. Instalar `ralph` no PATH (uma vez por maquina)

Nem o Claude Code nem o Codex expoem binario de plugin no PATH. O script
`mktux-setup.sh` gera um wrapper em `~/.local/bin` que resolve o caminho do
plugin em tempo de execucao — assim `plugin update` atualiza o ralph junto.

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/mktux-setup.sh"   # Claude Code
bash "$PLUGIN_ROOT/scripts/mktux-setup.sh"          # Codex
```

Se a variavel nao estiver disponivel na sessao, localize o plugin:

```bash
ls -d ~/.claude/plugins/*/mktux*/scripts 2>/dev/null
ls -d ~/.codex/plugins/cache/*/mktux*/*/scripts 2>/dev/null
```

Confirme com `ralph --help`. Se `~/.local/bin` nao estiver no PATH, o script
avisa e mostra a linha exata para o `~/.zshrc`.

Variaveis:

- `MKTUX_BIN_DIR` — onde instalar os wrappers (default `~/.local/bin`)
- `MKTUX_HARNESS_ROOT` — aponta para um clone proprio do repo, ignorando o
  plugin. Use para desenvolver o harness ou fixar um fork.

## 2. Preparar um projeto

O harness nao copia arquivo para dentro do projeto. O que o projeto precisa ter:

**Obrigatorio**

- Repositorio git, com a arvore de trabalho **limpa** quando o ralph rodar.
- `CLAUDE.md` e/ou `AGENTS.md` com as convencoes do projeto. As sessoes do ralph
  sao frias: o que nao esta ali nao existe para elas.
- Suite de testes que roda por um comando so. Se a deteccao automatica nao
  resolver, defina `RALPH_TEST_CMD` ou passe `--test-cmd`.

**Recomendado**

- `docs/features/` para os specs. Para mudar a raiz, defina `MKTUX_SPEC_DIR`.
- Laravel: containers do Sail de pe, e um `.env.testing` proprio.

  > Sem `.env.testing`, rodar a suite com `--env=testing` cai no `.env` de
  > desenvolvimento, e um `migrate:fresh` apaga o banco de dev. Verifique que o
  > arquivo existe **antes** do primeiro run.

**Ignorar no git**

O ralph registra `/.phases/` no `.git/info/exclude` sozinho, sem tocar no
`.gitignore` do projeto. Falta so a telemetria:

```gitignore
/.harness
```

## 3. Verificar que os hooks estao ativos

Os hooks vem do plugin, entao nao ha nada para configurar por projeto. Para
confirmar que estao rodando, faca uma edicao qualquer e cheque:

```bash
tail -3 .harness/events.jsonl
```

Se o arquivo nao existir depois de um turno completo, o plugin nao esta carregado
naquela engine. Confira com `/plugin` (Claude) ou `codex plugin list` (Codex).

## O que cada hook faz

| Hook | Quando | O que faz |
|---|---|---|
| `sail-guard` | antes de todo Bash | bloqueia comando que rodaria PHP/DB no host quando o projeto usa Sail, e devolve ao agente a forma correta |
| `log-event` | todo evento | grava o evento em `.harness/events.jsonl` com timestamp e branch |
| `pint-and-test` | Claude: apos Edit/Write · Codex: no fim do turno | roda Pint e os testes afetados |
| `log-tokens` | fim da sessao | grava consumo por modelo em `.harness/tokens.jsonl`, com `vendor` para comparar Claude e Codex |

`pint-and-test` e `log-tokens` sao **deliberadamente diferentes por engine** — o
Codex nao tem hook de Edit e le tokens do rollout em `~/.codex/sessions/`,
enquanto o Claude le o transcript da sessao. Nao unifique esses dois.
