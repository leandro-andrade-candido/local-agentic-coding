#!/usr/bin/env python3
"""Aggregates result.json files into Markdown tables (stdlib only; run with python3 -I).

Usage:
    python3 -I eval/summarize.py [path ...] [--json]

Each path can be a result.json or a directory (searched recursively). Default: eval/runs.

Tables:
  1. per harness x task: runs, successes, success rate, median agent time,
     tokens (median), prefill/generation speed (median), RAM/VRAM peak, timeouts;
  2. per harness: Goal 1 criterion (tasks T1-T7 solved in at least 2/3 of the runs);
  3. skills (K1-K3): in how many runs the skill was loaded;
  4. runs without server metrics, with the reason (e.g. 401 without a key);
  5. runs awaiting the rubric grade (T1, T5, T6).
"pending_grading" runs do not count toward the rate until they are graded (eval/grade.py).
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
        return f"{v:,.0f}{suffix}"
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
            pend = f", {row['pending']} awaiting grade" if row["pending"] else ""
            detail.append(f"{t}: {row['pass']}/{row['runs']}{pend}")
        meta[h] = {"tasks_solved_2of3": solved, "detail": detail}
    pending = [r for r in results if r.get("status") == "pending_grading"]
    skills = {}
    for r in results:
        for c in r.get("checks") or []:
            if c.get("type") != "skill_usage":
                continue
            key = (r.get("harness"), r.get("task_id"), c.get("skill"))
            row = skills.setdefault(key, {"harness": key[0], "task": key[1], "skill": key[2], "runs": 0,
                                          "loaded": 0, "no_transcript": 0, "task_pass": 0, "required": c.get("required")})
            row["runs"] += 1
            row["loaded"] += int(c.get("loaded") is True)
            row["no_transcript"] += int(c.get("loaded") is None)
            row["task_pass"] += int(r.get("status") == "pass")
    no_metrics = {}
    for r in results:
        llm = r.get("llm") or {}
        if llm.get("available") is False:
            reason = llm.get("reason") or "no reason recorded"
            no_metrics[reason] = no_metrics.get(reason, 0) + 1
    return {"rows": rows, "meta1": meta, "pending": pending,
            "skills": sorted(skills.values(), key=lambda x: (x["harness"], x["task"])), "no_metrics": no_metrics}


def render(agg: dict, n_results: int) -> str:
    out = [f"# Validation summary ({n_results} runs)", ""]
    out += ["## By harness and task", "",
            "| Harness | Task | Runs | Passed | Rate | Awaiting grade | Error | Time (median) | Tokens in | "
            "Tokens out | Prefill t/s | Generation t/s | RAM peak | VRAM peak | Timeouts |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in agg["rows"]:
        rate = "-" if r["success_rate"] is None else f"{r['success_rate']:.0%}"
        out.append(
            f"| {r['harness']} | {r['task']} | {r['runs']} | {r['pass']} | {rate} | {r['pending']} | {r['error']} | "
            f"{fmt_s(r['agent_wall_s_median'])} | {fmt(r['tokens_in_median'])} | {fmt(r['tokens_out_median'])} | "
            f"{fmt(r['prefill_tps_median'], 1)} | {fmt(r['gen_tps_median'], 1)} | "
            f"{fmt(r['ram_peak_mib'] and r['ram_peak_mib'] / 1024, 1, ' GiB')} | "
            f"{fmt(r['vram_peak_mib'] and r['vram_peak_mib'] / 1024, 1, ' GiB')} | {r['timeouts']} |")
    out += ["", "## Goal 1 by harness (T1–T7 solved in at least 2/3 of the runs; target: 5 of 7)", "",
            "| Harness | Tasks solved | Detail (passes/runs) |", "|---|---:|---|"]
    for h, m in agg["meta1"].items():
        out.append(f"| {h} | {m['tasks_solved_2of3']}/7 | {'; '.join(m['detail'])} |")
    if agg["skills"]:
        out += ["", "## Skills (K1–K3)", "",
                "K1 and K3 ask for the skill by name (loading it is required); K2 does not mention it and "
                "\"loaded\" only measures automatic triggering.", "",
                "| Harness | Task | Skill | Runs | Skill loaded | No transcript | Task ok |",
                "|---|---|---|---:|---:|---:|---:|"]
        for k in agg["skills"]:
            out.append(f"| {k['harness']} | {k['task']} | {k['skill']}{'' if k['required'] else ' (measurement)'} | "
                       f"{k['runs']} | {k['loaded']}/{k['runs']} | {k['no_transcript']} | {k['task_pass']}/{k['runs']} |")
    if agg["no_metrics"]:
        out += ["", "## WARNING: runs without server metrics", ""]
        for reason, n in sorted(agg["no_metrics"].items(), key=lambda kv: -kv[1]):
            out.append(f"- {n} run(s): {reason}")
    if agg["pending"]:
        out += ["", "## Awaiting rubric grade", "",
                "Record it with `python3 -I eval/grade.py <result.json> --score N --by NAME`.", ""]
        for r in agg["pending"]:
            rub = r.get("rubric") or {}
            out.append(f"- `{r.get('_path')}` ({r.get('harness')} {r.get('task_id')}, "
                       f"automatic hint {rub.get('auto_hint')}/{rub.get('max', 10)})")
    out += ["", "Notes: tokens and speeds come from llama-server /metrics (\"-\" = unavailable); "
            "the rate ignores runs awaiting a grade; time = agent wall clock, without setup and checks."]
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
            print(f"skipping {p}: {e}", file=sys.stderr)
            continue
        r["_path"] = os.path.relpath(p)
        r.setdefault("timing", {})
        r.setdefault("llm", {})
        results.append(r)
    agg = aggregate(results)
    if "--json" in sys.argv:
        agg = {**agg, "pending": [r["_path"] for r in agg["pending"]]}
        agg["no_metrics"] = [{"reason": k, "runs": v} for k, v in agg["no_metrics"].items()]
        print(json.dumps(agg, indent=2, ensure_ascii=False))
    else:
        sys.stdout.write(render(agg, len(results)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
