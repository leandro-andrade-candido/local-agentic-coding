# Codex CLI with the local model (codex-local)

OpenAI's Codex CLI (Apache-2.0), pointed at the llama-server's Responses endpoint
(`/v1/responses`). The everyday Codex (ChatGPT login in `~/.codex`) is neither
used nor changed.

| Item | Value |
|---|---|
| Pinned version | **0.165.0** (`@openai/codex`, `latest` tag, published 2026-10-27; GitHub release `rust-v0.165.0`) **[verified: npm, GitHub]**. A 0.166.0-alpha already exists |
| License | Apache-2.0 **[verified: npm, openai/codex repository]** |
| Executable | `codex`. The package is a 13 KB launcher; the native binary comes in the optional dependency `@openai/codex@0.165.0-linux-x64` (~446 MB unpacked) |
| API | Responses only (`wire_api = "responses"`, the only accepted value) **[verified: config-reference]** |

## Installation

```bash
agents/install.sh codex-local
# = npm install --global --prefix ~/.local/opt/agents/codex-local/0.165.0 @openai/codex@0.165.0
```

The package has no `postinstall`; the `bin/codex.js` launcher only picks the platform
binary **[verified: tarball]**. To reuse the already installed binary:
`AGENT_BIN="$(command -v codex)" agents/codex-local/codex-local`.

## Configuration isolation

- `CODEX_HOME` changes the state directory (default `~/.codex`): `config.toml`,
  profiles, `auth.json`, `rules/`, sessions, logs, SQLite **[verified: docs config-advanced]**.
- Interactive: `~/.local/state/local-agentic/agents/codex-local/codex`.
  Eval: `<log-dir>/home/codex`, new on every run.
- `env.sh` removes `OPENAI_API_KEY`, `CODEX_API_KEY` and `OPENAI_BASE_URL` from the environment.
  The isolated directory has no `auth.json`: the local provider only uses the
  llama-server key, in `LOCAL_LLM_API_KEY` (`env_key`; see `agents/README.md`).
- Still in effect: the project's `AGENTS.md` (`project_doc_max_bytes` at the default) and,
  only in a trusted project, the repository's `.codex/`. In `exec` the project is not
  trusted, so the repository's `.codex/` does not load.
- `config.toml` is regenerated at every start. In the TUI, the folder trust (written
  by Codex to `config.toml`) does not persist: the question may come back at every start.

## Files

| File | Role |
|---|---|
| `config.base.toml` | Provider, model, window, compaction, reasoning, telemetry, disabled features, hook |
| `interactive.config.toml`, `autonomous.config.toml` | Native Codex profiles (`--profile <name>` overlays `$CODEX_HOME/<name>.config.toml`) |
| `rules/base.rules`, `rules/autonomous.rules` | Execution rules (`prefix_rule`, `forbidden`), copied to `$CODEX_HOME/rules/local.rules` |
| `env.sh`, `run.sh`, `codex-local` | Environment, eval contract, interactive launcher |

## Model and server

| Setting | Value |
|---|---|
| Provider | `[model_providers.llamacpp]`: `base_url = $LLM_BASE_URL/v1`, `wire_api = "responses"`, `env_key = "LOCAL_LLM_API_KEY"`, WebSocket off, `stream_idle_timeout_ms` 30 min |
| Compaction | local (`capabilities.remote_compaction = "unsupported"`) at 98304 tokens (`model_auto_compact_token_limit`, 75%) |
| Window | `model_context_window = 131072` (Codex uses 95% of it) |
| Reasoning | `model_supports_reasoning_summaries = false`, `model_reasoning_summary = "none"`: no `reasoning.effort/summary`. Thinking stays on through the template |
| Instructions | Codex's base prompt for unknown models (~21 KB) without the Personality section (`personality = "none"`) |
| **Sampling** | **Codex does not send `temperature`, `top_p`, `top_k` or `max_output_tokens`**: the Responses request has no such fields **[verified: codex-api/src/common.rs]**. The server defaults apply, to be defined in E5 |

The ID `qwen3.6-35b` does not exist in Codex's catalog, which then uses generic
metadata (`model_info_from_slug`) **[verified: models-manager/src/model_info.rs]**:

- shell tool `exec_command`/`write_stdin` (unified exec), of type `function`;
- **no `apply_patch` tool**: in 0.165 it only exists in the "freeform" format
  (a `custom` tool), which only comes for catalog models. The base prompt tells it
  to call `apply_patch` through the shell, and `exec_command` intercepts that command
  **[verified: core/src/tools/spec_plan.rs, handlers/unified_exec/exec_command.rs]**.

On the llama.cpp b11982 side (`tools/server/server-chat.cpp`) **[verified: code]**:

- only `type: "function"` tools are converted; the others are dropped with a warning;
- accepted input items: messages, `function_call`, `function_call_output` and
  `reasoning` **with non-empty `content`**. Any other type (`custom_tool_call`,
  `local_shell_call`) causes a 400 error;
- `previous_response_id` is not accepted (Codex sends the whole history, `store: false`);
- the reasoning comes out as a `reasoning` item with `content: [{type: "reasoning_text"}]`, and
  Codex resends the `content` when it has `reasoning_text`
  (`protocol/src/models.rs`, `should_serialize_reasoning_content`). So the reasoning
  goes back to llama.cpp as `reasoning_content` (preserve thinking).

## Telemetry, network and disabled features

| What | How |
|---|---|
| Analytics and metrics (the default metrics exporter is `statsig`) | `[analytics] enabled = false`, `[otel] exporter/trace_exporter/metrics_exporter = "none"` |
| Feedback, update check | `[feedback] enabled = false`, `check_for_update_on_startup = false` |
| Web search | `web_search = "disabled"`, `capabilities.external_web_access = false` |
| Connectors, remote plugin catalog, fast/ultrafast, skill dependency installation | `[features] apps`, `remote_plugin`, `fast_mode`, `ultrafast_mode`, `skill_mcp_dependency_install` = `false` |
| Extra model calls | `[features] multi_agent`, `goals`, `memories` = `false`; `[tui] auto_recap = false` |

All the keys appear in the current Configuration Reference **[verified]**.

## Permissions

| | interactive (`codex-local`) | autonomous (`run.sh`) |
|---|---|---|
| Approval | `on-request` (the model asks to leave the sandbox) | `never` |
| Sandbox | `workspace-write`: write to the workspace and `/tmp`, network off | `danger-full-access` (isolation = the E7 container) |
| `forbidden` rules | `git push`, `sudo`, `su`, `doas`, `pkexec`, `runuser` | the same + `npm/pnpm/yarn/bun install/add/ci`, `pip install`, `python -m pip install`, `uv add/pip/tool`, `apt`, `brew`, `uvx`... |
| `PreToolUse` hook (`matcher = "Bash"`) | `lib/guard.py` | `lib/guard.py` |

- The hook receives `tool_name: "Bash"` and `tool_input.command`; exit code 2
  blocks and `stderr` goes to the model. It covers `exec_command` and the shell;
  `apply_patch` shows up as `apply_patch` (the guard only looks at shell) **[verified: docs hooks]**.
- Unmanaged hooks only run after being "trusted" by hash. `run.sh` and
  `codex-local` pass `--dangerously-bypass-hook-trust` (a 0.165 flag, checked
  in `utils/cli/src/shared_options.rs`); the only hook is the guard generated here.
- The rules use the `prefix_rule` format (Starlark) in `$CODEX_HOME/rules/`; the most
  restrictive decision wins; simple `bash -lc` scripts are split into commands
  **[verified: docs exec-policy]**. In the code, `forbidden` becomes a block before
  looking at the approval policy (`core/src/exec_policy.rs`) **[verified: code]**.
- The name `local.rules` keeps `default.rules` (where the TUI records the "always allow" choices) separate.

### Codex sandbox inside Docker

- On Linux the sandbox is `bwrap` + `seccomp` and needs to create user namespaces without
  privilege. Without `bwrap` on PATH, Codex uses a built-in helper with the same
  requirement **[verified: docs sandboxing]**.
- OpenAI's documentation says that, in a Docker container, the sandbox may not work
  when the host or the container blocks namespaces, setuid `bwrap` or `seccomp`.
  In that case the guidance is to isolate with the container itself and run with
  `--sandbox danger-full-access` or `--dangerously-bypass-approvals-and-sandbox`
  **[verified: docs agent-approvals-security]**.
- Docker's default seccomp profile does not let an unprivileged container create
  user namespaces. To keep the inner sandbox the container would have to be loosened
  (`--security-opt seccomp=unconfined`, maybe AppArmor too). **Unverified**
  here; test in E7 with `codex sandbox linux -- true`. Codex already falls back from `--proc`
  to `--tmpfs /proc` when mounting `/proc` fails (`linux-sandbox/src`).
- **Decision:** in the E7 container the autonomous profile uses `danger-full-access` with
  approval `never`, which is equivalent to `--dangerously-bypass-approvals-and-sandbox`.
  The barrier is the container; `forbidden` rules and the hook still apply.
- The autonomous profile only runs inside the agent-box (`AGENT_BOX=1`); E7 comes before
  E6, so all autonomous-profile tests go through the container. Outside
  it, only with `AGENT_ALLOW_HOST_AUTONOMOUS=1` (unsafe); in that case
  `CODEX_LOCAL_SANDBOX=workspace-write` turns on the Codex sandbox on the host (on WSL,
  `unshare -Ur` works and Codex uses the built-in helper, since there is no `bwrap`).

## Skills (AGENT_SKILLS_DIRS)

- **Discovery:** the skill folders are copied to `$CODEX_HOME/skills`, a user
  location that 0.165 still reads (marked obsolete in the code; the current doc cites
  `~/.agents/skills`, which lives in the real HOME) **[verified: ext/skills/src/host_roots.rs]**.
  The project's `.agents/skills` and, on the host, `~/.agents/skills` also apply.
- **On demand:** Codex puts only the name, description and path of each skill in the prompt and
  reads the `SKILL.md` when the task calls for it ("progressive disclosure") **[verified: docs skills]**.
- **Explicit call:** `$skill-name` in the prompt, or `/skills` in the TUI.
- **Superpowers bootstrap:** in `developer_instructions` (top-level key inserted at the
  start of `config.toml`), with `using-superpowers` and Superpowers' own
  `references/codex-tools.md`. The official Superpowers does not use a hook in Codex (it relies on the
  skill description); here the text always goes in, because the local model triggers skills with
  less precision. `codex-tools.md` is mostly about multi-agent, which is turned off.
- **Unverified (E6):** `$CODEX_HOME/skills` still loaded; `developer_instructions`
  applied in `exec`; token cost of the map (~1.2k).

> **Autonomous profile only in the agent-box.** `run.sh` refuses `AGENT_PROFILE=autonomous`
> outside the E7 container (which sets `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> forces it on the host and is unsafe. The agent's environment is clean (`env -i` + allowlist)
> and the llama-server key comes from `LLM_API_KEY` or the E5 file
> (see `agents/README.md`).

## Non-interactive use

```bash
agents/codex-local/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# runs: codex exec --json --color never --cd <dir> --skip-git-repo-check \
#   --output-last-message <log>/last-message.txt --profile autonomous \
#   --model qwen3.6-35b --dangerously-bypass-hook-trust <prompt>
```

`--json` writes JSONL to stdout: `thread.started`, `turn.started`, `item.*`
(`agent_message`, `reasoning`, `command_execution` with `exit_code`, `file_change`...),
`turn.completed` with `usage` (`input_tokens`, `cached_input_tokens`, `output_tokens`),
`turn.failed`, `error`; progress goes to stderr **[verified: docs noninteractive, exec/src/exec_events.rs]**.
The full session stays in `home/codex/sessions/`.

## Measuring the preamble

`agents/measure-preamble.sh codex-local`: the `turn.completed` `usage` and the server's
`/metrics`. Codex does not record the request body; to see
instructions and tools, use `llama-server --verbose` during the measurement.

## Test first in E6 (unverified)

1. `codex exec` with the local provider without login: no login screen, no access
   to chatgpt.com/openai.com (run once with the external network cut).
2. Round trip on `/v1/responses` for 5+ turns: `reasoning` items resent with
   `content` (otherwise llama.cpp answers 400 "item['content'] is not an array"),
   `function_call`/`function_call_output`, and fields that Codex sends and llama.cpp
   must ignore (`include`, `store`, `prompt_cache_key`, `client_metadata`, `tool_choice`).
3. File editing: Qwen3.6 must write `apply_patch`'s `*** Begin Patch` format through
   the shell. Count failed `file_change` entries in `events.jsonl`.
4. The hook with `--dangerously-bypass-hook-trust` fires in `exec` and blocks `git push`;
   the `forbidden` rule applies in `never` + `danger-full-access` mode.
5. Profiles read from `$CODEX_HOME/<profile>.config.toml` with `--profile`.
6. Local compaction at ~98k and at 95% of the window.
7. Startup traffic: model discovery on llama.cpp's `/v1/models`.
8. Preamble size (base instructions + tools).
9. `workspace-write` sandbox on the host (WSL) with the built-in helper; in the E7 container, `codex sandbox linux -- true`.

## Risks

- **Built for OpenAI models:** base prompt, `apply_patch` format and model catalog
  assume GPT. With generic metadata Qwen edits files through the shell, in a
  patch format it was not trained on.
- **`/v1/responses` in llama.cpp** is a newer and less used path than
  `/chat/completions`; the conversion of reasoning items has the requirements above.
- **No output limit:** Codex does not send `max_output_tokens`; without `-n` on the server,
  a response can run until it fills the window.
- **No client sampling:** depends on the server defaults (llama.cpp default:
  temp 0.8, top_k 40, min_p 0.05).
- **Version pace:** 0.163 → 0.165 in 12 days. Keys change (`--full-auto` and
  `approval_policy = "untrusted"` have already been removed); check the config at every version change.
- **Large binary:** ~446 MB.
