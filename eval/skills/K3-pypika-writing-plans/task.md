Use a skill `writing-plans` para escrever o plano de implementação da especificação abaixo, no formato que a skill define e salvo onde ela indica. Só o plano: não implemente nada nem altere código.

Especificação: suporte a `TRUNCATE TABLE` no pypika (este repositório).

- `Query.truncate(table)`, com `table` como nome (`str`) ou `Table` (que pode ter schema), gera `TRUNCATE TABLE "t"`.
- `PostgreSQLQuery.truncate(...)` aceita também `.restart_identity()` e `.cascade()`: `TRUNCATE TABLE "t" RESTART IDENTITY CASCADE`.
- `MySQLQuery.truncate("t")` usa crase: ``TRUNCATE TABLE `t` ``.
- Os métodos são imutáveis, como no resto da biblioteca.
- Testes com pytest em `pypika/tests/` (as dependências estão em `.venv`: `.venv/bin/python -m pytest`).
