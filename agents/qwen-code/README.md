# Qwen Code (local)

Goal 1 contender (single contest since Oct 29). A fork of Gemini CLI maintained by the Qwen team, with
OpenAI-compatible providers, hooks in the Claude Code format, permission
rules and a headless mode.

| Item | Value |
|---|---|
| Pinned version | **0.26.3** (`@qwen-code/qwen-code`, npm `latest` tag, published 2026-10-28) **[verified: npm]** |
| Other lines | `preview` 0.26.3-preview.0 and daily `nightly`; do not use |
| License | Apache-2.0 (the repository's `LICENSE` file; the published `package.json` does not carry the field) **[verified]** |
| Requirement | Node ≥ 22 (here: 24.21) |
| Size | ~155 MB unpacked, plus optional dependencies (bun, node-pty, sharp) |
| Executable | `qwen` |

## Installation

```bash
agents/install.sh qwen-code
# = npm install --global --prefix ~/.local/opt/agents/qwen-code/0.26.3 @qwen-code/qwen-code@0.26.3
#   and link ~/.local/opt/agents/qwen-code/current -> 0.26.3
```

Nothing goes into npm's global prefix (nvm). Automatic update is turned
off in the config (`general.enableAutoUpdate: false`), otherwise Qwen Code would
try `npm install -g` in the global prefix.

## Configuration isolation

- `QWEN_HOME` changes the global directory (default `~/.qwen`): settings, credentials,
  memory, skills, sessions and logs **[verified: docs/users/configuration/settings.md, variables table]**.
  `QWEN_RUNTIME_DIR` (sessions, logs) follows `QWEN_HOME` when not set.
- Interactive: `QWEN_HOME=~/.local/state/local-agentic/agents/qwen-code/qwen`.
  Eval: `QWEN_HOME=<log-dir>/home/qwen`, new on every run.
- `settings.json` is **regenerated at every start** from `settings.base.json` +
  `settings.<profile>.json` (`agents/lib/render.py`). Changes made through `/settings`
  or `/model` last only until the next time; edit the models in the repository.
- Still in effect, by Qwen Code's design: `.qwen/settings.json`, `QWEN.md` and
  `AGENTS.md` of the project, and `~/.env` (read after `$QWEN_HOME/.env`, without overriding
  variables already set). Currently neither `~/.env` nor `~/.qwen` exists on this machine.

## Files

| File | Role |
|---|---|
| `settings.base.json` | Local provider, sampling, window, compaction, telemetry, tools and hook |
| `settings.interactive.json` | Everyday-use permissions |
| `settings.autonomous.json` | Eval permissions (YOLO + blocklist) |
| `env.sh` | Environment variables and `settings.json` generation |
| `run.sh` | Eval contract |
| `qwen-local` | Interactive launcher (`cd project && .../qwen-local`) |

## Model and server

| Setting | Value | Where |
|---|---|---|
| Endpoint | `$LLM_BASE_URL/v1`, `openai` provider (Chat Completions) | `modelProviders.openai[0]` |
| Key | the llama-server's, via `envKey: LOCAL_LLM_API_KEY` (see the key in `agents/README.md`) | same |
| Sampling | temperature 0.6, top_p 0.95, top_k 20, min_p 0, presence_penalty 0 | `generationConfig.samplingParams` |
| Max output | 32768 (explicit `max_tokens`; turns off the automatic escalation to 64k) | same |
| Thinking | `chat_template_kwargs.preserve_thinking: true` | `generationConfig.extra_body` |
| Window | 131072 | `generationConfig.contextWindowSize` |
| Compaction | at 75% of the window (~98k) | `context.autoCompactThreshold: 0.75` |
| Timeouts | no per-request limit; 15 min without bytes on the stream; no stream lifetime limit | `timeout: 0`, `streamIdleTimeoutMs`, `QWEN_STREAM_MAX_LIFETIME_MS=0` |

All the keys above appear in `docs/users/configuration/settings.md` and
`model-providers.md` of tag v0.26.3 **[verified]**. Details checked in the code:

- With `samplingParams` set, the keys go to the server as they are and
  Qwen Code does not inject its own reasoning field **[verified: model-providers doc]**.
- For IDs that start with `qwen` outside DashScope, the reasoning profile is
  `qwen-chat-template` and the history resends each turn's `reasoning_content`
  (also copied to the `reasoning` field) **[verified: provider/default.ts]**.
  That is what `preserve_thinking` needs.
- Without `contextWindowSize`, a `qwen3.6-*` ID falls under the 1M-token rule and
  compaction never happens (issue #13415, open) **[verified]**.

## Telemetry, network and extra calls

| What | How |
|---|---|
| Usage statistics and telemetry | `privacy.usageStatisticsEnabled: false`, `telemetry.enabled: false`, `QWEN_USAGE_STATISTICS_ENABLED=0`, `QWEN_TELEMETRY_ENABLED=0` |
| models.dev catalog (daily download) | `QWEN_CODE_MODELS_DEV=off`, `QWEN_CODE_MODELS_DEV_REFRESH=off` |
| Automatic update | `general.enableAutoUpdate: false` |
| Web search, image generation, artifacts, cron, PR autofix | `tools.disabled` (the autonomous profile also turns off `web_fetch`, `ask_user_question` and plan mode) |
| Automatic memory, "dream", auto-skill | `memory.*: false` (see problem 1 below) |
| Follow-up suggestions, feedback, tool summaries, recap | `ui.enableFollowupSuggestions`, `ui.enableUserFeedback`, `experimental.emitToolUseSummaries`, `general.showSessionRecap`: `false` |
| Automatic title | only runs with `fastModel` (not configured); also `QWEN_DISABLE_AUTO_TITLE=1` **[unverified: cited only in the design doc]** |
| Messages between sessions | `agents.crossSessionMessaging: false` |
| Co-authorship in commits and git notes | `general.gitCoAuthor.commit/pr: false` |

With a single slot on the server, each background call evicts the main
prompt from the cache. That is why all extra calls are turned off.

## Permissions

Qwen Code decides in this order: `deny` > `ask` > `allow` > approval mode.
`Bash(...)` rules without `*` match by word prefix (`Bash(git push)` catches
`git push origin main`). Compound commands are split before the check.

| | interactive (`qwen-local`) | autonomous (`run.sh`) |
|---|---|---|
| Mode | `default`: edit and shell ask | `yolo` (`--approval-mode yolo`) |
| Read | `allow: Read` (read, grep, glob, ls) | free |
| Edit | `allow: Edit(/**)`, only inside the project (`/` = project root). The edit tools refuse paths outside the workspace | free inside the workspace |
| Shell | asks | free |
| Blocked (rule) | `git push`, `sudo`, `su`, `doas`, `pkexec` | the same + `npm/pnpm/yarn/bun install/add/ci`, `pip install`, `uv add`, `apt`, `brew` |
| Blocked (hook, best effort) | `lib/guard.py`: patterns of `git push`, `sudo`, `curl \| sh`, `rm` outside the project | the same + network installs |

In YOLO, `deny` still blocks (`permissionFlow.ts`: `deny` is checked before
the mode) **[verified: code]**; `ask` and `allow` have no effect. The hook runs on
`PreToolUse` with `matcher: ^run_shell_command$`; exit code 2 blocks and the
reason goes to the model **[verified: docs/users/features/hooks.md]**.
We do not use `auto` mode: it calls an LLM classifier on every action, which
costs an extra request on the single slot.

## Skills (AGENT_SKILLS_DIRS)

- **Discovery:** the `AGENT_SKILLS_DIRS` directories go into `skills.directories`
  ("user" level; each directory is scanned one level below, `<name>/SKILL.md`)
  **[verified: docs settings.md]**. Qwen Code also reads `$QWEN_HOME/skills`,
  the project's `.qwen/skills` and `.agents/skills`, and `~/.agents/skills` of the real HOME
  (on the host; in the agent-box HOME is empty).
- **On demand:** only name and description go into the `skill` tool's list; the body
  is loaded when the model calls the skill **[verified: docs features/skills.md]**.
- **Explicit call:** `/<skill-name>` (or the `/skills` panel).
- **Superpowers bootstrap:** `SessionStart` hook (`startup|resume|clear|compact`)
  that returns `hookSpecificOutput.additionalContext` with `using-superpowers` and the
  `qwen-code/superpowers-tools.md` map (`settings.skills-bootstrap.json`).
- **Tool map:** Qwen Code is a fork of Gemini CLI, but the tool names
  changed (`edit` not `replace`, `skill` not `activate_skill`, `agent`
  not `invoke_agent`, `todo_write` off by default; checked in
  `packages/core/src/tools/tool-names.ts`). That is why the map is ours, not
  Superpowers' `gemini-tools.md`.
- **Unverified (E6):** the `SessionStart` `additionalContext` reaches the model in
  `-p` mode; the model triggers the right skill by itself; token cost of the list.

> **Autonomous profile only in the agent-box.** `run.sh` refuses `AGENT_PROFILE=autonomous`
> outside the E7 container (which sets `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> forces it on the host and is unsafe. The agent's environment is clean (`env -i` + allowlist)
> and the llama-server key comes from `LLM_API_KEY` or the E5 file
> (see `agents/README.md`).

## Non-interactive use

```bash
agents/qwen-code/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# runs: qwen --prompt=<contents> --output-format stream-json --approval-mode yolo
```

- `events.jsonl`: `system` messages, `assistant` (with `usage`), tool
  results and the final `result`.
- Qwen Code exit codes: 0 success, 53 turn limit, 55 budget
  (`--max-wall-time`/`--max-tool-calls`), 130 SIGINT **[verified: docs/users/features/headless.md]**.
- `AGENT_LOG_REQUESTS=1` adds `--openai-logging --openai-logging-dir <log>/requests`
  (body of each request and response).
- The prompt goes as an argument (`--prompt=`); prompts above ~120 KB are refused.

## Measuring the preamble

`agents/measure-preamble.sh qwen-code`. The first request recorded in
`requests/` shows the system prompt, tools and messages; the first response's `usage`
in `events.jsonl` gives `prompt_tokens`; the server's `/metrics` gives the total
processed. Qwen Code defers rarely used tools (`tools.toolSearch.enabled`,
on by default), which reduces the preamble.

## Known problems with Qwen3.6 + llama.cpp

1. **Memory catalog at the end of the request** (#14203, open since 0.25.1): with
   automatic memory on, the catalog is appended at the end of each request and
   disappears in the next. On hybrid models such as Qwen3.6, llama.cpp only goes back to
   checkpoints near the end of the prompt, so each step reprocesses the whole
   conversation. **Mitigation:** `memory.enableManagedAutoMemory: false` (checked in
   the code: without managed memory the catalog stays empty).
2. **1M window assumed for `qwen3.x`** (#13415, open). **Mitigation:**
   `contextWindowSize: 131072`.
3. **Features that change the context** (#14215, open): suggestions, memory
   updates and session resume alter the prompt and drop the cache on local
   servers. **Mitigation:** the features are turned off.
4. `PreToolUse` hooks that fail (error ≠ 2) let the command through (#12457,
   open, cited for `qwen serve`). The guard only uses exit 0 or 2; the native
   `deny` rules are the first layer.

## Test first in E6 (unverified)

- The generated `settings.json` is accepted by 0.26.3 without a warning (`goals.modelProposed`,
  names in `tools.disabled`, `hooks`).
- The guard hook fires in `-p` with `--approval-mode yolo` and blocks `git push`.
- No extra request per turn: count `requests/` against the turns in `events.jsonl`.
- Cache reuse across turns: `prompt_tokens_details.cached_tokens`
  close to the size of the previous prompt.
- The extra `reasoning` field (copy of `reasoning_content`) does not get in the way of the Qwen3.6 template.
- `QWEN_DISABLE_AUTO_TITLE` (only in the design doc).
- `--bare` (only `read_file`, `edit`, `run_shell_command`) as a minimal-preamble variant:
  it ignores a good part of the config; test whether the local provider still applies.
