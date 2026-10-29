Em `src/locales/pt/constants.ts` e `src/locales/es/constants.ts`, o `YEAR_PATTERN` e a função `parseYear` são cópias idênticas. Quero centralizar isso:

- em `src/calculation/years.ts`, exporte a constante `YEAR_WITH_ERA_PATTERN` e a função `parseYearWithEra(match: string): number`, com exatamente o comportamento atual (inclusive anos com dois dígitos e "a.C."/"d.C.");
- faça os locales `pt` e `es` usarem essas versões e remova as cópias. Os parsers desses idiomas devem continuar funcionando igual.

Não mude comportamento. As dependências já estão instaladas (`npx jest` roda a suíte; `npx jest test/pt test/es` roda só esses idiomas).
