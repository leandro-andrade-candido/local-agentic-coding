#!/usr/bin/env python3
"""Registra a nota do gabarito (T1, T6) num result.json e recalcula o sucesso.

Uso:
    python3 -I eval/grade.py <result.json> --score N --by NOME [--notes TEXTO] [--interventions K]

Sucesso = verificações automáticas obrigatórias passaram E nota >= threshold do gabarito.
--interventions registra intervenções humanas feitas durante a execução (padrão: mantém).
"""
from __future__ import annotations

import argparse
import datetime
import json


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("result")
    ap.add_argument("--score", type=float)
    ap.add_argument("--by")
    ap.add_argument("--notes")
    ap.add_argument("--interventions", type=int)
    a = ap.parse_args()

    with open(a.result) as f:
        r = json.load(f)
    if a.interventions is not None:
        r["interventions"] = a.interventions
    if a.score is not None:
        rub = r.get("rubric")
        if not rub:
            ap.error("este result.json não tem gabarito (rubric)")
        if not a.by:
            ap.error("--by é obrigatório junto com --score")
        if not 0 <= a.score <= rub.get("max", 10):
            ap.error(f"nota fora de 0..{rub.get('max', 10)}")
        rub.update(score=a.score, graded_by=a.by, notes=a.notes,
                   graded_at=datetime.datetime.now().astimezone().isoformat(timespec="seconds"))
        if r.get("auto_checks_pass") is True:
            ok = a.score >= rub.get("threshold", 7)
            r["success"], r["status"] = ok, ("pass" if ok else "fail")
        elif r.get("auto_checks_pass") is False:
            r["success"], r["status"] = False, "fail"
    with open(a.result, "w") as f:
        json.dump(r, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{a.result}: status={r['status']} success={r['success']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
