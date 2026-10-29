Quero adicionar suporte a `CREATE VIEW` no pypika (este repositório). É uma mudança maior, então trabalhe em duas fases:

1. **Planejamento.** Antes de alterar qualquer código, estude como o projeto implementa os outros comandos DDL e escreva o plano em `PLANO.md`, na raiz do repositório: quais arquivos vai mexer, classes e métodos novos, como os dialetos entram, validações, riscos e como vai testar.
2. **Implementação.** Depois implemente seguindo o plano, com testes. Se mudar de ideia no caminho, atualize o `PLANO.md`.

Especificação:

- Ponto de entrada: `Query.create_view(view)`, onde `view` é um nome (`str`) ou um `Table` (que pode ter schema).
- `.as_select(query)` define a consulta da view (obrigatória). Se `query` não for um builder de consulta do pypika, levante `TypeError`. Sem `as_select`, o `str()` do builder devolve string vazia, como acontece no `create_table`.
- `.columns("a", "b")` define a lista de colunas da view (opcional).
- `.or_replace()` gera `CREATE OR REPLACE VIEW`; `.temporary()` gera `CREATE TEMPORARY VIEW`; `.if_not_exists()` gera `CREATE VIEW IF NOT EXISTS`.
- `or_replace()` com `if_not_exists()` é inválido: levante `QueryException` (de `pypika.utils`) na chamada que criar o conflito, em qualquer ordem.
- PostgreSQL: `PostgreSQLQuery.create_view(...)` tem também `.materialized()`, que gera `CREATE MATERIALIZED VIEW`. View materializada não pode ser combinada com `or_replace()` nem com `temporary()` (`QueryException`, em qualquer ordem). Nos outros dialetos o método `materialized()` não existe.
- Ordem das palavras: `CREATE [OR REPLACE] [TEMPORARY | MATERIALIZED] VIEW [IF NOT EXISTS] nome [(colunas)] AS consulta`.
- O nome da view e as colunas usam as aspas do dialeto (`MySQLQuery.create_view` usa crase). A consulta depois do `AS` deve sair exatamente como `str(query)` sairia sozinha.
- Como no resto do pypika, os métodos são imutáveis (devolvem um builder novo) e podem ser chamados em qualquer ordem.

Exemplos (resultado de `str()`):

```python
from pypika import Field, MySQLQuery, PostgreSQLQuery, Query, Table

q = Query.from_("pedidos").select("id", "total").where(Field("status") == "pago")

Query.create_view("v_pagos").as_select(q)
# CREATE VIEW "v_pagos" AS SELECT "id","total" FROM "pedidos" WHERE "status"='pago'

Query.create_view("v_pagos").or_replace().columns("pid", "valor").as_select(q)
# CREATE OR REPLACE VIEW "v_pagos" ("pid","valor") AS SELECT "id","total" FROM "pedidos" WHERE "status"='pago'

Query.create_view(Table("v_pagos", schema="relatorios")).if_not_exists().as_select(q)
# CREATE VIEW IF NOT EXISTS "relatorios"."v_pagos" AS SELECT "id","total" FROM "pedidos" WHERE "status"='pago'

MySQLQuery.create_view("v").as_select(MySQLQuery.from_("t").select("a"))
# CREATE VIEW `v` AS SELECT `a` FROM `t`

PostgreSQLQuery.create_view("mv").materialized().as_select(PostgreSQLQuery.from_("t").select("a"))
# CREATE MATERIALIZED VIEW "mv" AS SELECT "a" FROM "t"
```

Documente o recurso no README. As dependências estão em `.venv` (testes: `.venv/bin/python -m pytest`). Não precisa commitar.
