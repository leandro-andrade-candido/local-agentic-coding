#!/usr/bin/env python3
"""Verificações ocultas da suíte de validação (somente stdlib; rodar com python3 -I).

Uso:
    python3 -I eval/lib/check.py <task_dir> <workdir> [--baseline SHA] [--out checks.json]

Lê <task_dir>/task.json e executa, em ordem, as verificações declaradas em "checks".
Tipos suportados:
    hidden_tests    copia testes ocultos para o workdir, roda, remove
    baseline_tests  restaura os testes originais do commit-base e roda a suíte inteira
    unchanged       caminhos que o agente não deveria ter alterado
    report          arquivo de relatório (existência, tamanho, palavras-chave)
    mutation        testes do agente contra mutantes plantados (T4)
    rubric          gabarito de 10 itens; nota dada depois (orquestrador + usuário)

Código de saída: 0 passou, 1 falhou, 3 verificações automáticas ok mas aguarda nota
do gabarito, 2 erro de infraestrutura.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

EVAL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_TIMEOUT_S = int(os.environ.get("EVAL_TEST_TIMEOUT_S", "600"))


def log(msg: str) -> None:
    print(f"[check] {msg}", file=sys.stderr, flush=True)


def git(wd: str, *args: str, check: bool = True) -> str:
    res = subprocess.run(["git", "-C", wd, *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {res.stderr.strip()}")
    return res.stdout


def changed_paths(wd: str, baseline: str, paths: list[str] | None = None) -> list[str]:
    """Arquivos diferentes do commit-base (modificados, removidos ou novos não ignorados)."""
    spec = ["--", *paths] if paths else []
    out = git(wd, "diff", "--name-only", baseline, *spec).splitlines()
    out += git(wd, "ls-files", "--others", "--exclude-standard", *spec).splitlines()
    return sorted(set(p for p in out if p))


# --------------------------------------------------------------------------- runners
class TestRun:
    def __init__(self):
        self.ok = False
        self.total = self.failed = self.errors = self.skipped = 0
        self.failing: list[str] = []
        self.timed_out = False
        self.exit_code = None
        self.output_tail = ""
        self.seconds = 0.0

    def summary(self) -> dict:
        return {
            "ok": self.ok, "total": self.total, "failed": self.failed, "errors": self.errors,
            "skipped": self.skipped, "failing": self.failing[:30], "timed_out": self.timed_out,
            "exit_code": self.exit_code, "seconds": round(self.seconds, 1),
        }


def _run(cmd: list[str], cwd: str, env: dict, timeout: int, logf) -> tuple[int | None, str, bool]:
    t0 = time.time()
    try:
        res = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        out, code, to = res.stdout + res.stderr, res.returncode, False
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        code, to = None, True
    if logf:
        logf.write(f"\n$ {' '.join(cmd)}  (cwd={cwd}, {time.time() - t0:.1f}s)\n{out}\n")
        logf.flush()
    return code, out, to


def run_tests(repo: dict, wd: str, files: list[str], logf, timeout: int = TEST_TIMEOUT_S) -> TestRun:
    tr = TestRun()
    if not files:
        tr.output_tail = "nenhum arquivo de teste"
        return tr
    tmp = tempfile.mkdtemp(prefix="evalcheck-")
    env = dict(os.environ)
    t0 = time.time()
    try:
        if repo["kind"] == "python":
            junit = os.path.join(tmp, "junit.xml")
            env.update(PYTHONDONTWRITEBYTECODE="1")
            cmd = [os.path.join(wd, ".venv/bin/python"), "-m", "pytest", "-q", "-p", "no:cacheprovider",
                   f"--junitxml={junit}", *files]
            code, out, to = _run(cmd, wd, env, timeout, logf)
            tr.exit_code, tr.timed_out = code, to
            if os.path.exists(junit):
                root = ET.parse(junit).getroot()
                suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
                for s in suites:
                    tr.total += int(s.get("tests", 0))
                    tr.failed += int(s.get("failures", 0))
                    tr.errors += int(s.get("errors", 0))
                    tr.skipped += int(s.get("skipped", 0))
                for case in root.iter("testcase"):
                    if case.find("failure") is not None or case.find("error") is not None:
                        tr.failing.append(f"{case.get('classname')}::{case.get('name')}")
            tr.ok = (code == 0 and tr.total > 0 and tr.failed == 0 and tr.errors == 0)
        elif repo["kind"] == "node":
            jout = os.path.join(tmp, "jest.json")
            env.update(CI="true")
            cmd = [os.path.join(wd, "node_modules/.bin/jest"), "--ci", "--silent", "--coverage=false",
                   "--json", f"--outputFile={jout}", "--runTestsByPath", *files]
            code, out, to = _run(cmd, wd, env, timeout, logf)
            tr.exit_code, tr.timed_out = code, to
            if os.path.exists(jout):
                with open(jout) as f:
                    data = json.load(f)
                tr.total = data.get("numTotalTests", 0)
                tr.failed = data.get("numFailedTests", 0)
                for suite in data.get("testResults", []):
                    if suite.get("status") == "failed" and not any(
                            a.get("status") == "failed" for a in suite.get("assertionResults", [])):
                        tr.failing.append(f"{os.path.relpath(suite.get('name', ''), wd)} (suite error)")
                    for a in suite.get("assertionResults", []):
                        if a.get("status") == "failed":
                            tr.failing.append(f"{os.path.relpath(suite.get('name', ''), wd)}::{a.get('fullName')}")
                tr.errors = len([x for x in tr.failing if x.endswith("(suite error)")])
            tr.ok = (code == 0 and tr.total > 0 and tr.failed == 0 and tr.errors == 0)
        else:
            raise RuntimeError(f"tipo desconhecido: {repo['kind']}")
        tr.output_tail = out[-3000:]
    finally:
        tr.seconds = time.time() - t0
        shutil.rmtree(tmp, ignore_errors=True)
    return tr


def test_files_in(repo: dict, paths: list[str]) -> list[str]:
    rx = re.compile(repo["test_file_regex"])
    return sorted(p for p in paths if rx.search(p) and any(
        p == r or p.startswith(r.rstrip("/") + "/") for r in repo["test_roots"]))


# --------------------------------------------------------------------------- checks
def check_hidden_tests(ctx, spec) -> dict:
    wd, task_dir = ctx["wd"], ctx["task_dir"]
    placed = []
    try:
        for src, dst in spec["files"].items():
            dst_abs = os.path.join(wd, dst)
            if os.path.exists(dst_abs):
                # O agente criou um arquivo com o mesmo nome: preserva e restaura depois.
                shutil.move(dst_abs, dst_abs + ".agent-orig")
            os.makedirs(os.path.dirname(dst_abs), exist_ok=True)
            shutil.copyfile(os.path.join(task_dir, src), dst_abs)
            placed.append(dst_abs)
        tr = run_tests(ctx["repo"], wd, list(spec["files"].values()), ctx["logf"])
    finally:
        for p in placed:
            os.remove(p)
            if os.path.exists(p + ".agent-orig"):
                shutil.move(p + ".agent-orig", p)
            cache = os.path.join(os.path.dirname(p), "__pycache__")
            if os.path.isdir(cache) and not git(wd, "ls-files", os.path.relpath(cache, wd)).strip():
                shutil.rmtree(cache, ignore_errors=True)
    return {"pass": tr.ok, "tests": tr.summary(),
            "detail": f"{tr.total - tr.failed - tr.errors}/{tr.total} testes ocultos passaram"}


def baseline_test_files(ctx) -> list[str]:
    repo = ctx["repo"]
    files = git(ctx["wd"], "ls-tree", "-r", "--name-only", ctx["baseline"], "--", *repo["test_roots"]).splitlines()
    return test_files_in(repo, files)


def check_baseline_tests(ctx, spec) -> dict:
    wd, base = ctx["wd"], ctx["baseline"]
    files = baseline_test_files(ctx)
    modified = [p for p in changed_paths(wd, base, files) if p in files]
    if modified:
        git(wd, "checkout", base, "--", *modified)
    tr = run_tests(ctx["repo"], wd, files, ctx["logf"])
    detail = f"{tr.total - tr.failed - tr.errors}/{tr.total} testes da suíte original passaram"
    if modified:
        detail += f"; {len(modified)} arquivo(s) de teste alterado(s) pelo agente foram restaurados"
    return {"pass": tr.ok, "tests": tr.summary(), "tests_modified_by_agent": modified, "detail": detail}


def check_unchanged(ctx, spec) -> dict:
    changed = changed_paths(ctx["wd"], ctx["baseline"], spec["paths"])
    return {"pass": not changed, "changed": changed[:50],
            "detail": "nenhuma alteração" if not changed else f"{len(changed)} arquivo(s) alterado(s)"}


def find_report(wd: str, names: list[str]) -> str | None:
    lower = {n.lower() for n in names}
    for n in names:
        if os.path.isfile(os.path.join(wd, n)):
            return n
    for entry in os.listdir(wd):
        if entry.lower() in lower and os.path.isfile(os.path.join(wd, entry)):
            return entry
    return None


def keyword_hits(text: str, groups: list[list[str]]) -> list[bool]:
    low = text.lower()
    return [any(k.lower() in low for k in g) for g in groups]


def check_report(ctx, spec) -> dict:
    names = spec["file"] if isinstance(spec["file"], list) else [spec["file"]]
    found = find_report(ctx["wd"], names)
    if not found:
        return {"pass": False, "detail": f"relatório ausente ({' / '.join(names)})"}
    with open(os.path.join(ctx["wd"], found), errors="replace") as f:
        text = f.read()
    words = len(text.split())
    hits = keyword_hits(text, spec.get("keyword_groups", []))
    ok = words >= spec.get("min_words", 0) and all(hits)
    ctx["reports"][found] = text
    return {"pass": ok, "file": found, "words": words, "keyword_groups_hit": hits,
            "detail": f"{found}: {words} palavras; grupos de palavras-chave {sum(hits)}/{len(hits)}"}


def check_rubric(ctx, spec) -> dict:
    names = spec["report"] if isinstance(spec["report"], list) else [spec["report"]]
    found = find_report(ctx["wd"], names)
    text = ""
    if found:
        with open(os.path.join(ctx["wd"], found), errors="replace") as f:
            text = f.read()
    hits = keyword_hits(text, spec.get("hints", [])) if text else []
    ctx["rubric"] = {
        "rubric_file": os.path.relpath(os.path.join(ctx["task_dir"], spec.get("rubric", "rubric.md")), EVAL_DIR),
        "report_file": found, "max": spec.get("max", 10), "threshold": spec.get("threshold", 7),
        "score": None, "graded_by": None, "notes": None,
        "auto_hint": sum(hits), "auto_hint_items": hits,
    }
    return {"pass": None, "detail": f"aguarda nota (pista automática {sum(hits)}/{len(spec.get('hints', []))})"}


def check_mutation(ctx, spec) -> dict:
    wd, base, repo = ctx["wd"], ctx["baseline"], ctx["repo"]
    module = spec["module"]
    exclude = set(spec.get("exclude_tests", []))
    agent_tests = [p for p in test_files_in(repo, changed_paths(wd, base)) if p not in exclude
                   and os.path.exists(os.path.join(wd, p))]
    res = {"module": module, "agent_test_files": agent_tests}
    if not agent_tests:
        return {**res, "pass": False, "detail": "nenhum arquivo de teste novo ou alterado"}
    notes = []
    if changed_paths(wd, base, [module]):
        git(wd, "checkout", base, "--", module)
        notes.append("módulo alterado pelo agente foi restaurado antes da mutação")
    clean = run_tests(repo, wd, agent_tests, ctx["logf"])
    res["clean_run"] = clean.summary()
    if not clean.ok or clean.total < spec.get("min_tests", 1):
        return {**res, "pass": False, "notes": notes,
                "detail": f"testes do agente não passam no código original ({clean.total} testes, "
                          f"{clean.failed} falhas, {clean.errors} erros)"}
    mutants = sorted(glob.glob(os.path.join(ctx["task_dir"], spec.get("mutants", "mutants/*.patch"))))
    killed, rows = 0, []
    for m in mutants:
        name = os.path.basename(m)
        ap = subprocess.run(["git", "-C", wd, "apply", m], capture_output=True, text=True)
        if ap.returncode != 0:
            rows.append({"mutant": name, "killed": None, "error": ap.stderr.strip()[:200]})
            continue
        try:
            tr = run_tests(repo, wd, agent_tests, ctx["logf"], timeout=spec.get("mutant_timeout_s", 180))
        finally:
            git(wd, "checkout", base, "--", module)
        k = not tr.ok
        killed += int(k)
        rows.append({"mutant": name, "killed": k, "failed": tr.failed, "timed_out": tr.timed_out})
    valid = [r for r in rows if r["killed"] is not None]
    score = killed / len(valid) if valid else 0.0
    ok = bool(valid) and score >= spec.get("min_score", 0.6)
    return {**res, "pass": ok, "notes": notes, "mutants": rows, "killed": killed, "total": len(valid),
            "score": round(score, 3),
            "detail": f"{killed}/{len(valid)} mutantes mortos ({score:.0%}; mínimo {spec.get('min_score', 0.6):.0%}); "
                      f"{clean.total} testes do agente"}


def restore_protected_config(ctx) -> list[str]:
    """Volta arquivos de configuração do runner de testes ao commit-base (o agente não deve
    conseguir esconder testes ocultos mudando, por exemplo, testPathIgnorePatterns)."""
    wd, base = ctx["wd"], ctx["baseline"]
    protected = ctx["repo"].get("protected_config", [])
    changed = [p for p in changed_paths(wd, base, protected) if p in protected]
    in_base = set(git(wd, "ls-tree", "-r", "--name-only", base, "--", *protected).split()) if protected else set()
    for p in changed:
        if p in in_base:
            git(wd, "checkout", base, "--", p)
        elif os.path.exists(os.path.join(wd, p)):
            os.remove(os.path.join(wd, p))
    return changed


CHECKS = {
    "hidden_tests": check_hidden_tests, "baseline_tests": check_baseline_tests,
    "unchanged": check_unchanged, "report": check_report, "rubric": check_rubric,
    "mutation": check_mutation,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("task_dir")
    ap.add_argument("workdir")
    ap.add_argument("--baseline")
    ap.add_argument("--out")
    ap.add_argument("--log")
    a = ap.parse_args()

    task_dir, wd = os.path.abspath(a.task_dir), os.path.abspath(a.workdir)
    with open(os.path.join(task_dir, "task.json")) as f:
        task = json.load(f)
    with open(os.path.join(EVAL_DIR, "repos", task["repo"], "repo.json")) as f:
        repo = json.load(f)
    baseline = a.baseline or git(wd, "rev-list", "--max-parents=0", "HEAD").split()[-1]
    logf = open(a.log, "a") if a.log else None

    ctx = {"wd": wd, "task_dir": task_dir, "repo": repo, "baseline": baseline, "logf": logf,
           "reports": {}, "rubric": None}
    t0 = time.time()
    restored = restore_protected_config(ctx)
    if restored:
        log(f"{task['id']}: configuração de testes restaurada do commit-base: {', '.join(restored)}")
    results, status = [], "pass"
    try:
        for spec in task["checks"]:
            name = spec.get("name", spec["type"])
            log(f"{task['id']}: {name} ...")
            try:
                r = CHECKS[spec["type"]](ctx, spec)
            except Exception as e:  # noqa: BLE001 - registra e segue
                r = {"pass": False, "detail": f"erro na verificação: {e!r}", "infra_error": True}
            required = spec.get("required", spec["type"] != "rubric")
            r = {"name": name, "type": spec["type"], "required": required, **r}
            results.append(r)
            log(f"{task['id']}: {name}: {'ok' if r['pass'] else ('pendente' if r['pass'] is None else 'FALHOU')}"
                f" - {r.get('detail', '')}")
    finally:
        if logf:
            logf.close()

    failed = [r for r in results if r["required"] and r["pass"] is False]
    infra = [r for r in results if r.get("infra_error")]
    if failed:
        status, passed = "fail", False
    elif ctx["rubric"] is not None:
        status, passed = "pending_grading", None
    else:
        status, passed = "pass", True
    out = {"task_id": task["id"], "pass": passed, "status": status, "checks": results,
           "rubric": ctx["rubric"], "baseline": baseline, "infra_errors": len(infra),
           "protected_config_restored": restored,
           "seconds": round(time.time() - t0, 1)}
    if a.out:
        with open(a.out, "w") as f:
            json.dump(out, f, indent=2, ensure_ascii=False)
    print(json.dumps({"task_id": task["id"], "status": status,
                      "checks": {r["name"]: r["pass"] for r in results}}, ensure_ascii=False))
    if infra and not failed:
        return 2
    return {"pass": 0, "fail": 1, "pending_grading": 3}[status]


if __name__ == "__main__":
    sys.exit(main())
