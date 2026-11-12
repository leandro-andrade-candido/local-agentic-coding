# shellcheck shell=bash
# Codex CLI environment pointed at the local llama-server (sourced by run.sh and
# codex-local, after lib/common.sh). Requires AGENT_HOME to be set.
# Nothing here reads or writes ~/.codex (where the everyday ChatGPT login lives):
# CODEX_HOME moves config, auth, rules, sessions, logs and state elsewhere.

keep CODEX_HOME="$AGENT_HOME/codex"
mkdir -p "$CODEX_HOME/rules"

# OpenAI credentials must not reach this session (nor the local server);
# run.sh and the launcher also clean the environment.
unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL OPENAI_ORG_ID OPENAI_PROJECT_ID

# Automatic compaction at 75% of the window.
keep CODEX_AUTO_COMPACT=$(( LLM_CONTEXT * 3 / 4 ))

render "$CODEX_HOME/config.toml" "$AGENTS_DIR/codex-local/config.base.toml"

# Skills: copied to $CODEX_HOME/skills (the "user" location Codex 0.165 still reads;
# the current doc cites ~/.agents/skills, which lives in the real HOME). Superpowers
# bootstrap in developer_instructions (top-level key, inserted at the start of config.toml).
setup_skills codex-local
python3 -I "$AGENTS_DIR/lib/skills.py" copy "$CODEX_HOME/skills"
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  python3 -I -c 'import json, sys
cfg, boot = sys.argv[1], sys.argv[2]
text = open(cfg, encoding="utf-8").read()
line = "developer_instructions = " + json.dumps(open(boot, encoding="utf-8").read()) + "\n"
open(cfg, "w", encoding="utf-8").write(line + text)' "$CODEX_HOME/config.toml" "$AGENT_SKILLS_BOOTSTRAP_FILE"
fi
# Native Codex profiles: --profile <name> overlays $CODEX_HOME/<name>.config.toml.
cp "$AGENTS_DIR/codex-local/interactive.config.toml" "$CODEX_HOME/interactive.config.toml"
cp "$AGENTS_DIR/codex-local/autonomous.config.toml" "$CODEX_HOME/autonomous.config.toml"
# Execution rules: base in both profiles, installs blocked only in autonomous.
# The name local.rules leaves default.rules (the TUI's "always" approvals) intact.
if [ "$AGENT_PROFILE" = autonomous ]; then
  render "$CODEX_HOME/rules/local.rules" \
    "$AGENTS_DIR/codex-local/rules/base.rules" "$AGENTS_DIR/codex-local/rules/autonomous.rules"
else
  render "$CODEX_HOME/rules/local.rules" "$AGENTS_DIR/codex-local/rules/base.rules"
fi

# --dangerously-bypass-hook-trust: Codex only runs unmanaged hooks after
# "trusting" their hash; the only hook is the guard generated above.
CODEX_COMMON_ARGS=(--profile "$AGENT_PROFILE" --model "$LLM_MODEL" --dangerously-bypass-hook-trust)
