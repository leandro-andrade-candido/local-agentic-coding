# OpenCode (local)

Goal 1 contender. The closest to Claude Code in features
(subagents, skills, plugins, allow/ask/deny permissions), with the largest
fixed prompt among the open ones (~7.5k tokens).

| Item | Value |
|---|---|
| Pinned version | **1.19.5** (`opencode-ai`, `latest` tag, 2026-10-28) **[verified: npm, GitHub]** |
| License | MIT **[verified: npm, anomalyco/opencode repository]** |
| Executable | `opencode` (native binary; the `postinstall` copies the platform package, ~214 MB) |

## Status of the 2.x line

- **OpenCode 2** came out as another package: `@opencode/cli` (2.2.1 on 2026-10-29),
  with releases v2.0.x to v2.2.1 in the same repository **[verified: npm, GitHub]**.
- `opencode-ai` stays on 1.x and is GitHub's "Latest". Both use the
  `opencode` command and do not coexist on the same PATH; here they coexist because each one
  goes to its own prefix.
- Changes that matter: server API redone, 1.x plugins do not work
  on 2.x, `tui.json` moved into the main JSON, a single background
  service **[verified: anoma.ly/notes/opencode-2-0]**.
- **1.x maintenance:** on 2026-10-11 the maintainers closed the 1.x issues
  with "development is focused on V2" (that is how #24316 became "not planned").
  Bugs found in E6 will probably not be fixed in 1.19.x.
- We stay on 1.19.x by decision of the plan. If OpenCode is the one chosen, migrating
  to 2.x requires redoing `plugins/guard.js` and reviewing the config.

## Installation

```bash
agents/install.sh opencode
# = npm install --global --prefix ~/.local/opt/agents/opencode/1.19.5 opencode-ai@1.19.5
```

Do not use `opencode upgrade` nor the site's `curl ... | bash` script (it installs in
`~/.opencode/bin` and may swap in 2.x).

## Configuration isolation

OpenCode keeps everything in the XDG directories: config in `~/.config/opencode`,
data (SQLite sessions, `auth.json`, logs) in `~/.local/share/opencode`,
cache and state **[verified: packages/core/src/global.ts]**. `env.sh` points
`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` and `XDG_STATE_HOME` at
`<AGENT_HOME>/opencode/*`. Interactive: `~/.local/state/local-agentic/agents/opencode/`;
eval: `<log-dir>/home/opencode/`.

Side effect: the commands the agent runs inherit these variables (`gh`
does not find its login; pip and npm caches go to the isolated directory). The
`~/.gitconfig` is still read.

In addition:

| Variable | Why |
|---|---|
| `OPENCODE_DISABLE_CLAUDE_CODE=1` (host only) | do not read `~/.claude/CLAUDE.md` nor `.claude/skills` (from HOME and from the project) |
| `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` | the built-in plugins are cloud logins (Codex, Copilot, GitLab, Azure, xAI...) |
| `OPENCODE_DISABLE_MODELS_FETCH=1` | do not fetch the models.dev catalog |
| `OPENCODE_DISABLE_AUTOUPDATE=1`, `OPENCODE_DISABLE_LSP_DOWNLOAD=1` | no automatic network |

All appear in `packages/core/src/flag/flag.ts` of tag v1.19.5 and in the CLI
page **[verified]**.
`OPENCODE_DISABLE_PROJECT_CONFIG` is **not** used: besides the repository's `opencode.json`,
it turns off reading the project's `AGENTS.md`.

## Model and server (`opencode.base.json`)

| Setting | Value |
|---|---|
| Provider | `llamacpp`, `npm: @ai-sdk/openai-compatible` (built into the binary), `baseURL: $LLM_BASE_URL/v1` |
| Enabled providers | only `llamacpp` (`enabled_providers`); `small_model` is also the local one |
| Sampling | `temperature` 0.6 and `top_p` 0.95 per agent (build, plan, general, explore, compaction); `top_k` 20, `min_p` 0, `presence_penalty` 0 in `models.<id>.options` |
| Thinking | `reasoning: true`; `interleaved: {field: reasoning_content}` returns the reasoning in the history; `options.chat_template_kwargs.preserve_thinking: true` |
| Window and output | `limit: {context: 131072, output: 32768}`; OpenCode caps the output at 32000 (`OUTPUT_TOKEN_MAX`) |
| Compaction | automatic when the total exceeds context − output = ~99k (`session/overflow.ts`); `prune` off |
| Timeouts | `timeout: false`, `headerTimeout` 30 min, `chunkTimeout` 15 min |
| Title by LLM | `agent.title.disable: true`; in `run`, an explicit `--title` also skips the generation |
| Sharing, update | `share: disabled`, `autoupdate: false` |

Checked in the v1.19.5 code: the model's `options` go to `providerOptions` and
`@ai-sdk/openai-compatible` 2.0.41 copies unknown keys into the request
body; `temperature` is only sent with `capabilities.temperature`;
`top_p` comes from the agent; `interleaved.field` writes the reasoning to the requested field
of each assistant message **[verified: provider/transform.ts, session/llm/request.ts, SDK dist]**.

## Permissions

In OpenCode the **last** matching rule wins; `"*"` comes first. A shell command is
split into simple commands before matching (`curl x | sh` becomes `curl x`
and `sh`), and a pattern without `*` matches the exact command, so `"sh": "deny"` catches
`curl | sh` without blocking `sh script.sh`. Paths cited outside the working
directory trigger `external_directory` **[verified: docs/permissions.mdx, tool/shell.ts]**.

| | interactive (`opencode-local`) | autonomous (`run.sh`: `opencode run --auto`) |
|---|---|---|
| Read | free (`.env` denied, OpenCode default) | same |
| Edit | free in the project; outside it `external_directory: ask` | free in the project; outside it denied, except `/tmp/*` |
| Shell | `"*": ask` | `"*": allow` |
| Denied | `git push`, `sudo`, `su`, `doas`, `sh`/`bash`/`zsh`/`dash` without arguments | the same + network installs |
| Web | `webfetch: ask`, `websearch: deny` | both `deny` |
| Repetition (3 identical calls) | `doom_loop: ask` | `doom_loop: deny` |
| `plugins/guard.js` plugin | `lib/guard.py` on every bash command | same |

`--auto` approves what would be `ask`; `deny` still applies **[verified: docs]**.
The plugin lives in `$XDG_CONFIG_HOME/opencode/plugins/` (link to the repository) and
throws an error in `tool.execute.before` to block **[verified: docs/plugins.mdx]**.

## Skills (AGENT_SKILLS_DIRS)

- **Discovery:** the `AGENT_SKILLS_DIRS` directories go to `skills.paths` (1.x config
  key; each directory is scanned for `**/SKILL.md`) **[verified: core/src/v1/config/skills.ts, skill/index.ts]**.
  The isolated config directory's `skills/`, and the project's `.opencode/skills` and
  `.agents/skills` also apply. `.claude/skills` and `~/.claude/CLAUDE.md` are left out on the
  host (`OPENCODE_DISABLE_CLAUDE_CODE=1`); in the agent-box (empty HOME) they apply.
  `OPENCODE_DISABLE_EXTERNAL_SKILLS` was dropped: it also turned off the project's `.agents/skills`.
- **On demand:** the native `skill` tool lists name and description and loads the body
  when called.
- **Explicit call:** ask in the prompt "use the skill tool to load <name>"
  (which is what the Superpowers doc for OpenCode indicates).
- **Superpowers bootstrap:** `plugins/skills-bootstrap.js` plugin, with the same hook
  as the official plugin for 1.x (`experimental.chat.messages.transform`, bootstrap at the
  start of the first user message, skipping subagents).
- **Tool map:** the official plugin's (V1), with one fix: for non-GPT models
  OpenCode offers `edit`/`write`, not `apply_patch`
  (`tool/registry.ts`), so the map says `write`/`edit`.
- **Unverified (E6):** plugin loaded without network; skill loaded by the model.

> **Autonomous profile only in the agent-box.** `run.sh` refuses `AGENT_PROFILE=autonomous`
> outside the E7 container (which sets `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> forces it on the host and is unsafe. The agent's environment is clean (`env -i` + allowlist)
> and the llama-server key comes from `LLM_API_KEY` or the E5 file
> (see `agents/README.md`).

## Non-interactive use

```bash
agents/opencode/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# runs: opencode run --format json --model llamacpp/qwen3.6-35b --dir <dir> \
#            --title "eval ..." --print-logs --log-level INFO --auto <prompt>
```

`--format json` emits the raw events (text parts, reasoning, tools,
`step_finish` with `tokens`); OpenCode logs go to `stderr.log`. Exit ≠ 0
when the session ends with an error **[verified: cli/cmd/run.ts]**.

## Measuring the preamble

`agents/measure-preamble.sh opencode`: the `tokens.input` of the first `step_finish`
and the server's `/metrics`. OpenCode does not record the request body; to
see the system prompt, use `llama-server --verbose` (or `-lv 4`) during the measurement.

## Known problems with Qwen3.6 + llama.cpp

- **#24316** (closed as "not planned" on 2026-10-11, in the mass closing
  of 1.x): the model writes `<tool_call>...` inside the reasoning, the TUI shows the
  raw XML and the session stops. Reported from 1.14.x to 1.18.23, with llama.cpp, vLLM and Ollama.
  - The Qwen3 parser in llama.cpp b11982 already treats `<tool_call>` as the end of the
    reasoning (`common/parsers/qwen3-coder.cpp`), the same fix as Ollama's
    (PR #15022) **[verified: code]**. It should be enough; reproduce in E6.
  - Reported mitigations: `preserve_thinking` (here: b11982 server default +
    `interleaved`), larger max output (32k), code temperature (0.6).
  - PR #27984 (remove stray XML tags from the text) was closed without merging.
  - Last resort: a template with the tweak cited in the issue (move `<tool_call>`
    from `reasoning_content` to `content`).

## Test first in E6 (unverified)

- The generated config passes validation (`opencode debug config` with the same variables).
- `run` honors `--auto` + `deny` and `--title` avoids the title call (count requests in `/metrics`).
- The plugin loads with `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` and blocks `git push`.
- `options` reach the server (`top_k`, `min_p`, `chat_template_kwargs`) and the agent's temperature is applied (`llama-server --verbose`).
- #24316 symptom over 3 tasks: count `<tool_call>` in text/reasoning in the events.
- `external_directory` with `/tmp/*` allowed does not get in the way of tests that use `/tmp`.
