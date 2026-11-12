# T6 rubric: plan (`PLAN.md`) for CREATE VIEW

Written before the runs. It assesses **the plan**, not the code (the code is assessed by the hidden tests).
Each item is worth 1 point if `PLAN.md` covers it explicitly and correctly. **T6 success: hidden tests pass and grade >= 7.**

When grading, also check in the transcript (agent log) that `PLAN.md` was written **before** the first edits in `pypika/`. If it was not, record it in `notes` and subtract 2 points.

| # | Item | How to check |
|---|---|---|
| 1 | Identifies the existing pattern: separate builders per DDL command in `pypika/queries.py` (`CreateQueryBuilder`, `DropQueryBuilder`, `CreateIndexBuilder`) and proposes a new builder class for views following that pattern. | Cites at least one of those builders as a model and names the new class. |
| 2 | Plans the `Query.create_view` entry point as a `classmethod` on `Query`. | Mentions `create_view` on `Query`. |
| 3 | Plans immutability with the `@builder` decorator on every building method. | Mentions `@builder` or a copy on each call. |
| 4 | Notices that `@builder` makes a shallow copy and that lists (e.g. columns) must not be changed in place, or plans `__copy__`. | Mentions shallow copy, `copy.copy`, list sharing or `__copy__`. |
| 5 | Integrates the dialects in `pypika/dialects.py`: `MySQLQuery.create_view` with backticks and `PostgreSQLQuery.create_view` with its own builder that has `materialized()`. | Cites `dialects.py`, MySQL and PostgreSQL and what changes in each. |
| 6 | Lists the validations: `TypeError` in `as_select`, `QueryException` for `or_replace`+`if_not_exists` and for `materialized` with `or_replace`/`temporary`, in both orders. | All three rules appear. |
| 7 | Defines how the SQL is assembled in the specification's order, including the empty string without `as_select`. | Shows the template or describes the order. |
| 8 | Handles quotes and kwargs: the name uses the builder's `QUOTE_CHAR` (via `_set_kwargs_defaults`/`get_sql`) and the inner query comes out the same as `str(query)` (do not pass quote/dialect settings that change the query). | Mentions how the inner query is rendered and why. |
| 9 | Handles the name as `str` or as a `Table` with a schema, reusing `Table.get_sql`. | Mentions `Table`/schema. |
| 10 | A concrete test plan (new test file, cases for each modifier, errors, dialects, immutability) and documentation in the README; run the whole suite. | Lists test cases and mentions the README and the full suite. |

Recording the grade: `python3 -I eval/grade.py <result.json> --score N --by NAME [--notes "..."]`.
