Use the `writing-plans` skill to write the implementation plan for the specification below, in the format the skill defines and saved where it says. Only the plan: don't implement anything or change code.

Specification: `TRUNCATE TABLE` support in pypika (this repository).

- `Query.truncate(table)`, with `table` as a name (`str`) or a `Table` (which may have a schema), produces `TRUNCATE TABLE "t"`.
- `PostgreSQLQuery.truncate(...)` also accepts `.restart_identity()` and `.cascade()`: `TRUNCATE TABLE "t" RESTART IDENTITY CASCADE`.
- `MySQLQuery.truncate("t")` uses backticks: ``TRUNCATE TABLE `t` ``.
- The methods are immutable, as in the rest of the library.
- Tests with pytest in `pypika/tests/` (the dependencies are in `.venv`: `.venv/bin/python -m pytest`).
