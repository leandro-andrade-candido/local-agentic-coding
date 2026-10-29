O módulo `src/calculation/duration.ts` (funções `addDuration` e `reverseDuration`) é usado por vários parsers de expressões relativas ("in 2 weeks", "3 days ago" etc.), mas hoje não tem nenhum teste próprio.

Escreva uma suíte de testes jest para ele em `test/calculation_duration.test.ts`. Quero testes que realmente peguem regressões nesse módulo: cubra cada unidade de tempo, as abreviações aceitas, combinações de unidades, valores fracionários e o `reverseDuration`. Use datas fixas, nada que dependa do dia em que o teste roda.

Não altere `src/calculation/duration.ts`; se achar algo estranho no comportamento, só me avise. Os testes novos precisam passar.

As dependências já estão instaladas: rode com `npx jest test/calculation_duration.test.ts` (a suíte inteira é `npx jest`).
