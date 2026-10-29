# Brainstorm: filtros reutilizáveis entre consultas

Resposta de referência do K1 (usada pelo harness `fake-oracle` e pelo `validate.sh`).

## O que entendi

Você quer declarar uma vez critérios como "ativo", "do tenant X" ou "do mês atual" e aplicá-los a várias consultas, sem repetir `.where(...)`.

O pypika já tem peças que ajudam:

- `Criterion` combinável com `&` e `|` (`pypika/terms.py`);
- `QueryBuilder.where` acumula critérios com AND;
- `QueryBuilder.pipe(func, *args)` (`pypika/queries.py`) aplica uma função que recebe e devolve a query;
- os builders são imutáveis (`@builder`), então aplicar um filtro não altera a query base.

## Perguntas

1. Os filtros dependem de valores conhecidos só na hora da consulta (tenant atual, data de hoje) ou são fixos?
2. Os filtros precisam funcionar com joins, quando a coluna está em outra tabela ou com outro alias?
3. Isso é para o seu código (padrão de uso) ou para publicar como recurso do pypika?
4. Precisa funcionar também em `UPDATE` e `DELETE`, ou só em `SELECT`?
5. Um filtro pode ser desligado depois de aplicado (por exemplo, um admin que vê todos os tenants)?

## Abordagens

### Opção A: funções que devolvem `Criterion` (padrão de uso)

`def ativo(t): return t.ativo == True` e `q.where(ativo(t) & do_tenant(t, x))`.

- Prós: nada muda na biblioteca; é explícito; composição com `&`/`|`.
- Contras: ainda repete o `.where`; o código precisa saber a tabela de cada filtro.

### Opção B: funções para `pipe` (padrão de uso com o que já existe)

`def do_tenant(q, t, x): return q.where(t.tenant_id == x)` e `q.pipe(do_tenant, t, x).pipe(ativo, t)`.

- Prós: usa `QueryBuilder.pipe`, que já existe; encadeia como os outros métodos; dá para aplicar a SELECT, UPDATE e DELETE.
- Contras: o filtro ainda precisa receber a tabela; não há como "desligar" depois.

### Opção C: escopos registrados na biblioteca

Algo como `Query.from_(t).scope("ativo")`, com um registro de escopos por tabela.

- Prós: leitura mais curta; um lugar só para os filtros.
- Contras: estado global num builder que hoje é puro; mais API para manter; mais difícil com aliases e joins.

## Recomendação

Começar pela **opção B**, que não exige mudança na biblioteca. Só considerar a C se as respostas às perguntas 3 e 5 indicarem que é preciso um recurso oficial com desligamento.
