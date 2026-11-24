# mktux-harness — instrucoes para agentes

Este repositorio e publico no GitHub. O harness e agnostico de stack e de
projeto: quem instala nao conhece os projetos onde ele ja rodou.

## Nunca cite projeto real

Em codigo, comentario, teste, fixture, doc, mensagem de commit, nome de branch e
texto de PR:

- nenhum nome de projeto onde o harness rodou, nem slug de feature desses
  projetos;
- nenhuma classe, metodo, caminho, rota, campo ou regra de negocio copiada de um
  projeto real. Exemplo e inventado.

Incidente de run real que explica uma decisao entra assim: "num run real, 19 de
26 sessoes releram o AGENTS.md". O numero fica; o nome do projeto, nao.

Nome de stack (framework, ferramenta de um ecossistema) fica em
`plugins/mktux-harness/profiles/<nome>/` e nos `references/<nome>.md` das
skills. O core nao cita: a secao 6 do `test-layout.sh` barra.

## Antes do commit

```
bash plugins/mktux-harness/scripts/test-layout.sh
bash plugins/mktux-harness/scripts/test-ralph.sh
```

A secao 11 do `test-layout.sh` procura os termos de `.git/info/private-terms`
nos arquivos do repo (rastreados e novos), nas mensagens dos commits que ainda
nao estao no upstream e no nome da branch. Um termo por linha, palavra inteira,
sem diferenciar maiusculas; `#` comenta. A lista fica dentro de `.git/` de
proposito: nunca vai para o GitHub, senao ela mesma publicaria os nomes. Cada
clone monta a sua com os nomes dos projetos onde o harness roda, os slugs de
feature e os identificadores que so existem neles. Sem a lista, a checagem e
pulada.

O texto de PR nao passa pela checagem: confira antes de abrir.
