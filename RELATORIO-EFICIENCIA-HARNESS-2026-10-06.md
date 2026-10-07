# Auditoria de eficiência do mktux-harness

Data: 06/10/2026. Código analisado: `2ff9818`, versão 0.14.0.

O plano completo de implementação e os comandos para executar “a etapa N” estão na seção **Plano de execução por etapas**, após a auditoria.

**Existem melhorias com efeito perceptível. A prioridade é evitar retrabalho causado por planos contraditórios e vereditos incorretos, seguido de eliminar testes repetidos sem mudança de estado.** Não encontrei evidência que justifique reescrever o harness, trocar todos os modelos ou paralelizar fases agora.

Este relatório não implementa alterações. A análise usou o código atual, os prompts e logs locais do Bargi e três registros de execução de 05/10. O foco quantitativo é a execução `db9c597c-3e5c-4440-980d-4dd23277a19e`, com a versão atual, fases 3–8 de `superadmin-email-digest`. O Bargi foi somente consultado; nenhuma engine, suíte de projeto ou envio de e-mail foi executado nesta auditoria.

## Evidência de custo

| Medida observada no run 0.14.0 | Resultado |
|---|---:|
| Tempo do run, pelo estado publicado | 2h09min17s |
| Sessões principais contabilizadas | 25 |
| Subagentes contabilizados | 25 |
| Ciclos de correção, conforme telemetria | 6 |
| Tokens de entrada observados | 29.360.258 |
| Entrada atendida por cache, já incluída acima | 27.187.712 — 92,6% |
| Tokens de saída observados | 245.252 |
| Entrada de implementação/correção | 27.564.735 — 93,9% |
| Entrada de verificação/juiz | 1.795.523 — 6,1% |
| Entrada das correções com ciclo > 1 | 8.144.470 — 27,7% |
| Entrada da fase final, que terminou travada | 4.913.866 — 16,7% |

As categorias se sobrepõem: não se deve somar correções, subagentes e implementação. Somei o último acumulado por sessão, incluindo cada subagente uma vez; não somei snapshots cumulativos entre si. Cache do Codex já está dentro de `input`. Não há conversão para dinheiro: tokens em cache e tokens novos não representam o mesmo custo.

O resumo está marcado `partial`, com uma tentativa sem correspondência. Identifiquei um erro concreto de associação de sessão, descrito adiante. Os números são o consumo observado, não uma garantia de cobertura integral nem uma previsão de economia. Um único run também não prova o comportamento de todas as stacks.

## 1. Corrigir o caminho de contestação e recurso — prioridade máxima

**Problema confirmado.** Na fase 3, o verificador reprovou `weekly_monthly.stale_tenants`. A sessão seguinte não mudou nenhum arquivo; o recurso aprovou exatamente o mesmo código. Entre a primeira reprovação e a aprovação passaram aproximadamente 8min25s. A sessão de correção, com seu subagente, acumulou 1.321.349 tokens de entrada. Esse é custo observado de investigação/retrabalho, não economia garantida.

Na fase 8, houve novas contestações sem mudança de código. O recurso não foi acionado: a chave do memo inclui código **e** texto das contestações, enquanto a chamada de `gate3_appeal` depende de a chave inteira continuar igual. Evidência nova invalida o memo e acaba também evitando a escalada. O run terminou travado após 24min52s nessa fase.

Há falso negativo verificável: `phase-08.verify-2.log` mostra `'daily' => 'o fechamento anterior'` sob `reference` na leitura do arquivo, mas a resposta final afirma que o valor está sob outro grupo. A informação estava disponível ao verificador; não foi apenas ausência de contexto.

**Melhoria proposta:** separar identidade do código, identidade das evidências e estado do recurso. Quando uma correção conclui sem alteração de código e apresenta evidência contra a reprovação, encaminhar a disputa ao recurso, incluindo as contestações atualizadas. Limitar o recurso por fase e preservar a capacidade de reprovar problemas reais. Para checagens literais — arquivo ausente, string presente, chave preservada — permitir verificações determinísticas explicitamente declaradas no plano, deixando julgamento semântico para o modelo.

Exigir que uma reprovação identifique o requisito e a evidência concreta ajuda a distinguir defeito do código, contradição do plano e falha de leitura. Não basta acrescentar mais uma instrução genérica de “leia com atenção”: a versão atual já exige leitura completa.

**Efeito esperado:** menos correções sem alteração e menos runs interrompidos com implementação correta. A magnitude dependerá da frequência de falsos negativos. Não é correto prometer recuperar todos os 24min52s da fase 8.

**Aceitação:** um caso com código idêntico e contestação nova precisa acionar o recurso; um defeito real continua reprovando; o valor de tradução presente não pode ser tratado como ausente; não deve haver loop de recursos.

Referências: `scripts/ralph.sh:2447–2555`; Bargi `.phases/logs/run.log:418–428`, `phase-08.verify-{0,1,2}.last.txt`, `phase-08.verify-2.log:2241`, `phase-08.cycle-2.last.txt`. Caminhos de scripts neste relatório são relativos a `plugins/mktux-harness/`.

## 2. Validar contradições entre fases antes da execução — prioridade alta

**Problema confirmado.** A fase 5 remove `flow`, `snapshots` e `weekly_monthly`, mas protege testes que ainda exigem essas chaves. Foram necessários dois ciclos de correção e um juiz para liberar a atualização mínima dos testes. O juiz confirmou expressamente a contradição.

A fase 8 proíbe qualquer ocorrência de identificadores removidos inclusive em `tests/`, enquanto a fase anterior introduz testes que precisam mencionar esses identificadores para afirmar sua ausência. Essa condição não mede corretamente a remoção da funcionalidade. O verificador ora aceitou a contestação, ora voltou à leitura literal.

**Melhoria proposta:** uma revisão de consistência do plano contra o código e entre fases, antes de iniciar o run. Concentrar a revisão em remoções/renomeações, testes protegidos, invariantes temporárias e buscas de ausência. Quando uma fase remove uma interface, ela deve incluir a atualização dos testes que dependem dela; buscas por referências ativas devem distinguir código executável de assertions negativas.

Começar pelas regras da geração do plano e por verificações específicas. Uma revisão semântica extra só se justifica se prevenir mais custo do que acrescenta. Não propor um novo agente revisando tudo em cada fase.

**Efeito esperado:** evitar correções que apenas negociam contradições já presentes no plano. A fase 5 gastou cerca de 14min38s entre a primeira falha da suíte e a conclusão, mas esse intervalo também contém trabalho legítimo; não é inteiramente eliminável.

**Aceitação:** os dois conflitos reais acima precisam ser apontados antes do run; o plano corrigido deve manter a cobertura e a remoção da funcionalidade, sem afrouxar testes para obter verde.

Referências: Bargi `.phases/phase-05.md`, `.phases/phase-08.md`, `.phases/logs/phase-05.judge-2.last.txt`; `skills/plan-project-phases/SKILL.md`.

## 3. Evitar repetir a suíte completa quando sua validade foi preservada — ganho direto de tempo

**Problema confirmado.** `gate2_tests_pass` executa a suíte em toda passagem. No run atual, após sessões explicitamente registradas como sem alteração de arquivo:

| Passagem | Tempo de suíte repetida |
|---|---:|
| Fase 3, ciclo 2 | 2min19s |
| Fase 8, ciclo 1 | 2min23s |
| Fase 8, ciclo 2 | 2min27s |
| Total | **7min09s** |

É aproximadamente 5,5% do tempo desse run somente nessas três passagens. Além disso, as mensagens finais das duas sessões da fase 8 relatam execução da suíte completa dentro da sessão, exigida pelo próprio plano, antes de o gate repetir o comando.

**Melhoria proposta:** permitir reaproveitamento de um resultado verde dentro do run quando código, comando, dependências e ambiente relevante forem os mesmos. Começar com opção explícita por perfil/projeto e invalidação conservadora. Não reutilizar automaticamente resultado vermelho nem persistir cache entre runs nessa primeira versão. Remover dos planos gerados a duplicação da suíte que já é responsabilidade do gate 2, salvo exigência específica do projeto.

**Limite importante:** árvore Git idêntica não prova ambiente idêntico. Arquivos ignorados, banco, serviços, relógio e dependências podem mudar. O ganho de 7min09s é o tempo observado elegível à investigação; só pode ser realizado quando a reutilização for válida. A assinatura atual também não deve ser promovida a chave global: não inclui explicitamente HEAD e ambiente.

**Efeito esperado:** minutos economizados em runs com correções sem escrita; menos tempo de runner nos projetos cuja suíte cresce. O gate externo não consome tokens de modelo diretamente, portanto a economia principal aqui é tempo.

**Aceitação:** árvore e ambiente válidos reutilizam verde; mudança relevante força execução; projetos sem declaração de estabilidade preservam execução completa; a suíte final obrigatória permanece garantida.

Referências: `scripts/ralph.sh:2111–2161,2979`; Bargi `.phases/logs/run.log:420–422,523–537`; `phase-08.cycle-{1,2}.last.txt`.

## 4. Restringir buscas de contexto do juiz — melhoria pequena e concreta

O juiz da fase 5 executou `cat docs/features/*/project-phases.md`, lendo planos de features alheias. O log chegou a aproximadamente 1,10 MB e 12.112 linhas. Tamanho de log não equivale a tokens entregues ao modelo: a ferramenta pode truncar sua resposta. A sessão observada somou 69.424 tokens de entrada; não é o gargalo principal.

**Melhoria proposta:** entregar ao juiz o caminho exato do plano ativo e os trechos pertinentes, aplicando também a ele a orientação de consulta pontual já existente na implementação. Validar que buscas não abrem todos os planos. Se o modelo continuar ignorando o escopo, considerar restrição efetiva da ferramenta de leitura; apenas reforçar o prompt não garante cumprimento.

**Efeito esperado:** menor leitura irrelevante e menor risco de decidir com requisitos de outra feature. O benefício cresce com a quantidade de planos no repositório. Cabe junto da correção de julgamento; isoladamente, não justifica uma grande refatoração.

Referências: `scripts/ralph.sh:2562–2623`; Bargi `.phases/logs/phase-05.judge-2.log:948`.

## Medição: corrigir um defeito antes de comparar economias

Em `telemetry.py:294–299`, a busca por `session id` percorre todo o log e escolhe o último texto compatível, sem validar formato do identificador. No juiz acima, encontrou o UUID correto no cabeçalho, depois palavras de documentos como `and`, `in` e finalmente **`absence`**. O registro da tentativa ficou com `session_id: absence`, embora exista consumo do juiz associado ao UUID real nos snapshots.

Apliquei a mesma expressão ao log, somente em leitura, e reproduzi essa sequência. Isso explica a tentativa sem correspondência nesse run; não prova que todos os eventos possíveis foram capturados.

**Melhoria proposta:** extrair identidade de metadados estruturados ou cabeçalho validado, nunca de prosa arbitrária. Conservar as categorias de cache e incluir no resumo custo por modo, correção e subagente, além de duração dos gates e motivo do retry.

Essa correção **não reduz diretamente o custo da implementação**. Ela evita medir errado o efeito das mudanças prioritárias. Não é razão para construir um novo dashboard agora.

## Escalabilidade: o que faz sentido e o que adiar

O run atual é sequencial, mas as fases alteram repetidamente a mesma action, traduções e view. Não há evidência de que paralelizá-las reduziria o tempo líquido após conflitos e integração. Os 25 subagentes já representam paralelismo interno; consumiram 4.153.017 tokens de entrada, cerca de 14,1% do total observado. Isso não demonstra desperdício: podem ter reduzido a duração da implementação.

Não recomendo remover subagentes nem ampliar sua quantidade sem medir a contribuição por tarefa. Também não recomendo criar um scheduler distribuído.

Há uma limitação concreta para rodar duas instâncias no mesmo checkout: `.phases`, prompts, progresso, logs e alterações Git são compartilhados, e não encontrei trava exclusiva de execução no orquestrador. Os locks da telemetria não protegem esse estado. **Se múltiplos runs simultâneos fizerem parte do uso desejado**, o requisito inicial é isolamento por worktree, trava por checkout e isolamento dos recursos de teste, inclusive banco. Isso protege a concorrência; não acelera o run único atual. Não houve teste de colisão nesta auditoria.

O gate 2 também não passa pelo watchdog de `run_logged`: uma suíte travada pode segurar o run indefinidamente. Um timeout próprio seria útil para execução autônoma, mas não encontrei esse incidente no run analisado; por isso não o classifico como economia já demonstrada.

## O que preservar

- Recorte de contexto por fase e consultas pontuais já implementados.
- Sessões frias e isolamento de memória.
- Testes focados durante implementação e suíte externa como gate.
- Verificação independente: na fase 6 ela detectou cenário de teste realmente incompleto, depois corrigido.
- Memo, recurso e backoff existentes, corrigindo suas interações específicas.

Não há evidência suficiente para recomendar redução global de effort, troca global de modelo, compressão cosmética dos prompts ou reescrita do Bash. O modelo verificador já foi barato neste run em participação de tokens; desligá-lo sacrificaria uma verificação que encontrou defeito real.

## Ordem recomendada e comprovação

1. Corrigir associação de sessões na telemetria e o recurso com contestações novas.
2. Incorporar os conflitos reais na validação/geração dos planos.
3. Eliminar duplicação explícita de suíte e implementar reutilização conservadora onde o ambiente permitir.
4. Ajustar escopo de leitura do juiz junto dessas mudanças.

Validar primeiro com fixtures locais que reproduzam os casos observados, sem consumo de modelos. Depois, mediante autorização para execução real, comparar tarefas equivalentes em checkouts isolados, mantendo modelo, effort, plano e ambiente controlados. Registrar tempo, entrada nova, entrada em cache, saída, correções, falsos negativos e defeitos detectados. Fixtures verdes comprovam a mecânica; não comprovam economia real nem qualidade do julgamento.

**Critério de sucesso:** menos sessões sem alteração, menos repetição de suíte e menos interrupções incorretas, preservando a detecção de defeitos. As economias potenciais deste relatório se sobrepõem e não devem ser somadas. A maior oportunidade está em evitar o trabalho que não deveria ter sido necessário.


---

# Plano de execução por etapas — instruções para o implementador

Esta seção é a fonte principal do plano. Os números **Etapa 1** a **Etapa 6** abaixo são os números que o usuário utilizará nos pedidos de implementação; não confundir com os números dos achados da auditoria acima.

## Como executar um pedido curto

- **“Faça a etapa N”**: implementar e validar somente essa etapa; ao terminar, registrar o resultado e informar a próxima. Não significa autorização implícita para todas as seguintes.
- **“Faça da etapa 1 até a 6, em sequência”**: seguir as etapas autorizadas, validando cada uma antes de avançar, sem pedir confirmação entre etapas rotineiras. Respeitar as condições das etapas 5 e 6; autorização da sequência não transforma condição técnica ausente em condição satisfeita.
- Verificar os pré-requisitos lendo o estado do código e o registro de execução; não confiar apenas na marcação de conclusão. Etapas 1–4 podem ser verificadas localmente; etapa 5 depende delas; etapa 6 depende da avaliação da etapa 5.
- Se uma etapa já estiver implementada, confirmar o aceite e registrar a evidência, sem reimplementá-la.

## Contrato de trabalho comum

1. Trabalhar no repositório `mktux-harness`. Conferir instruções locais, Git e mudanças existentes antes de editar. Preservar trabalho alheio. Os caminhos abreviados `scripts/`, `skills/` e `profiles/` nesta seção são relativos a `plugins/mktux-harness/`.
2. Ler a etapa solicitada e o achado correspondente. Usar funções e arquivos indicados como pontos de partida; conferir os nomes no código atual porque números de linha podem mudar.
3. Fazer a menor alteração que cumpra o aceite. Manter compatibilidade das engines suportadas e neutralidade de stack. Não introduzir refatoração abrangente, framework, dependência ou novo serviço sem necessidade demonstrada.
4. Para bugs mecânicos, reproduzir a falha com fixture sintética antes da correção e verificar que passa depois. Não enfraquecer assertions para obter verde.
5. Rodar testes focados e os checks pertinentes. Para alterações na orquestração, executar também as suítes locais do harness. Evitar repetição de checks já verdes sem nova mudança que os afete.
6. Preservar gates, restrições de escrita, regras de interrupção e rastreabilidade dos erros. Não contornar falhas desligando o verificador, marcando tasks de código como manuais ou tratando ausência de dados como sucesso.
7. Consultar projetos reais somente em leitura. Reproduções que escrevam devem usar diretórios ou checkouts temporários isolados, sem credenciais, contas ou efeitos de produção. Não versionar logs privados.
8. A execução de uma etapa autoriza suas alterações locais e testes simulados. Execuções reais de modelos devem estar abrangidas pelo pedido do usuário; se já autorizadas, não perguntar de novo. Antes de executar, definir casos e limite de consumo/tentativas. Sem essa autorização, completar a validação local e registrar a medição real como pendente.
9. Commit, push, PR, release e instalação não fazem parte destas etapas, salvo pedido explícito do usuário.
10. Ao terminar, atualizar o registro abaixo com arquivos alterados, comandos e resultados reais, critérios atendidos, pendências e próximo passo. Não declarar economia real com base apenas em testes simulados.

## Modelo recomendado

**Recomendação prática: GPT-6 Luna, esforço `high`, uma etapa por vez.** O escopo delimitado, as fixtures e os critérios de aceite tornam essa uma opção econômica para tentar primeiro. Não existe benchmark deste plano que comprove ser a combinação de menor custo total; corrigir erros também consome tempo e tokens.

Se surgirem falhas repetidas de entendimento na etapa 2 ou na política de invalidação da etapa 6, usar **GPT-6.1 Sol** para revisar o diff e o problema específico, sem reiniciar o trabalho inteiro. Não é necessário contratar uma revisão adicional para cada alteração simples.

A documentação oficial consultada em 06/10/2026 posiciona [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) para tarefas focadas e econômicas e [GPT-6.1 Sol](https://developers.openai.com/api/docs/models) como equilíbrio entre capacidade e custo. A escolha de esforço `high` é uma recomendação para este plano. Preço de API não equivale ao consumo de cota de uma assinatura; este documento não estima cobrança nem garante disponibilidade no seletor de cada conta.

## Pedidos prontos

Para começar com uma etapa:

```text
Leia a seção “Plano de execução por etapas” do arquivo
RELATORIO-EFICIENCIA-HARNESS-2026-10-06.md e faça a etapa 1.
Implemente, valide pelos critérios de aceite e atualize o registro de execução.
Conclua somente essa etapa e informe o próximo passo.
```

Depois, no mesmo contexto, basta pedir `Faça a etapa 2`, e assim sucessivamente. Em uma conversa nova, mencione novamente o nome do relatório.

Para uma sequência autônoma:

```text
Leia a seção “Plano de execução por etapas” do arquivo
RELATORIO-EFICIENCIA-HARNESS-2026-10-06.md e execute da etapa 1 até a 6,
em ordem. Valide cada etapa antes de avançar e atualize o registro de execução.
Siga sem novas confirmações nas alterações locais e testes simulados.
Na etapa 5, prepare e conclua a validação local; registre a comparação real
como pendente se eu ainda não tiver autorizado o consumo de modelos.
Na etapa 6, implemente somente se as condições de benefício e estabilidade
forem demonstradas; caso contrário, registre ADIADA com o motivo.
Não faça commit, push, release ou instalação.
```

Uma sequência pode terminar com medição real pendente e etapa 6 adiada. Isso deve ficar explícito no resultado, sem declarar as seis etapas concluídas. Para exigir a medição real também, o pedido deve incluir autorização de execução e um limite de consumo ou de tentativas apropriado aos casos preparados.

## Registro de execução

Estado inicial deste plano: nenhuma etapa implementada por esta auditoria.

| Etapa | Estado | Evidências / pendências |
|---|---|---|
| 1 | CONCLUÍDA | Corrigida e revisada em 06/10/2026; falha reproduzida com fixtures, suites locais verdes e conferência somente em leitura do log observado. Detalhes abaixo. |
| 2 | CONCLUÍDA | Assinaturas de código e evidências separadas; recurso direto com contestação nova. Falha reproduzida antes da correção; 554 asserts de orquestração e 122 de layout verdes. Detalhes abaixo. |
| 3 | CONCLUÍDA | Pendências da revisão corrigidas: procedimento para planos existentes, exemplo de ausência e fechamento check-only; 139 asserts de layout verdes. Comportamento de modelo real não observado. Detalhes abaixo. |
| 4 | CONCLUÍDA | Pendência da revisão corrigida; 61 assertions focadas, 572 de orquestração e 139 de layout verdes. Nova chamada real adversarial consultou somente caminhos pertinentes; avaliação da restrição técnica registrada abaixo. |
| 5 | VALIDADA LOCALMENTE | Duas suítes, sintaxe e diff check verdes; comparação real pendente de autorização com limite de consumo. Detalhes abaixo. |
| 6 | ADIADA | A repetição por ciclo continua no código, mas não há comparação pós-etapas 1–4 nem projeto com ambiente de testes controlado e fingerprint declarado para validar a adesão. |

Estados possíveis: EM ANDAMENTO, VALIDADA LOCALMENTE, CONCLUÍDA, PENDENTE ou ADIADA. Para as etapas 3 e 4, declarar separadamente se o comportamento do modelo foi observado em execução real. Para a etapa 5, “CONCLUÍDA” exige a comparação real descrita no aceite; validação local isolada não basta.

### Registro detalhado — etapa 1 (06/10/2026)

Em `plugins/mktux-harness/scripts/telemetry.py`, a gravação de tentativas extrai IDs somente de eventos de identidade reconhecidos no JSON/JSONL inicial: `session_meta` ou `thread.started` do Codex e `result` do Claude. JSON emitido posteriormente no corpo do log não vira metadado. Nos logs textuais do Codex, a extração aceita o cabeçalho `Session ID: <UUID>` dentro do bloco inicial de metadados do CLI (ou linhas completas e consecutivas no início de um log sem banner), reconhecendo também `session_id` e `session-id`. Em `verify`/`judge` do Claude, a saída textual é a resposta do modelo e não fornece identidade confiável. Identidades conflitantes na fonte reconhecida deixam a tentativa sem ID e impedem o fallback por snapshots. Sem identidade encontrada, permanece o fallback existente quando há exatamente um snapshot raiz correspondente à fase/ciclo/modo; sem correspondência, a tentativa segue parcial.

As fixtures sintéticas em `plugins/mktux-harness/scripts/test-layout.sh` cobrem o cabeçalho válido seguido por `session ID absence`, outro cabeçalho e JSON no corpo; os eventos `session_meta` e `result` com JSON de `assistant` conflitante; resposta textual do Claude em `verify`; identidade ambígua mesmo com um único snapshot candidato; tentativas distintas; deduplicação de Stop/reconciliação; cache; e registro parcial sem identidade. Os IDs de texto nas fixtures seguem o formato UUID das engines; os dados históricos não foram reescritos. Os testes de telemetria ficam em `test-layout.sh`; `test-ralph.sh` cobre a integração/orquestração.

Validação antes da correção: um run sintético isolado registrou `absence` no lugar do UUID do cabeçalho; as fixtures ampliadas reprovaram seis associações antes do ajuste da extração. Após a correção:

- `bash plugins/mktux-harness/scripts/test-layout.sh` — `TODOS VERDES: 122 asserts`.
- `bash plugins/mktux-harness/scripts/test-ralph.sh` — `TODOS VERDES: 534 asserts`.
- `bash -n` em `test-layout.sh`, `test-ralph.sh` e `ralph.sh` — passou.
- Compilação sintática em memória de `telemetry.py` — passou.
- `git diff --check` — passou.
- Conferência somente em leitura de `.phases/logs/phase-05.judge-2.log` no Bargi: um UUID no cabeçalho do Codex, identidade extraída igual a ele, `absence` rejeitado e um snapshot raiz correspondente. Nenhum identificador ou conteúdo privado foi copiado para o repositório.

Não foram executados modelos reais nem alterados dados de projetos. A etapa corrige a confiabilidade da medição; não foi contabilizada como economia de tokens. Próximo passo: etapa 2.

### Registro detalhado — etapa 2 (06/10/2026)

Em `plugins/mktux-harness/scripts/ralph.sh`, o memo do gate 3 agora mantém assinaturas separadas para o estado do código e para contestações/travas. Quando a verificação reprova e a sessão de correção preserva o mesmo código, a existência de novas contestações invalida o veredito anterior e encaminha a disputa diretamente ao recurso, com o prompt construído a partir das evidências atuais. Não há uma nova sessão barata intermediária. Com código alterado, o fluxo executa uma verificação normal. O recurso continua limitado a uma tentativa por fase; se não emitir veredito, a reprovação e sua causa original permanecem.

As fixtures em `plugins/mktux-harness/scripts/test-ralph.sh` reproduzem código igual com contestação idêntica ou nova, código alterado, recurso que confirma a reprovação e recurso sem veredito. Também conferem que o recurso recebe as contestações atuais, que não há repetição barata antes dele, que a resposta sem veredito não aprova e que as restrições de leitura e o gate 2 seguem ativos.

Validação antes da correção: o caso sintético de código igual com contestação nova falhou em seis assertions: chamou o modelo barato, não acionou o recurso e encerrou a fase travada. Após a correção:

- `bash plugins/mktux-harness/scripts/test-ralph.sh` — `TODOS VERDES: 554 asserts`.
- `bash plugins/mktux-harness/scripts/test-layout.sh` — `TODOS VERDES: 122 asserts`.
- Casos focados de recurso aprovado, reprovação mantida, evidência nova, recurso sem veredito, código alterado e integração de contestações — todos verdes.
- `bash -n` em `ralph.sh` e `test-ralph.sh` — passou.
- `git diff --check` — passou.

Não foram executados modelos reais. Os testes simulados comprovam a decisão do orquestrador e os limites do recurso; ainda não medem a frequência de falsos negativos nem a economia em execuções reais. Próximo passo: etapa 3.

### Registro detalhado — etapa 3 (06/10/2026)

Em `plugins/mktux-harness/skills/plan-project-phases/SKILL.md`, a revisao
obrigatoria do rascunho completo agora ocorre na mesma sessao que gera o plano,
antes de gravar o artefato. Ela mapeia remocoes e renomeacoes aos consumidores e
testes, delimita o ciclo de vida das invariantes, separa referencias ativas de
assertions negativas e impede que a fase de fechamento repita pelo
`test-runner` o comando completo ja executado pelo Gate 2. Uma verificacao
adicional so fica no plano quando uma instrucao explicita do projeto exige algo
que o Gate 2 nao cobre.

A skill documenta exemplos sinteticos revisados para os conflitos observados:
a remocao de `flow`, `snapshots` e `weekly_monthly` atualiza os testes que ainda
esperam essas chaves na mesma fase (ou preserva compatibilidade ate a adaptacao
dos consumidores); uma busca por ausencia fica limitada ao codigo ativo e
permite que `tests/` cite identificadores em assertions negativas. O roteiro de
Regression e a referencia Laravel tambem deixam de prescrever a suite completa
como tarefa duplicada.

`plugins/mktux-harness/scripts/test-layout.sh` ganhou onze verificacoes do
contrato e dos exemplos documentados. Elas protegem as instrucoes da skill, mas
nao alegam avaliar semanticamente um plano gerado por modelo; essa avaliacao
continua prevista na etapa 5.

Validacao local em 06/10/2026:

- `bash plugins/mktux-harness/scripts/test-layout.sh` — `TODOS VERDES: 133 asserts`.
- `bash -n plugins/mktux-harness/scripts/test-layout.sh` — passou.
- `git diff --check` — passou.
- Revisao dos exemplos sinteticos de remocao de payload, busca por ausencia e
  fechamento — coerentes com a atualizacao dos testes, cobertura negativa e
  execucao unica da suite completa pelo Gate 2.

#### Correção após revisão da entrega (06/10/2026)

A revisão posterior identificou três pendências na entrega inicial, apesar dos
133 asserts verdes. Elas foram corrigidas em `SKILL.md`:

- Documentado o procedimento de revisão de planos existentes antes do run,
  aplicando os mesmos quatro passos a todas as fases e registrando requisito,
  evidência, fases afetadas e proposta. A revisão não reescreve o plano; quando
  o pedido inclui correção, as alterações ocorrem fora do run, com auto-checagem
  e informação do efeito sobre stamp/progresso. Alteração automática durante o
  run fica expressamente proibida.
- Substituído o exemplo antigo da tabela de tasks que proibia identificadores
  em todos os arquivos de `tests/`. O exemplo agora delimita leituras/emissões
  ativas em código de runtime e permite referências em assertions negativas.
- Incluído `**Check-only phase**` no exemplo sintético de fechamento, que apenas
  verifica estados existentes.

Seis verificações adicionais em `test-layout.sh` cobrem essas pendências. A
checagem do fechamento usa a função `phase_is_check_only` extraída do próprio
`ralph.sh` contra as fases documentadas: o fechamento é reconhecido, e a fase
que altera código/testes permanece sem o marcador. Antes da correção, cinco
dessas verificações falharam, reproduzindo os pontos da revisão.

Validação após a correção:

- `bash plugins/mktux-harness/scripts/test-layout.sh` — `TODOS VERDES: 139 asserts`.
- `bash -n plugins/mktux-harness/scripts/test-layout.sh` — passou.
- `git diff --check` — passou.
- Revisão dos seis itens de trabalho da etapa 3 — atendidos na documentação;
  exemplos de ausência e fechamento agora seguem as regras da própria skill.

Nenhum modelo real gerou um plano nesta etapa; portanto, o comportamento do
modelo não foi observado em execução real. Essa avaliação permanece prevista
na etapa 5. A etapa 4 foi concluída; próximo passo: etapa 5.

### Registro detalhado — etapa 4 (06/10/2026)

Em `plugins/mktux-harness/scripts/ralph.sh`, `build_judge_prompt` agora resolve
o caminho canônico do plano de fases ativo e reaproveita `phase_context` para
anexar somente os trechos selecionados pela fase e pelas contestações pendentes.
O recorte inclui o título/regra e a story citados, sem anexar documentos irmãos
inteiros nem documentos ou planos de outras features. As instruções do juiz
priorizam caminhos, símbolos e regras citados, permitem seguir imports e
dependências relevantes, proíbem listar planos alheios e mantêm o modo
somente-leitura já aplicado pelo runner.

O caso `contest-judge-context` em `plugins/mktux-harness/scripts/test-ralph.sh`
cria duas features e documentos citados e não citados. As assertions conferem o
caminho exato, os trechos BR/US necessários, a ausência dos documentos alheios,
as instruções de consulta e a configuração read-only.

Validações locais em 06/10/2026:

- `bash plugins/mktux-harness/scripts/test-ralph.sh contest-judge` — `57`
  assertions verdes.
- `bash plugins/mktux-harness/scripts/test-ralph.sh` — `TODOS VERDES: 568
  asserts`.
- `bash plugins/mktux-harness/scripts/test-layout.sh` — `TODOS VERDES: 139
  asserts`.
- `bash -n` em `ralph.sh`, `test-ralph.sh` e `test-layout.sh` — passou.
- `git diff --check` — passou.

Comportamento de modelo real observado: uma chamada limitada do juiz Codex,
modelo `gpt-6-luna`, effort `low`, em um repositório Git temporário com fixture
sintética e somente uma chamada de juiz. O prompt continha o caminho absoluto do
plano ativo e os recortes BR-13/US-2.1. O log mostra leitura do plano ativo, da
fase e do arquivo citado pela contestação; o juiz respondeu `UPHELD` para a
contradição entre a task e a proibição de alterar o arquivo. Ele consultou os
dois símbolos citados por uma busca `rg` iniciada na raiz do fixture, excluindo
dependências e lockfiles, e depois tentou uma busca limitada a diretórios de
testes que não existiam naquela fixture. A revisão posterior confirmou que essa
busca na raiz podia devolver planos alheios quando eles contivessem os mesmos
símbolos. A fixture inicial não tinha essa colisão, portanto aquela chamada não
comprovou o escopo restrito das consultas. A validação do run terminou com
código 1 porque o teste da fixture foi deliberadamente configurado para falhar
após o julgamento; o veredito real foi emitido antes dessa falha esperada.

O run usou somente dados sintéticos, sem executar testes ou comandos de escrita
no juiz. A suíte simulada valida o contrato do prompt; a chamada real verifica
apenas esse caso delimitado. Não se afirma economia de tokens nem conformidade
universal. A pendência identificada na revisão e seu fechamento são registrados
a seguir.

#### Correção após revisão da entrega (06/10/2026)

O prompt agora informa também o caminho canônico do diretório documental da
feature ativa. Proíbe explicitamente buscas recursivas na raiz, incluindo
`rg/grep` sobre `.` e Glob `**/*`, e limita buscas por símbolos aos arquivos
citados ou diretórios pertinentes de código/testes. Para documentos, o mesmo
escopo vale para Read, Glob, Grep e comandos equivalentes, mesmo quando outras
features usam os mesmos símbolos ou IDs BR/US. Seguir imports e dependências
do projeto continua permitido.

A fixture de `test-ralph.sh` agora contém `InboundValue`, BR-13 e US-2.1 também
na feature alheia, com contrato conflitante e marcadores próprios. Quatro
assertions adicionais cobrem o diretório permitido e as instruções de escopo.
Antes da correção, essas quatro assertions falharam; após a correção, o teste
focado terminou com `TODOS VERDES: 61 asserts`. `test-layout.sh` passou novamente
com 139 assertions. As verificações `bash -n` foram executadas separadamente
para `ralph.sh` e `test-ralph.sh`, ambas com sucesso.

Foi executada uma nova chamada real limitada, `gpt-6-luna` com effort `low`,
usando o prompt produzido por `build_judge_prompt` em um repositório Git
temporário (sessão sintética `01a11393-88b4-7ee3-b84a-38fc1f6b6ae6`). A sessão recebeu as mesmas flags de read-only, isolamento de hooks
e memória do runner. A feature alheia continha `InboundValue`, BR-13 e US-2.1,
com instruções conflitantes. O teste sintético de identidade do objeto falhou
antes da chamada, produzindo a evidência da disputa; o juiz não executou testes.
O código importava `make_payload` de `src/contract.py`, permitindo conferir que
a consulta a uma dependência relevante continua disponível.

O transcript registra uma única chamada de ferramenta com leituras explícitas:

```sh
cat docs/features/target/feature-description.md &&
cat docs/features/target/user-stories.md &&
cat src/handler.py && cat tests/test_handler.py && cat src/contract.py &&
cat .phases/phase-01.md && cat docs/features/target/project-phases.md
```

Não houve busca recursiva, leitura/listagem da feature alheia, consulta a
dependências de terceiros nem execução de build/teste/lint pelo juiz. A sessão
real terminou com código 0 e `CONTEST TASK 1: UPHELD`, autorizando remover a
proibição de alterar o handler para aceitar/retornar o objeto sem conversão.
Hashes dos arquivos de código, testes e documentos permaneceram idênticos.
Uma consulta ampla reproduzida localmente nessa mesma fixture devolveu os dois
documentos alheios com seus marcadores, confirmando que o caso realmente expõe
o problema se houver busca fora do escopo. Em outra cópia temporária, a mudança
mínima autorizada no handler fez o teste passar (código 0), mantendo o teste
idêntico; isso confere a evidência do veredito sem enfraquecer a assertion.
Essa chamada valida somente o caso adversarial descrito; não mede economia,
não compara baseline/candidato e não substitui a etapa 5.

Avaliação da restrição técnica de leitura, conforme a cláusula desta etapa:

- O runner atual controla escrita, mas não implementa autorização de leitura
  por caminho. A retirada de Glob isoladamente não bloquearia buscas por Grep
  ou comandos equivalentes. Restringir todas as leituras ao diretório documental
  também impediria analisar código/testes e seguir imports pertinentes.
- Uma restrição técnica robusta exigiria validar caminhos canônicos em cada
  operação de leitura/busca, ou um isolamento de filesystem que disponibilizasse
  código/testes e somente os documentos da feature ativa. Isso precisa tratar
  symlinks, imports externos ao diretório inicial e ambas as engines, com testes
  próprios, em trabalho separado.
- Decisão nesta etapa: manter as travas de escrita existentes e o mecanismo de
  recorte, entregar instruções de consulta mais específicas e validar o caso com
  colisões. Não introduzir um novo mecanismo de filesystem/tooling nesta etapa.
  O escopo das consultas continua orientado pelo prompt, não garantido por uma
  barreira técnica de leitura. Se o desvio reaparecer, essa restrição deve ser
  especificada e validada em trabalho separado antes de afirmar isolamento.

Validação final após a correção:

- `bash plugins/mktux-harness/scripts/test-ralph.sh contest-judge` — `TODOS VERDES: 61 asserts`.
- `bash plugins/mktux-harness/scripts/test-ralph.sh` — `TODOS VERDES: 572 asserts`.
- `bash plugins/mktux-harness/scripts/test-layout.sh` — `TODOS VERDES: 139 asserts`.
- `bash -n` executado separadamente em `ralph.sh`, `test-ralph.sh` e `test-layout.sh` — passou.
- `git diff --check` e checagem de whitespace do relatório ainda não versionado — passaram.
- Chamada real adversarial: código 0, uma ferramenta com caminhos explícitos,
  dependência consultada, nenhuma leitura alheia ou alteração dos arquivos.
- Conferência independente da mudança mínima autorizada: teste verde com a
  assertion preservada em outra cópia temporária.

Etapa 4 concluída conforme seus quatro itens de trabalho e critérios de aceite.
A avaliação técnica documentada fecha a pendência da revisão sem declarar uma
barreira de leitura que não existe. Próximo passo: etapa 5, ainda não iniciada.

### Registro detalhado — etapa 5 (06/10/2026)

Validação local executada sobre `16f6c39` (melhorias das etapas 1–4):

- `bash plugins/mktux-harness/scripts/test-ralph.sh` — `TODOS VERDES: 572 asserts`.
- `bash plugins/mktux-harness/scripts/test-layout.sh` — `TODOS VERDES: 139 asserts`.
- `bash -n` em `ralph.sh`, `test-ralph.sh` e `test-layout.sh` — passou.
- Compilação sintática em memória de `telemetry.py` — passou.
- `git diff --check` — passou após este registro.

As suítes incluem fixtures sintéticas para identidade de sessão, código igual
com contestação nova, limite de um recurso por fase, recurso sem veredito,
contexto do juiz e preservação de testes negativos. Elas confirmam a mecânica
local do harness e que os defeitos simulados continuam cobertos. Não são uma
execução do Ralph com modelo real, nem medem se um modelo real detecta todos os
defeitos apresentados.

A comparação entre baseline e candidato não foi executada. O procedimento desta
auditoria exige autorização para consumo de modelos e um limite de tentativas
antes dessa medição; o pedido desta etapa não especificou esse limite. Portanto,
não houve chamadas reais, tarefas reais em checkouts temporários nem coleta de
duração, tokens de entrada/cache/saída, sessões por modo ou correções sem
escrita. Nenhuma economia ou ganho de qualidade é declarado. A etapa fica
`VALIDADA LOCALMENTE`, com a comparação real pendente; para concluí-la, será
necessário autorizar a comparação delimitada e definir o limite de consumo.

### Registro detalhado — etapa 6 (06/10/2026)

**Estado: ADIADA conforme a condição de entrada da etapa.** A etapa 5 segue
`VALIDADA LOCALMENTE`, com a comparação baseline/candidato pendente. O achado
original mediu 7min09s em três repetições elegíveis antes das etapas 1–4; a
implementação atual ainda chama o gate 2 em cada ciclo. A etapa 3 removeu dos
planos gerados a instrução duplicada para rodar a suíte completa, mas não há run
posterior que demonstre quanto desse custo permanece depois das mudanças.
Portanto, o benefício residual não foi reavaliado.

Também não foi identificado projeto com adesão explícita e fingerprint de
ambiente validado. O comando do gate 2 pode vir de override ou dos perfis
Laravel, Node e Python; estes incluem serviços Sail, dependências/runtime locais
e estado externo que não são descritos pela árvore Git. O harness não possui um
contrato de opt-in nem uma declaração versionada que cubra esses fatores. Uma
assinatura somente do Git seria insuficiente, e criar um cache genérico agora
contrariaria a invalidação conservadora especificada no plano. Nenhum código do
orquestrador foi alterado nesta etapa.

Validação solicitada, executada em 06/10/2026:

- `bash plugins/mktux-harness/scripts/test-ralph.sh` — exit 0; `TODOS VERDES: 572 asserts`.
- `bash plugins/mktux-harness/scripts/test-layout.sh` — exit 0; `TODOS VERDES: 139 asserts`.

As suítes confirmam o estado atual do harness; não demonstram estabilidade de um
ambiente de projeto nem economia por reutilização. Próximo passo: concluir a
comparação real da etapa 5, com limite de tentativas/consumo autorizado, e
reavaliar a etapa 6 somente se ela mostrar custo residual relevante e houver um
projeto controlado para validar o fingerprint.

## Sequência proposta

| Etapa | Entrega | Benefício | Prioridade |
|---|---|---|---|
| 1 | Corrigir identidade das sessões na telemetria | Medição confiável do antes/depois | Pré-requisito curto |
| 2 | Corrigir recurso quando há contestação nova | Menos travamentos e correções sem escrita | Máxima |
| 3 | Evitar contradições e testes duplicados nos planos | Menos retrabalho antes mesmo de executar | Alta |
| 4 | Entregar contexto específico ao juiz | Menos leitura irrelevante e confusão entre features | Complementar |
| 5 | Medir o resultado das etapas anteriores | Confirmar ganho e preservar qualidade | Obrigatória para declarar economia |
| 6 | Reutilizar suíte verde em ambiente estável | Reduzir tempo de runner | Condicional |

## Etapa 1 — Consertar a associação de sessões

**Arquivos iniciais:** `plugins/mktux-harness/scripts/telemetry.py` e `plugins/mktux-harness/scripts/test-layout.sh` (onde já ficam os testes de telemetria); validar também a integração com `test-ralph.sh` quando necessário.

Trabalho:

1. Criar fixture mínima, sintética, com cabeçalho de sessão válido e prosa posterior contendo `session ID absence`. Não copiar logs privados inteiros para o repositório.
2. Extrair a identidade de evento estruturado quando disponível; para logs textuais, aceitar somente o cabeçalho reconhecido e o formato de ID da engine. Não selecionar o último texto encontrado no corpo do log.
3. Quando a identificação for impossível ou ambígua, preservar ausência/estado parcial, sem inventar identidade ou consumo zero.
4. Preservar deduplicação de snapshots, atribuição de subagentes e semântica de cache. Não reescrever os arquivos históricos originais.

**Aceite:** a fixture associa o UUID correto, nunca `absence`; tentativas distintas continuam distintas; Stop e reconciliação não duplicam consumo; registros sem identidade permanecem parciais. Cobrir os formatos atualmente suportados de ambas as engines.

**Validação:** reproduzir a falha antes da correção e executar os testes focados depois. Comparar a reconciliação antiga e nova sobre cópias temporárias de dados, caso necessário. Essa etapa não será contabilizada como economia direta de tokens.

## Etapa 2 — Corrigir a escalada do verificador

**Arquivos iniciais:** `scripts/ralph.sh`, `scripts/test-ralph.sh` e documentação operacional afetada, dentro do plugin.

Trabalho:

1. Separar o estado usado para identificar código igual do estado usado para invalidar o memo por novas evidências.
2. Depois de reprovação do gate 3, se a sessão de correção concluir com código idêntico ao código reprovado, acionar o recurso ainda disponível, inclusive quando as contestações tiverem mudado.
3. Entregar ao recurso as evidências e contestações atualizadas. Não abrir primeiro mais uma verificação barata redundante nesse caminho.
4. Manter no máximo um recurso por fase. Mudanças reais de código seguem a verificação normal; falha de engine não equivale a discordância fundamentada.
5. Registrar no log por que o recurso foi acionado, preservando a causa original caso ele termine sem veredito.

**Aceite:**

- Código igual + contestação nova aciona um recurso e não termina prematuramente como fase travada.
- Código igual + contestação igual preserva o comportamento de recurso já existente.
- Código alterado recebe julgamento normal; uma reprovação antiga não é reaproveitada indevidamente.
- Recurso que confirma defeito mantém reprovação; recurso sem resposta não aprova; recurso já usado não entra em loop.
- Não há alteração das restrições de escrita dos verificadores nem dispensa do gate 2.

**Validação:** fixtures das combinações acima, testes de memo/recurso/contestação e suíte local do harness. Testes simulados comprovam a decisão do orquestrador, não que o modelo sempre dará o veredito correto.

**Ganho buscado:** eliminar a brecha que manteve a fase 8 travada. Esta etapa ainda pode exigir uma sessão de correção antes do recurso; não promete eliminar todo o custo observado dessa sessão.

## Etapa 3 — Melhorar a consistência dos planos e eliminar duplicação explícita

**Arquivos iniciais:** `skills/plan-project-phases/SKILL.md`, referências pertinentes e testes de layout/contratos. Alterar referências de stack somente quando necessário.

Trabalho:

1. Integrar uma revisão de consistência à própria geração do plano, antes de concluir o artefato, sem criar uma sessão extra por fase.
2. Para cada remoção ou renomeação de interface, identificar consumidores e testes que precisam mudar. A fase responsável deve autorizar e especificar essas atualizações.
3. Conferir se uma condição preservada nas primeiras fases deixa de valer legitimamente nas posteriores. Não carregar uma invariante temporária até o fechamento.
4. Diferenciar referências ativas de assertions negativas em condições de ausência. Não resolver o problema excluindo todos os testes da análise.
5. Fazer a fase de fechamento reconhecer a suíte executada pelo gate 2, evitando mandar um subagente executar o mesmo comando novamente. Respeitar exigências explícitas do projeto.
6. Documentar esse procedimento também para revisão de planos existentes, sem alterá-los automaticamente durante o run.

**Aceite:** exemplos sintéticos derivados dos dois conflitos do relatório produzem planos coerentes: remoção de payload inclui atualização dos testes dependentes; remoção de funcionalidade permite testes negativos pertinentes; suíte completa não aparece duplicada sem justificativa; cobertura de regressão permanece.

**Validação:** revisar exemplos de plano antes/depois e executar testes de contrato. Um teste que apenas encontra uma frase na skill não comprova capacidade de identificar contradições semânticas: a etapa 5 precisa avaliar planos gerados de fato.

**Limite:** não construir agora um analisador universal de contradições em texto livre. Caso a revisão integrada não resolva os casos observados, avaliar uma revisão semântica única antes do run, comparando seu custo ao retrabalho evitado.

## Etapa 4 — Restringir o contexto entregue ao juiz

**Arquivos iniciais:** `scripts/ralph.sh`, biblioteca existente de recorte de contexto e testes correspondentes.

Trabalho:

1. Informar o caminho exato do plano ativo e fornecer os recortes das regras citadas pela fase/contestação.
2. Reaproveitar o mecanismo atual de recorte, sem anexar todos os documentos da feature.
3. Orientar consultas pontuais por caminho, símbolo e regra, evitando glob de todos os planos do repositório.
4. Preservar consulta a dependências relevantes do código quando necessária para julgar corretamente.

**Aceite:** em fixture com várias features, o prompt aponta o plano correto e não incorpora planos alheios; contém a evidência necessária à disputa; mantém limites de contexto e modo somente leitura.

**Validação real:** conferir as ferramentas usadas pelo juiz. Prompt correto não garante obediência. Se persistirem buscas indiscriminadas, avaliar uma restrição técnica de leitura em trabalho separado, sem afirmar que o problema já foi resolvido.

## Etapa 5 — Comprovar o resultado

Primeiro executar validações locais do harness, sem modelos reais: testes focados de cada alteração, suítes `test-ralph.sh` e `test-layout.sh`, verificações sintáticas aplicáveis e `git diff --check`. Nenhuma suíte do Bargi é necessária para comprovar a mecânica do orquestrador.

Depois, quando a execução real for autorizada, comparar baseline e candidato em checkouts temporários isolados. Manter iguais o commit inicial do projeto, modelo, effort, ambiente e plano ao medir alterações do orquestrador. Avaliar mudanças do plano em uma comparação separada; mudar tudo ao mesmo tempo impediria atribuir o ganho.

Usar casos delimitados:

- Reprovação contestada sem mudança de código.
- Remoção de contrato que exige atualizar testes.
- Defeito real, como cenário de teste ausente, que deve continuar reprovando.

Registrar duração, entrada nova, entrada em cache, saída, sessões por modo, correções sem escrita, execuções de suíte e resultado de revisão independente das tasks. Reutilizar dados existentes; acrescentar campos somente quando faltarem para essa comparação, sem criar dashboard novo.

**Aceite:** falhas mecânicas observadas não se repetem; defeitos reais continuam detectados; redução de trabalho aparece nas métricas. Uma única comparação demonstra somente aqueles casos. Para afirmar ganho geral, repetir casos representativos e publicar também a variação e regressões encontradas.

Não somar economias sobrepostas nem prometer recuperar todos os tokens de correção do relatório. Se não houver ganho líquido, simplificar ou retirar a mudança responsável antes de ampliá-la.

## Etapa 6 — Reutilização conservadora de suíte verde

Iniciar somente se, após as etapas anteriores, a repetição de suíte ainda representar custo relevante e houver projeto com ambiente de testes suficientemente controlado.

Trabalho:

1. Definir contrato explícito de adesão por projeto/perfil; manter execução normal como padrão.
2. Restringir reutilização inicialmente à mesma fase e ao mesmo run, após resultado verde do gate externo. Não confiar apenas no relato do agente.
3. Validar identidade de HEAD, conteúdo relevante, comando, configuração, dependências e estado externo exigido pelo projeto. Uma assinatura só do Git é insuficiente.
4. Ambiente indeterminado, fingerprint ausente, resultado vermelho, mudança relevante ou novo run obrigam execução.
5. Preservar uma execução efetiva no fechamento obrigatório e registrar claramente quando um resultado foi reutilizado.

**Aceite:** fixture estável reutiliza verde; mudança de código, comando ou ambiente invalida; ausência de adesão mantém comportamento atual; falha anterior nunca é tratada como verde; dois runs não compartilham o resultado.

**Validação:** testar invalidação e, em projeto adequado, comparar tempo e número de execuções. Se não for possível representar o ambiente com confiança e custo razoável, adiar esta etapa e manter somente a eliminação da duplicação explícita feita na etapa 3.

Os 7min09s do relatório são tempo observado de repetição, não economia garantida nem meta obrigatória para qualquer projeto.

## Itens fora da primeira entrega

- Verificações determinísticas declaradas no plano: avaliar se checagens literais continuarem causando falsos negativos após a etapa 2. Começar por um conjunto pequeno de condições estruturadas, com comportamento definido para condições não suportadas; não converter texto livre arbitrariamente em comandos.
- Concorrência entre runs: só implementar quando houver necessidade real, começando por trava de checkout e isolamento de worktree/banco, antes de paralelizar fases.
- Timeout próprio do gate 2: melhoria de robustez caso testes travados sejam problema observado; não há economia medida no relatório.
- Troca global de modelo, redução global de effort, reescrita do Bash e novo dashboard: sem justificativa atual.

**Primeira entrega recomendada:** etapas 1–4, verificadas localmente, seguidas da medição da etapa 5. A etapa 6 deve ser uma decisão posterior baseada no custo residual e na viabilidade do ambiente.
