// S2 hidden tests: YEAR_PATTERN/parseYear of pt and es centralized in src/calculation/years.ts.
import * as fs from "fs";
import * as path from "path";
import * as chrono from "../src";
import { YEAR_WITH_ERA_PATTERN, parseYearWithEra } from "../src/calculation/years";

test("Hidden S2 - shared helpers keep the old behaviour", () => {
    expect(parseYearWithEra("2012")).toBe(2012);
    expect(parseYearWithEra("99")).toBe(1999);
    expect(parseYearWithEra("12")).toBe(2012);
    expect(parseYearWithEra("88 a.C.")).toBe(-88);
    expect(parseYearWithEra("234 AC")).toBe(-234);
    expect(parseYearWithEra("234 d.C.")).toBe(234);
    expect(parseYearWithEra("1 a.d.")).toBe(1);

    const re = new RegExp(`^(?:${YEAR_WITH_ERA_PATTERN})$`, "i");
    for (const ok of ["2012", "88 a.C.", "234 AC", "1 d.C.", "5 a.d."]) {
        expect(re.test(ok)).toBe(true);
    }
    expect(re.test("12345")).toBe(false);
});

test("Hidden S2 - copies removed from pt and es", () => {
    for (const locale of ["pt", "es"]) {
        const file = path.join(__dirname, "..", "src", "locales", locale, "constants.ts");
        const source = fs.readFileSync(file, "utf8");
        expect(source).not.toMatch(/function\s+parseYear\s*\(/);
        expect(source).not.toContain("[0-9]{1,4}(?![^");
    }
});

test("Hidden S2 - locales still parse years", () => {
    const ref = new Date(2020, 0, 1);
    expect(chrono.pt.parseDate("10 de agosto de 2012", ref)?.getFullYear()).toBe(2012);
    expect(chrono.pt.parseDate("10 de agosto de 99", ref)?.getFullYear()).toBe(1999);
    expect(chrono.es.parseDate("10 de agosto de 2012", ref)?.getFullYear()).toBe(2012);
    expect(chrono.es.parseDate("10 agosto 12", ref)?.getFullYear()).toBe(2012);
});
