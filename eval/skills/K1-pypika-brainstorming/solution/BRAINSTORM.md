# Brainstorm: reusable filters across queries

K1 reference answer (used by the `fake-oracle` harness and by `validate.sh`).

## What I understood

You want to declare criteria such as "active", "of tenant X" or "of the current month" once and apply them to several queries, without repeating `.where(...)`.

pypika already has pieces that help:

- `Criterion`, combinable with `&` and `|` (`pypika/terms.py`);
- `QueryBuilder.where` accumulates criteria with AND;
- `QueryBuilder.pipe(func, *args)` (`pypika/queries.py`) applies a function that takes and returns the query;
- the builders are immutable (`@builder`), so applying a filter does not change the base query.

## Questions

1. Do the filters depend on values known only at query time (current tenant, today's date) or are they fixed?
2. Do the filters need to work with joins, when the column is in another table or under another alias?
3. Is this for your own code (a usage pattern) or to publish as a pypika feature?
4. Does it also need to work for `UPDATE` and `DELETE`, or only `SELECT`?
5. Can a filter be turned off after it is applied (for example, an admin who sees every tenant)?

## Approaches

### Option A: functions that return a `Criterion` (usage pattern)

`def active(t): return t.active == True` and `q.where(active(t) & of_tenant(t, x))`.

- Pros: nothing changes in the library; it is explicit; composes with `&`/`|`.
- Cons: it still repeats `.where`; the code needs to know each filter's table.

### Option B: functions for `pipe` (usage pattern with what already exists)

`def of_tenant(q, t, x): return q.where(t.tenant_id == x)` and `q.pipe(of_tenant, t, x).pipe(active, t)`.

- Pros: uses `QueryBuilder.pipe`, which already exists; chains like the other methods; works for SELECT, UPDATE and DELETE.
- Cons: the filter still needs the table; there is no way to "turn it off" later.

### Option C: scopes registered in the library

Something like `Query.from_(t).scope("active")`, with a per-table scope registry.

- Pros: shorter to read; a single place for the filters.
- Cons: global state in a builder that is pure today; more API to maintain; harder with aliases and joins.

## Recommendation

Start with **option B**, which needs no library change. Only consider C if the answers to questions 3 and 5 show that an official feature with a way to turn filters off is needed.
