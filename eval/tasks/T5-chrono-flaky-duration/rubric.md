# T5 rubric: root cause in `INVESTIGATION.md`

Written before the runs. The fix is checked by the hidden tests and the suite; this only assesses whether the report **explains the right cause**. The automatic check only confirms that the report exists and mentions `parseDuration` (or `parsedDurationCache`) and `addDuration`. Loose words such as "cache" or "shared state" are not enough.

Each item is worth 1 point. **Correct root cause = 2 of 2.** T5 success = hidden tests + original suite + grade 2.

| # | Item | What must appear |
|---|---|---|
| 1 | The cache in `parseDuration` (`src/locales/en/constants.ts`, `parsedDurationCache`) returns **the same `Duration` object** on every call with the same text (the key ignores case). | Cache + same object (shared instance), in the right place. |
| 2 | `addDuration` (`src/calculation/duration.ts`) **modifies the object it receives** when there are fractions (it adds the remainder to the smaller unit), so the second parse of the same text starts from an already modified object. This explains why only repeated fractional expressions fail and why "Strict mode" passes alone. | Mutation of the argument by `addDuration` as the mechanism, linked to the order symptom. |

Does not cost points, but record in `notes`:
- a fix that makes `addDuration` immutable (fails the suite: it changes "in half a day");
- a report that gets the cause right and the mechanism wrong, or the other way round (worth 1).

Recording: `python3 -I eval/grade.py <result.json> --score N --by NAME [--notes "..."]`.
