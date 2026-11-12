# Pi (local)

Goal 1 contender. Minimal agent (4 tools, ~1.4k-token prompt),
extensible in TypeScript, first place on harness-bench with local
models. It has no permissions or sandbox: the real isolation is the E7 container.

| Item | Value |
|---|---|
| Pinned version | **1.4.0** (`@earendil-works/pi-coding-agent`, `latest` tag, 2026-10-21) **[verified: npm]** |
| Former name | `@mariozechner/pi-coding-agent` (stalled at 0.73.1); the repository moved to `earendil-works/pi` |
| License | MIT **[verified: LICENSE and npm]** |
| Requirement | Node ≥ 22.19 (here: 24.21) |
| Size | ~23 MB, plus `@earendil-works/pi-*` dependencies |
| Executable | `pi` |

## Installation

```bash
agents/install.sh pi
# = npm install --global --prefix ~/.local/opt/agents/pi/1.4.0 @earendil-works/pi-coding-agent@1.4.0
```

Do not use `pi update` (it updates Pi itself); change the version in `agents/versions.env`.

## Configuration isolation

- `PI_CODING_AGENT_DIR` changes the agent directory (default `~/.pi/agent`):
  `models.json`, `settings.json`, `auth.json`, `trust.json`, sessions **[verified: docs/environment-variables.md]**.
- Interactive: `~/.local/state/local-agentic/agents/pi/pi`. Eval: `<log-dir>/home/pi`.
- `models.json` and `settings.json` are regenerated at every start.
- Still in effect: `AGENTS.md`/`CLAUDE.md` of the directory and its ancestors (always,
  even without project trust) and the project's `.pi/` if it is trusted. The
  eval uses `--no-approve` and `defaultProjectTrust: never`, which ignore `.pi/`.

## Files

| File | Role |
|---|---|
| `models.json` | `local` provider (llama-server, `openai-completions`) and the model |
| `settings.base.json` | Default model, thinking, compaction, timeouts, telemetry, built-in extensions |
| `settings.interactive.json` / `settings.autonomous.json` | Trust in the project's `.pi/` |
| `extensions/guard.ts` | Permissions (Pi has none): blocklist, shell asks, writing outside the project |
| `extensions/request-log.ts` | Records each request (`AGENT_LOG_REQUESTS=1`) |
| `env.sh`, `run.sh`, `pi-local` | Environment, eval contract, interactive launcher |

## Model and server

Pi's built-in `llama.cpp` provider requires the llama-server **router mode**
(server started without `-m`) **[verified: docs/llama-cpp.md]**. Our server
runs with a fixed model, so the provider is declared in `models.json` as a
compatible endpoint, and the built-in one is turned off (`-builtin:llama.cpp`). It
would also try `http://127.0.0.1:8080`, which here is already used by another local service.

| Setting | Value | Field |
|---|---|---|
| Endpoint | `$LLM_BASE_URL/v1`, `api: openai-completions` | `providers.local` |
| Key | `$LOCAL_LLM_API_KEY` (Pi interpolates `$NAME`) | `apiKey` |
| Thinking | `thinkingFormat: qwen-chat-template`: sends `chat_template_kwargs.enable_thinking` and `preserve_thinking: true` | `compat` |
| `developer` role | off (`supportsDeveloperRole: false`, uses `system`; see issue #10741) | `compat` |
| Sampling | temperature 0.6, top_p 0.95, top_k 20, min_p 0, presence_penalty 0 (merged into the body) | `samplingParams` |
| Max output | 32768 | `maxTokens` |
| Window | 131072 | `contextWindow` |
| Compaction | when < 32768 remain free (~98k used); keeps 20k recent | `compaction.reserveTokens`, `keepRecentTokens` |
| Timeouts | 15 min without bytes | `httpIdleTimeoutMs: 900000` |
| Cache warming | off (extra requests) | `cacheWarming: off` |

Fields checked in `docs/models-configuration.md` and `docs/settings.md` of tag
v1.4.0 **[verified]**. In the code (`pi-ai/src/api/openai-completions.ts`), the
`qwen-chat-template` format sends `enable_thinking` according to the thinking level
(the eval uses `--thinking medium`, which only turns thinking on) and `preserve_thinking: true`,
and the reasoning goes back in the history through the same field it arrived in
(`reasoning_content` in llama.cpp) **[verified: code]**.

## Telemetry and network

`PI_OFFLINE=1` (no automatic update of the model catalog),
`PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY=0`, `enableInstallTelemetry: false`,
`enableAnalytics: false` **[verified: docs]**. Built-in extensions turned off:
`builtin:mcp` and `builtin:llama.cpp`. `codemode` and `tool_search` exist but stay
inactive (outside `defaultTools`). Pi has no web search.

## Permissions (`guard.ts` extension)

| | interactive (`pi-local`) | autonomous (`run.sh`, or without a UI) |
|---|---|---|
| Read | free | free |
| `write`/`edit` in the project | free | free |
| `write`/`edit` outside the project | asks | blocked |
| `bash` | goes through the guard; commands that are not simple reads (`ls`, `cat`, `rg`, `git status/diff/log`...) ask | goes through the guard |
| Blocked (best effort) | `lib/guard.py`: patterns of `git push`, `sudo`, `curl \| sh`, `rm` outside the project | the same + network installs |

The extension uses the `tool_call` event and returns `{ block: true, reason }`; the
confirmation uses `ctx.ui.confirm` **[verified: types in core/extensions/types.ts]**.
If the guard is missing or fails, the command is blocked.

## Skills (AGENT_SKILLS_DIRS)

- **Discovery:** the `extensions/skills.ts` extension returns the
  `AGENT_SKILLS_DIRS` directories in the `resources_discover` event (same mechanism as the
  official Superpowers extension `.pi/extensions/superpowers.ts`) **[verified: 1.4 types]**.
  Pi also reads the project's `.agents/skills` and `~/.agents/skills`.
- **On demand:** only name and description in the prompt; the model reads the `SKILL.md` with `read`
  when the task calls for it **[verified: docs skills.md]**.
- **Explicit call:** `/skill:name` (arguments after the name become the request).
- **Superpowers bootstrap:** the same extension inserts `using-superpowers` + the map
  (`pi/superpowers-tools.md`, the official extension's text) as the first user
  message in the `context` event, at the start and after compaction.
- **Unverified (E6):** loading of `-e skills.ts` in `--mode json`; the model reads the
  `SKILL.md` by itself.

> **Autonomous profile only in the agent-box.** `run.sh` refuses `AGENT_PROFILE=autonomous`
> outside the E7 container (which sets `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> forces it on the host and is unsafe. The agent's environment is clean (`env -i` + allowlist)
> and the llama-server key comes from `LLM_API_KEY` or the E5 file
> (see `agents/README.md`).

## Non-interactive use

```bash
agents/pi/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# runs: pi --mode json --provider local --model qwen3.6-35b --thinking medium \
#             --no-approve -e agents/pi/extensions/guard.ts <prompt>
```

`--mode json` writes JSONL: session header, `agent_start`, `turn_*`,
`message_*` (with `usage`), `tool_*`, `agent_end`, `agent_settled`, and exits
**[verified: docs/json.md]**. The full session stays in `home/pi/sessions/`.

## Measuring the preamble

`agents/measure-preamble.sh pi`: `requests.jsonl` keeps the exact body of each
request (`request-log.ts` extension, `before_provider_request` event); the
`usage` of the assistant's first `message_end` gives the tokens.

## Known problems with Qwen3.6 + llama.cpp

- No Qwen3.6-specific report in Pi's repository up to Oct 29. Related:
  #10741 (open: Pi sends the `developer` role and some servers refuse it;
  mitigated with `supportsDeveloperRole: false`) and #10522 (built-in llama.cpp
  login, which we do not use).
- No permissions or plan mode: everything depends on the extension and the container.

## Test first in E6 (unverified)

- `models.json` and `settings.json` accepted without error (`pi --list-models local`).
- The request goes out with `chat_template_kwargs` and the `samplingParams` (see `requests.jsonl`).
- Loading the extension with `-e` outside a package: the `import type` must be
  erased by the loader (jiti) without resolving `@earendil-works/pi-coding-agent`.
- `ctx.ui.confirm` in the TUI and the block without a UI (`--mode json`).
- Exit code of `pi --mode json` when the model fails or the server goes down.
- Cache reuse across turns (`cached_tokens` in `usage`).
