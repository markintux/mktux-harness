---
name: plan-project-phases
description: Passo 4 do pipeline mktux e o mais importante. Gera docs/features/<slug>/project-phases.md — o documento que o ralph.sh quebra em uma sessao fria por fase. Contem o contrato completo do ralph, as regras de isolamento de fase, e como escrever task que o verificador do gate 3 consegue julgar. Use antes de rodar o ralph em qualquer feature.
---

# mktux — project phases (passo 4 de 4)

Voce e um arquiteto de software senior e tech lead.

Slug vem do argumento. Diretorio: `${MKTUX_SPEC_DIR:-docs/features}/<slug>/`.

## Antes de escrever

**Perfil de stack.** O primeiro marcador da tabela que existir na raiz do
projeto define o perfil. Leia o reference dele, ao lado desta skill, **antes**
de escrever. Ele completa as Partes 1.6, 2, 3, 4, 5 e 6 com os comandos,
caminhos, framework de teste e a ordem de fases do perfil. Nenhum marcador na
raiz, nenhum perfil: tire comandos, caminhos e framework de teste do
`CLAUDE.md` / `AGENTS.md` do projeto.

<!-- perfis -->
| Perfil | Marcador na raiz | Reference |
|---|---|---|
| Laravel | `artisan` | `references/laravel.md` |
<!-- /perfis -->

Antes de abrir qualquer Reference, confirme que o marcador daquela linha existe
na raiz. Se nenhum marcador existir, **nao leia nenhum
`references/<perfil>.md`**: a tabela e um registro, nao uma lista de leitura.

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
| implementacao / correcao | preambulo de stack + o **recorte** do que a fase cita nos `.md` irmaos (`feature-description.md`, `user-stories.md`, `database-schema.md`) + os caminhos deles, so para consulta pontual + o comando de teste do projeto + aquela fase |
| verificador (gate 3) | aquela fase + a lista numerada das tasks (a primeira linha de cada) + os arquivos alterados na fase. **Nenhum doc irmao** |

O ralph recorta, mecanicamente, o que a fase cita — e so isso chega como
conteudo. O resto chega como caminho, com a instrucao de nao ler inteiro. Entao
o que a fase precisa tem que estar citado de um jeito que o recorte ache:

| Cite | Como | O ralph recorta |
|---|---|---|
| secao | no **Read first:**, depois do arquivo: `` `feature-description.md` next to this file, section "PII Rules" `` — titulo exato, entre aspas duplas | a secao, ate o proximo titulo do mesmo nivel |
| tabela | no **Read first:**, depois de `` `database-schema.md` ``: `` table `orders` `` | o `` ### `orders` `` ou o bloco DBML `Table orders {…}` |
| regra | `BR-07`, ou a faixa `BR-07 through BR-14`, em qualquer ponto da fase | o item da lista de Business Rules |
| story | `US-2.1`, ou a faixa `US-2.1 through US-2.5`, em qualquer ponto da fase | a story com os criterios |

Citacao vaga — *"all CLI-facing stories"*, *"the relevant rules"*, *"see the
description"* — nao e recortada: escreva os ids e os titulos.

Isso nao e estetica. Num run real, "leia os documentos de contexto" fazia 25 de
26 sessoes — correcao inclusive — lerem todos os docs irmaos inteiros, e trechos
do arquivo de fases: ~19k tokens que ficam no contexto em todo turno seguinte. O
recorte das mesmas fases fica entre 3 e 10 KB.

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

## 1.4b O ralph numera as tasks — a primeira linha tem que se sustentar

O ralph conta task mecanicamente (`grep -cE '^[[:space:]]*- \[[ x]\]'`) e entrega
ao verificador uma lista numerada com a **primeira linha** de cada task, junto
com a fase completa. O verificador nao conta mais lendo o markdown: contando
sozinho, num run real, ele emitiu `TASK 9` numa fase de 8 e reprovou uma fase
completa com a suite verde.

A linha `**This phase has exactly N tasks.**` que planos antigos carregam deixou
de ser necessaria. Nao atrapalha; nao escreva em plano novo.

O que continua valendo:

- a primeira linha da task diz sozinha do que ela trata — arquivo, classe,
  estado. E o que aparece na lista numerada; os detalhes ficam nos sub-bullets;
- todo `- [ ]` vira um numero. Checkbox num sub-bullet ou num bloco de testes e
  uma task propria, com veredito proprio.

## 1.5 Os gates, e como escrever para eles

Por fase, em ordem. Todos verdes → commit. Qualquer vermelho → ciclo de correcao
(default 3, depois a fase falha).

- **Gate 0** — a engine terminou limpa.
- **Gate 1** — a sessao escreveu codigo? Sinal, nao veredito.
- **Gate 2** — a suite de testes do projeto, rodada pelo ralph **fora** da sessao
  do agente. Fase cujos testes nao passam nunca chega no gate 3.
- **Gate 3** — verificador independente, read-only, task a task, num modelo
  barato. No claude tem so `Read`, `Glob` e `Grep` — **sem Bash, sem shell, sem
  git**. No codex tem shell em sandbox read-only, instruido a nao rodar build nem
  teste. Escreva a task para o caso mais restrito: legivel lendo arquivo. Para
  cada task ele emite exatamente um de:
  - `TASK n: DONE`
  - `TASK n: INCOMPLETE — <o que falta>` → **reprova a fase**
  - `TASK n: NOT-CODE — <o que precisa de um humano>` → nao reprova, e reportado
    como pendencia manual

  Task marcada `(manual)` (1.6) nao entra no gate 3: nenhum veredito pedido,
  nenhum aceito.

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
rodar antes do PR. Marque-a com `(manual)`, literal e minusculo, logo depois do
checkbox:

```markdown
- [ ] (manual) Run `<project formatter>` on the files this feature touched.
- [ ] (manual) Open the export screen on a real phone, portrait and landscape.
```

O ralph tira toda task `(manual)` do gate 3 **por construcao**: ela nao entra na
lista numerada do verificador, veredito que ele emita para ela e descartado, e
ela sai no fim do run em "Pendencias manuais" — o checklist de quem abre o PR. A
posicao dela na fase continua contando: a task seguinte mantem o mesmo `<n>`. A
sessao de implementacao roda a task `(manual)` quando e um comando do repo que
ela consegue rodar (formatador, build); o que exige pessoa ou aparelho fica.

Sao `(manual)`:

- rodar o formatador do projeto;
- rodar a suite completa pelo subagent `test-runner`;
- o build de assets, quando o projeto tem um;
- sanity check com `git diff --stat`;
- verificar algo em dispositivo real, ou fazer uma pergunta ao usuario.

Escreva o comando exato de cada procedimento — o do perfil de stack, ou o que o
`CLAUDE.md` / `AGENTS.md` do projeto define.

Task de estado **nunca** leva `(manual)`: ela sairia do gate 3 e ninguem mais a
confirmaria.

**Nunca escreva uma fase 100% `(manual)`.** Custa uma sessao inteira sem nada
que um gate confirme. Uma fase de fechamento mistura afirmacoes legiveis
(nenhuma migration perdida, nenhum identificador residual, nenhum codigo
proibido em arquivo protegido) com os poucos procedimentos reais.

### Por que tipar, em vez de deixar o verificador classificar

Sem a marca, o destino da fase depende de o verificador classificar `NOT-CODE`
corretamente todas as vezes — e ele nao classifica. Num run real, uma fase de
fechamento com 7 tasks (4 de estado, 3 procedurais) reprovou duas vezes
seguidas: no primeiro ciclo o verificador marcou 3 tasks como `NOT-CODE` e uma
quarta como `INCOMPLETE` por nao conseguir confirmar; no segundo, com o codigo
byte-identico, marcou duas daquelas como `DONE` e uma como `INCOMPLETE` dizendo
que estava "aguardando o resultado da suite" — numa sessao onde a ferramenta de
shell esta bloqueada. Nao havia nada errado com o codigo. Com `(manual)`, nao ha
o que classificar.

Planos antigos trazem `**Operational phase**` numa linha logo abaixo do heading:
o gate 3 da fase inteira passa a reportar sem reprovar. O ralph continua
honrando o marcador, mas nao o escreva em plano novo — ele tira o poder de
reprovar tambem das tasks de estado, que sao justamente o que a fase de
fechamento precisa provar. `(manual)` tira so o procedimento.

## 1.7 Ambiguidade e loop infinito

O verificador recebe a instrucao: na duvida entre DONE e INCOMPLETE, escolha
INCOMPLETE. Uma task com escape condicional — *"faca X, mas se ficar estranho,
deixe como esta"* — nunca pode ser confirmada, entao reprova em todo ciclo ate a
fase esgotar.

Decida, e escreva a decisao. Uma instrucao, um resultado.

Task de teste com quantificador — *"prove every precondition"* — e o mesmo loop
por outro caminho: o verificador inventa a lista, e cada ciclo inventa outra. A
Parte 5.1 fecha isso.

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

**Tasks:**
- [ ] One task, stated as a code state, naming the exact class/file path.
  - detail bullet, plain `-`, never a checkbox
- [ ] `<test file path, in the stack's layout>` (new file) covers these scenarios, one test case each:
  - <situation> → <observable result> (US-N.N)
  - <situation> → <observable result> (US-N.N)
- [ ] Next task

**Completion criteria:** Specific, verifiable conditions — what exists, what
passes, and which existing tests must still pass **unmodified**.

---
```

Mantenha o separador `---` entre fases. E cosmetico pro ralph, mas mantem o
documento legivel quando um humano revisa.

---

# Parte 3 — Diretrizes de fasear

Ordene as fases de modo que cada uma produza um incremento funcional e testavel:

1. **Foundations** — tipos e constantes compartilhados, flags, classes de suporte
   compartilhadas, tudo de que as fases seguintes dependem
2. **Database** — schema, camada de dados, dados de teste e seed
3. **Backend core** — autorizacao, regras de negocio, validacao de entrada
4. **Routes + handlers** — um contexto por vez
5. **Views** — telas e componentes, mais o build de assets quando houver
6. **Regression** — formatador, suite completa, e afirmacoes legiveis de que nada
   mais se moveu

O perfil de stack traz a mesma ordem nos termos do framework — use a dele quando
houver.

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
- Para cada task de handler, nomeie a classe ou funcao e a rota que ela atende.
- Nomeie URI exata, nome da rota e middleware de toda task de rota.
- Quando uma rota tem que ser registrada em posicao especifica (segmento literal
  antes de um wildcard, grupo de middleware aninhado), diga isso **e diga por
  que** — uma sessao fria vai, caso contrario, anexar no fim e quebrar.
- Quando uma task modifica codigo existente, diga precisamente o que muda **e o
  que tem que continuar identico**.

## 4.1 Regra que atravessa camadas

Uma business rule muitas vezes tem mais de uma clausula, e cada clausula
acontece numa camada diferente: *"a geracao escreve tudo antes de trocar a
coluna; se falhar, apaga o parcial, mantem a coluna e o admin recebe erro de
validacao"* e escrita atomica na action **e** resposta no controller.

Antes de distribuir as tasks, quebre cada BR nas clausulas dela e decida em que
fase cada clausula acontece. Toda fase que recebe uma clausula:

- cita o id da BR (`BR-16`) — sem a citacao, o recorte (1.3) nao leva a regra
  para aquela sessao;
- carrega a clausula escrita na task do artefato onde ela acontece;
- tem um cenario de teste para ela (5.1).

Citar a BR so na fase da primeira clausula nao basta. A sessao fria da fase
seguinte nao ve a regra, e o verificador so julga o que a lista de tasks diz.
Num run real, a escrita atomica ficou na fase da action, a fase do controller
nao citou a BR, as duas passaram nos quatro gates, e a falha de geracao chegava
ao admin como erro 500 — so a revisao humana pegou.

---

# Parte 5 — Especificacao de testes

O framework de teste, o tipo de teste preferido e o comando que cria o arquivo
vem do perfil de stack; sem perfil, do `CLAUDE.md` / `AGENTS.md` do projeto.
Rode pelo subagent `test-runner`, nunca direto.

## 5.1 Um arquivo de teste, uma task, uma lista fechada de cenarios

Teste e task. Cada arquivo de teste que a fase cria ou estende e **uma** task
propria (`- [ ]`), logo depois da task cujo codigo ele cobre. A primeira linha
nomeia o arquivo e diz se e novo ou existente; os cenarios vem embaixo, um por
sub-bullet `-` simples:

```markdown
- [ ] `<test dir>/orders/cancel-order` (new file) covers these scenarios, one test case each:
  - owner cancels a pending order → status becomes `cancelled` (US-2.1)
  - owner cancels a shipped order → validation error, status unchanged (US-2.3)
  - user from another tenant cancels → not found, status unchanged (US-2.4)
- [ ] `<test dir>/orders/order-list` (existing file — add cases; do not rewrite the file and do not delete existing cases) covers these scenarios, one test case each:
  - list after a cancellation → the cancelled order shows the `cancelled` badge (US-2.1)
```

Cada cenario e `<situacao> → <resultado observavel> (US-N.N)`: o que o teste
monta e o que ele verifica. O verificador julga a task confirmando que **cada
cenario listado** tem um caso de teste que monta aquela situacao e verifica
aquele resultado — e nada alem da lista.

Por isso a lista e o contrato, e tem que ser fechada:

- **Nenhum quantificador sem lista.** "every precondition", "all CHECK
  constraints", "each pause category" nao sao cenarios: sao um convite pro
  verificador inventar a lista. Escreva os itens: um cenario por precondicao,
  constraint, categoria.
- **Um arquivo por task.** Nunca "Domain, application and CLI tests prove …" com
  tres arquivos embaixo: vira uma task com tres alvos e um veredito so.
- **Diga a camada quando ela importa.** Se o cenario tem que exercitar uma classe
  especifica, e nao um chamador dela, o arquivo de teste e o texto do cenario
  dizem qual.
- **Ate 8 cenarios por task.** Mais que isso, divida o arquivo por
  comportamento.

Isso nao e estetica. Num run real de 15 fases, 8 das 9 fases que voltaram pra
correcao reprovaram no gate 3 numa task de teste unica que juntava 3 a 5 arquivos
e prometia "prove every precondition", "all CHECK constraints", "every pause
category". Sem lista, o verificador monta a dele a cada ciclo, e o alvo muda sem
uma linha do plano mudar: numa mesma fase, o ciclo 1 reprovou por faltarem tres
gates especificos; com esses cobertos, o ciclo 2 reprovou por faltar teste
"direto" de outra classe, que ninguem tinha pedido.

## 5.2 Cobertura

Cobertura obrigatoria para toda feature:

- **Authorization** — cada papel pode e nao pode executar cada acao
- **Tenant isolation** — usuario do tenant A nunca alcanca dado do tenant B
  (pule so se o projeto genuinamente nao for multi-tenant)
- **Validation** — campos obrigatorios, comprimentos, valores de enum
- **Happy path** — create, read, update, delete, conforme aplicavel
- **Edge cases** nomeados nas business rules do `feature-description.md`

Cada item acima vira cenario **escrito** na lista de algum arquivo de teste
(5.1). "Cada papel pode e nao pode executar cada acao" significa um cenario por
par papel × acao que importa, nao a frase copiada para o plano.

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
    and reproduce its structure faithfully, adapting to <template syntax>.
  ```
  `<template syntax>` e a linguagem de template do stack (o perfil diz qual).
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

# Procedimento sem (manual) (1.6) — toda linha impressa ganha a marca ou vira estado
grep -nE '^[[:space:]]*- \[[ x]\][[:space:]]+(Run|Execute|Build|Confirm|Verify|Check|Ask)\b' "$f"

# Quantificador em task ou cenario (1.7, 5.1). Linha de teste impressa: vira
# itens escritos. Linha de codigo: o conjunto tem que estar listado na propria task.
grep -nwiE 'every|all|each|any' "$f" | grep -E '^[0-9]+:[[:space:]]*- '

# Fases que citam cada BR (4.1), faixas "BR-a through BR-b" expandidas.
# BR sem fase e lacuna; BR de varias clausulas numa fase so, confira se as
# outras clausulas nao acontecem em outra camada.
d="$(dirname "$f")/feature-description.md"
grep -oE 'BR-[0-9]+' "$d" | sort -u -t- -k2,2n | while read -r br; do
  printf '%-7s %s\n' "$br" "$(awk -v n="${br#BR-}" '
    /^## Phase [0-9]+: /{ph=$3; sub(":","",ph); last=ph}
    ph!="" {
      l=$0
      while (match(l, /BR-[0-9]+ through BR-[0-9]+/)) {
        r=substr(l, RSTART, RLENGTH); split(r, a, /[^0-9]+/)
        if (n+0>=a[2]+0 && n+0<=a[3]+0) hit[ph]=1
        l=substr(l, RSTART+RLENGTH)
      }
      if ($0 ~ ("BR-0*" n "([^0-9]|$)")) hit[ph]=1
    }
    END{for (p=1; p<=last; p++) if (p in hit) s=s " " p; print (s=="" ? "-- nenhuma fase" : "fases" s)}' "$f")"
done
```

Depois releia e confirme:

- [ ] A contagem que o `awk` imprimiu e a que voce pretendia: nenhum checkbox perdido em sub-bullet.
- [ ] A primeira linha de cada task diz sozinha do que ela trata.
- [ ] Toda fase que toca codigo compartilhado ou arriscado carrega a propria linha **Do not touch**.
- [ ] Nenhuma task esta escrita como comando de shell quando a mesma exigencia e legivel do repo.
- [ ] Todo procedimento (formatador, build, suite, aparelho real, pergunta) leva
      `(manual)`; nenhuma task de estado leva.
- [ ] Nenhuma fase e 100% `(manual)`.
- [ ] Nenhuma task tem escape condicional.
- [ ] Sub-bullets de detalhe sao `-` simples, nao `- [ ]`.
- [ ] Todo arquivo de teste e uma task propria, com no maximo 8 cenarios
      `<situacao> → <resultado observavel>`, nenhum quantificador sem lista.
- [ ] Todo cenario rastreia a pelo menos um `US-N.N`.
- [ ] Toda clausula de toda BR tem task e cenario na fase onde acontece, e essa
      fase cita o id da BR (4.1).
- [ ] Todo nome entre aspas no **Read first:** e o titulo exato de uma secao do
      arquivo citado antes dele; regra e story sao citadas por id, nunca por
      descricao vaga.
- [ ] Os criterios de conclusao nomeiam os testes existentes que passam sem modificacao.
- [ ] `[x]` aparece so em task confirmada lendo o codigo.
- [ ] Se um perfil casou, o reference dele foi lido, e comandos, caminhos de
      teste e ordem de fases do plano seguem ele.

---

# Instrucoes

- Inspecione o codebase antes de escrever. Marque task concluida `[x]`, pendente `[ ]`.
- Nao inclua task para coisa ja implementada em outra feature.
- Titulos de fase curtos e orientados a acao.
- Se a descricao da feature for ambigua em algo que muda o faseamento, use a
  ferramenta AskUserQuestion **antes** de escrever — nao um `TODO` no documento.
- Escreva tudo em ingles.
