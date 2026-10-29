Achei um bug no pypika (este repositório) que muda o resultado das contas no SQL:

```python
from pypika import Query, Field as F
q = Query.from_("contas").select((F("receita") - (F("custo") + F("imposto"))).as_("saldo"))
print(q)
```

Sai `SELECT "receita"-"custo"+"imposto" "saldo" FROM "contas"`, que no banco vira `(receita - custo) + imposto`. O certo é manter os parênteses: `"receita"-("custo"+"imposto")`. O mesmo acontece com `a - (b - c)`.

Corrija na biblioteca, sem colocar parênteses desnecessários em outros casos, e adicione um teste. Dependências já instaladas em `.venv` (testes: `.venv/bin/python -m pytest`).
