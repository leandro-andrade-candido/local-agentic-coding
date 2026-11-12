#!/usr/bin/env python3
"""Hidden checks of the validation suite (stdlib only; run with python3 -I).

Usage:
    python3 -I eval/lib/check.py <task_dir> <workdir> [--baseline SHA] [--out checks.json] [--log check.log]
        [--deps-env DIR] [--agent-logs DIR] [--skills-dirs D1:D2]

Reads <task_dir>/task.json and runs, in order, the checks declared in "checks".
Supported types:
    hidden_tests    copies hidden tests into the workdir, runs them, removes them
    baseline_tests  restores the original tests from the base commit and runs the whole suite
    unchanged       paths the agent should not have changed
    report          report file (existence, size, keywords, questions, options)
    mutation        the agent's NEW tests against planted mutants (T4, S3)
    rubric          rubric; grade given later (orchestrator + user) -> status pending_grading
    skill_usage     the agent transcript shows the skill was loaded (K1-K3)
    plan_format     plan file in the expected format (K3)

The tests never run with anything the agent may have changed (I1):
  - dependencies from the clean environment (--deps-env, built from the cache before the agent):
    Python uses the .venv from there; Node gets a fresh copy of the node_modules from there;
  - runner configuration given on the command line: pytest with -c <empty ini>,
    --noconftest and plugin autoload off; jest with --config <json from repo.json>
    and a fresh --cacheDirectory; clean process environment (no PYTEST_*/NODE_OPTIONS...);
  - versioned test and configuration files go back to the base commit before running.

Exit code: 0 passed, 1 failed, 3 automatic checks ok but awaiting the rubric grade,
2 infrastructure error.
"""
from __future__ import annotations

import argparse
import fnmatch
import glob
import hashlib
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


# The grader's git runs on the agent's workdir, whose .git/config the agent controls.
# Neutralizes whatever would run agent code (fsmonitor, hooks) or read outside config,
# so the agent cannot alter the grader's operations (E7, item 7).
GIT_HARDENING = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                 "-c", "core.autocrlf=false", "-c", "protocol.ext.allow=never"]


def _git_env() -> dict:
    env = dict(os.environ)
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
               GIT_CONFIG_SYSTEM="/dev/null", GIT_TERMINAL_PROMPT="0")
    return env


def git_run(wd: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *GIT_HARDENING, "-C", wd, *args],
                          capture_output=True, text=True, env=_git_env())


def git(wd: str, *args: str, check: bool = True) -> str:
    res = git_run(wd, *args)
    if check and res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {res.stderr.strip()}")
    return res.stdout


def changed_paths(wd: str, baseline: str, paths: list[str] | None = None) -> list[str]:
    """Files that differ from the base commit (modified, deleted, or new and not ignored)."""
    spec = ["--", *paths] if paths else []
    out = git(wd, "diff", "--name-only", baseline, *spec).splitlines()
    out += git(wd, "ls-files", "--others", "--exclude-standard", *spec).splitlines()
    return sorted(set(p for p in out if p))


def baseline_files(ctx, paths: list[str]) -> set[str]:
    return set(git(ctx["wd"], "ls-tree", "-r", "--name-only", ctx["baseline"], "--", *paths).splitlines())


# --------------------------------------------------------------------------- clean environment
def default_deps_env(repo: dict) -> str:
    """Same path as deps_env_dir in lib/common.sh."""
    cache = os.environ.get("EVAL_CACHE") or os.path.join(EVAL_DIR, ".cache")
    req = os.path.join(EVAL_DIR, "repos", repo["name"], "requirements.txt")
    if os.path.exists(req):
        with open(req, "rb") as f:
            key = hashlib.sha256(f.read()).hexdigest()[:8]
    else:
        key = "lock"
    return os.path.join(cache, "envs", f"{repo['name']}-{repo['commit'][:12]}-{key}")


def prepare_deps(ctx) -> dict:
    """Checks the clean environment and, for Node, replaces the workdir node_modules with a copy of it."""
    env_dir, repo, wd = ctx["deps_env"], ctx["repo"], ctx["wd"]
    if not os.path.isfile(os.path.join(env_dir, ".complete")):
        raise RuntimeError(f"clean dependency environment missing: {env_dir} (run the task setup.sh)")
    info = {"deps_env": env_dir}
    if repo["kind"] == "python":
        py = os.path.join(env_dir, ".venv", "bin", "python")
        if not os.path.exists(py):
            raise RuntimeError(f"python missing from the clean environment: {py}")
        ctx["python"] = py
    elif repo["kind"] == "node":
        src, dst = os.path.join(env_dir, "node_modules"), os.path.join(wd, "node_modules")
        if os.path.islink(dst) or os.path.isfile(dst):
            os.unlink(dst)
        elif os.path.isdir(dst):
            shutil.rmtree(dst)
        subprocess.run(["cp", "-a", src, dst], check=True)
        info["node_modules"] = "replaced by a copy from the clean environment"
    return info


def clean_env(ctx) -> dict:
    """Minimal process environment for the tests: no PYTEST_*, NODE_OPTIONS, PYTHON*..."""
    env = {k: os.environ[k] for k in ("TZ", "LANG", "LC_ALL") if k in os.environ}
    dirs = []
    for exe in ("node", "git"):
        w = shutil.which(exe)
        if w:
            dirs.append(os.path.dirname(w))
    env["PATH"] = ":".join(dict.fromkeys(dirs + ["/usr/local/bin", "/usr/bin", "/bin"]))
    env["HOME"] = ctx["home"]
    env["CI"] = "true"
    env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    return env


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


def run_tests(ctx, files: list[str], timeout: int = TEST_TIMEOUT_S) -> TestRun:
    repo, wd, logf = ctx["repo"], ctx["wd"], ctx["logf"]
    tr = TestRun()
    if not files:
        tr.output_tail = "no test files"
        return tr
    tmp = tempfile.mkdtemp(prefix="evalcheck-", dir=ctx["tmp"])
    env = clean_env(ctx)
    t0 = time.time()
    try:
        if repo["kind"] == "python":
            junit = os.path.join(tmp, "junit.xml")
            ini = os.path.join(tmp, "pytest.ini")
            with open(ini, "w") as f:
                f.write("[pytest]\n")
            # -I: no cwd/PYTHON*/user site on sys.path; -c: ignores the repo's pytest.toml, .pytest.ini,
            # pyproject, setup.cfg and tox.ini; --noconftest: ignores conftest.py (the
            # pinned upstream has none).
            cmd = [ctx["python"], "-I", "-B", "-m", "pytest", "-q", "-c", ini, "--rootdir", wd,
                   "--noconftest", "-p", "no:cacheprovider", f"--junitxml={junit}", *files]
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
            # explicit --config: the package.json "jest" key and any jest.config.* are ignored.
            config = json.dumps({**repo.get("jest_config", {}), "rootDir": wd})
            cmd = [os.path.join(wd, "node_modules/.bin/jest"), "--config", config, "--ci", "--silent",
                   "--coverage=false", "--cacheDirectory", ctx["jest_cache"], "--json",
                   f"--outputFile={jout}", "--runTestsByPath", *files]
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
            raise RuntimeError(f"unknown kind: {repo['kind']}")
        tr.output_tail = out[-3000:]
    finally:
        tr.seconds = time.time() - t0
        shutil.rmtree(tmp, ignore_errors=True)
    return tr


def test_files_in(repo: dict, paths) -> list[str]:
    rx = re.compile(repo["test_file_regex"])
    return sorted(p for p in paths if rx.search(p) and any(
        p == r or p.startswith(r.rstrip("/") + "/") for r in repo["test_roots"]))


def restore_test_roots(ctx) -> list[str]:
    """Restores from the base commit every versioned file under test_roots that the agent changed
    or deleted (tests, __init__.py, helpers such as test/test_util.ts). New files stay."""
    wd, base = ctx["wd"], ctx["baseline"]
    roots = ctx["repo"]["test_roots"]
    in_base = baseline_files(ctx, roots)
    touched = [p for p in changed_paths(wd, base, roots) if p in in_base]
    if touched:
        git(wd, "checkout", base, "--", *touched)
    return touched


# --------------------------------------------------------------------------- checks
def check_hidden_tests(ctx, spec) -> dict:
    wd, task_dir = ctx["wd"], ctx["task_dir"]
    restored = restore_test_roots(ctx)
    placed = []
    try:
        for src, dst in spec["files"].items():
            dst_abs = os.path.join(wd, dst)
            if os.path.lexists(dst_abs):
                # The agent created a file with the same name: keep it aside and restore it afterwards.
                shutil.move(dst_abs, dst_abs + ".agent-orig")
            os.makedirs(os.path.dirname(dst_abs), exist_ok=True)
            shutil.copyfile(os.path.join(task_dir, src), dst_abs)
            placed.append(dst_abs)
        tr = run_tests(ctx, list(spec["files"].values()))
    finally:
        for p in placed:
            os.remove(p)
            if os.path.lexists(p + ".agent-orig"):
                shutil.move(p + ".agent-orig", p)
    return {"pass": tr.ok, "tests": tr.summary(), "test_files_restored": restored,
            "detail": f"{tr.total - tr.failed - tr.errors}/{tr.total} hidden tests passed"}


def check_baseline_tests(ctx, spec) -> dict:
    files = test_files_in(ctx["repo"], baseline_files(ctx, ctx["repo"]["test_roots"]))
    restored = restore_test_roots(ctx)
    tr = run_tests(ctx, files)
    detail = f"{tr.total - tr.failed - tr.errors}/{tr.total} original-suite tests passed"
    if restored:
        detail += f"; {len(restored)} test file(s) changed by the agent were restored"
    return {"pass": tr.ok, "tests": tr.summary(), "tests_modified_by_agent": restored, "detail": detail}


def check_unchanged(ctx, spec) -> dict:
    changed = changed_paths(ctx["wd"], ctx["baseline"], spec["paths"])
    return {"pass": not changed, "changed": changed[:50],
            "detail": "no changes" if not changed else f"{len(changed)} file(s) changed"}


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


OPTION_RX = (r"(?im)^\s*(?:#{1,6}\s*|[-*]\s+|\d+[.)]\s+)?(?:\*\*)?"
             r"(?:op[çc][ãa]o|option|abordagem|approach|alternativa|alternative)\b")


def check_report(ctx, spec) -> dict:
    names = spec["file"] if isinstance(spec["file"], list) else [spec["file"]]
    found = find_report(ctx["wd"], names)
    if not found:
        return {"pass": False, "detail": f"report missing ({' / '.join(names)})"}
    with open(os.path.join(ctx["wd"], found), errors="replace") as f:
        text = f.read()
    words = len(text.split())
    hits = keyword_hits(text, spec.get("keyword_groups", []))
    questions = sum(1 for line in text.splitlines() if "?" in line)
    options = len(re.findall(spec.get("option_regex", OPTION_RX), text))
    ok = (words >= spec.get("min_words", 0) and all(hits)
          and questions >= spec.get("min_questions", 0) and options >= spec.get("min_options", 0))
    ctx["reports"][found] = text
    detail = f"{found}: {words} words; keyword groups {sum(hits)}/{len(hits)}"
    if "min_questions" in spec or "min_options" in spec:
        detail += (f"; {questions} lines with a question (min. {spec.get('min_questions', 0)}); "
                   f"{options} options (min. {spec.get('min_options', 0)})")
    return {"pass": ok, "file": found, "words": words, "keyword_groups_hit": hits,
            "questions": questions, "options": options, "detail": detail}


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
    return {"pass": None,
            "detail": f"awaiting grade (automatic hint {sum(hits)}/{len(spec.get('hints', []))})"}


def check_mutation(ctx, spec) -> dict:
    """Only NEW test files count (absent from the base commit): editing a test that already
    exists, and may already exercise the module, does not inflate the score (I7). Versioned files
    under test_roots go back to the base commit before running (helpers included)."""
    wd, base, repo = ctx["wd"], ctx["baseline"], ctx["repo"]
    module = spec["module"]
    exclude = set(spec.get("exclude_tests", []))
    in_base = baseline_files(ctx, repo["test_roots"])
    changed_tests = test_files_in(repo, changed_paths(wd, base))
    agent_tests = [p for p in changed_tests if p not in in_base and p not in exclude
                   and os.path.exists(os.path.join(wd, p))]
    if spec.get("test_paths"):
        agent_tests = [p for p in agent_tests if p in spec["test_paths"]]
    ignored = [p for p in changed_tests if p in in_base]
    res = {"module": module, "agent_test_files": agent_tests, "ignored_existing_test_files": ignored}
    if not agent_tests:
        return {**res, "pass": False, "detail": "no new test file"}
    notes = []
    restored = restore_test_roots(ctx)
    if restored:
        notes.append(f"{len(restored)} versioned file(s) under the tests restored before mutation")
    if changed_paths(wd, base, [module]):
        git(wd, "checkout", base, "--", module)
        notes.append("module changed by the agent was restored before mutation")
    clean = run_tests(ctx, agent_tests)
    res["clean_run"] = clean.summary()
    if not clean.ok or clean.total < spec.get("min_tests", 1):
        return {**res, "pass": False, "notes": notes,
                "detail": f"agent tests do not pass on the original code ({clean.total} tests, "
                          f"{clean.failed} failures, {clean.errors} errors)"}
    mutants = sorted(glob.glob(os.path.join(ctx["task_dir"], spec.get("mutants", "mutants/*.patch"))))
    killed, rows = 0, []
    for m in mutants:
        name = os.path.basename(m)
        ap = git_run(wd, "apply", m)
        if ap.returncode != 0:
            rows.append({"mutant": name, "killed": None, "error": ap.stderr.strip()[:200]})
            continue
        try:
            tr = run_tests(ctx, agent_tests, timeout=spec.get("mutant_timeout_s", 180))
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
            "detail": f"{killed}/{len(valid)} mutants killed ({score:.0%}; minimum {spec.get('min_score', 0.6):.0%}); "
                      f"{clean.total} tests in {len(agent_tests)} new file(s)"}


# --------------------------------------------------------------------------- skills (K1-K3)
SKILL_PATH_RX = re.compile(r"([^\s\"'`]*?)([A-Za-z0-9][A-Za-z0-9._-]*)/SKILL\.md")
ARG_KEYS = ("input", "arguments", "args", "parameters")


def _looks_like_schema(args) -> bool:
    return isinstance(args, dict) and ("properties" in args or args.get("type") == "object")


def iter_tool_calls(obj):
    """Tool calls in any of the harnesses' events.jsonl formats, without looking at
    results: Claude/Qwen (tool_use: name+input), Pi (toolCall: name+arguments),
    OpenCode (part.tool + part.state.input), Codex (command_execution.command)."""
    if isinstance(obj, dict):
        name = obj.get("name") or obj.get("tool") or obj.get("toolName")
        args = None
        for k in ARG_KEYS:
            if k in obj:
                args = obj[k]
                break
        if args is None and isinstance(obj.get("state"), dict) and "input" in obj["state"]:
            args = obj["state"]["input"]
        if args is None and obj.get("type") == "command_execution" and "command" in obj:
            name, args = name or "exec_command", obj["command"]
        if isinstance(name, str) and args is not None and not _looks_like_schema(args):
            yield name, args
        for k, v in obj.items():
            if k in ARG_KEYS or k == "state":
                continue  # arguments do not contain calls
            yield from iter_tool_calls(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from iter_tool_calls(v)


def _skill_tool_names(args) -> list[str]:
    vals = []
    if isinstance(args, str):
        vals.append(args)
    elif isinstance(args, dict):
        for k in ("skill", "name", "command", "skill_name", "skillName"):
            if isinstance(args.get(k), str):
                vals.append(args[k])
    out = []
    for v in vals:
        v = v.strip().lstrip("/").split()[0] if v.strip() else ""
        v = v.split(":")[-1]
        if v:
            out.append(v)
    return out


def scan_skill_usage(paths: list[str], skills_dirs: list[str]) -> dict:
    """Skills loaded according to the transcript: (a) a read of <skill>/SKILL.md in the argument of
    any tool (read, cat, sed...), or (b) a call to a tool whose name contains "skill" with
    the skill name in the argument. Tool results do not count (a `find -name SKILL.md`
    would list them all)."""
    skills: dict[str, list] = {}
    n_events = n_calls = 0
    for path in paths:
        with open(path, errors="replace") as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                n_events += 1
                for name, args in iter_tool_calls(event):
                    n_calls += 1
                    text = args if isinstance(args, str) else json.dumps(args, ensure_ascii=False)
                    for m in SKILL_PATH_RX.finditer(text):
                        full = m.group(1) + m.group(2) + "/SKILL.md"
                        under = any(full.startswith(d.rstrip("/") + "/") for d in skills_dirs) if skills_dirs else None
                        skills.setdefault(m.group(2), []).append(
                            {"via": "read_path", "tool": name, "path": full, "under_skills_dirs": under,
                             "file": os.path.basename(path), "line": lineno})
                    if re.search(r"(?i)skill", name):
                        for s in _skill_tool_names(args):
                            skills.setdefault(s, []).append(
                                {"via": "skill_tool", "tool": name, "arg": text[:120],
                                 "file": os.path.basename(path), "line": lineno})
    return {"skills": skills, "events": n_events, "tool_calls": n_calls}


def check_skill_usage(ctx, spec) -> dict:
    skill = spec["skill"]
    logs = ctx["agent_logs"]
    if not logs or not os.path.isdir(logs):
        return {"pass": False, "loaded": None, "detail": "no agent log directory"}
    files = [os.path.join(logs, f) for f in spec.get("transcript_files", ["events.jsonl"])
             if os.path.isfile(os.path.join(logs, f))]
    if not files:
        return {"pass": False, "loaded": None,
                "detail": f"transcript missing ({', '.join(spec.get('transcript_files', ['events.jsonl']))})"}
    usage = scan_skill_usage(files, ctx["skills_dirs"])
    loaded = skill in usage["skills"]
    ev = usage["skills"].get(skill, [])
    return {"pass": loaded, "loaded": loaded, "skill": skill,
            "skills_loaded": sorted(usage["skills"]), "evidence": ev[:5],
            "events": usage["events"], "tool_calls_seen": usage["tool_calls"],
            "detail": (f"skill {skill} loaded ({ev[0]['via']}, {ev[0]['tool']})" if loaded
                       else f"skill {skill} not loaded; loaded: {sorted(usage['skills']) or 'none'}"
                            f" ({usage['tool_calls']} calls in {usage['events']} events)")}


def check_plan_format(ctx, spec) -> dict:
    """Finds, among the new or changed .md files, the one that best matches the format markers."""
    wd = ctx["wd"]
    cands = [p for p in changed_paths(wd, ctx["baseline"])
             if p.lower().endswith(".md") and os.path.isfile(os.path.join(wd, p))]
    best = None
    for p in cands:
        with open(os.path.join(wd, p), errors="replace") as f:
            text = f.read()
        counts = {m["name"]: len(re.findall(m["regex"], text)) for m in spec["markers"]}
        met = {m["name"]: counts[m["name"]] >= m.get("min", 1) for m in spec["markers"]}
        extra = {m["name"]: len(re.findall(m["regex"], text)) for m in spec.get("optional_markers", [])}
        row = {"file": p, "markers": counts, "met": met, "optional": extra,
               "path_matches_convention": bool(re.search(spec.get("path_regex", r"$^"), p))}
        if best is None or sum(met.values()) > sum(best["met"].values()):
            best = row
    if best is None:
        return {"pass": False, "candidates": [], "detail": "no new or changed .md file"}
    ok = all(best["met"].values())
    missing = [k for k, v in best["met"].items() if not v]
    return {"pass": ok, **best, "candidates": cands[:20],
            "detail": f"{best['file']}: markers {sum(best['met'].values())}/{len(best['met'])}"
                      + (f" (missing: {', '.join(missing)})" if missing else "")
                      + f"; conventional path: {'yes' if best['path_matches_convention'] else 'no'}"}


def _match(path: str, pat: str) -> bool:
    if fnmatch.fnmatch(path, pat):
        return True
    return pat.startswith("**/") and fnmatch.fnmatch(path, pat[3:])


def restore_protected_config(ctx) -> list[str]:
    """Restores from the base commit (or deletes, if new) the test runner configuration files
    matching repo.json:protected_config (fnmatch patterns; "**/" = any directory).
    New files hidden by .gitignore do not show up here: against them, the explicit
    command-line options apply (pytest -c/--noconftest, jest --config)."""
    wd, base = ctx["wd"], ctx["baseline"]
    pats = ctx["repo"].get("protected_config", [])
    deps_dirs = ("node_modules/", ".venv/")  # replaced/ignored by prepare_deps; leave them alone here
    changed = [p for p in changed_paths(wd, base)
               if not p.startswith(deps_dirs) and any(_match(p, x) for x in pats)]
    in_base = baseline_files(ctx, changed) if changed else set()
    for p in changed:
        if p in in_base:
            git(wd, "checkout", base, "--", p)
        elif os.path.lexists(os.path.join(wd, p)):
            os.remove(os.path.join(wd, p))
    return changed


CHECKS = {
    "hidden_tests": check_hidden_tests, "baseline_tests": check_baseline_tests,
    "unchanged": check_unchanged, "report": check_report, "rubric": check_rubric,
    "mutation": check_mutation, "skill_usage": check_skill_usage, "plan_format": check_plan_format,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("task_dir")
    ap.add_argument("workdir")
    ap.add_argument("--baseline")
    ap.add_argument("--out")
    ap.add_argument("--log")
    ap.add_argument("--deps-env", help="clean dependency environment (default: computed from repo.json)")
    ap.add_argument("--agent-logs", help="directory with the agent transcript (events.jsonl)")
    ap.add_argument("--skills-dirs", default=None,
                    help="skill directories seen by the agent, separated by ':' (default: $AGENT_SKILLS_DIRS)")
    a = ap.parse_args()

    task_dir, wd = os.path.abspath(a.task_dir), os.path.abspath(a.workdir)
    with open(os.path.join(task_dir, "task.json")) as f:
        task = json.load(f)
    with open(os.path.join(EVAL_DIR, "repos", task["repo"], "repo.json")) as f:
        repo = json.load(f)
    baseline = a.baseline or git(wd, "rev-list", "--max-parents=0", "HEAD").split()[-1]
    logf = open(a.log, "a") if a.log else None
    skills_dirs = a.skills_dirs if a.skills_dirs is not None else os.environ.get("AGENT_SKILLS_DIRS", "")

    tmp = tempfile.mkdtemp(prefix="evalcheck-run-")
    os.makedirs(os.path.join(tmp, "home"))
    ctx = {"wd": wd, "task_dir": task_dir, "repo": repo, "baseline": baseline, "logf": logf,
           "reports": {}, "rubric": None, "tmp": tmp, "home": os.path.join(tmp, "home"),
           "jest_cache": os.path.join(tmp, "jest-cache"),
           "deps_env": os.path.abspath(a.deps_env) if a.deps_env else default_deps_env(repo),
           "agent_logs": os.path.abspath(a.agent_logs) if a.agent_logs else None,
           "skills_dirs": [d for d in skills_dirs.split(":") if d]}
    t0 = time.time()
    results, restored, deps, setup_error = [], [], {}, None
    try:
        try:
            restored = restore_protected_config(ctx)
            if restored:
                log(f"{task['id']}: test configuration restored from the base commit: {', '.join(restored)}")
            if any(c["type"] in ("hidden_tests", "baseline_tests", "mutation") for c in task["checks"]):
                deps = prepare_deps(ctx)
        except Exception as e:  # noqa: BLE001 - without a trusted environment, nothing runs
            setup_error = f"{e!r}"
            log(f"{task['id']}: ERROR preparing the checks: {setup_error}")
        for spec in ([] if setup_error else task["checks"]):
            name = spec.get("name", spec["type"])
            log(f"{task['id']}: {name} ...")
            try:
                r = CHECKS[spec["type"]](ctx, spec)
            except Exception as e:  # noqa: BLE001 - record and move on
                r = {"pass": False, "detail": f"check error: {e!r}", "infra_error": True}
            required = spec.get("required", spec["type"] != "rubric")
            r = {"name": name, "type": spec["type"], "required": required, **r}
            results.append(r)
            log(f"{task['id']}: {name}: {'ok' if r['pass'] else ('pending' if r['pass'] is None else 'FAILED')}"
                f" - {r.get('detail', '')}")
    finally:
        if logf:
            logf.close()
        shutil.rmtree(tmp, ignore_errors=True)

    failed = [r for r in results if r["required"] and r["pass"] is False]
    infra = [r for r in results if r.get("infra_error")]
    if setup_error:
        status, passed = "error", None
    elif failed:
        status, passed = "fail", False
    elif ctx["rubric"] is not None:
        status, passed = "pending_grading", None
    else:
        status, passed = "pass", True
    out = {"task_id": task["id"], "pass": passed, "status": status, "checks": results,
           "rubric": ctx["rubric"], "baseline": baseline, "infra_errors": len(infra) + bool(setup_error),
           "setup_error": setup_error, "protected_config_restored": restored, **deps,
           "seconds": round(time.time() - t0, 1)}
    if a.out:
        with open(a.out, "w") as f:
            json.dump(out, f, indent=2, ensure_ascii=False)
    print(json.dumps({"task_id": task["id"], "status": status,
                      "checks": {r["name"]: r["pass"] for r in results}}, ensure_ascii=False))
    if setup_error or (infra and not failed):
        return 2
    return {"pass": 0, "fail": 1, "pending_grading": 3}[status]


if __name__ == "__main__":
    sys.exit(main())
