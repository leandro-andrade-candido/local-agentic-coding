# Claude Code with the local model (claude-local)

Since Oct 29 it competes for Goal 1 alongside the open agents (in a technical tie,
the open one wins). It is Claude Code pointed at the llama-server's Anthropic
endpoint (`/v1/messages`). Anthropic does not support non-Claude models; everything
here is documented gateway configuration, but the behavior with Qwen3.6 is only
shown by E6.

| Item | Value |
|---|---|
| Pinned version | **2.1.308** (`@anthropic-ai/claude-code`, npm `stable` channel, 2026-10-22) **[verified: npm]** |
| Alternative | `latest` = 2.1.312 (Oct 27). The everyday Claude Code (2.1.311) is neither used nor changed |
| License | Proprietary ("© Anthropic PBC. All rights reserved"; terms at code.claude.com/docs/en/legal-and-compliance) |
| Executable | `claude` (native binary of ~292 MB, copied by the platform package's `postinstall`) |

## Installation

```bash
agents/install.sh claude-local
# = npm install --global --prefix ~/.local/opt/agents/claude-local/2.1.308 @anthropic-ai/claude-code@2.1.308
```

The `postinstall` (`install.cjs`) only links or copies the platform binary inside
`node_modules`; it does not write to `~/.claude` or `~/.local/bin` **[verified: tarball]**.
To reuse the already installed binary instead of downloading another:
`AGENT_BIN="$(command -v claude)" agents/claude-local/claude-local` (the version
then follows the everyday one, which updates itself).

## Configuration isolation

`CLAUDE_CONFIG_DIR` moves settings, sessions, plugins, credentials **and
`.claude.json`** to another directory **[verified: docs env-vars and claude-directory]**.

- Interactive: `~/.local/state/local-agentic/agents/claude-local/claude`.
- Eval: `<log-dir>/home/claude` (JSONL transcript in `projects/`).
- `env.sh` also removes `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`
  and the Bedrock/Vertex/Foundry selections from the environment, so the user's account does not leak
  to the local server nor the local session fall back to the cloud.
- `~/.claude` and `~/.claude.json` are not read: the personal `CLAUDE.md` and the everyday
  plugins stay out. The project's `CLAUDE.md`/`AGENTS.md` still applies.

## Variables (`env.sh`)

All checked on the variables page (code.claude.com/docs/en/env-vars) on 2026-10-29.

| Variable | Value | Purpose |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `$LLM_BASE_URL` (without `/v1`) | llama-server's Anthropic endpoint |
| `ANTHROPIC_AUTH_TOKEN` | llama-server key (`LLM_API_KEY`) | sent as `Authorization: Bearer`; the server requires the key on every route (E5) |
| `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_MODEL` | `qwen3.6-35b` | main model |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`, `_SONNET_`, `_HAIKU_` | same | aliases; haiku also does the background tasks |
| `CLAUDE_CODE_SUBAGENT_MODEL` | same | subagents and workflow agents |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | 131072 | assumed window; without it an unknown ID counts as 200k and compaction goes past the server limit. It applies on its own because the ID does not start with `claude-` |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | 32000 | default for an unknown ID, made explicit |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | 1 | updates, telemetry, error reports, feature flags, release notes |
| `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` | 1 | redundant with the previous one, explicit |
| `DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` | 1 | fixed version |
| `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` | 1 | no quality survey |
| `CLAUDE_CODE_DISABLE_FAST_MODE` | 1 | the fast mode check calls `api.anthropic.com` directly, ignoring `BASE_URL` |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | 1 | removes `context_management`, `strict`/`defer_loading`, `output_config.format`, `task_budget` and tool search, which llama.cpp does not know |
| `CLAUDE_CODE_EFFORT_LEVEL` | `unset` | does not send `output_config.effort` |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | 0 | removes the attribution block from the start of the system prompt (see below) |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY` | 1 | no automatic memory |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` | 1 | no background tasks competing for the single slot |
| `API_TIMEOUT_MS` | 1800000 | wait for the headers; the ~100k-token prefill takes minutes |
| `API_FORCE_IDLE_TIMEOUT` | 0 | turns off the 5-minute cut with no bytes |
| `CLAUDE_STREAM_IDLE_TIMEOUT_MS` | 1800000 | stream watchdogs (30-minute cap) |
| `CLAUDE_CODE_EXTRA_BODY` | temperature 0.6, top_p 0.95, top_k 20, `chat_template_kwargs.preserve_thinking`, `extra_params: {min_p: 0, presence_penalty: 0}` | sampling from the model card; llama.cpp's `/v1/messages` forwards `temperature`, `top_p`, `top_k`, `chat_template_kwargs` and the `extra_params` object **[verified: server-chat.cpp b11982]** |

Left out on purpose: `DISABLE_NON_ESSENTIAL_MODEL_CALLS` (does not exist in the
current documentation) and `DISABLE_PROMPT_CACHING` (only affects `cache_control`
markers, which llama.cpp ignores).

**Attribution block:** Claude Code puts a block at the start of the system prompt with
the version and a conversation fingerprint. Since 2.1.181 it is stable within
the conversation when `ANTHROPIC_BASE_URL` is set, so the cache from one turn to the next
works even with it. With `0`, the prefix is also identical **across** runs and the
llama-server's `--cache-ram` reuses the preamble from one task to the next
**[verified: docs llm-gateway-protocol, "System prompt attribution block"]**.

## Lean preamble

| Measure | Effect |
|---|---|
| `--tools "Bash,Read,Edit,Write"` (`CLAUDE_LOCAL_TOOLS`) | only the essential tools. Without `Agent` there are no subagents; Glob/Grep are already left out of the default on Linux (search via `find`/`grep` in Bash); the task tools do not come for unknown IDs |
| `--exclude-dynamic-system-prompt-sections` | per-user/machine context leaves the system prompt and goes into the first message |
| `--setting-sources user` | only the isolated directory's `settings.json`; the repository's hooks and permissions do not load |
| `CLAUDE_LOCAL_BARE=1` → `--bare` | minimal prompt, only Bash/read/edit, no hooks, skills, CLAUDE.md or system reminders. **Unverified** with `ANTHROPIC_AUTH_TOKEN` (the doc mentions `ANTHROPIC_API_KEY` or `apiKeyHelper`) |

The ~25–31k tokens in the plan are for the full set; the size with the
lean set is the first measurement of E6.

## Permissions

`settings.json` file generated in `CLAUDE_CONFIG_DIR` (user scope).
`deny` rules apply in all modes, including `bypassPermissions`; the `PreToolUse`
hook that exits with code 2 blocks before the rules
**[verified: docs permissions and permission-modes]**. A `Bash(...)` rule without `*`
matches the exact command and compound commands are split, so `Bash(sh)` catches the
`sh` of `curl ... | sh`.

| | interactive (`claude-local`) | autonomous (`run.sh`) |
|---|---|---|
| Mode | `acceptEdits`: edits and common file commands in the working directory without asking; Bash asks | `--permission-mode bypassPermissions` (requires a non-root user) |
| Denied | WebSearch, `git push`, `sudo`, `su`, `doas`, `sh`/`bash`/`zsh`/`dash` without arguments, `rm -rf /`, `~`, `$HOME` | the same + WebFetch + network installs |
| Asks | WebFetch | — |
| Hook | `lib/guard.py` on every Bash | same |

We only use keys and types checked against `settings-reference`: a value of the wrong
type makes Claude Code ignore the whole file, and the permissions with it.

## Skills (AGENT_SKILLS_DIRS)

- **Discovery:** the skill folders are copied to `$CLAUDE_CONFIG_DIR/skills`
  (personal skills of the isolated directory). The project's `.claude/skills` still applies.
  With skills, `Skill` is added to `--tools` (without it the model cannot load skills).
- **On demand:** only name and description in the prompt; the `Skill` tool loads the body.
- **Explicit call:** `/skill-name`.
- **Superpowers bootstrap:** `SessionStart` hook (`startup|clear|compact`) with
  `hookSpecificOutput.additionalContext`, same as the official plugin's hook
  (`hooks/session-start`), with `using-superpowers` and `references/claude-code-tools.md`.
- `--bare` (`CLAUDE_LOCAL_BARE=1`) turns off skills and hooks.
- **Unverified (E6):** the hook runs with `--setting-sources user` in `-p`; the local
  model uses the `Skill` tool.

> **Autonomous profile only in the agent-box.** `run.sh` refuses `AGENT_PROFILE=autonomous`
> outside the E7 container (which sets `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> forces it on the host and is unsafe. The agent's environment is clean (`env -i` + allowlist)
> and the llama-server key comes from `LLM_API_KEY` or the E5 file
> (see `agents/README.md`).

## Non-interactive use

```bash
agents/claude-local/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# runs: claude -p --output-format stream-json --verbose --model qwen3.6-35b \
#   --tools Bash,Read,Edit,Write --setting-sources user \
#   --exclude-dynamic-system-prompt-sections --permission-mode bypassPermissions <prompt>
```

Exit 0 on success and non-zero on failure; denials show up as
`permission_denied` in the stream and in `permission_denials` in the final result
**[verified: docs headless]**.

## Measuring the preamble

`agents/measure-preamble.sh claude-local`: the `usage` of the assistant's first message in the
stream (`input_tokens` + `cache_read_input_tokens`; in llama.cpp
`input_tokens` is only the part not reused from the cache) and `/metrics`.

## Risks with a local backend

- **Thinking:** for an unknown ID Claude Code sends the adaptive thinking format.
  llama.cpp only converts `thinking.type == "enabled"` (it becomes a limit on reasoning
  tokens); the adaptive one is ignored and the model thinks without limit, the
  template default. With `MAX_THINKING_TOKENS` Claude Code would start sending
  a budget, and llama.cpp would cut the reasoning at it.
- **Preserve thinking:** the `thinking` blocks come back in the history and llama.cpp
  converts them to `reasoning_content`; the b11982 server already turns on `preserve_reasoning`
  by default. Whether the prefix matches across turns remains to be measured.
- **Features that depend on Anthropic** do not work: WebSearch, fast mode,
  artifacts, remote control, push notifications, the `auto` mode classifier.
- **Background calls** (summaries, titles, checks) use the main model and
  compete for the single slot; the lean set reduces them but does not zero them.

## Test first in E6 (unverified)

- Full round trip on `/v1/messages`: `tool_use`, `tool_result`, `thinking` blocks
  without signature, `count_tokens`.
- Whether Claude Code sends its own `temperature` and which value wins in the merge with
  `CLAUDE_CODE_EXTRA_BODY` (see the slot's parameters line with `llama-server --verbose`).
- Real compaction threshold with window 131072 and output 32000 (`/context` in interactive mode).
- Preamble size with `--tools Bash,Read,Edit,Write` and with `--bare`.
- A second identical run reuses the preamble (high `cache_read_input_tokens`).
- First interactive use with a new `CLAUDE_CONFIG_DIR`: welcome screens and theme.
- Startup traffic (`HEAD /api/hello`) gets a 404 from llama-server with no effect.
