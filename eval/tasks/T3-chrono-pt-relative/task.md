O chrono entende expressões relativas em inglês ("3 days ago", "in 2 weeks"), mas em português não: `chrono.pt.parseDate("há 3 dias")` devolve `null`. Implemente isso no locale `pt`.

Precisa funcionar em `chrono.pt.parse` / `chrono.pt.parseDate` e também em `chrono.pt.strict`:

- passado: "há 3 dias", "ha 3 dias", "faz 2 meses", "5 minutos atrás" (ou "atras"), "há 3 dias atrás";
- futuro: "daqui a 2 semanas", "dentro de 3 dias", "em 10 minutos";
- unidades: segundo(s), minuto(s) e "min", hora(s), dia(s), semana(s), mês/mes/meses, trimestre(s), ano(s);
- números em algarismos (inclusive decimais com vírgula, como "1,5"), por extenso de "um"/"uma" até "doze", e "meia" ("em meia hora" = 30 minutos);
- combinações com "e": "daqui a 1 hora e 30 minutos".

O resultado tem que ser o mesmo da expressão equivalente em inglês, com a mesma data e hora. Por exemplo, `chrono.pt.parseDate("há 3 dias", ref)` deve ser igual a `chrono.en.parseDate("3 days ago", ref)`. O `text` e o `index` do resultado devem cobrir só a expressão: em "Recebi o pedido há 3 dias, ok?", o texto é "há 3 dias".

Não pode quebrar o que já existe: "em 5 de maio" continua sendo a data 5 de maio, e "há muito tempo" ou "em 2015" não devem gerar resultado.

Siga a organização que os outros idiomas já usam e escreva testes. As dependências já estão instaladas (`npx jest test/pt` roda os testes do português; `npx jest` roda tudo).
