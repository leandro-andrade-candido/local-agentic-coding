#!/usr/bin/env python3
"""Agrega result.json em tabelas Markdown (somente stdlib; rode com python3 -I).

Uso:
    python3 -I eval/summarize.py [caminho ...] [--json]

Cada caminho pode ser um result.json ou um diretório (busca recursiva). Padrão: eval/runs.

Tabelas:
  1. por harness x tarefa: execuções, sucessos, taxa de sucesso, mediana de tempo do agente,
     tokens (mediana), velocidade de prefill/geração (mediana), pico de RAM/VRAM, timeouts;
  2. por harness: critério da Meta 1 (tarefas T1-T7 resolvidas em pelo menos 2/3 das execuções);
  3. execuções que aguardam nota do gabarito (T1, T6).
Execuções "pending_grading" não entram na taxa até receberem nota (eval/grade.py).
"""
from __future__ import annotations

import json
import math
import os
import statistics
import sys

EVAL_DIR = os.path.dirname(os.path.abspath(__file__))
PLAN_TASKS = ["T1", "T2", "T3", "T4", "T5", "T6", "T7"]


def find_results(paths: list[str]) -> list[str]:
    found = []
    for p in paths:
        if os.path.isfile(p):
            found.append(p)
        elif os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                if "result.json" in files:
                    found.append(os.path.join(root, "result.json"))
    return sorted(set(found))


def med(values):
    vals = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(vals) if vals else None


def mx(values):
    vals = [v for v in values if isinstance(v, (int, float))]
    return max(vals) if vals else None


def fmt(v, digits=0, suffix=""):
    if v is None:
        return "-"
    if digits == 0:
        return f"{v:,.0f}{suffix}".replace(",", ".")
    return f"{v:.{digits}f}{suffix}"


def fmt_s(seconds):
    if seconds is None:
        return "-"
    m, s = divmod(int(round(seconds)), 60)
    return f"{m}m{s:02d}s" if m else f"{s}s"


def task_order(tid: str):
    return (0 if tid.startswith("S") else 1, tid)


def aggregate(results: list[dict]) -> dict:
    groups: dict[tuple[str, str], list[dict]] = {}
    for r in results:
        groups.setdefault((r.get("harness"), r.get("task_id")), []).append(r)
    rows = []
    for (h, t), rs in sorted(groups.items(), key=lambda kv: (kv[0][0], task_order(kv[0][1]))):
        st = [r.get("status") for r in rs]
        passed, failed = st.count("pass"), st.count("fail")
        pending, errors = st.count("pending_grading"), st.count("error")
        decided = passed + failed
        rows.append({
            "harness": h, "task": t, "runs": len(rs), "pass": passed, "fail": failed,
            "pending": pending, "error": errors,
            "success_rate": (passed / decided) if decided else None,
            "agent_wall_s_median": med([r["timing"].get("agent_wall_s") for r in rs]),
            "tokens_in_median": med([r["llm"].get("tokens_in") for r in rs]),
            "tokens_out_median": med([r["llm"].get("tokens_out") for r in rs]),
            "prefill_tps_median": med([r["llm"].get("prefill_tps") for r in rs]),
            "gen_tps_median": med([r["llm"].get("gen_tps") for r in rs]),
            "ram_peak_mib": mx([r.get("resources", {}).get("ram_used_mib_peak") for r in rs]),
            "vram_peak_mib": mx([r.get("resources", {}).get("vram_used_mib_peak") for r in rs]),
            "timeouts": sum(1 for r in rs if r.get("agent", {}).get("timed_out")),
            "tool_call_errors": sum((r.get("agent", {}).get("metrics") or {}).get("tool_call_errors", 0) or 0
                                    for r in rs),
            "interventions_median": med([r.get("interventions") for r in rs]),
        })
    meta = {}
    for h in sorted({r["harness"] for r in rows}):
        solved, detail = 0, []
        for t in PLAN_TASKS:
            row = next((x for x in rows if x["harness"] == h and x["task"] == t), None)
            if not row:
                detail.append(f"{t}: -")
                continue
            need = math.ceil(2 * row["runs"] / 3)
            ok = row["pass"] >= need
            solved += int(ok)
            pend = f", {row['pending']} aguardando nota" if row["pending"] else ""
            detail.append(f"{t}: {row['pass']}/{row['runs']}{pend}")
        meta[h] = {"tasks_solved_2of3": solved, "detail": detail}
    pending = [r for r in results if r.get("status") == "pending_grading"]
    return {"rows": rows, "meta1": meta, "pending": pending}


def render(agg: dict, n_results: int) -> str:
    out = [f"# Resumo da validação ({n_results} execuções)", ""]
    out += ["## Por harness e tarefa", "",
            "| Harness | Tarefa | Exec. | Sucesso | Taxa | Aguarda nota | Erro | Tempo (mediana) | Tokens in | "
            "Tokens out | Prefill t/s | Geração t/s | Pico RAM | Pico VRAM | Timeouts |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in agg["rows"]:
        rate = "-" if r["success_rate"] is None else f"{r['success_rate']:.0%}"
        out.append(
            f"| {r['harness']} | {r['task']} | {r['runs']} | {r['pass']} | {rate} | {r['pending']} | {r['error']} | "
            f"{fmt_s(r['agent_wall_s_median'])} | {fmt(r['tokens_in_median'])} | {fmt(r['tokens_out_median'])} | "
            f"{fmt(r['prefill_tps_median'], 1)} | {fmt(r['gen_tps_median'], 1)} | "
            f"{fmt(r['ram_peak_mib'] and r['ram_peak_mib'] / 1024, 1, ' GiB')} | "
            f"{fmt(r['vram_peak_mib'] and r['vram_peak_mib'] / 1024, 1, ' GiB')} | {r['timeouts']} |")
    out += ["", "## Meta 1 por harness (T1–T7 resolvidas em pelo menos 2/3 das execuções; alvo: 5 de 7)", "",
            "| Harness | Tarefas resolvidas | Detalhe (sucessos/execuções) |", "|---|---:|---|"]
    for h, m in agg["meta1"].items():
        out.append(f"| {h} | {m['tasks_solved_2of3']}/7 | {'; '.join(m['detail'])} |")
    if agg["pending"]:
        out += ["", "## Aguardando nota do gabarito", "",
                "Registre com `python3 -I eval/grade.py <result.json> --score N --by NOME`.", ""]
        for r in agg["pending"]:
            hint = (r.get("rubric") or {}).get("auto_hint")
            out.append(f"- `{r.get('_path')}` ({r.get('harness')} {r.get('task_id')}, pista automática {hint}/10)")
    out += ["", "Notas: tokens e velocidades vêm de /metrics do llama-server (\"-\" = indisponível); "
            "a taxa ignora execuções aguardando nota; tempo = parede do agente, sem setup e verificação."]
    return "\n".join(out) + "\n"


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    paths = args or [os.path.join(EVAL_DIR, "runs")]
    results = []
    for p in find_results(paths):
        try:
            with open(p) as f:
                r = json.load(f)
        except (OSError, ValueError) as e:
            print(f"ignorando {p}: {e}", file=sys.stderr)
            continue
        r["_path"] = os.path.relpath(p)
        r.setdefault("timing", {})
        r.setdefault("llm", {})
        results.append(r)
    agg = aggregate(results)
    if "--json" in sys.argv:
        agg = {**agg, "pending": [r["_path"] for r in agg["pending"]]}
        print(json.dumps(agg, indent=2, ensure_ascii=False))
    else:
        sys.stdout.write(render(agg, len(results)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
