# shellcheck shell=bash
# Claude Code environment pointed at the local llama-server (sourced by run.sh and
# claude-local, after lib/common.sh). Requires AGENT_HOME to be set.
# Nothing here reads or writes ~/.claude or ~/.claude.json: CLAUDE_CONFIG_DIR moves
# settings, sessions, plugins, credentials and .claude.json to another directory.
# Variables checked at code.claude.com/docs/en/env-vars (2026-10-29).

keep CLAUDE_CONFIG_DIR="$AGENT_HOME/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"

# The user's account credentials and providers must not leak into this session
# (run.sh and the launcher also clean the environment; this covers the script itself).
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_BETAS \
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
  ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL

# Backend: the llama-server Anthropic /v1/messages endpoint. The server key
# (LLM_API_KEY, see lib/common.sh) goes in the Authorization: Bearer header.
keep ANTHROPIC_BASE_URL="$LLM_BASE_URL"
keep ANTHROPIC_AUTH_TOKEN="$LOCAL_LLM_API_KEY"

# Every model role points at the local alias: main, opus/sonnet/haiku aliases
# (haiku also does the background tasks), subagents.
keep ANTHROPIC_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_OPUS_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_SONNET_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_HAIKU_MODEL="$LLM_MODEL"
keep CLAUDE_CODE_SUBAGENT_MODEL="$LLM_MODEL"

# Window and output: the ID does not start with "claude-", so the value stands on its own.
keep CLAUDE_CODE_MAX_CONTEXT_TOKENS="$LLM_CONTEXT"
# For an unknown ID the default is already 32000; made explicit. Raising it reduces the usable window before compaction.
keep CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000

# Non-essential traffic, telemetry, error reports, updates, surveys.
keep CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
keep DISABLE_TELEMETRY=1
keep DISABLE_ERROR_REPORTING=1
keep DISABLE_AUTOUPDATER=1
keep DISABLE_UPDATES=1
keep CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
# The fast mode check calls api.anthropic.com directly (the WebFetch one goes away via skipWebFetchPreflight).
keep CLAUDE_CODE_DISABLE_FAST_MODE=1

# llama-server compatibility: no pre-release betas (context_management,
# strict/defer_loading, output_config.format, task_budget, tool search) and no
# effort level (output_config.effort).
keep CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
keep CLAUDE_CODE_EFFORT_LEVEL=unset
# Attribution block at the start of the system prompt: since 2.1.181 it is stable within
# a conversation, but carries a per-conversation fingerprint; without it the prefix is
# identical across runs and the llama-server prompt cache (--cache-ram) is reused.
keep CLAUDE_CODE_ATTRIBUTION_HEADER=0

# No automatic memory or background tasks (each extra call competes for the single slot).
keep CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
keep CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1

# Long prefill: the server sends no byte until the first token.
keep API_TIMEOUT_MS=1800000
keep API_FORCE_IDLE_TIMEOUT=0
keep CLAUDE_STREAM_IDLE_TIMEOUT_MS=1800000

# Sampling from the model card. llama.cpp's /v1/messages forwards temperature,
# top_p, top_k and chat_template_kwargs; the rest goes in extra_params.
# [unverified] whether Claude Code sends its own temperature and which value wins in the merge.
keep CLAUDE_CODE_EXTRA_BODY='{"temperature":0.6,"top_p":0.95,"top_k":20,"chat_template_kwargs":{"preserve_thinking":true},"extra_params":{"min_p":0,"presence_penalty":0}}'

# Skills: copied to $CLAUDE_CONFIG_DIR/skills (personal skills of the isolated
# directory); Superpowers bootstrap in a SessionStart hook, like the official plugin's.
setup_skills claude-local
python3 -I "$AGENTS_DIR/lib/skills.py" copy "$CLAUDE_CONFIG_DIR/skills"
claude_extra=()
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  claude_extra+=("$AGENTS_DIR/claude-local/settings.skills-bootstrap.json")
fi
render "$CLAUDE_CONFIG_DIR/settings.json" \
  "$AGENTS_DIR/claude-local/settings.base.json" \
  "$AGENTS_DIR/claude-local/settings.$AGENT_PROFILE.json" "${claude_extra[@]}"

# Lean tool set (reduces the ~25-31 thousand token preamble).
# Glob and Grep are already left out of the default on Linux; search uses find/grep via Bash.
# With skills, the Skill tool is added (without it the model cannot load skills).
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  CLAUDE_LOCAL_TOOLS="${CLAUDE_LOCAL_TOOLS:-Bash,Read,Edit,Write,Skill}"
else
  CLAUDE_LOCAL_TOOLS="${CLAUDE_LOCAL_TOOLS:-Bash,Read,Edit,Write}"
fi
