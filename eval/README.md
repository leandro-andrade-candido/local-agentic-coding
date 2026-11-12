# Validation suite (`eval/`)

Measures, without human intervention, whether an agent (Qwen Code, Pi, OpenCode, Claude Code pointed at the local model...) solves real programming tasks. It covers tasks T1–T7 from section 9 of the [plan](../DIAGNOSIS-AND-PLAN.md) (stage E8). For the comparative agent test (stage E6), it also has 3 short tasks (S1–S3) and 3 skill checks (K1–K3).

The suite does not depend on any specific harness. Each run follows the same steps:

1. creates a fresh workdir from a pinned commit of a public repository;
2. hands the prompt to the harness and waits for it to finish, with a time limit;
3. runs hidden checks, which the agent never sees;
4. writes `result.json` with success, timings, tokens and RAM/VRAM peak.

Everything is bash + Python stdlib. The repositories' dependencies live only inside the workdirs (`.venv` with uv, local `node_modules`). Nothing is installed globally.

## Language

- The suite, the prompts (`task.md`), the rubrics and the reference solutions are in English.
- **T3 stays in Portuguese on purpose.** It tests Portuguese relative-date parsing in chrono's `pt` locale ("há 3 dias", "daqui a 2 semanas"), so its prompt and data are test data. Nothing in `tasks/T3-chrono-pt-relative/` was translated, including its check names (`testes_aceitacao`, `suite_original`); the grader and `summarize.py` do not depend on check names.
- The prompts of T1, T2, T4–T7, S1–S3 and K1–K3 were translated from Portuguese on 2026-11-12, before any E6/E8 run used them, so no recorded result depends on the old wording.
- The report files are now English and requested in English: T1 asks for `ARCHITECTURE.md` (was `ARQUITETURA.md`), T5 for `INVESTIGATION.md` (was `INVESTIGACAO.md`) and T6 for `PLAN.md` (was `PLANO.md`). The checks accept only the English names (plus lowercase). The reference answers were translated: T1 `solution/ARCHITECTURE.md`, and the new-file hunks for `INVESTIGATION.md`/`PLAN.md` in the T5/T6 `solution.patch` (the hunks touching upstream code are byte-identical).
- The check names in `task.json` were translated to English snake_case (for example `testes_ocultos` → `hidden_tests`, `suite_original` → `original_suite`, `gabarito` → `rubric`, `formato_do_plano` → `plan_format`, and the K3 marker names). Only T3 keeps its Portuguese names.
- Some keyword lists (T6 hints, the report option regex, the K3 markers) still accept both Portuguese and English words.

## Repositories used

| | Python | TypeScript |
|---|---|---|
| Project | [pypika](https://github.com/kayak/pypika): SQL builder | [chrono](https://github.com/wanasit/chrono) (`chrono-node`): natural-language dates |
| Pinned commit | `443e10f3c7b4c40afbed98216be63146c4fc4a1b` (2026-10-27, 0.51.1+) | `d4fe7e39015c818b271d74789fb96f74777421d0` (tag v2.10.3, 2026-10-12) |
| License | Apache-2.0 | MIT |
| Size | ~6.5k lines of code + ~10k of tests | ~18k lines of code + ~25k of tests, 267 files in `src/` |
| Suite | 1361 tests in **~1 s** (pytest) | 753 tests in **~8 s** (jest + ts-jest, 16 cores) |
| Dependencies | none at runtime; tests: pytest, parameterized | none at runtime; 133 MB of devDependencies |

Why these two:

- **Medium size and an architecture with real layers.** pypika has immutable builders (`@builder`), a `Term` tree and dialects. chrono has a pipeline of parsers and refiners and 16 languages. Both suit planted bugs, new features and architecture explanations.
- **Fast, offline suites.** The suites run in seconds. That allows running the full suite on every check and testing mutants (T4) in under 30 s. After the first download (~40 MB of cache), everything works without network.
- **Less contamination.** They are known projects, but far from the most famous ones (about 2.6k and 5k stars). The pinned commits are from October 2026. T3 and T6 ask for features that **do not exist upstream** (Portuguese relative expressions and `CREATE VIEW`), so there is no solution for the model to remember.
- **Permissive licenses** and few dependencies.

Setup deletes the upstream `AGENTS.md`/`CLAUDE.md`/`QWEN.md`/`GEMINI.md` from the workdirs. chrono ships an `AGENTS.md` with an architecture summary, which would make T1 trivial and give different information to harnesses that read different files.

## Tasks

| Id | Repo | Task | Hidden check | Max time |
|---|---|---|---|---|
| T1 | chrono | Explain the architecture in `ARCHITECTURE.md`. | Document exists (≥ 300 words), code intact and **grade ≥ 7/10** on `rubric.md`, given afterwards. | 30 min |
| T2 | pypika | User report: joins leak between queries derived from the same base. Planted bug: `__copy__` stopped copying `_joins`. | 6 hidden tests and the whole original suite. | 30 min |
| T3 | chrono | New feature: "há 3 dias", "daqui a 2 semanas" etc. in the `pt` locale (constants + 2 parsers + registration). Prompt in Portuguese (see "Language"). | 4 acceptance tests (25 expressions compared with the English equivalent, strict mode, sentences, negative cases) and the original suite. | 30 min |
| T4 | chrono | Write tests for `src/calculation/duration.ts`, whose test was removed. | The agent's tests pass and kill **≥ 60%** of 12 mutants; module intact; original suite. | 30 min |
| T5 | chrono | Two tests fail although nobody touched them, and one passes when run alone. Planted cause: a cache in `parseDuration` returns the same object, which `addDuration` mutates. | Whole original suite with the tests restored, 3 hidden repeatability tests, `INVESTIGATION.md` citing `parseDuration` and `addDuration`, and **grade 2/2** for the root cause on `rubric.md`, given afterwards. | 30 min |
| T6 | pypika | Plan in `PLAN.md` and then implement `CREATE VIEW` (OR REPLACE, TEMPORARY, IF NOT EXISTS, columns, schema, MySQL, materialized on PostgreSQL). | 21 hidden tests, original suite and **grade ≥ 7/10** for the plan on `rubric.md`. | 45 min |
| T7 | pypika | Review the user's uncommitted diff (`paginate()` + a "simplification" that made `LIMIT 0` disappear) and fix it. | 10 hidden tests (regression fixed and feature kept) and the original suite. | 30 min |
| S1 | pypika | Smoke: `a - (b + c)` loses the parentheses. | 3 hidden tests and the original suite. | 15 min |
| S2 | chrono | Smoke: centralize the duplicated `YEAR_PATTERN`/`parseYear` of `pt` and `es` in `src/calculation/years.ts` (3 files). | 3 hidden tests (behavior, copies removed, parsers) and the original suite. | 15 min |
| S3 | pypika | Smoke: write tests for 3 functions in `pypika/utils.py`. | Tests pass and kill ≥ 60% of 6 mutants; module intact. | 15 min |
| K1 | pypika | Skills, explicit call: "use the `brainstorming` skill" for a vague idea, without interaction; questions and options in `BRAINSTORM.md`, no code. | Transcript shows the skill loaded; ≥ 3 questions and ≥ 2 options; no file under `pypika/` changed. | 15 min |
| K2 | pypika | Skills, automatic triggering: BETWEEN tests failing (bug planted in the `Field[a:b]` slice); the prompt does not mention skills. | Fix: hidden tests and suite. **Measurement** (does not fail the task): was `systematic-debugging` loaded? | 15 min |
| K3 | pypika | Skills, effect on the format: "use the `writing-plans` skill" to plan `TRUNCATE TABLE`, without implementing it. | Transcript shows the skill loaded; plan in the skill format (markers); no file under `pypika/` changed. | 15 min |

When a visible upstream test would catch the planted bug (T2, T7, S1), it is **removed from the visible suite** and becomes part of the hidden tests. The agent has to find the problem from the report or the review, not from a red test. The exception is T5, where the red tests are the task statement itself (and K2, where they trigger the debugging).

In T6, `.columns()` may accumulate or replace: the specification does not say, and the hidden immutability test starts from a base without columns, which works for both readings and still catches a list shared between `@builder` copies.

The prompts (`task.md`) are written in the tone of a real request and do not mention the hidden tests. The Python ones say how to run the tests (`.venv/bin/python -m pytest`); the TypeScript ones, `npx jest`.

## How to run

Prerequisites already on the machine: `git`, `uv`, `node`/`npm`, `python3` (3.12), `timeout` and `flock` (coreutils/util-linux). The first setup of each repository downloads the commit and the dependencies into `eval/.cache/`; after that it does not use the network (`EVAL_OFFLINE=1` enforces this).

```bash
# one task with one harness (harness = agents/<name>/run.sh or eval/harnesses/<name>/run.sh)
eval/run.sh qwen-code T2 batch1

# serial matrix: 3 repetitions, two harnesses, T1-T7 (or: smoke, skills, all, or a list T2,T5,S1)
eval/matrix.sh -r 3 e8-qwen36 qwen-code,pi full

# aggregate table (default: every run in eval/runs)
python3 -I eval/summarize.py eval/runs/e8-qwen36

# rubric grade (T1, T5, T6)
python3 -I eval/grade.py eval/runs/e8-qwen36/r1/qwen-code/T1/result.json --score 8 --by NAME --notes "..."

# validation of the suite itself, without an LLM (fails before / passes with the reference solution)
eval/validate.sh            # all; or: eval/validate.sh T2 S1

# end to end without an LLM, with the fake harness that applies the reference solution
eval/matrix.sh -r 1 runner-test fake-oracle all
```

Manual use of a task: `eval/tasks/T2-*/setup.sh /tmp/wd` creates the workdir; the prompt is `task.md`; `eval/tasks/T2-*/check.sh /tmp/wd` runs the checks. `check.sh` exits with 0 (passed), 1 (failed), 3 (awaiting grade) or 2 (error).

**Never run two executions in parallel.** There is one GPU and one model. `run.sh` uses a lock (`eval/.cache/run.lock`): a second call waits for the first to finish. The matrix already runs serially, in the order repetition -> task -> harness, so the harnesses alternate.

### Environment variables

| Variable | Default | Effect |
|---|---|---|
| `LLM_BASE_URL` | `http://127.0.0.1:9931` | Passed to the harness; also used to read `/metrics`. |
| `LLM_MODEL` | `qwen3.6-35b` | Passed to the harness. |
| `LLM_API_KEY` | read from the file below | llama-server key (E5: required on every route, `/metrics` included). Exported to the harness (`run-in-box.sh` passes `LLM_*` on) and used for `/metrics`. Never printed; `result.json` only records the source (`env`, `file` or `none`). |
| `LLM_API_KEY_FILE` | `~/.config/local-agentic/llm-api-key` | File from `scripts/llm key`, read when `LLM_API_KEY` is empty. Without a key, `run.sh` warns and `result.json` has `llm.available: false` with the reason. |
| `EVAL_TIMEOUT_MIN` | `timeout_min` from `task.json` | Maximum agent time (the task default is 30; T6 45; smoke 15). |
| `EVAL_SAMPLE_INTERVAL` | `3` | Seconds between RAM/VRAM samples. |
| `EVAL_WORK_ROOT` | `~/.cache/local-agentic/eval-work` | Where the workdirs live (outside the repository). |
| `EVAL_CLEANUP` | `deps` | `deps` deletes `.venv`/`node_modules` at the end and keeps the sources; `all` deletes the workdir; `none` keeps everything. |
| `EVAL_FORCE` | `0` | `1` overwrites an existing `result.json`. |
| `EVAL_OFFLINE` | `0` | `1` fails instead of using the network when the cache is cold. |
| `EVAL_WARMUP` | `1` | Short request to the model before measuring, only with real harnesses (E4, M4). `0` disables it. |
| `EVAL_WRAPPER` | empty | `sandbox/run-in-box.sh` runs the agent, the diff capture and the checks in containers (section below). |

### In the container (E7)

With the agents in autonomous mode, always run through the E7 container ([`sandbox/`](../sandbox/README.md)):

```bash
sandbox/build.sh                                   # once, and again when agents/versions.env changes
EVAL_WRAPPER=sandbox/run-in-box.sh eval/run.sh qwen-code S1 batch1
EVAL_WRAPPER=sandbox/run-in-box.sh eval/matrix.sh -r 3 e6 qwen-code,pi smoke
```

With `EVAL_WRAPPER`, `run.sh` uses three fresh containers per run. Setup stays on the host, because no agent has run yet.

| Step | Mounted (nothing else from the host) | Network |
|---|---|---|
| Agent (`agents/<h>/run.sh`) | workdir and log-dir (read-write); `prompt.md`, `agents/` and the base skill profile (read-only) | only the llama-server, through the forwarder |
| Diff capture (`git add -A`/`diff`/`rev-list`) | only the workdir, **read-only** | none |
| Checks (`check.sh`) | workdir (read-write); `eval/lib`, `eval/repos`, the task directory (with `hidden/` and the solution), the clean dependency environment and the already sanitized `agent-logs` (read-only). **The result directory is NOT mounted.** | none |

- **The agent never sees `eval/`** (hidden tests, solutions, rubrics and other runs). The exception is the test harnesses in `eval/harnesses/` (such as `fake-oracle`), which use no LLM and read the solutions by definition; for them, `eval/` is mounted read-only.
- **After the agent, the host executes nothing from the workdir.** The hidden tests import the code the agent wrote, and the host's `git` would run a `core.fsmonitor` or filter planted in the workdir's `.git/config`. That is why the diff capture and the checks also run in containers, created after the agent container has been removed.
- **The diff capture mounts the workdir read-only and does not mount the result directory**, runs git with the agent's config neutralized (`core.fsmonitor=false`, `core.hooksPath=/dev/null`, `--no-ext-diff --no-textconv`, system/global config ignored; objects and index in a container tmpfs) and returns the diff on stdout. So agent code that runs in this step neither sees nor writes any host path.
- **The checks also run without the result directory mounted** (scoreboard integrity). The hidden tests import the agent's code, which could forge `checks.json`/the verdict if it could write it. So `check.sh` writes to a container tmpfs and returns the result as a tar on stdout; the **host** writes `checks.json`, `check.log` and `check.stdout/stderr` (with `boxio`). The grader (`eval/lib`), the task (with `hidden/` and the solution) and the transcript are mounted read-only, so the agent's code, which runs in the test subprocesses, cannot change the grader. The grader's git also runs with `core.fsmonitor`/hooks off and system/global config ignored.
- **The host never follows the agent's symlinks** (`eval/lib/boxio.py`, fix for item 7 of `docs/verifications/E7.md`): `agent-logs` is copied with regular files only; `$out` is scanned (every symlink deleted) before any read/write; `agent-metrics.json` is read with `O_NOFOLLOW` and a size cap; `checks.json`, `result.json` and `meta.json` are written through a temporary file + `os.replace` (they do not follow a symlink planted in their place).
- The timeout still applies: the `run.sh` `timeout` stops the wrapper, which removes the container.
- The host time zone (`TZ`) is passed to the container, because chrono's tests depend on it.
- `meta.json` records the wrapper in `sandbox`.
- To inspect a workdir after the run, prefer `agent.patch`. To run `git` or tests in it, use `sandbox/agent-shell.sh shell <workdir>`.

## Harness contract

Each harness provides an executable `agents/<harness>/run.sh`:

```
run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
```

- Runs the agent without interaction, automatically approving actions inside the workdir, and returns when the agent stops.
- Writes the transcript and logs to `--log-dir`.
- Exits with 0 if the agent process finished normally.
- Receives `LLM_BASE_URL`, `LLM_MODEL` and `LLM_API_KEY` in the environment.
- Writes the transcript to `<log-dir>/events.jsonl` (the agent's own JSON format). The skill checks (K1–K3) read this file.

The runner executes the harness with `cwd` = workdir, `stdin` = `/dev/null` and `timeout -k 30`. The timeout kills the whole process group: exit 124 or 137 is recorded as `timed_out`.

Optional: if the harness writes `<log-dir>/agent-metrics.json`, its content goes to `result.json` under `agent.metrics`. The suggested keys are `turns`, `tool_calls`, `tool_call_errors`, `loops_detected`, `tokens_in` and `tokens_out` (from the client's point of view, cache included). `summarize.py` sums `tool_call_errors`.

The workdir, the prompt (`<work>/prompt.md`) and the log-dir live outside the repository, in `EVAL_WORK_ROOT`. The logs are copied to `eval/runs/...` at the end.

## Task layout

```
eval/tasks/T2-pypika-join-leak/
  task.md          prompt given to the agent
  task.json        id, repo, category, timeout and list of checks
  setup.sh         setup.sh <workdir>: idempotent, recreates the workdir from scratch
  check.sh         check.sh <workdir> [--out checks.json] [--log check.log] [--baseline SHA]
                   [--deps-env DIR] [--agent-logs DIR] [--skills-dirs D1:D2]
  setup.patch      applied before the base commit: planted bug and/or visible tests removed
  pending.patch    (T7) applied after the base commit, without a commit: the "user's diff"
  hidden/          hidden tests; copied into the workdir only during the checks
  mutants/*.patch  (T4, S3) mutations of the module under test
  solution.patch   reference solution (relative to the state after setup)
  solution/        (T1, K1, K3) reference files copied into the workdir
  oracle/          (K1-K3) simulated transcript (events.jsonl) used by fake-oracle and validate.sh
  rubric.md        (T1, T6: 10 items; T5: 2 items) rubric
```

The tasks live in `eval/tasks/` (T1–T7), `eval/smoke/` (S1–S3) and `eval/skills/` (K1–K3).

To create a new task, copy `lib/task-setup.sh` and `lib/task-check.sh` as `setup.sh`/`check.sh`, write `task.md` and `task.json`, generate the patches with `git diff` in a workdir and check with `eval/validate.sh <task>`. (T3's `setup.sh`/`check.sh` keep the older Portuguese comments; they behave the same.)

The workdir is a git repository with **a single commit** ("Initial import", fixed author and date, always the same hash). It does not carry the upstream history, so the planted bug does not show up in `git log -p`. `.venv/`, `node_modules/` and the like are in `.git/info/exclude`, and `git status` starts clean (in T7, only with the user's diff).

The checks (`lib/check.py`) are declared in `task.json`:

| Type | What it does |
|---|---|
| `hidden_tests` | Copies `hidden/*` into the workdir, runs it with pytest (`--junitxml`) or jest (`--json`) and removes it. |
| `baseline_tests` | Restores the versioned files under the test directories that the agent changed and runs the whole original suite ("nothing else breaks"). |
| `unchanged` | Paths that should not change. |
| `report` | Report at the root: exists, minimum size, keyword groups (at least one from each group) and, optionally, a minimum of lines with a question and of options ("Option A", "Approach"...). |
| `mutation` | Finds the agent's **new** test files (absent from the base commit), confirms they pass on the original code and applies each mutant. The mutant is "killed" if the tests fail. Existing tests that the agent edited do not count, and everything versioned under the test directories goes back to the base commit first. |
| `rubric` | Does not decide by itself: records the rubric and an automatic keyword hint. The status stays `pending_grading` until the grade. |
| `skill_usage` | Reads the agent transcript (`events.jsonl`) and says whether the skill was loaded (section "Skills"). |
| `plan_format` | Among the new or changed `.md` files, finds the one that best matches the format markers (K3) and records whether the path follows the skill's convention. |

### The tests never run with anything the agent may have changed

- **Clean dependencies.** `setup.sh` creates once, before any agent, one environment per repository in `eval/.cache/envs/<repo>-<commit>-<lock>/`, installed from the cache. The checks use the `.venv` from there (Python) or replace the workdir's `node_modules` with a fresh copy from there (Node). The `.venv`/`node_modules` the agent used never runs in the tests.
- **Configuration on the command line.**
  - pytest: `python -I -B -m pytest -c <empty ini> --rootdir <workdir> --noconftest -p no:cacheprovider`, with `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`. So `pytest.toml`, `.pytest.toml`, `pytest.ini`, `.pytest.ini`, `pyproject.toml`, `setup.cfg`, `tox.ini` and any `conftest.py` in the repository are ignored (the pinned upstream has none of them with pytest configuration).
  - jest: `--config '<json from repo.json + rootDir>'`, which ignores the `"jest"` key in `package.json` and any `jest.config.*`, with a fresh `--cacheDirectory`. The `package.json` scripts are never called.
  - The test process gets only `PATH`, a temporary `HOME`, `TZ`, `LANG` and `CI`: no `PYTEST_*`, `PYTHON*` or `NODE_OPTIONS`.
- **Versioned files back to the base commit.**
  - Configuration: `protected_config` patterns in `repos/<repo>/repo.json`, such as `**/conftest.py`, `tsconfig*.json` and `jest.config.*`. New ones are deleted.
  - Test directories: tests, `__init__.py` and helpers such as `test/test_util.ts`.
  - What was restored is recorded in `checks.json`.
- **Limit.** The code under test is the agent's by definition (the hidden tests import its `src/`). An agent that sabotages its own score through the library code, for example by altering `unittest`, is only caught by reading `agent.patch`.

## `result.json`

Written to `eval/runs/<run-id>/<harness>/<task-id>/`, together with:

| File | Content |
|---|---|
| `agent.patch` | The agent's diff, with new files, captured before the checks. |
| `agent-logs/` | Harness logs. |
| `agent.stdout`/`agent.stderr` | Harness output. |
| `setup.log` | Setup output. |
| `checks.json` and `check.log` | Result and full output of the tests. |
| `metrics.before.prom`/`metrics.after.prom` | `/metrics` snapshots. |
| `resources.tsv` | RAM/VRAM series. |

`eval/runs/` and `eval/.cache/` are in `.gitignore`.

```jsonc
{
  "schema_version": 1,
  "run_id": "e8-qwen36/r1", "harness": "qwen-code", "task_id": "T2",
  "task_dir": "eval/tasks/T2-pypika-join-leak", "task_title": "...", "task_category": "bugfix",
  "repo": "pypika", "repo_commit": "443e10f...",
  "status": "pass",            // pass | fail | pending_grading (T1/T5/T6 until graded) | error (setup or environment failed)
  "success": true,             // true / false / null
  "auto_checks_pass": true,    // required automatic checks
  "interventions": 0,          // always 0 in the runner; adjust with grade.py --interventions if there was help
  "started_at": "...", "finished_at": "...",
  "timing": {"setup_s": 0.3, "agent_wall_s": 412.7, "check_s": 1.4, "timeout_s": 1800},
  "agent": {"exit_code": 0, "timed_out": false, "commits_made": 0,
            "diff": {"files_changed": 2, "insertions": 11, "deletions": 0},
            "metrics": {/* the harness agent-metrics.json, if present */}},
  "llm": {"base_url": "...", "model": "...", "api_key_source": "file",   // env | file | none (never the key)
          "available": true, "counter_reset": false,     // without metrics: "available": false, "reason": "HTTP 401: ..."
          "tokens_in": 182345, "tokens_out": 9120, "prefill_seconds": 520.3, "gen_seconds": 260.1,
          "prefill_tps": 350.5, "gen_tps": 35.1, "decode_calls": 9800, "counters_delta": {/* ... */}},
  "resources": {"interval_s": 3, "samples": 140, "ram_total_mib": 52206,
                "ram_used_mib_first": 30100, "ram_used_mib_peak": 33900, "swap_used_mib_peak": 0,
                "vram_available": true, "vram_total_mib": 8151,
                "vram_used_mib_first": 7300, "vram_used_mib_peak": 7700,
                "process": "llama-server", "process_rss_mib_peak": 23000},
  "checks": [{"name": "hidden_tests", "type": "hidden_tests", "required": true, "pass": true,
              "detail": "6/6 hidden tests passed", "tests": {/* total, failed, failing[] ... */}}],
  "rubric": null,              // T1/T5/T6: {"score": null, "threshold": 7, "max": 10, "auto_hint": 8, ...}
  "paths": {"workdir": "...", "baseline_commit": "...", "agent_patch": "agent.patch", ...},
  "env": {"eval_commit": "abc1234", "eval_dirty": false, "hostname": "...", "kernel": "..."}
}
```

### Metrics

- **Tokens and speed:** difference between `GET $LLM_BASE_URL/metrics` before and after the agent, with `Authorization: Bearer $LLM_API_KEY` (the E5 server requires the key on `/metrics` too). `llama-server` must run with `--metrics`. The counters used are `llamacpp:prompt_tokens_total`, `prompt_seconds_total`, `tokens_predicted_total`, `tokens_predicted_seconds_total` and `n_decode_total`.
  - `tokens_in` counts only the prefill actually processed: tokens reused from the prompt cache are not included. So `tokens_in` shows the real cost and `prefill_tps` the real speed.
  - The total sent by the client comes from `agent-metrics.json`, if the harness provides it.
  - **Warm-up (E4, M4).** With a real harness, `run.sh` sends a short request (`max_tokens: 4`) **before** the "before" snapshot, so it stays out of the deltas. Reason: the first requests after loading generate ~10% slower, and the first request after loading, measured on 2026-10-29, took ~75 s. The result goes to `llm.warmup` (`done`, `http_status`, `seconds`, `reason`); a 503 while the model loads is waited out for up to 300 s. `EVAL_WARMUP=0` disables it.
  - Without metrics, the fields are `null`, `available: false` and `reason` gives the reason: server down, 401 without a key or with an invalid key, 404 without `--metrics`. The reason is also in `metrics.*.prom.err`, and `summarize.py` shows a warning with the count per reason. If the server restarts midway, `counter_reset: true` and the deltas are discarded.
- **RAM and VRAM:** `lib/sampler.py` samples every 3 s:
  - used RAM = `MemTotal - MemAvailable` (whole system) and swap;
  - VRAM via `nvidia-smi --query-gpu=memory.used` (read-only);
  - RSS of the `llama-server` process.

  It records the first sample (baseline) and the peak. The numbers are system-wide, so **the machine must stay dedicated during the measurements** (decision 2 of the plan).

## T1, T5 and T6: rubric and grade

- **T1:** `rubric.md` lists 10 verifiable facts about chrono's architecture, written before the runs. A fact is worth 1 point if `ARCHITECTURE.md` states it correctly and with the real names. Invented claims cost points. The reference answer is in `solution/ARCHITECTURE.md`.
- **T5:** the automatic part only checks that `INVESTIGATION.md` exists and cites `parseDuration` (or `parsedDurationCache`) **and** `addDuration`. Loose words ("cache", "immutable", "shared state") are not enough. The root cause is checked by a person against `rubric.md` (2 items, success = 2/2).
- **T6:** `rubric.md` assesses `PLAN.md` on 10 items. The grader also checks in the transcript whether the plan was written **before** the edits in `pypika/`; if not, 2 points are subtracted. The implementation is assessed by the hidden tests.
- **Flow:** the runner writes `status: "pending_grading"`, `rubric.score: null` and `rubric.auto_hint` (0–10). The automatic hint counts items with the expected keyword and is only for triage. The orchestrator and the user read the report, give the grade and record it with `eval/grade.py ... --score N --by NAME`.
- **Success** = required automatic checks passed **and** grade ≥ threshold (7/10 for T1 and T6; 2/2 for T5).
- `summarize.py` lists the runs awaiting a grade and does not count them in the rate until then.

## T4 and S3: mutants

The mutants are small, type-correct patches, each changing one observable behavior:

- **T4:** wrong unit in an abbreviation, quarter factor, fractions, hour sign, `reverseDuration` without reversing etc.;
- **S3:** `all`/`any`, unescaped quotes, `alias_quote_char` precedence etc.

The reference tests (the file removed from upstream, in T4) kill 12/12 and 6/6. A mutant that does not apply (the agent touched the module) is restored and recorded. The target is ≥ 60%, as in the plan.

Only **new** test files count. In T4, the tests in `test/en/*_time_units_*` already go through `addDuration`. If an existing test counted once the agent edited it, even an incidental edit would inflate the score. So they are left out, show up in `ignored_existing_test_files` and go back to the base commit before mutation.

## Skills (K1–K3)

They measure, per harness, whether the skills mounted in `AGENT_SKILLS_DIRS` (base profile `skills/profiles/base.txt`; `/opt/skills/...` in the container) work with the local model:

- **K1, explicit call:** the prompt asks for the `brainstorming` skill. The task passes if the skill was loaded, if `BRAINSTORM.md` has questions and options, and if no code changed.
- **K2, automatic triggering:** a common bug, without mentioning skills. It records whether `systematic-debugging` was loaded; this is a measurement and does not fail the task. Task success is the fix.
- **K3, effect on the format:** the prompt asks for the `writing-plans` skill. The task passes if the skill was loaded and the plan has the format markers. The conventional path (`docs/superpowers/plans/YYYY-MM-DD-*.md` or `docs/plans/`) is only a measurement.

**"Skill loaded"** is decided from the `events.jsonl` in the agent log, looking only at the **arguments** of tool calls, never at the results (a `find -name SKILL.md` would list them all):

1. any tool whose argument contains `.../<skill>/SKILL.md` (read, `cat`, `sed -n`...). It also records whether the path is under the skill directories the agent saw (`--skills-dirs`: `/opt/skills` with `EVAL_WRAPPER`, otherwise `$AGENT_SKILLS_DIRS`);
2. or a tool whose name contains "skill" with the skill name in the argument (accepts `superpowers:<name>` and `/<name>`).

Tool definitions (JSON schema) do not count.

| Harness | `events.jsonl` format (from `agents/lib/agent_metrics.py`) | How the skill should show up | State |
|---|---|---|---|
| claude-local | stream-json: `assistant` → `tool_use` (`name`, `input`) | `Skill` tool (`{"skill": ...}`) or `Read` of `SKILL.md` | unverified |
| qwen-code | stream-json, same as Claude | Qwen's skill tool (name containing "skill") or `read_file` of `SKILL.md` | unverified |
| pi | `message_end` → `toolCall` (`name`, `arguments`) | `read` of `SKILL.md` (Pi lists the skills with their path in the prompt) | unverified |
| opencode | `tool_use` → `part.tool` + `part.state.input` | native `skill` tool (`{"name": ...}`) or `read` | unverified |
| codex-local | `item.*` → `command_execution.command` | shell command that reads `SKILL.md` | unverified |

The `oracle/events.jsonl` files of K1 (Claude format), K2 (Pi) and K3 (OpenCode, `skill` tool) exercise the detection without an LLM. When the agents run for real, check against a real transcript from each one. If an agent loads skills some other way (for example, injecting the text without a tool call), its detection needs another rule.

The K3 format markers (title "Implementation Plan", Goal, `### Task N`, `**Files:**`, `- [ ]` steps, code blocks, test command) follow the Superpowers `writing-plans` as known up to v6. **They were not checked against the `SKILL.md` of the pinned v6.4.1**, which has not been downloaded yet. After `scripts/fetch-skills.sh`, compare and adjust `markers`, `optional_markers` and `path_regex` in K3's `task.json`.

## Validation done (2026-10-29, without an LLM)

`eval/validate.sh`: for each task, (a) right after setup the checks **fail**, and (b) with the reference solution they **pass**. T1, T5 and T6 stay "awaiting grade", with the automatic hint at most. The K tasks use the simulated transcript from `oracle/`. Run on the host, after the I1/I5/I6/I7 + K1–K3 + API key batch, in 4 min 11 s. Output as printed at the time, by the then-Portuguese script (the current script prints the same table in English: `TASK`, `fails (ok)`, `passes (ok)`, `awaiting grade (ok)`, `OK`):

```
TAREFA                           (a) após setup        (b) após solução    RESULTADO
T1-chrono-architecture           falha (ok)             aguarda nota (ok)      OK
T2-pypika-join-leak              falha (ok)             passa (ok)             OK
T3-chrono-pt-relative            falha (ok)             passa (ok)             OK
T4-chrono-duration-tests         falha (ok)             passa (ok)             OK
T5-chrono-flaky-duration         falha (ok)             aguarda nota (ok)      OK
T6-pypika-create-view            falha (ok)             aguarda nota (ok)      OK
T7-pypika-review-pagination      falha (ok)             passa (ok)             OK
S1-pypika-arith-parens           falha (ok)             passa (ok)             OK
S2-chrono-shared-year            falha (ok)             passa (ok)             OK
S3-pypika-utils-tests            falha (ok)             passa (ok)             OK
K1-pypika-brainstorming          falha (ok)             passa (ok)             OK
K2-pypika-debugging              falha (ok)             passa (ok)             OK
K3-pypika-writing-plans          falha (ok)             passa (ok)             OK
```

With the isolated runner (clean environment, `pytest -c/--noconftest`, `jest --config`), the counts are the same as before: pypika 1361 tests, chrono 753 (747 in T4, without the removed file). Mutants: T4 12/12, S3 6/6. Skills: K1 (Claude format, `Read`), K2 (Pi, `read`) and K3 (OpenCode, `skill` tool) detected; before the solution, "not loaded".

End to end with the `fake-oracle` harness:

- `eval/matrix.sh -r 1 e2e2 fake-oracle all`, on the host, without a wrapper, with the E5 llama-server up: 10 pass, 3 awaiting grade (T1, T5, T6), 0 errors, 2 min 21 s.
  - `llm.available: true` in all 13 runs, with `api_key_source: file`.
  - Skills table: 1/1 loaded in K1, K2 and K3.
- Warm-up, checked separately against the server, with the run lock: 200 in ~75 s, the first request after loading. With a wrong key: 401 and `reason` filled in.
- Before this batch (`e2e-oracle`, `e2e-negative`):
  - `FAKE_ORACLE_MODE=noop` gave fail;
  - `sleep:60` with `EVAL_TIMEOUT_S=5` gave exit 124, `timed_out: true` and fail;
  - without a server, `llm.available: false`.

## Known limitations

- **Isolation.** Without `EVAL_WRAPPER`, the agent runs on the host. The workdir is outside the repository and the agent gets no path to `eval/`, but an agent that searches the disk could find `hidden/` and `solution.patch`. With `EVAL_WRAPPER=sandbox/run-in-box.sh` (E7), the agent container mounts only the workdir, the log-dir, the prompt and `agents/`. Output processing on the host does not follow symlinks planted by the agent (see `eval/lib/boxio.py` and the section "In the container"). The checks run without the result directory mounted and the host writes `checks.json` from the grader's verdict (not from a file the agent could plant), so the agent cannot forge its own score or reach the host. Known residue: in the tests the agent writes itself (T4/S3), agent code runs in the same pytest/jest process and could, in theory, forge that process's JUnit/jest report; mitigating that requires isolating the test runner even further.
- **Contamination.** Both projects are public and the models may have seen them. T2, T5 and T7 use planted bugs that do not exist upstream. T3 and T6 ask for nonexistent features. T4 carries the highest risk: the removed test file exists on GitHub.
- **T5:** a correct report that does not cite `parseDuration` or `addDuration` by name fails the automatic part. The root cause itself is always checked by a person.
- **Skills:** detection depends on each agent's transcript format, not yet checked against real runs, and the K3 markers were not checked against v6.4.1 (section "Skills").
- **RAM/VRAM** are system-wide, not just the agent and the server.
- **Time zone.** chrono's tests and the hidden tests use local dates and pass in `America/Sao_Paulo`. The dates were chosen far from daylight saving transitions, but another machine or time zone should run `eval/validate.sh` first.
- **Client tokens** (cache included) and tool call errors depend on the harness writing `agent-metrics.json`. Without it, only the server numbers exist.
