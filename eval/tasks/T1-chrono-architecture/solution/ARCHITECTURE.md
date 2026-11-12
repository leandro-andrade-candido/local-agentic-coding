# chrono architecture

T1 reference answer (used by the `fake-oracle` harness and to calibrate the rubric).

chrono extracts dates and times from free text ("next Friday at 5pm", "3 days ago"). It has no runtime dependencies; the code is in `src/` (TypeScript) and the tests in `test/` (jest + ts-jest).

## Entry point and public API

`src/index.ts` is the front door:

- it re-exports each language as a namespace: `chrono.en`, `chrono.pt`, `chrono.de`, `chrono.fr`, `chrono.ja`, `chrono.zh` etc.;
- it exposes the shortcuts `chrono.parse(text, ref?, option?)` (a list of `ParsedResult`) and `chrono.parseDate(...)` (only the `Date` of the first result);
- `chrono.casual` and `chrono.strict` are the English instances (`en.casual`/`en.strict`); the shortcuts use `casual`;
- it exports the classes for anyone who wants to build their own configuration: `Chrono`, `Parser`, `Refiner`, `ParsingResult`, `ParsingComponents`, `ReferenceWithTimezone`.

## From text to result

1. `Chrono.parse()` (`src/chrono.ts`) creates a `ParsingContext` with the text, the reference (`ReferenceWithTimezone.fromInput`, from a `Date` or a `ParsingReference`) and the options.
2. For each parser in the configuration, `Chrono.executeParser` runs the RegExp from `parser.pattern(context)` over the remaining text. For each match it calls `parser.extract(context, match)`. If the return value is `null`, it advances 1 character and tries again; otherwise it converts the return value (`ParsingResult`, `ParsingComponents` or a plain components object) into a `ParsingResult` and continues after the matched span.
3. The results of all parsers are sorted by `index` (position in the text).
4. The refiners are applied in sequence; each receives the list and returns another one (it may merge, remove or adjust results).
5. `parseDate()` returns `results[0].start.date()`.

## Main abstractions

- **`Parser`** (`src/chrono.ts`): `pattern(context): RegExp` and `extract(context, match)`.
- **`AbstractParserWithWordBoundaryChecking`** (`src/common/parsers/AbstractParserWithWordBoundary.ts`): the base of almost every parser. It prefixes `(\W|^)` to the pattern to require a word boundary, adjusts the match index and delegates to `innerPattern(context)` and `innerExtract(context, match)`. It caches the compiled pattern.
- **`Refiner`**: `refine(context, results): ParsingResult[]`. Base classes in `src/common/abstractRefiners.ts` (`Filter`, `MergingRefiner`).
- **`ParsingResult`** (`src/results.ts`): `index`, `text`, `start`, `end` (ranges), `refDate` and `reference`.
- **`ParsingComponents`**: the date components (year, month, day, hour, minute, second, time zone, weekday). It separates **known** values (`assign`, `knownValues`), stated in the text, from **implied** ones (`imply`, `impliedValues`), inherited from the reference. `isCertain(c)` says whether the component was stated; `date()` builds the `Date`. `createRelativeFromReference` creates components from a duration (used by "in 2 days", "3 days ago").
- **`ReferenceWithTimezone`**: the reference instant plus the time zone.

## Common refiners

In `src/common/refiners/`:

- `AbstractMergeDateTimeRefiner`: merges an adjacent date-only result and time-only result ("Friday" + "at 5pm").
- `AbstractMergeDateRangeRefiner`: merges "X to Y"/"X - Y" into one result with `start` and `end`.
- `OverlapRemovalRefiner`: removes overlapping results, keeping the longest.
- `ForwardDateRefiner`: with `forwardDate`, pushes ambiguous dates into the future.
- `ExtractTimezoneAbbrRefiner` / `ExtractTimezoneOffsetRefiner`: read "EST", "+0300" after the date.
- `MergeWeekdayComponentRefiner` and `UnlikelyFormatFilter` (drops unlikely formats, stricter in strict mode).

The order matters: the English configuration runs `OverlapRemovalRefiner` and `ENMergeDateTimeRefiner` more than once, and the range refiner comes last.

## Configurations

- `src/configurations.ts` `includeCommonConfiguration(configuration, strictMode)` adds the `ISOFormatParser` and the common refiners to any language.
- Each language has `createConfiguration(strictMode, littleEndian)` (formal formats) and `createCasualConfiguration()`, which adds informal parsers ("today", "tomorrow", "now", "tonight"). Each language's `casual` and `strict` are a `new Chrono(...)` with one of them.
- `littleEndian` decides whether "01/02" is day/month (en.GB) or month/day (en.US).
- Per-call options (`ParsingOption`, `src/types.ts`): `forwardDate`, `timezones` (custom abbreviation map) and `debug` (a handler, e.g. `BufferedDebugHandler` from `src/debugging.ts`).

## Languages

`src/locales/<language>/` follows the same layout:

- `constants.ts`: dictionaries (weekdays, months, spelled-out numbers, time units), regex patterns and functions such as `parseNumberPattern`, `parseYear`, `parseDuration`;
- language-specific `parsers/` and `refiners/` (e.g. `ENWeekdayParser`, `ENTimeUnitAgoFormatParser`, `ENMergeDateRangeRefiner`);
- `index.ts`: builds the configurations and exports `casual`, `strict`, `parse`, `parseDate`.

Coverage is uneven: English is the most complete; `pt` only has weekdays, months, times and casual expressions. To extend a language, you create the parser (usually extending `AbstractParserWithWordBoundaryChecking`), put the vocabulary in `constants.ts` and register the parser in the configuration in the language's `index.ts`.

## Time zone

`src/timezone.ts` has `TIMEZONE_ABBR_MAP` (abbreviations to offsets, including daylight saving time rules with `getNthWeekdayOfMonth`/`getLastWeekdayOfMonth`) and `toTimezoneOffset`. The reference can be `{ instant, timezone }` (`ParsingReference`).

## Utilities

- `src/calculation/`: `duration.ts` (`addDuration`, `reverseDuration`), `weekdays.ts` (next/last weekday), `years.ts` (most likely year when the text does not say), `mergingCalculation.ts` (merges date and time).
- `src/utils/pattern.ts`: `matchAnyPattern` (builds a regex alternation from a dictionary, longest terms first) and `repeatedTimeunitPattern`; `src/utils/dates.ts`.

## Tests

- `test/` has one directory per language (`test/en/`, `test/pt/` ...) and core tests (`result.test.ts`, `system.test.ts`, `calculation_*.test.ts`).
- jest with the `ts-jest` preset (configured in `package.json`); `npx jest` runs everything, `npx jest test/pt` a single language.
- `test/test_util.ts` has the helpers `testSingleCase(chrono, text, ref, callback)`, `testUnexpectedResult` and the `toBeDate` matcher.
