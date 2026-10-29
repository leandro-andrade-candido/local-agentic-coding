# Gabarito do T6: plano (`PLANO.md`) para CREATE VIEW

Escrito antes das execuções. Avalia **o plano**, não o código (o código é avaliado pelos testes ocultos).
Cada item vale 1 ponto se o `PLANO.md` o cobre de forma explícita e correta. **Sucesso do T6: testes ocultos passam e nota >= 7.**

Ao corrigir, confira também no transcript (log do agente) que o `PLANO.md` foi escrito **antes** das primeiras edições em `pypika/`. Se não foi, anote em `notes` e tire 2 pontos.

| # | Item | Como verificar |
|---|---|---|
| 1 | Identifica o padrão existente: builders separados por comando DDL em `pypika/queries.py` (`CreateQueryBuilder`, `DropQueryBuilder`, `CreateIndexBuilder`) e propõe uma classe nova de builder para views seguindo esse padrão. | Cita ao menos um desses builders como modelo e nomeia a classe nova. |
| 2 | Prevê o ponto de entrada `Query.create_view` como `classmethod` em `Query`. | Menciona `create_view` em `Query`. |
| 3 | Prevê imutabilidade com o decorador `@builder` em todos os métodos de construção. | Menciona `@builder` ou cópia a cada chamada. |
| 4 | Percebe que `@builder` faz cópia rasa e que listas (ex.: colunas) não podem ser alteradas in place, ou prevê `__copy__`. | Menciona cópia rasa, `copy.copy`, compartilhamento de lista ou `__copy__`. |
| 5 | Integra os dialetos em `pypika/dialects.py`: `MySQLQuery.create_view` com crase e `PostgreSQLQuery.create_view` com builder próprio que tem `materialized()`. | Cita `dialects.py`, MySQL e PostgreSQL com o que muda em cada um. |
| 6 | Lista as validações: `TypeError` em `as_select`, `QueryException` para `or_replace`+`if_not_exists` e para `materialized` com `or_replace`/`temporary`, nas duas ordens. | As três regras aparecem. |
| 7 | Define a montagem do SQL na ordem da especificação, incluindo string vazia sem `as_select`. | Mostra o template ou descreve a ordem. |
| 8 | Trata aspas e kwargs: o nome usa `QUOTE_CHAR` do builder (via `_set_kwargs_defaults`/`get_sql`) e a consulta interna sai igual a `str(query)` (não repassar quote/dialeto que mudem a consulta). | Menciona como a consulta interna é renderizada e por quê. |
| 9 | Trata nome como `str` ou `Table` com schema, reaproveitando `Table.get_sql`. | Menciona `Table`/schema. |
| 10 | Plano de testes concreto (arquivo de teste novo, casos de cada modificador, erros, dialetos, imutabilidade) e documentação no README; rodar a suíte inteira. | Lista casos de teste e menciona README e suíte completa. |

Registro da nota: `python3 -I eval/grade.py <result.json> --score N --by NOME [--notes "..."]`.
