I want to add `CREATE VIEW` support to pypika (this repository). It's a bigger change, so work in two phases:

1. **Planning.** Before changing any code, study how the project implements the other DDL commands and write the plan, in English, in `PLAN.md`, at the repository root: which files you'll touch, new classes and methods, how the dialects fit in, validations, risks and how you'll test it.
2. **Implementation.** Then implement it following the plan, with tests. If you change your mind along the way, update `PLAN.md`.

Specification:

- Entry point: `Query.create_view(view)`, where `view` is a name (`str`) or a `Table` (which may have a schema).
- `.as_select(query)` sets the view's query (required). If `query` is not a pypika query builder, raise `TypeError`. Without `as_select`, the builder's `str()` returns an empty string, as happens with `create_table`.
- `.columns("a", "b")` sets the view's column list (optional).
- `.or_replace()` produces `CREATE OR REPLACE VIEW`; `.temporary()` produces `CREATE TEMPORARY VIEW`; `.if_not_exists()` produces `CREATE VIEW IF NOT EXISTS`.
- `or_replace()` together with `if_not_exists()` is invalid: raise `QueryException` (from `pypika.utils`) in the call that creates the conflict, in either order.
- PostgreSQL: `PostgreSQLQuery.create_view(...)` also has `.materialized()`, which produces `CREATE MATERIALIZED VIEW`. A materialized view cannot be combined with `or_replace()` or `temporary()` (`QueryException`, in either order). In the other dialects the `materialized()` method does not exist.
- Word order: `CREATE [OR REPLACE] [TEMPORARY | MATERIALIZED] VIEW [IF NOT EXISTS] name [(columns)] AS query`.
- The view name and the columns use the dialect's quotes (`MySQLQuery.create_view` uses backticks). The query after `AS` must come out exactly as `str(query)` would on its own.
- As in the rest of pypika, the methods are immutable (they return a new builder) and can be called in any order.

Examples (result of `str()`):

```python
from pypika import Field, MySQLQuery, PostgreSQLQuery, Query, Table

q = Query.from_("orders").select("id", "total").where(Field("status") == "paid")

Query.create_view("v_paid").as_select(q)
# CREATE VIEW "v_paid" AS SELECT "id","total" FROM "orders" WHERE "status"='paid'

Query.create_view("v_paid").or_replace().columns("oid", "amount").as_select(q)
# CREATE OR REPLACE VIEW "v_paid" ("oid","amount") AS SELECT "id","total" FROM "orders" WHERE "status"='paid'

Query.create_view(Table("v_paid", schema="reports")).if_not_exists().as_select(q)
# CREATE VIEW IF NOT EXISTS "reports"."v_paid" AS SELECT "id","total" FROM "orders" WHERE "status"='paid'

MySQLQuery.create_view("v").as_select(MySQLQuery.from_("t").select("a"))
# CREATE VIEW `v` AS SELECT `a` FROM `t`

PostgreSQLQuery.create_view("mv").materialized().as_select(PostgreSQLQuery.from_("t").select("a"))
# CREATE MATERIALIZED VIEW "mv" AS SELECT "a" FROM "t"
```

Document the feature in the README. The dependencies are in `.venv` (tests: `.venv/bin/python -m pytest`). No need to commit.
