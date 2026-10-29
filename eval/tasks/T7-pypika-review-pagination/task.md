Implementei um helper de paginação no pypika, `QueryBuilder.paginate(page, per_page)`, e aproveitei para simplificar o `_apply_pagination`. As mudanças estão no working tree, ainda sem commit (veja com `git diff`). Os testes passam aqui.

Antes de eu commitar, revise o diff com cuidado, como um revisor exigente: procure bugs e mudanças de comportamento que eu não tenha percebido, inclusive em código que já existia. Se encontrar problemas, corrija-os mantendo a funcionalidade nova, e no fim me diga o que encontrou e o que mudou. Não precisa commitar.

As dependências estão em `.venv` (testes: `.venv/bin/python -m pytest`).
