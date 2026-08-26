---
name: plan-project-phases
description: Passo 4 do pipeline mktux e o mais importante. Gera docs/features/<slug>/project-phases.md — o documento que o ralph.sh quebra em uma sessao fria por fase. Contem o contrato completo do ralph, as regras de isolamento de fase, e como escrever task que o verificador do gate 3 consegue julgar. Use antes de rodar o ralph em qualquer feature.
---

# mktux — project phases (passo 4 de 4)

Voce e um arquiteto de software senior e tech lead.

Slug vem do argumento. Diretorio: `${MKTUX_SPEC_DIR:-docs/features}/<slug>/`.

## Antes de escrever

Leia:

- `<dir>/feature-description.md`
- `<dir>/user-stories.md`
- `<dir>/database-schema.md`
- O `CLAUDE.md` / `AGENTS.md` do projeto — stack, convencoes, comando de teste
- `docs/project-description.md`, se existir

Depois **inspecione o codebase** pra identificar o que ja esta implementado desta
feature. Marque as tasks ja concluidas com `[x]` — o verificador checa essas
tambem, entao so marque o que voce confirmou lendo o codigo.

## Saida

`<dir>/project-phases.md`, **em ingles**, com o carimbo na linha 3:

```markdown
# Project Phases — <Nome>

<!-- inputs: feature-description.md@sha256:aaa111 user-stories.md@sha256:bbb222 database-schema.md@sha256:ccc333 -->
```

---

# Parte 1 — O contrato do ralph (leia antes de escrever qualquer coisa)

Este documento nao e lido por humano. Ele e **executado** pelo `ralph`, que quebra
o arquivo em um arquivo por fase e roda uma **sessao fria por fase**. Errar a
mecanica faz o loop queimar ciclo em nada. Toda regra abaixo vem do comportamento
real do script.

## 1.1 Contrato de formato (validado no preflight — violacao aborta o run)

- Pelo menos um heading `## Phase N: <titulo>`.
- **Nenhum** heading `## Phase ...` fora desse formato exato.
- Sub-fases sao `### Phase N.M: <titulo>` — ficam dentro da fase pai e **nao**
  viram sessao propria.
- Qualquer outro heading `## ` encerra a captura da fase acima dele.

## 1.2 Isolamento de fase — a regra que a maioria dos planos erra

O `split_phases()` copia **apenas** as linhas **entre** headings `## Phase N:`.

Todo o resto e **descartado e nunca chega em sessao nenhuma**:

- toda linha antes de `## Phase 1`;
- toda secao `## ` que nao e fase (`## Conventions`, `## Do not touch`,
  `## Reused — No Task Required`), e tudo abaixo dela.

Ou seja: um preambulo de "regras para a feature inteira" e **invisivel**. Cada
sessao e fria e ve exatamente uma fase.

**Portanto: toda fase carrega os proprios guards.** Repita, dentro de cada fase
que precisa:

- **o que nao pode ser tocado** naquela fase (arquivos, actions, telas, o
  subsistema critico do projeto);
- as **convencoes de pasta e nomenclatura** que valem para os artefatos daquela
  fase;
- as **pegadinhas de ambiente de teste** que os testes daquela fase vao encontrar
  (reset de cache, estados de factory, dado semeado).

A duplicacao e deliberada. **Nao "DRY" isso num preambulo.**

Uma secao `## ` depois da ultima fase serve pro leitor humano, mas escreva
sabendo que nenhum agente vai ver.

## 1.3 O que cada sessao recebe de fato

| Sessao | Recebe |
|---|---|
| implementacao / correcao | preambulo de stack + **os caminhos** dos `.md` irmaos (`feature-description.md`, `user-stories.md`, `database-schema.md`) + o comando de teste do projeto + aquela fase |
| verificador (gate 3) | **aquela fase e mais nada** |

Os docs irmaos chegam como *caminho*, nao como conteudo — a sessao precisa
escolher abrir. Entao uma fase que depende de decisao registrada em outro lugar
tem que dizer:
`**Read first:** feature-description.md next to this file, section "<nome>"`.

O verificador nao recebe doc irmao nenhum. Qualquer coisa que ele precise pra
julgar uma task tem que estar **dentro da task** ou nos criterios de conclusao da
fase.

## 1.4 O que conta como task

Uma task e uma linha casando `- [ ]` ou `- [x]` **em qualquer nivel de indentacao**.

Consequencia: sub-bullets que detalham uma task tem que ser `-` simples, **nunca**
`- [ ]`, ou inflam a contagem e o verificador emite um veredito para cada.

```
- [ ] Create `App\Support\CsvDocument` with:
  - `section(string $title, array $headers, array $rows): static` — appends …
  - `render(): string` — returns the whole file …
```

Isso e **uma** task, nao tres.

## 1.4b Declare a contagem de tasks em toda fase

O ralph conta task mecanicamente (`grep -cE '^[[:space:]]*- \[[ x]\]'`). O
verificador conta *lendo o markdown*, num modelo barato. Quando as duas contagens
divergem, o ralph rejeita o relatorio inteiro como malformado e **reprova a
fase** — mesmo com todo veredito tendo saido `DONE`.

Isso nao e hipotetico. Num run real custou dois ciclos e 30 minutos numa fase cujo
codigo estava completo e cuja suite estava verde: o verificador emitiu `TASK 9`
numa fase de 8 tasks, e o ralph recusou o indice fora de faixa.

Entao **de o numero pro verificador**. Imediatamente acima de `**Tasks:**`, em
toda fase:

```markdown
**This phase has exactly 8 tasks.** Emit one verdict line per task, numbered 1 to
8 in the order they appear. The sub-bullets under "Automated tests to generate"
are part of the task above them, not tasks of their own.
```

Dois habitos que tornam o erro de contagem mais provavel, ambos evitaveis:

- task que junta dois artefatos ligados por "and" (`Filenames: X and Y`,
  `Activity events: A and B`, `Both controllers: …`) le como duas tasks pra um
  modelo que esta contando em vez de parseando;
- um bloco longo de `Automated tests to generate:` sob a ultima task da fase, que
  visualmente fica no mesmo nivel das tasks.

A linha de contagem e o que de fato te protege. Atualize sempre que adicionar ou
remover task — numero velho e pior que nenhum.

## 1.5 Os gates, e como escrever para eles

Por fase, em ordem. Todos verdes → commit. Qualquer vermelho → ciclo de correcao
(default 3, depois a fase falha).

- **Gate 0** — a engine terminou limpa.
- **Gate 1** — a sessao escreveu codigo? Sinal, nao veredito.
- **Gate 2** — a suite de testes do projeto, rodada pelo ralph **fora** da sessao
  do agente. Fase cujos testes nao passam nunca chega no gate 3.
- **Gate 3** — verificador independente, read-only, task a task. Roda num modelo
  barato com `Read`, `Glob` e `Grep` — **sem Bash, sem shell, sem git**. Para cada
  task ele emite exatamente um de:
  - `TASK n: DONE`
  - `TASK n: INCOMPLETE — <o que falta>` → **reprova a fase**
  - `TASK n: NOT-CODE — <o que precisa de um humano>` → nao reprova, e reportado
    como pendencia manual

## 1.6 Escreva task como estado, nao como comando

Esta e a regra de maior alavancagem do documento inteiro.

O verificador faz uma pergunta so: *esta task afirma alguma coisa sobre o codigo?*
Task que descreve um **estado** pode ser confirmada lendo arquivo → `DONE` /
`INCOMPLETE`. Task que descreve uma **acao que alguem roda**, depois da qual o
codigo continua igual → `NOT-CODE`.

Como o verificador tem Grep e Glob mas **nao tem Bash**, a *mesma exigencia* cai
de um lado ou do outro dependendo puramente de como voce escreveu:

| Redacao | Veredito |
|---|---|
| ``Confirm with `grep -rn "old_key" app/` that no reference survives`` | NOT-CODE |
| ``No file under `app/`, `routes/` or `tests/` contains the identifier `old_key``` | DONE / INCOMPLETE |
| ``Run `git diff` and confirm `FooAction` was not modified`` | NOT-CODE |
| ``` `FooAction` contains no export, CSV or `streamDownload` code ``` | DONE / INCOMPLETE |
| `Confirm no migration was created` | NOT-CODE |
| ``` `database/migrations/` contains no file dated `2026_08_21` or later ``` | DONE / INCOMPLETE |

Prefira a forma de estado toda vez que a exigencia for legivel a partir do
repositorio.

**Task genuinamente procedural continua pertencendo ao plano** — alguem tem que
rodar antes do PR. Essas ficam `NOT-CODE` e isso esta correto:

- rodar o formatador (`vendor/bin/sail bin pint --dirty --format agent`);
- rodar a suite completa pelo subagent `test-runner`;
- `vendor/bin/sail npm run build`;
- sanity check com `git diff --stat`;
- verificar algo em dispositivo real, ou fazer uma pergunta ao usuario.

**Nunca escreva uma fase 100% procedural.** Custa uma sessao inteira e uma passada
de verificador pra confirmar `0/N` tasks em codigo. Uma fase de fechamento mistura
afirmacoes legiveis (nenhuma migration perdida, nenhum identificador residual,
nenhum codigo proibido em arquivo protegido) com os poucos procedimentos reais.

## 1.7 Ambiguidade e loop infinito

O verificador recebe a instrucao: na duvida entre DONE e INCOMPLETE, escolha
INCOMPLETE. Uma task com escape condicional — *"faca X, mas se ficar estranho,
deixe como esta"* — nunca pode ser confirmada, entao reprova em todo ciclo ate a
fase esgotar.

Decida, e escreva a decisao. Uma instrucao, um resultado.

## 1.8 Re-rodar

Editar o `project-phases.md` invalida o stamp do manifest e zera
`.phases/.progress`. Use `ralph <caminho> --from N` pra retomar sem re-rodar fase
ja commitada.

---

# Parte 2 — Estrutura obrigatoria

```markdown
## Phase N: Short action-oriented title

**Goal:** One sentence describing what this phase delivers.

**Read first:** `feature-description.md` next to this file, section "<name>".
(Only when the phase depends on a decision recorded there.)

**Do not touch in this phase:** <files, actions, screens, subsystems this phase
must leave alone — and the project's critical subsystem whenever it is anywhere
near the blast radius>.

**Conventions here, to follow rather than "fix":** <where the artifacts of this
phase live and how they are named, when it is not obvious>.

<Test-environment gotcha this phase's tests will hit, if any.>

**This phase has exactly N tasks.** Emit one verdict line per task, numbered 1 to
N in the order they appear. The sub-bullets under "Automated tests to generate"
are part of the task above them, not tasks of their own.

**Tasks:**
- [ ] One task, stated as a code state, naming the exact class/file path.
  - detail bullet, plain `-`, never a checkbox
- [ ] Next task

  Automated tests to generate:
    - `tests/Feature/[Context]/[Resource]/SomeTest.php` — the scenarios it covers (US-N.N)

**Completion criteria:** Specific, verifiable conditions — what exists, what
passes, and which existing tests must still pass **unmodified**.

---
```

Mantenha o separador `---` entre fases. E cosmetico pro ralph, mas mantem o
documento legivel quando um humano revisa.

---

# Parte 3 — Diretrizes de fasear

Ordene as fases de modo que cada uma produza um incremento funcional e testavel:

1. **Foundations** — enums, flags, classes de suporte compartilhadas, tudo de que
   as fases seguintes dependem
2. **Database** — migrations, models, factories, seeders
3. **Backend core** — policies, actions, services (so quando justificado), form
   requests
4. **Controllers + Routes** — um contexto por vez
5. **Views** — views e componentes Blade, mais `vendor/bin/sail npm run build`
6. **Regression** — formatador, suite completa, e afirmacoes legiveis de que nada
   mais se moveu

Adapte a feature; nem toda feature precisa de toda fase.

Duas regras que importam mais que a ordem:

- **Primitiva compartilhada ganha fase propria, cedo.** Se cinco fases posteriores
  vao cada uma formatar moeda ou escapar CSV, construa isso uma vez, numa fase que
  tambem prove que um chamador existente continua produzindo saida identica.
- **Agrupe pelo que falha junto.** Duas telas que precisam da mesma request class
  e do mesmo gate pertencem a uma fase. Uma tela com formato de parametro
  diferente pertence a outra.

---

# Parte 4 — Granularidade de task

- Cada task mapeia para um arquivo unico ou um grupo bem acoplado de arquivos.
- Nao junte "cria controller, request, action, view" numa task — separe.
- Especifique o caminho exato do arquivo e o nome de classe totalmente
  qualificado de todo artefato.
- Para cada task de controller, nomeie o Single Action Controller e a rota que ele
  atende.
- Nomeie URI exata, nome da rota e middleware de toda task de rota.
- Quando uma rota tem que ser registrada em posicao especifica (segmento literal
  antes de um wildcard, grupo de middleware aninhado), diga isso **e diga por
  que** — uma sessao fria vai, caso contrario, anexar no fim e quebrar.
- Quando uma task modifica codigo existente, diga precisamente o que muda **e o
  que tem que continuar identico**.

---

# Parte 5 — Especificacao de testes

Toda task nao-trivial lista os testes automatizados a gerar ao lado dela, como
sub-bullets `-` simples sob `Automated tests to generate:`.

Testes sao **PHPUnit** — Feature preferencialmente, Unit so pra logica isolada.
Crie arquivos com `vendor/bin/sail artisan make:test --phpunit {name}`.
Rode pelo subagent `test-runner`, nunca direto.

Para cada teste, especifique:

- o caminho do arquivo sob `tests/Feature/` ou `tests/Unit/`;
- os cenarios que cobre, cada um rastreado a um id de story (`US-N.N`);
- se **estende um arquivo existente** — e se sim, diga explicitamente
  "add cases; do not rewrite the file and do not delete existing cases".

Cobertura obrigatoria para toda feature:

- **Authorization** — cada papel pode e nao pode executar cada acao
- **Tenant isolation** — usuario do tenant A nunca alcanca dado do tenant B
  (pule so se o projeto genuinamente nao for multi-tenant)
- **Validation** — campos obrigatorios, comprimentos, valores de enum
- **Happy path** — create, read, update, delete, conforme aplicavel
- **Edge cases** nomeados nas business rules do `feature-description.md`

Quando um refactor tem que preservar comportamento, nomeie nos criterios de
conclusao os arquivos de teste existentes que precisam passar **sem modificacao**,
e adicione: "if a test needs editing to go green, the refactor changed behavior
and must be corrected instead."

---

# Parte 6 — Arquivo de referencia

Se uma fase exige que o agente implementador siga um mockup estatico, arquivo
HTML, referencia de design ou qualquer artefato externo:

- Sempre de o **caminho exato do arquivo** na task — nunca so a pasta.
- Nome de arquivo referenciado nao pode ter espaco. Renomeie antes
  (`login panel.html` → `login-panel.html`).
- A task tem que abrir com instrucao explicita de leitura:
  ```
  - Before writing any code, read the full contents of `path/to/reference.html`
    and reproduce its structure faithfully, adapting to Blade/PHP syntax.
  ```
- O agente tem que verificar que o arquivo existe antes de comecar. Se estiver
  faltando, ele para e pergunta ao usuario com a ferramenta AskUserQuestion —
  nunca prossegue por suposicao.

---

# Parte 7 — Auto-checagem antes de terminar

Rode isto contra o arquivo que voce acabou de escrever, e corrija o que aparecer.

```bash
f="${MKTUX_SPEC_DIR:-docs/features}/<slug>/project-phases.md"

# Contrato de formato: tem que imprimir um numero >= 1, depois 0
grep -cE '^## Phase [0-9]+: ' "$f"
grep -E '^## Phase' "$f" | grep -vcE '^## Phase [0-9]+: '

# Tasks por fase — fase com 0 task e bug; >10 normalmente quer dizer que da pra dividir
awk '/^## Phase [0-9]+: /{p=$0; order[++n]=p; c[p]=0}
     /^[[:space:]]*- \[[ x]\]/{if(p!="")c[p]++}
     END{for(i=1;i<=n;i++) printf "%-55s %d\n", order[i], c[order[i]]}' "$f"

# Tudo acima da Phase 1 e descartado — confirme que nada estrutural mora la
sed -n "1,/^## Phase 1: /p" "$f"
```

Depois releia e confirme:

- [ ] Toda fase declara a contagem exata de tasks, e o numero bate com o que o `awk` imprimiu.
- [ ] Toda fase que toca codigo compartilhado ou arriscado carrega a propria linha **Do not touch**.
- [ ] Nenhuma task esta escrita como comando de shell quando a mesma exigencia e legivel do repo.
- [ ] Nenhuma fase e 100% procedural.
- [ ] Nenhuma task tem escape condicional.
- [ ] Sub-bullets de detalhe sao `-` simples, nao `- [ ]`.
- [ ] Todo bullet de teste rastreia a pelo menos um `US-N.N`.
- [ ] Os criterios de conclusao nomeiam os testes existentes que passam sem modificacao.
- [ ] `[x]` aparece so em task confirmada lendo o codigo.

---

# Instrucoes

- Inspecione o codebase antes de escrever. Marque task concluida `[x]`, pendente `[ ]`.
- Nao inclua task para coisa ja implementada em outra feature.
- Titulos de fase curtos e orientados a acao.
- Se a descricao da feature for ambigua em algo que muda o faseamento, use a
  ferramenta AskUserQuestion **antes** de escrever — nao um `TODO` no documento.
- Escreva tudo em ingles.
