# Feature Brief — [Nome da Feature]

> Esta é a forma do brief. Duas maneiras de chegar nela, o arquivo é o mesmo:
>
> - **Entrevista** — `/mktux:plan <slug> "<sua ideia>"`. A skill pergunta e preenche.
> - **Na mão** — copie este arquivo, preencha com suas palavras. Não precisa ser
>   formal; escreva como falaria para um dev do time.
>
> Salve em: `docs/features/<slug>/feature-brief.md`
> Os **títulos de seção são fixos** — o passo 1 lê o brief por eles.

---

## O que é essa feature?

[Descreva em linguagem natural o que você quer construir.]

Exemplo:
> Quero um módulo de relatórios pro dono ver o fechamento do dia,
> os produtos mais vendidos e o saldo em carteira dos clientes.

---

## Por que estamos construindo isso?

[Qual problema resolve? Para quem?]

---

## O que DEVE entrar nessa feature?

- [item 1]
- [item 2]
- [item 3]

---

## O que NÃO entra nessa feature (por hora)?

- [item 1]
- [item 2]

---

## O que NÃO pode mudar de comportamento?

> **Este é o campo mais importante do brief.** Cada fase do plano vira uma sessão
> nova e cega — o que estiver aqui vira o bloco `Do not touch` que impede um
> agente de reescrever tela que já funciona.
>
> Deixar em branco é como o harness quebra na prática.

[Telas, fluxos, cálculos ou arquivos que devem continuar exatamente como estão.]

- [ex: a tela de checkout inteira]
- [ex: os números do relatório de fechamento]
- [ex: a busca da listagem de clientes]

---

## Regras de negócio que você já sabe?

[Liste qualquer regra, restrição ou detalhe de domínio que já tem na cabeça.
Não precisa ser completo — o agente completa com o que achar no codebase.]

- [regra 1]
- [regra 2]

---

## Quem usa essa feature?

Liste os papéis do **seu** projeto e o que cada um faz aqui.

- [ ] [papel 1 — ex: super_admin]
- [ ] [papel 2 — ex: admin / dono]
- [ ] [papel 3 — ex: atendente]
- [ ] [papel 4 — ex: cliente final]

---

## Tem limite por plano / feature flag?

- [ ] Não, todo mundo usa
- [ ] Sim — quais planos: [.....]
- [ ] Sim, e quem não tem deve ver: [botão bloqueado com upgrade / nada / outro]

---

## Mexe em dado pessoal?

- [ ] Não
- [ ] Sim — quais campos: [CPF, telefone, e-mail, data de nascimento, ...]
- [ ] Se sim, o dado sai do sistema (arquivo, e-mail, integração)? [sim/não]

---

## Alguma referência ou observação extra?

[Prints, links, decisões anteriores, qualquer coisa relevante.
Se houver mockup ou HTML de referência, coloque **o caminho exato do arquivo** —
e sem espaços no nome. `login panel.html` → renomeie para `login-panel.html`.]
