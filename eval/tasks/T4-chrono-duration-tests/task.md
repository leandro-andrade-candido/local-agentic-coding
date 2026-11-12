The `src/calculation/duration.ts` module (functions `addDuration` and `reverseDuration`) is used by several parsers for relative expressions ("in 2 weeks", "3 days ago" etc.), but right now it has no tests of its own.

Write a jest test suite for it in `test/calculation_duration.test.ts`. I want tests that actually catch regressions in this module: cover every time unit, the accepted abbreviations, combinations of units, fractional values and `reverseDuration`. Use fixed dates, nothing that depends on the day the test runs.

Don't change `src/calculation/duration.ts`; if you find something odd in its behavior, just let me know. The new tests must pass.

The dependencies are already installed: run with `npx jest test/calculation_duration.test.ts` (the whole suite is `npx jest`).
