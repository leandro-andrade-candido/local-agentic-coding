# Arquitetura do chrono

Resposta de referência do T1 (usada pelo harness `fake-oracle` e para calibrar o gabarito).

O chrono extrai datas e horários de texto livre ("next Friday at 5pm", "há 3 dias"). Não tem dependências de runtime; o código está em `src/` (TypeScript) e os testes em `test/` (jest + ts-jest).

## Ponto de entrada e API pública

`src/index.ts` é a porta de entrada:

- reexporta cada idioma como namespace: `chrono.en`, `chrono.pt`, `chrono.de`, `chrono.fr`, `chrono.ja`, `chrono.zh` etc.;
- expõe atalhos `chrono.parse(text, ref?, option?)` (lista de `ParsedResult`) e `chrono.parseDate(...)` (só a `Date` do primeiro resultado);
- `chrono.casual` e `chrono.strict` são as instâncias do inglês (`en.casual`/`en.strict`); os atalhos usam o `casual`;
- exporta as classes para quem quer montar a própria configuração: `Chrono`, `Parser`, `Refiner`, `ParsingResult`, `ParsingComponents`, `ReferenceWithTimezone`.

## Do texto ao resultado

1. `Chrono.parse()` (`src/chrono.ts`) cria um `ParsingContext` com o texto, a referência (`ReferenceWithTimezone.fromInput`, a partir de `Date` ou `ParsingReference`) e as opções.
2. Para cada parser da configuração, `Chrono.executeParser` executa a RegExp de `parser.pattern(context)` sobre o texto restante. Para cada match chama `parser.extract(context, match)`. Se o retorno for `null`, avança 1 caractere e tenta de novo; senão converte o retorno (`ParsingResult`, `ParsingComponents` ou objeto simples de componentes) em `ParsingResult` e continua depois do trecho reconhecido.
3. Os resultados de todos os parsers são ordenados por `index` (posição no texto).
4. Os refiners são aplicados em sequência; cada um recebe a lista e devolve outra (pode juntar, remover ou ajustar resultados).
5. `parseDate()` devolve `results[0].start.date()`.

## Abstrações principais

- **`Parser`** (`src/chrono.ts`): `pattern(context): RegExp` e `extract(context, match)`.
- **`AbstractParserWithWordBoundaryChecking`** (`src/common/parsers/AbstractParserWithWordBoundary.ts`): base de quase todos os parsers. Prefixa `(\W|^)` ao padrão para exigir fronteira de palavra, ajusta o índice do match e delega para `innerPattern(context)` e `innerExtract(context, match)`. Guarda o padrão compilado em cache.
- **`Refiner`**: `refine(context, results): ParsingResult[]`. Bases em `src/common/abstractRefiners.ts` (`Filter`, `MergingRefiner`).
- **`ParsingResult`** (`src/results.ts`): `index`, `text`, `start`, `end` (intervalos), `refDate` e `reference`.
- **`ParsingComponents`**: componentes da data (ano, mês, dia, hora, minuto, segundo, fuso, dia da semana). Separa valores **conhecidos** (`assign`, `knownValues`), ditos no texto, de **implícitos** (`imply`, `impliedValues`), herdados da referência. `isCertain(c)` diz se o componente foi dito; `date()` monta a `Date`. `createRelativeFromReference` cria componentes a partir de uma duração (usado por "in 2 days", "3 days ago").
- **`ReferenceWithTimezone`**: instante de referência mais o fuso.

## Refiners comuns

Em `src/common/refiners/`:

- `AbstractMergeDateTimeRefiner`: junta um resultado só de data com um só de hora adjacentes ("Friday" + "at 5pm").
- `AbstractMergeDateRangeRefiner`: junta "X to Y"/"X - Y" num resultado com `start` e `end`.
- `OverlapRemovalRefiner`: remove resultados sobrepostos, mantendo o mais longo.
- `ForwardDateRefiner`: com `forwardDate`, empurra datas ambíguas para o futuro.
- `ExtractTimezoneAbbrRefiner` / `ExtractTimezoneOffsetRefiner`: leem "EST", "+0300" depois da data.
- `MergeWeekdayComponentRefiner` e `UnlikelyFormatFilter` (descarta formatos improváveis, mais rígido no modo strict).

A ordem importa: a configuração em inglês roda `OverlapRemovalRefiner` e `ENMergeDateTimeRefiner` mais de uma vez, e o refiner de intervalos fica por último.

## Configurações

- `src/configurations.ts` `includeCommonConfiguration(configuration, strictMode)` acrescenta o `ISOFormatParser` e os refiners comuns a qualquer idioma.
- Cada idioma tem `createConfiguration(strictMode, littleEndian)` (formatos formais) e `createCasualConfiguration()`, que soma parsers informais ("today", "tomorrow", "now", "tonight"). `casual` e `strict` de cada idioma são `new Chrono(...)` com uma delas.
- `littleEndian` decide se "01/02" é dia/mês (en.GB) ou mês/dia (en.US).
- Opções por chamada (`ParsingOption`, `src/types.ts`): `forwardDate`, `timezones` (mapa de abreviações customizado) e `debug` (handler, ex.: `BufferedDebugHandler` de `src/debugging.ts`).

## Idiomas

`src/locales/<idioma>/` segue o mesmo formato:

- `constants.ts`: dicionários (dias da semana, meses, números por extenso, unidades de tempo), padrões regex e funções como `parseNumberPattern`, `parseYear`, `parseDuration`;
- `parsers/` e `refiners/` específicos (ex.: `ENWeekdayParser`, `ENTimeUnitAgoFormatParser`, `ENMergeDateRangeRefiner`);
- `index.ts`: monta as configurações e exporta `casual`, `strict`, `parse`, `parseDate`.

A cobertura é desigual: inglês é o mais completo; `pt` tem só dias da semana, meses, horários e expressões casuais. Para estender, cria-se o parser (normalmente estendendo `AbstractParserWithWordBoundaryChecking`), coloca-se o vocabulário em `constants.ts` e registra-se o parser na configuração do `index.ts` do idioma.

## Fuso horário

`src/timezone.ts` tem `TIMEZONE_ABBR_MAP` (abreviações para offset, incluindo regras de horário de verão com `getNthWeekdayOfMonth`/`getLastWeekdayOfMonth`) e `toTimezoneOffset`. A referência pode ser `{ instant, timezone }` (`ParsingReference`).

## Utilitários

- `src/calculation/`: `duration.ts` (`addDuration`, `reverseDuration`), `weekdays.ts` (próximo/último dia da semana), `years.ts` (ano mais provável quando o texto não diz), `mergingCalculation.ts` (junta data e hora).
- `src/utils/pattern.ts`: `matchAnyPattern` (gera alternação regex de um dicionário, termos maiores primeiro) e `repeatedTimeunitPattern`; `src/utils/dates.ts`.

## Testes

- `test/` tem um diretório por idioma (`test/en/`, `test/pt/` ...) e testes de núcleo (`result.test.ts`, `system.test.ts`, `calculation_*.test.ts`).
- jest com preset `ts-jest` (configurado no `package.json`); `npx jest` roda tudo, `npx jest test/pt` só um idioma.
- `test/test_util.ts` tem os helpers `testSingleCase(chrono, texto, ref, callback)`, `testUnexpectedResult` e o matcher `toBeDate`.
