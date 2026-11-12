In `src/locales/pt/constants.ts` and `src/locales/es/constants.ts`, `YEAR_PATTERN` and the `parseYear` function are identical copies. I want to centralize them:

- in `src/calculation/years.ts`, export the constant `YEAR_WITH_ERA_PATTERN` and the function `parseYearWithEra(match: string): number`, with exactly the current behavior (including two-digit years and "a.C."/"d.C.");
- make the `pt` and `es` locales use these versions and remove the copies. The parsers of these languages must keep working the same way.

Don't change behavior. The dependencies are already installed (`npx jest` runs the suite; `npx jest test/pt test/es` runs only these languages).
