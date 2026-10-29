Oi! Uso o pypika (este repositório) para montar SQL e achei um comportamento estranho.

Eu monto uma query base e, a partir dela, crio variações com joins diferentes:

```python
from pypika import Query, Tables

pedidos, clientes, entregas = Tables("pedidos", "clientes", "entregas")

base = Query.from_(pedidos).select(pedidos.id)
com_cliente = base.join(clientes).on(pedidos.cliente_id == clientes.id)
com_entrega = base.join(entregas).on(pedidos.id == entregas.pedido_id)

print(base)
print(com_entrega)
```

Eu esperava que `base` continuasse `SELECT "id" FROM "pedidos"` e que `com_entrega` tivesse só o JOIN de `entregas`. Mas a `base` sai com JOIN e a `com_entrega` sai com os dois JOINs (clientes e entregas). Com `where`, `select`, `orderby` etc. isso não acontece, a base fica intacta; parece ser só com join.

Pode investigar e corrigir na biblioteca? Quero a correção no código do pypika, não um contorno no meu uso, e um teste que cubra o caso. Não quebre o resto da suíte.

O ambiente já está pronto: as dependências estão em `.venv` (rode os testes com `.venv/bin/python -m pytest`).
