# Agents (harnesses) for the local model

Configuration of the five agents that stage E6 compares, all pointed at the local
llama-server (Qwen3.6-35B-A3B, alias `qwen3.6-35b`, port 9931). Since Oct 29 it is a
single contest on Goal 1 (see section 11 of `DIAGNOSIS-AND-PLAN.md`): Qwen Code,
Codex CLI, Pi and OpenCode (open) and Claude Code (closed, free of charge).
In E6, local Claude Code and local Codex run first. E7 (agent-box) comes before
E6: the autonomous profile only runs inside the container.

Nothing was installed in this stage. Versions, docs and code were checked on
2026-10-29 on npm, on GitHub (tags of the pinned versions), at code.claude.com/docs and at
developers.openai.com/codex.
Labels as in `DIAGNOSIS-AND-PLAN.md`: **[verified]** = checked against the
primary source; **unverified** = depends on a test in E6.

## Comparison

| | Qwen Code | Codex CLI (local) | Pi | OpenCode | Claude Code (local) |
|---|---|---|---|---|---|
| Folder | [`qwen-code/`](qwen-code/README.md) | [`codex-local/`](codex-local/README.md) | [`pi/`](pi/README.md) | [`opencode/`](opencode/README.md) | [`claude-local/`](claude-local/README.md) |
| Pinned version | 0.26.3 (Oct 28) | 0.165.0 (Oct 27) | 1.4.0 (Oct 21) | 1.19.5 (Oct 28); 2.x = `@opencode/cli` 2.2.1, not used | 2.1.308, stable channel (Oct 22) |
| npm package | `@qwen-code/qwen-code` | `@openai/codex` | `@earendil-works/pi-coding-agent` | `opencode-ai` | `@anthropic-ai/claude-code` |
| License | Apache-2.0 | Apache-2.0 | MIT | MIT | Proprietary |
| Default global config | `~/.qwen` | `~/.codex` | `~/.pi/agent` | `~/.config/opencode` + `~/.local/share/opencode` (XDG) | `~/.claude` + `~/.claude.json` |
| Isolation | `QWEN_HOME` | `CODEX_HOME` | `PI_CODING_AGENT_DIR` | `XDG_CONFIG/DATA/CACHE/STATE_HOME` | `CLAUDE_CONFIG_DIR` |
| API used | OpenAI Chat Completions `/v1` | OpenAI Responses `/v1/responses` | OpenAI Chat Completions `/v1` | OpenAI Chat Completions `/v1` (`@ai-sdk/openai-compatible`) | Anthropic `/v1/messages` |
| Sampling from the model card | everything (`samplingParams`) | **none**: Codex sends no temperature/top_p/top_k nor output limit; the server default applies | everything (`samplingParams`) | everything (temperature/top_p per agent; the rest in `options`) | via `CLAUDE_CODE_EXTRA_BODY` (**unverified** whether it beats the client's temperature) |
| `preserve_thinking` | `extra_body` + resend of `reasoning_content` | `reasoning` items resent with `reasoning_text`; server default | `thinkingFormat: qwen-chat-template` | `interleaved.field: reasoning_content` + `options` | `thinking` blocks in the history; server default |
| Max output / window | 32768 / 131072 | no client limit / 131072 (uses 95%) | 32768 / 131072 | 32000 (internal cap) / 131072 | 32000 / 131072 |
| Compacts at | 75% (~98k) | 98304 (`model_auto_compact_token_limit`) | < 32k free (~98k) | context − output (~99k) | ~window − output (**measure**) |
| Native permissions | allow/ask/deny + modes; deny applies in YOLO | approval + sandbox (bwrap/seccomp) + `forbidden` rules | none (our extension) | allow/ask/deny by default; deny applies in `--auto` | allow/ask/deny + modes; deny applies in bypass |
| Common guard (`lib/guard.py`) | `PreToolUse` hook | `PreToolUse` hook (`matcher = "Bash"`) | `tool_call` extension | `tool.execute.before` plugin | `PreToolUse` hook |
| Non-interactive command | `qwen --prompt=… --output-format stream-json --approval-mode yolo` | `codex exec --json --cd … --skip-git-repo-check --profile autonomous --model … --dangerously-bypass-hook-trust …` | `pi --mode json --provider local --model … --no-approve -e guard.ts …` | `opencode run --format json --auto --title … --model llamacpp/…` | `claude -p --output-format stream-json --verbose --tools Bash,Read,Edit,Write --permission-mode bypassPermissions …` |
| Transcript | `events.jsonl` + session in `home/qwen` | `events.jsonl` + session in `home/codex/sessions` | `events.jsonl` + session in `home/pi/sessions` | `events.jsonl` + SQLite in `home/opencode/data` | `events.jsonl` + JSONL in `home/claude/projects` |
| Request bodies | `--openai-logging` | not recorded (use `llama-server --verbose`) | `request-log.ts` extension | not recorded (same) | not recorded (same) |
| Preamble (plan) | to measure | to measure (base instructions ~21 KB + tools) | ~1.4k | ~7.5k | ~25–31k full; lean one to measure |
| Skills: discovery | `skills.directories` | copy in `$CODEX_HOME/skills` | `skills.ts` extension (`resources_discover`) | `skills.paths` | copy in `$CLAUDE_CONFIG_DIR/skills` (+ `Skill` tool) |
| Skills: explicit call | `/<name>` | `$<name>` | `/skill:<name>` | ask for the `skill` tool | `/<name>` |
| Superpowers bootstrap | `SessionStart` hook | `developer_instructions` | `context` event (like the official extension) | `experimental.chat.messages.transform` plugin (like the official 1.x one) | `SessionStart` hook (like the official plugin) |
| Problems with Qwen3.6 | #14203 memory catalog forces full reprocessing (mitigated: memory off); #13415 1M window (mitigated) | built for OpenAI models: no `apply_patch` tool for an unknown ID (edits through the shell in OpenAI's patch format); llama.cpp rejects a `reasoning` item without `content` | none specific; #10741 `developer` role (mitigated) | #24316 `<tool_call>` in the reasoning hangs it (1.x unmaintained; llama.cpp b11982 parser already cuts the reasoning at `<tool_call>`) | no official support; adaptive thinking ignored by llama.cpp |

## Installation (E6)

One pattern for all five, same as llama.cpp: each version in its own prefix,
with a `current` link.

```bash
agents/install.sh qwen-code     # or codex-local | pi | opencode | claude-local | all
# npm install --global --prefix ~/.local/opt/agents/<agent>/<version> <package>@<version>
# ln -sfn <version> ~/.local/opt/agents/<agent>/current
```

- **Nothing runs with the real HOME.** npm (cache, `~/.npmrc`, install scripts) and
  `<agent> --version` run with `env -i`, a temporary HOME and each agent's isolation
  variables pointing at it, as in `sandbox/install-agents.sh` (some agents create files
  in HOME already at `--version`). It does not touch npm's global prefix (nvm) or the
  agents' configs.
- Integrity: `npm pack` of the agent package and the file's sha512 checked against
  `versions.env` before installing; npm checks the dependencies against the registry.
- Claude Code and OpenCode need the `postinstall` (it copies the platform's native
  binary); the scripts were read in the tarballs and only touch `node_modules`.
  Codex has no `postinstall`: the binary comes in a per-platform optional dependency.
- Space: ~1.2 GB in total (Codex ~446 MB, Claude Code ~292 MB, OpenCode ~214 MB,
  Qwen Code ~155 MB + optionals, Pi ~30 MB). The plan estimated 0.3 GB.
- Uninstall: `rm -rf ~/.local/opt/agents/<agent>`. Interactive state:
  `rm -rf ~/.local/state/local-agentic/agents/<agent>`.

This directory's `versions.env` is the source of the versions. Proposal: merge it into
the root `versions.env` when E6 is approved.

## Isolation

No agent reads or writes `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.gemini`,
`~/.qwen`, `~/.pi` or `~/.config/opencode`.

- **Configuration generated, not hand-edited:** each start builds the agent's file
  from `<agent>/*.base.json` + `<agent>/*.<profile>.json`
  (`lib/render.py`: merges and replaces `@@LLM_BASE_URL@@`, `@@LLM_MODEL@@`,
  `@@INT:LLM_CONTEXT@@`... from the environment; `//` keys are comments and are removed).
  In Codex, `config.toml` and `.rules` are text (replacement with string escaping) and
  the profiles are native `<profile>.config.toml` files chosen with `--profile`.
- **Eval:** fresh state on every run in `<log-dir>/home/`. No memory,
  session or trust carries over from one task to another.
- **Interactive:** `~/.local/state/local-agentic/agents/<agent>/`.
- **Clean environment.** `run.sh` and the launchers run the agent with a zeroed
  environment (`unset` of everything, in a subshell, except a list: `PATH`, `HOME`, `LANG`/`LC_*`,
  `TERM`, `TZ`, `TMPDIR`, `LLM_*`, `LOCAL_LLM_API_KEY`, `AGENT_*`, `GIT_AUTHOR_*`/
  `GIT_COMMITTER_*` and the variables the agent's `env.sh` sets with `keep`).
  `CLAUDECODE`, `CLAUDE_CODE_*`, `ANTHROPIC_*`, `OPENAI_*` and tokens of the calling
  session do not pass; those of `claude-local` and `codex-local` are the ones set on purpose.
  The values do not go on the command line (`ps`). `command.txt` lists the names.
- Still in effect, in all five: the project's `AGENTS.md` (and `CLAUDE.md`/`QWEN.md`)
  and those of the directories above it. The eval workdir must not sit below a folder
  with someone else's `AGENTS.md`/`CLAUDE.md`. On the host, Qwen Code, Codex, Pi and OpenCode also
  read `~/.agents/skills` of the real HOME (currently without skills); in the agent-box HOME is empty.

## llama-server key

Since E5 the server requires a key on every route, including `/metrics`.
`lib/common.sh` uses `LLM_API_KEY` (in the agent-box it comes from the environment) or, without it, the first
non-comment line of `LLM_API_KEY_FILE` (default `~/.config/local-agentic/llm-api-key`,
created by `scripts/llm key`). The key is never printed nor put on the command line:
the agents receive it in `LOCAL_LLM_API_KEY` (Qwen `envKey`, Codex `env_key`, Pi `apiKey`,
OpenCode `{env:...}`, Claude `ANTHROPIC_AUTH_TOKEN`) and `/metrics` receives it through
`curl`'s standard input (`-H @-`). Without a key, there is a warning and the server answers 401.

## Contract with the eval

```bash
agents/<agent>/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
```

| Item | Behavior |
|---|---|
| Environment | `LLM_BASE_URL` (default `http://127.0.0.1:9931`; a trailing `/v1` is removed), `LLM_MODEL` (default `qwen3.6-35b`), `LLM_CONTEXT` (131072), `LLM_MAX_OUTPUT` (32768) |
| Profile | `AGENT_PROFILE=autonomous` (default in `run.sh`). **Only inside the agent-box**: without `AGENT_BOX=1` (set by the E7 entrypoint, checked together with `/.dockerenv`) `run.sh` exits with error 2. `AGENT_ALLOW_HOST_AUTONOMOUS=1` forces it on the host and is **unsafe** (YOLO, `bypassPermissions`, `danger-full-access` and Pi without permissions, with no container). `AGENT_PROFILE=interactive` runs on the host |
| Execution | `cd <workdir>`, stdin on `/dev/null`, non-interactive mode, automatic approval inside the workdir |
| Output | the agent's exit code (0 = finished normally) |
| `<log-dir>` | `events.jsonl` (stdout: JSON/stream), `stderr.log`, `run-meta.json` (version, profile, model, start/end, seconds, code), `agent-metrics.json` (below), `command.txt`, effective config, `guard.log` (blocks), `home/` (state and session), `metrics-before.prom`/`metrics-after.prom` (if the server has `--metrics`) |
| Skills | `AGENT_SKILLS_DIRS` (see Skills); `AGENT_SKILLS_BOOTSTRAP=0` removes the Superpowers bootstrap |
| Optional | `AGENT_TIMEOUT=30m` (uses `timeout`), `AGENT_LOG_REQUESTS=1` (request bodies, Qwen Code and Pi), `AGENT_BIN=<executable>`, `AGENT_DRY_RUN=1` (generates the config and shows the command; does not require the agent-box) |
| Prompt | goes as an argument; limit ~120 KB. A prompt that starts with `-` gets a newline at the start |
| Concurrency | one run at a time: the server has a single slot (`-np 1`) |

Interactive launchers (`interactive` profile): `qwen-code/qwen-local`,
`codex-local/codex-local`, `pi/pi-local`, `opencode/opencode-local`,
`claude-local/claude-local`. Run from inside the project; they accept the agent's own options.

### `agent-metrics.json`

After the agent exits, `lib/agent_metrics.py` reads `events.jsonl` and writes
`<log-dir>/agent-metrics.json`, which the eval copies to `result.json` under
`agent.metrics`. It never changes the exit code; if reading fails, it writes `error`.

| Field | Meaning |
|---|---|
| `turns` | model responses in the main loop |
| `requests` | requests to the model seen by the client |
| `tool_calls` | tool calls |
| `tool_call_errors` (= `tool_errors`) | results marked as errors by the agent |
| `loops_detected` (= `loops_suspected`) | runs of 3+ consecutive calls with the same tool and the same arguments |
| `tokens_in`, `tokens_out` (= `client_tokens.input/output`) | tokens from the client's point of view, cache included |
| `raw_tool_call_text` | texts or reasoning with raw `<tool_call>`/`<function=` (a call the server did not recognize) |
| `guard_blocks` | lines of `guard.log` |

The two names of each field serve `eval/README.md` (`tool_call_errors`,
`loops_detected`, `tokens_in`, `tokens_out`) and the orchestrator's request
(`tool_errors`, `loops_suspected`, `client_tokens`).

| Agent | Source | What is `null` or changes meaning |
|---|---|---|
| Qwen Code | `assistant`/`user`/`result` events (Claude SDK format) | `usage.input_tokens` already includes the cache; `turns` = the result's `num_turns` |
| Codex | `item.completed` (`command_execution`, `file_change`...) and `turn.completed.usage` | **`turns` and `requests` = `null`**: `exec --json` has no per-model-response event (`user_turns` carries the user turns). Error = command with status `failed`/`declined` or a `failed` patch (exit ≠ 0 counts as an error) |
| Pi | assistant `message_end`, `tool_execution_end.isError`, `turn_end` | — |
| OpenCode | `tool_use` (state `error`), `step_finish.tokens` | main session only (subagents are left out); `turns` = `requests` = steps |
| Claude Code | same as Qwen Code | llama.cpp's `input_tokens` excludes the cache: add `cache_read`/`cache_creation` |

The formats were taken from each version's documentation and code and tested
with synthetic events; with the agents installed, check them in E6 (especially whether
Claude Code repeats content blocks across `assistant` events of the same message).

## Permissions

Three layers, in order of strength: the **E7 container** (the barrier), each agent's
**native rules** (see each README) and the **common guard** `lib/guard.py`.

### Common guard (best effort)

The same guard in all five, called before every shell command (`PreToolUse` hook
in Qwen Code, Codex and Claude Code; plugin in OpenCode; extension in Pi). It is a
**conservative** second layer: it looks for dangerous patterns in the whole command text,
without depending on structure, and accepts false positives. It blocks with exit code 2, returns the
reason to the model and records it in `guard.log`.

| Pattern | interactive | autonomous |
|---|---|---|
| `git` and `push`/`send-pack`/`receive-pack` in the same command (accepted false positive: `git commit -m "push"`) | blocks | blocks |
| `sudo`, `su`, `doas`, `pkexec`, `runuser` in any position | blocks | blocks |
| Downloaded code executed: pipe from `curl`/`wget` to a shell, `source`, `eval`, `xargs`, `env`, `if` or an interpreter reading stdin; `<(curl`, `$(curl`; a downloaded file executed in the same command | blocks | blocks |
| `rm` outside the project, on the root, on `.git` or with an unresolvable target; `rm -r/-f` coming from `xargs`, after an unresolvable `cd`/`pushd` or after `ln`; `find -delete`/`-exec rm` outside the project. `/tmp` allowed, except the folder that contains the project | blocks | blocks |
| Install: `npm/pnpm/yarn/bun install/add/ci`, bare `yarn`, `pip install` (including `pip3.12`, `python -m pip`), `uv add/sync/pip/tool`, `uv run --with`, `npx`/`npm exec` of a program outside `node_modules/.bin`, `poetry`, `cargo`, `go install`, `gem`, `apt`, `brew`… | allows (shell asks) | blocks |

Structure is also analyzed: keywords (`if`/`then`/`for`/`do`…) separate
commands, wrapper options (`nice -n`, `time -p`, `env -S`) are skipped, and the script
of `bash -c`, heredocs and here-strings is evaluated as a command (the body of `apply_patch`
is not, since it is file content).

**What gets through** (the container covers it): code generated and run later (`echo … > x.sh`,
then `sh x.sh`), strings built at run time (`git $(printf 'p%sh' us)`),
interpreters performing actions (`perl -e "system q(rm -rf ~)"`), and writing outside the
project without `rm` (`mv`, `truncate`, `> ~/.bashrc`). Tests: `lib/test-guard.sh`
(223 cases, including the bypass examples listed in the static verification; all pass).

### By profile

| | interactive (host or box) | autonomous (agent-box only) |
|---|---|---|
| Read | free | free |
| Edit tools | free inside the project; outside asks (or is refused) | free inside the project (Codex `danger-full-access`: no path limit) |
| Shell | asks (Pi: only plain reads do not ask) | approved. **The shell writes anywhere the process user can reach**; the guard only catches the patterns above |
| Web | search denied; fetch asks | denied |

## Skills

Contract: `AGENT_SKILLS_DIRS` = directories separated by `:`; each one contains skill
folders (`<name>/SKILL.md`). Without the variable the base profile applies: `/opt/skills/base` (in the
agent-box) or `$SKILLS_PREFIX/profiles/base` (on the host), whichever exists first.
`AGENT_SKILLS_DIRS=` (empty) turns skills off. `lib/skills.py` resolves the directories,
copies or lists the skills for each agent and generates the bootstrap.

- **Base profile:** `scripts/fetch-skills.sh` downloads the Superpowers pinned in
  `versions.env` (commit checked), stores the tree in
  `$SKILLS_PREFIX/superpowers/<version>/` and copies only the skills of
  `skills/profiles/base.txt` to `$SKILLS_PREFIX/profiles/base/`, with `LICENSE.superpowers`
  and `SOURCE`. All read-only. The cross-references of the profile's skills
  (`subagent-driven-development/scripts`, `requesting-code-review/code-reviewer.md`,
  `using-superpowers/references`) stay inside the profile itself.
- **Extra profiles:** `scripts/fetch-skills.sh frontend` builds `profiles/frontend/`
  (`anthropic:frontend-design` and `anthropic:webapp-testing`, from `anthropics/skills` at the
  pinned commit, only the skill folders, each with its `LICENSE.txt`). It enters the
  agent with `--skills-dir`. `webapp-testing` uses the Playwright and Chromium of the
  agent-box image (`python`, not `python3`).
- **On demand in all five:** only the name and description of each skill go into the prompt; the
  body is loaded when the model decides to or when the skill is called by name
  (syntax per agent in the comparison table).
- **Superpowers bootstrap:** when `using-superpowers` is present, the skill's text and the agent's
  tool map go at the start of each session (~1k tokens; up to ~2k in
  Codex). Maps: `claude-code-tools.md` and `codex-tools.md` from Superpowers itself; Pi,
  the official extension's text; OpenCode, the official plugin's with `edit`/`write` in place
  of `apply_patch`; Qwen Code, one of our own (the Gemini CLI names do not apply there).
- **Unverified (E6):** in each agent, whether the bootstrap reaches the model, whether the model
  triggers the right skill by itself and whether the explicit call works (see the Skills section of
  each README).

## How to measure the size of the first prompt

```bash
agents/measure-preamble.sh <agent>     # trivial task in an empty git repository
```

It uses the interactive profile (autonomous only runs in the agent-box; to measure it, run the
script through the container with `AGENT_PROFILE=autonomous`). `/metrics` requires the server
key. With skills, the preamble includes the skills list and the bootstrap; to measure
without them, `AGENT_SKILLS_DIRS=`.

| Source | What it gives | Requirement |
|---|---|---|
| llama-server `/metrics`, before and after | `llamacpp:prompt_tokens_total` (processed) + `llamacpp:prompt_tokens_cached_total` (from the cache); sum of all requests of the run | `--metrics` on llama-server **[verified: tools/server/README.md and server-task.cpp b11982]**. **Request for E5:** include `--metrics` |
| `usage` of the first response in `events.jsonl` | OpenAI: `prompt_tokens` and `prompt_tokens_details.cached_tokens`; Anthropic: `input_tokens` (uncached) + `cache_read_input_tokens` **[verified: server-task.cpp]** | none |
| Request body | exact system prompt, tools and messages | Qwen Code (`requests/`), Pi (`requests.jsonl`) with `AGENT_LOG_REQUESTS=1` |
| Server log | prompt tokens per task in the slot and checkpoint reuse | `llama-server --verbose` / `-lv 4` (exact text of the lines **unverified**) |

For the per-turn cache cost: in the real task, the `cached_tokens` of each response
should stay close to the size of the previous prompt; a large drop = the prefix changed.

## Recommendations for the server configuration (E4/E5)

- `--metrics` (measurement above).
- Server default sampling equal to the model card's (`--temp 0.6 --top-p 0.95
  --top-k 20 --min-p 0 --presence-penalty 0`): applies to any client that does not
  send the parameters. llama.cpp's default `min_p` is 0.05, different from the card.
  **Mandatory for Codex**, which sends no sampling parameter.
- `-n 32768` (default output limit per request): Codex does not send
  `max_output_tokens`; the other agents send their own limit and are not affected.
- `--reasoning-preserve` is redundant: b11982 already turns on `preserve_reasoning` by
  default when the template supports it (`common/arg.cpp`) **[verified]**. Keeping it does no harm.
- The Qwen3 parser in b11982 ends the reasoning when `<tool_call>` appears
  (`common/parsers/qwen3-coder.cpp`), which attacks the cause of OpenCode's issue #24316
  **[verified: code]**.

## Test first in E6 (unverified)

E7 comes first: the autonomous profile runs through the agent-box. In order, for each installed agent:

1. `AGENT_DRY_RUN=1 agents/<agent>/run.sh …`: generated config and command.
2. Config accepted by the agent without a warning (Qwen: clean start; Pi: `pi --list-models local`;
   OpenCode: `opencode debug config`; Claude: `/status` in interactive mode).
3. `measure-preamble.sh`: preamble, number of requests per turn (look for extra
   calls for title, memory, suggestions) and whether the sampling reached the
   server (`--verbose`).
4. Guard: ask the agent for `git push` and `rm -rf ../x`; it must show up in `guard.log`.
5. Cache across turns in a task with 5+ steps (`cached_tokens`).
6. Specific items in the "Test first" section of each README, especially:
   Claude Code with `/v1/messages` (thinking, temperature, `--bare`), Codex with
   `/v1/responses` (resent `reasoning` items, `apply_patch` through the shell, hook with
   `--dangerously-bypass-hook-trust`), Qwen Code hook in YOLO, Pi extension
   loaded with `-e`, OpenCode plugin and the #24316 symptom.
7. Each agent's `agent-metrics.json` matches what is seen in `events.jsonl`.
8. Skills: bootstrap present in the first request, explicit call, and whether the model
   triggers the skill by itself in the Superpowers acceptance test ("Let's make a react todo
   list" must trigger `brainstorming` before writing code).
9. Real isolation: after installing and running, `find -newer <marker>` on `~/.claude`,
   `~/.claude.json`, `~/.codex`, `~/.qwen`, `~/.pi`, `~/.config/opencode`,
   `~/.local/share/opencode`, `~/.cache/opencode` and `~/.agents` shows nothing.

## Risks found

- **OpenCode 1.x unmaintained:** 2.0 came out and the 1.x issues were closed
  en masse on 2026-10-11. Whatever fails on 1.19.5 stays unfixed; migrating to
  2.x requires redoing the plugin (the plugin API changed).
- **Qwen Code changes fast** (0.25.0 → 0.26.3 in 23 days, daily nightly) and turns on by
  default features that call the model in the background. Each update may bring
  another extra call; check the number of requests per turn at every version change.
- **Single slot:** any parallel call (title, memory, classifier,
  subagent) evicts the main prompt from the cache. All of that is turned off where there is an
  option; the server's `--cache-ram` mitigates the rest.
- **Claude Code with a non-Claude model:** no official support. Features that depend on
  Anthropic (WebSearch, fast mode, artifacts, the `auto` mode classifier) do not
  work; the adaptive thinking format is ignored by llama.cpp; the
  effective temperature depends on the merge with `CLAUDE_CODE_EXTRA_BODY`.
- **Codex with a non-OpenAI model:** prompt, catalog and `apply_patch` assume GPT; the
  llama.cpp `/v1/responses` path is the least tested; no client sampling or output
  limit. The Codex sandbox (bwrap) should not work inside the E7 container
  without loosening Docker's seccomp: there the autonomous profile runs without it
  (`danger-full-access`), and the container is the barrier.
- **The guard is best effort:** conservative and with false positives (it blocks text that
  merely mentions `git push` or `sudo`, including in a documentation heredoc). In
  autonomous mode the shell writes anywhere; the container is what holds.
- **Skills cost prompt:** ~50–150 tokens per skill plus the bootstrap, in every prompt;
  the base profile has 13 skills and `frontend` has 2.
- **Pi without permissions:** the extension is the only layer besides the container; it only sees
  the `bash`, `write` and `edit` tools.
- **Long prefill** (~100k tokens at 500–1000 tok/s = 2 to 3 min with no bytes): the
  timeouts of all agents were raised; if one still cuts it off, the symptom is
  a repeat of the same request (and another 2 to 3 min of prefill).
- **Space** larger than estimated (~1.2 GB against 0.3 GB).

## Files

| Path | Content |
|---|---|
| `versions.env` | versions, npm integrity, prefixes, server defaults |
| `install.sh` | isolated installation of an agent |
| `measure-preamble.sh` | first-prompt measurement |
| `lib/common.sh` | `run.sh` contract, config generation, metrics, metadata |
| `lib/render.py` | JSON merge and `@@VAR@@` replacement (JSON, TOML, rules) |
| `lib/agent_metrics.py` | `agent-metrics.json` from `events.jsonl` |
| `lib/skills.py` | `AGENT_SKILLS_DIRS`: directories, copy, config overlays and bootstrap |
| `<agent>/superpowers-tools.md` | tool map of the bootstrap (Qwen Code, Pi, OpenCode) |
| `../scripts/fetch-skills.sh` | downloads the pinned skills (Superpowers, `anthropics/skills`) and builds the profiles (`base`, `frontend`) |
| `lib/guard.py` | common shell command guard |
| `lib/test-guard.sh` | guard test cases |
| `<agent>/` | base config and profiles, `env.sh`, `run.sh`, interactive launcher, README |
