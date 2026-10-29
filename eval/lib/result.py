#!/usr/bin/env python3
"""Monta o result.json de uma execução a partir das peças gravadas pelo eval/run.sh.

Uso (chamado pelo run.sh): python3 -I result.py <dir_da_execucao>
Lê do diretório: meta.json, checks.json, metrics.before.prom, metrics.after.prom,
resources.json, agent-logs/agent-metrics.json (opcional, fornecido pelo harness).
"""
from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import metrics  # noqa: E402

SCHEMA_VERSION = 1


def load(path: str, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def main() -> int:
    run_dir = sys.argv[1]
    meta = load(os.path.join(run_dir, "meta.json"), {})
    checks = load(os.path.join(run_dir, "checks.json"))
    resources = load(os.path.join(run_dir, "resources.json"), {})
    agent_metrics = load(os.path.join(run_dir, "agent-logs", "agent-metrics.json"))
    llm = metrics.delta(os.path.join(run_dir, "metrics.before.prom"), os.path.join(run_dir, "metrics.after.prom"))

    if checks is None:
        status, success, auto_ok = "error", None, None
        check_list, rubric = [], None
    else:
        check_list, rubric = checks.get("checks", []), checks.get("rubric")
        auto_ok = all(c.get("pass") is not False for c in check_list if c.get("required"))
        status, success = checks.get("status", "error"), checks.get("pass")
    if meta.get("setup_ok") is False:
        status, success = "error", None

    result = {
        "schema_version": SCHEMA_VERSION,
        "run_id": meta.get("run_id"),
        "harness": meta.get("harness"),
        "task_id": meta.get("task_id"),
        "task_dir": meta.get("task_dir"),
        "task_title": meta.get("task_title"),
        "task_category": meta.get("task_category"),
        "repo": meta.get("repo"),
        "repo_commit": meta.get("repo_commit"),
        "status": status,              # pass | fail | pending_grading | error
        "success": success,            # true / false / null (aguarda nota ou erro)
        "auto_checks_pass": auto_ok,   # verificações automáticas obrigatórias
        "interventions": 0,            # execuções do runner são sem intervenção; ajuste manual se houver
        "started_at": meta.get("started_at"),
        "finished_at": meta.get("finished_at"),
        "timing": {
            "setup_s": meta.get("setup_s"),
            "agent_wall_s": meta.get("agent_wall_s"),
            "check_s": meta.get("check_s"),
            "timeout_s": meta.get("timeout_s"),
        },
        "agent": {
            "exit_code": meta.get("agent_exit_code"),
            "timed_out": meta.get("timed_out"),
            "commits_made": meta.get("agent_commits"),
            "diff": meta.get("diff"),
            "metrics": agent_metrics,  # opcional: <log-dir>/agent-metrics.json do harness
        },
        "llm": {"base_url": meta.get("llm_base_url"), "model": meta.get("llm_model"), **llm},
        "resources": resources,
        "checks": check_list,
        "rubric": rubric,
        "paths": {
            "workdir": meta.get("workdir"),
            "baseline_commit": meta.get("baseline"),
            "agent_patch": "agent.patch",
            "agent_logs": "agent-logs/",
            "check_log": "check.log",
        },
        "env": {
            "eval_commit": meta.get("eval_commit"),
            "eval_dirty": meta.get("eval_dirty"),
            "hostname": meta.get("hostname"),
            "kernel": meta.get("kernel"),
        },
    }
    with open(os.path.join(run_dir, "result.json"), "w") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
