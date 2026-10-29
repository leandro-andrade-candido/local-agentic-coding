// Testes ocultos do T3: expressões relativas com unidades de tempo em português.
// O comportamento esperado é o da expressão equivalente em inglês.
import * as chrono from "../src";

const REF = new Date(2012, 7, 10, 12, 14);

const PAIRS: Array<[string, string]> = [
    ["há 3 dias", "3 days ago"],
    ["ha 3 dias", "3 days ago"],
    ["Há uma semana", "a week ago"],
    ["faz 2 meses", "2 months ago"],
    ["5 minutos atrás", "5 minutes ago"],
    ["5 minutos atras", "5 minutes ago"],
    ["há 3 dias atrás", "3 days ago"],
    ["há 1 ano", "1 year ago"],
    ["há dois anos", "2 years ago"],
    ["há 2 horas", "2 hours ago"],
    ["há 30 segundos", "30 seconds ago"],
    ["há 1,5 hora", "1.5 hours ago"],
    ["daqui a 2 semanas", "in 2 weeks"],
    ["dentro de 3 dias", "within 3 days"],
    ["em 10 minutos", "in 10 minutes"],
    ["em 5 min", "in 5 minutes"],
    ["daqui a uma hora", "in an hour"],
    ["daqui a 1 mês", "in 1 month"],
    ["daqui a 1 mes", "in 1 month"],
    ["daqui a três meses", "in 3 months"],
    ["daqui a 2 anos", "in 2 years"],
    ["em 1 trimestre", "in 1 quarter"],
    ["em meia hora", "in half an hour"],
    ["daqui a 1 hora e 30 minutos", "in 1 hour and 30 minutes"],
    ["em doze dias", "in 12 days"],
];

test("Hidden T3 - same result as the English equivalent (casual)", () => {
    for (const [pt, en] of PAIRS) {
        const expected = chrono.en.parseDate(en, REF);
        expect(expected).not.toBeNull();
        const results = chrono.pt.parse(pt, REF);
        expect(results.length).toBe(1);
        expect(results[0].text.toLowerCase()).toBe(pt.toLowerCase());
        expect(results[0].start.date().getTime()).toBe(expected!.getTime());
    }
});

test("Hidden T3 - strict mode", () => {
    for (const [pt, en] of PAIRS.filter(([p]) => !p.includes("min ") && !p.endsWith("min"))) {
        const expected = chrono.en.parseDate(en, REF);
        const got = chrono.pt.strict.parseDate(pt, REF);
        expect(got?.getTime()).toBe(expected!.getTime());
    }
});

test("Hidden T3 - expression inside a sentence", () => {
    const r1 = chrono.pt.parse("Recebi o pedido há 3 dias, ok?", REF);
    expect(r1.length).toBe(1);
    expect(r1[0].index).toBe(16);
    expect(r1[0].text).toBe("há 3 dias");

    const r2 = chrono.pt.parse("A entrega chega daqui a 2 semanas.", REF);
    expect(r2.length).toBe(1);
    expect(r2[0].text).toBe("daqui a 2 semanas");
    expect(r2[0].start.date().getTime()).toBe(new Date(2012, 7, 24, 12, 14).getTime());

    expect(chrono.pt.parseDate("Me liga em 10 minutos", REF)?.getTime()).toBe(new Date(2012, 7, 10, 12, 24).getTime());
});

test("Hidden T3 - negative cases and existing behaviour", () => {
    expect(chrono.pt.parse("há muito tempo", REF)).toHaveLength(0);
    expect(chrono.pt.parse("em 2015", REF)).toHaveLength(0);

    const date = chrono.pt.parse("Vamos nos ver em 5 de maio", REF);
    expect(date).toHaveLength(1);
    expect(date[0].start.get("day")).toBe(5);
    expect(date[0].start.get("month")).toBe(5);

    const casual = chrono.pt.parse("amanhã", REF);
    expect(casual).toHaveLength(1);
    expect(casual[0].start.get("day")).toBe(11);
});
