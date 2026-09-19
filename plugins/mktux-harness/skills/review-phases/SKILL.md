---
name: review-phases
description: Revisa o commit de uma fase ja executada pelo ralph contra as instrucoes do projeto e roda uma auditoria de seguranca sobre os arquivos alterados. Use depois que o ralph fecha uma fase, quando o usuario pedir para revisar a fase N, ou disser /mktux:review-phases N. Nunca corrige nada.
---

# mktux — review phase $1

Voce revisa o diff de **uma** fase ja commitada pelo ralph. Voce **nao corrige
nada**, so reporta.

O numero da fase vem do argumento. Sem argumento, liste as fases commitadas e
pergunte qual.

**Perfil de stack.** O primeiro marcador da tabela que existir na raiz do
projeto define o perfil. Leia o reference dele, ao lado desta skill. Ele lista
as pastas relevantes a seguranca e traz a secao de auditoria de seguranca do
perfil.

<!-- perfis -->
| Perfil | Marcador na raiz | Reference |
|---|---|---|
| Laravel | `artisan` | `references/laravel.md` |
<!-- /perfis -->

Antes de abrir qualquer Reference, confirme que o marcador daquela linha existe
na raiz. Se nenhum marcador existir, **nao leia nenhum
`references/<perfil>.md`**: a tabela e um registro, nao uma lista de leitura.

## 1. Localize o commit da fase

```bash
git log --oneline | grep -iE "(phase|fase)[[:space:]]*$1" | head -5
```

Identifique o commit mais provavel da fase `$1`.

Se nenhum commit for encontrado, pare e retorne:

```text
ERROR: No commit found for phase $1.
```

## 2. Inspecione o diff da fase

```bash
git show --stat <commit-hash>
git show --name-only --format="" <commit-hash>
```

Use a lista de arquivos alterados nas revisoes abaixo.

## 3. Revisao de convencao

Leia o arquivo de instrucoes do projeto, nesta ordem de preferencia:

1. `CLAUDE.md`
2. `AGENTS.md`
3. `agents.md`
4. `GUIDELINES.md`
5. `.ai/GUIDELINES.md`
6. `docs/GUIDELINES.md`

Use o primeiro que existir. Se nenhum existir, retorne:

```text
ERROR: No project instruction/guideline file found.
```

Para cada arquivo alterado, revise **apenas as regras relevantes** daquele
guideline.

Reporte violacao neste formato:

```text
[V<N>] <file>:<line> — Rule: <citacao curta da regra> — Found: <descricao>
```

Se nao houver violacao:

```text
No convention violations found.
```

## 4. Revisao de seguranca

Passe **so** os arquivos alterados relevantes a seguranca web: rotas, handlers,
validacao, autorizacao, models, templates com formulario e migrations. O perfil
de stack lista as pastas tipicas.

- **Claude Code:** use o subagent `security-auditor` (ferramenta Task). Ele carrega
  sozinho a secao de seguranca do perfil. Instrua:

  ```text
  Audit only the changed files from phase $1 that are relevant to web security.
  Do not fix anything. Return only the compact security report.
  ```

- **Codex:** nao ha subagent. Faca voce mesmo a auditoria desses arquivos, sem
  corrigir nada, com a secao "Security audit" do perfil: processo, checklist e
  formato do relatorio.

Se nenhum arquivo alterado for relevante a fluxo web sensivel:

```text
No relevant web flow changed in this phase — security audit not applicable.
```

## 5. Relatorio final

Retorne um relatorio Markdown com exatamente estas secoes:

```md
## Convention

<revisao de convencao>

## Security

<relatorio do security-auditor>

## Pendencias manuais

<as tasks `(manual)` da fase (.phases/phase-$1.md) e as que o gate 3 marcou
NOT-CODE (.phases/logs/phase-$1.verify-*.log), se houver. Sao os procedimentos
que ainda precisam de quem conduz antes do PR.>
```

## Restricoes

- Nao corrija nada.
- Nao edite arquivo.
- Nao crie arquivo.
- Nao rode teste.
- Nao rode migration.
- Nao rode formatador.
- Nao rode build de assets.
- Nao revise arquivo nao relacionado.
- Nao cole diff bruto completo, salvo pra sustentar um achado especifico.
- Relatorio compacto e acionavel.
