# Gabarito do T5: causa raiz no `INVESTIGACAO.md`

Escrito antes das execuções. A correção é conferida pelos testes ocultos e pela suíte; aqui só se avalia se o relatório **explica a causa certa**. A verificação automática só confere que o relatório existe e cita `parseDuration` (ou `parsedDurationCache`) e `addDuration`. Palavras soltas como "cache" ou "estado compartilhado" não bastam.

Cada item vale 1 ponto. **Causa raiz correta = 2 de 2.** Sucesso do T5 = testes ocultos + suíte original + nota 2.

| # | Item | O que precisa aparecer |
|---|---|---|
| 1 | O cache em `parseDuration` (`src/locales/en/constants.ts`, `parsedDurationCache`) devolve **o mesmo objeto** `Duration` a cada chamada com o mesmo texto (a chave ignora maiúsculas). | Cache + mesmo objeto (instância compartilhada), no lugar certo. |
| 2 | `addDuration` (`src/calculation/duration.ts`) **altera o objeto recebido** quando há frações (soma o resto na unidade menor), então a segunda análise do mesmo texto parte de um objeto já alterado. Isso explica por que só falham expressões fracionárias repetidas e por que "Strict mode" passa sozinho. | Mutação do argumento por `addDuration` como mecanismo, ligada ao sintoma da ordem. |

Não tira ponto, mas anote em `notes`:
- correção que torna `addDuration` imutável (reprova pela suíte: muda "in half a day");
- relatório que acerta a causa e erra o mecanismo, ou o contrário (vale 1).

Registro: `python3 -I eval/grade.py <result.json> --score N --by NOME [--notes "..."]`.
