I found a bug in pypika (this repository) that changes the result of arithmetic in the SQL:

```python
from pypika import Query, Field as F
q = Query.from_("accounts").select((F("revenue") - (F("cost") + F("tax"))).as_("balance"))
print(q)
```

It outputs `SELECT "revenue"-"cost"+"tax" "balance" FROM "accounts"`, which the database reads as `(revenue - cost) + tax`. The right thing is to keep the parentheses: `"revenue"-("cost"+"tax")`. The same happens with `a - (b - c)`.

Fix it in the library, without adding unnecessary parentheses in other cases, and add a test. The dependencies are already installed in `.venv` (tests: `.venv/bin/python -m pytest`).
