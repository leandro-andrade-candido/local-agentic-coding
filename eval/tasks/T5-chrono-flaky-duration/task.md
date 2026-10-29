Dois testes começaram a falhar na main e ninguém entende por quê:

- `Test - Strict mode`, em `test/en/en_time_units_within.test.ts`
- `Test - From now Expression`, em `test/en/en_time_units_later.test.ts`

Ninguém mexeu nesses arquivos de teste. O mais estranho: o primeiro passa quando rodo sozinho (`npx jest test/en/en_time_units_within.test.ts -t "Strict mode"`).

Investigue até encontrar a causa raiz e corrija no código da biblioteca. Não altere, pule nem desative testes, e não mude o comportamento do parser em outros casos: a suíte inteira tem que passar.

Quando terminar, escreva em `INVESTIGACAO.md`, na raiz do repositório, qual era a causa raiz, como você chegou nela e por que a correção resolve.

As dependências já estão instaladas (`npx jest` roda a suíte; `npx jest <arquivo>` roda um arquivo).
