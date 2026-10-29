# TRUNCATE TABLE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

(Resposta de referência do K3, usada pelo harness `fake-oracle` e pelo `validate.sh`.)

**Goal:** Add `Query.truncate(table)` producing `TRUNCATE TABLE`, with PostgreSQL `RESTART IDENTITY`/`CASCADE` and MySQL quoting.

**Architecture:** New immutable `TruncateQueryBuilder` in `pypika/queries.py`, following `DropQueryBuilder`; `Query.truncate` entry point; dialect subclasses in `pypika/dialects.py` for MySQL quoting and PostgreSQL options.

**Tech Stack:** Python 3.12, pypika, unittest tests run with pytest.

---

### Task 1: Base builder and `Query.truncate`

**Files:**
- Modify: `pypika/queries.py` (new `TruncateQueryBuilder`, `Query.truncate`)
- Test: `pypika/tests/test_truncate.py`

- [ ] **Step 1: Write the failing test**

```python
import unittest
from pypika import Query, Table

class TruncateTests(unittest.TestCase):
    def test_truncate(self):
        self.assertEqual('TRUNCATE TABLE "t"', str(Query.truncate("t")))

    def test_truncate_schema(self):
        self.assertEqual('TRUNCATE TABLE "s"."t"', str(Query.truncate(Table("t", schema="s"))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest pypika/tests/test_truncate.py -v`
Expected: FAIL with `AttributeError: type object 'Query' has no attribute 'truncate'`

- [ ] **Step 3: Write minimal implementation**

```python
class TruncateQueryBuilder:
    QUOTE_CHAR = '"'

    def __init__(self, dialect=None):
        self._table = None
        self.dialect = dialect

    @builder
    def truncate(self, table):
        self._table = table if isinstance(table, Table) else Table(table)

    def get_sql(self, **kwargs):
        kwargs.setdefault("quote_char", self.QUOTE_CHAR)
        return "TRUNCATE TABLE " + self._table.get_sql(**kwargs) if self._table else ""
```

and in `Query`: `def truncate(cls, table): return TruncateQueryBuilder().truncate(table)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest pypika/tests/test_truncate.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pypika/queries.py pypika/tests/test_truncate.py
git commit -m "feat: Query.truncate"
```

### Task 2: Dialects (MySQL quoting, PostgreSQL options)

**Files:**
- Modify: `pypika/dialects.py` (`MySQLQuery.truncate`, `PostgreSQLQuery.truncate`, `PostgreSQLTruncateQueryBuilder`)
- Test: `pypika/tests/test_truncate.py`

- [ ] **Step 1: Write the failing tests**

```python
def test_mysql(self):
    self.assertEqual("TRUNCATE TABLE `t`", str(MySQLQuery.truncate("t")))

def test_postgresql_options(self):
    q = PostgreSQLQuery.truncate("t").restart_identity().cascade()
    self.assertEqual('TRUNCATE TABLE "t" RESTART IDENTITY CASCADE', str(q))

def test_immutable(self):
    base = PostgreSQLQuery.truncate("t")
    base.cascade()
    self.assertEqual('TRUNCATE TABLE "t"', str(base))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest pypika/tests/test_truncate.py -v`
Expected: FAIL (`MySQLQuery.truncate` uses `"`; `restart_identity` missing)

- [ ] **Step 3: Implement** `MySQLTruncateQueryBuilder` (`QUOTE_CHAR = "`"`) and `PostgreSQLTruncateQueryBuilder` with `@builder` `restart_identity()`/`cascade()` appended in `get_sql`.

- [ ] **Step 4: Run the full suite**

Run: `.venv/bin/python -m pytest pypika/tests -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pypika/dialects.py pypika/tests/test_truncate.py
git commit -m "feat: TRUNCATE dialect support"
```
