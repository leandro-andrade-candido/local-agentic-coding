// T5 hidden tests: the result of a relative expression must not depend on
// what was parsed before (state shared between calls).
import * as chrono from "../src";

const REF = new Date(2012, 7, 10, 12, 14);

const CASES: Array<[string, Date, boolean]> = [
    // [text, expected date, hour "certain"?] - upstream values without the regression
    ["in half a quarter", new Date(2012, 8, 24, 12, 14), false],
    ["within half an hour", new Date(2012, 7, 10, 12, 44), true],
    ["half an hour from now", new Date(2012, 7, 10, 12, 44), true],
    ["in 1.5 hours", new Date(2012, 7, 10, 13, 44), true],
    ["in half a day", new Date(2012, 7, 11, 0, 14), true],
    ["2.5 days from now", new Date(2012, 7, 13, 0, 14), true],
    ["in 1.5 weeks", new Date(2012, 7, 21, 12, 14), false],
    ["in 2 days", new Date(2012, 7, 12, 12, 14), false],
];

test("Hidden T5 - repeated parsing gives the same result", () => {
    for (let round = 0; round < 3; round++) {
        for (const [text, expected, hourCertain] of CASES) {
            for (const variant of [text, text.toUpperCase(), `we met ${text}`]) {
                const results = chrono.parse(variant, REF);
                expect(results.length).toBe(1);
                expect(results[0].start.date().getTime()).toBe(expected.getTime());
                expect(results[0].start.isCertain("hour")).toBe(hourCertain);
            }
        }
    }
});

test("Hidden T5 - strict and casual share no state", () => {
    for (let round = 0; round < 3; round++) {
        expect(chrono.strict.parseDate("in half a quarter", REF)?.getTime()).toBe(new Date(2012, 8, 24, 12, 14).getTime());
        expect(chrono.casual.parseDate("within half an hour", REF)?.getTime()).toBe(new Date(2012, 7, 10, 12, 44).getTime());
        expect(chrono.en.GB.parseDate("in 1.5 hours", REF)?.getTime()).toBe(new Date(2012, 7, 10, 13, 44).getTime());
    }
});

test("Hidden T5 - different reference dates", () => {
    const refs = [new Date(2012, 7, 10, 12, 14), new Date(2013, 0, 5, 8, 0), new Date(2014, 5, 1, 23, 30)];
    for (let round = 0; round < 2; round++) {
        for (const ref of refs) {
            const d = chrono.parseDate("within half an hour", ref);
            expect(d?.getTime()).toBe(ref.getTime() + 30 * 60 * 1000);
        }
    }
});
