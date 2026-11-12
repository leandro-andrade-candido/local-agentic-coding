Two tests started failing on main and nobody understands why:

- `Test - Strict mode`, in `test/en/en_time_units_within.test.ts`
- `Test - From now Expression`, in `test/en/en_time_units_later.test.ts`

Nobody touched those test files. The strangest part: the first one passes when I run it alone (`npx jest test/en/en_time_units_within.test.ts -t "Strict mode"`).

Investigate until you find the root cause and fix it in the library code. Don't change, skip or disable tests, and don't change the parser's behavior in other cases: the whole suite has to pass.

When you're done, write a report in English in `INVESTIGATION.md`, at the repository root, covering what the root cause was, how you got to it and why the fix solves it.

The dependencies are already installed (`npx jest` runs the suite; `npx jest <file>` runs one file).
