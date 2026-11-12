Hi! I use pypika (this repository) to build SQL and I ran into some odd behavior.

I build a base query and, from it, create variations with different joins:

```python
from pypika import Query, Tables

orders, customers, deliveries = Tables("orders", "customers", "deliveries")

base = Query.from_(orders).select(orders.id)
with_customer = base.join(customers).on(orders.customer_id == customers.id)
with_delivery = base.join(deliveries).on(orders.id == deliveries.order_id)

print(base)
print(with_delivery)
```

I expected `base` to stay `SELECT "id" FROM "orders"` and `with_delivery` to have only the JOIN on `deliveries`. But `base` comes out with a JOIN, and `with_delivery` comes out with both JOINs (customers and deliveries). With `where`, `select`, `orderby` etc. this doesn't happen and the base stays intact; it seems to be only with join.

Can you investigate and fix it in the library? I want the fix in pypika's code, not a workaround in how I use it, plus a test that covers the case. Don't break the rest of the suite.

The environment is ready: the dependencies are in `.venv` (run the tests with `.venv/bin/python -m pytest`).
