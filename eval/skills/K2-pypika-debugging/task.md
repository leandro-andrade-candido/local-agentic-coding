Rodei a suíte do pypika e vários testes de BETWEEN em `pypika/tests/test_criterions.py` estão falhando (por exemplo `test__between_number` e `test__between_date`). Ninguém mexeu nesses testes.

Descubra a causa e corrija na biblioteca, sem alterar os testes. No fim, me diga em poucas linhas qual era a causa.

As dependências estão em `.venv` (testes: `.venv/bin/python -m pytest`).
