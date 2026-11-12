# shellcheck shell=bash
# Local OpenCode 1.x environment (sourced by run.sh and opencode-local, after lib/common.sh).
# Requires AGENT_HOME to be set. Nothing here reads or writes ~/.config/opencode, ~/.local/share/opencode,
# ~/.cache/opencode or ~/.claude.

# OpenCode keeps config, data (sessions, auth.json, logs), cache and state in the
# XDG directories: pointing them at AGENT_HOME isolates everything. It only applies
# to the OpenCode process and its children (commands the agent runs inherit it too).
keep XDG_CONFIG_HOME="$AGENT_HOME/opencode/config"
keep XDG_DATA_HOME="$AGENT_HOME/opencode/data"
keep XDG_CACHE_HOME="$AGENT_HOME/opencode/cache"
keep XDG_STATE_HOME="$AGENT_HOME/opencode/state"
mkdir -p "$XDG_CONFIG_HOME/opencode/plugins" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

keep OPENCODE_DISABLE_AUTOUPDATE=1
# Do not fetch the models.dev catalog: the local provider is entirely in the config.
keep OPENCODE_DISABLE_MODELS_FETCH=1
keep OPENCODE_DISABLE_LSP_DOWNLOAD=1
# Do not read ~/.claude/CLAUDE.md nor skills from ~/.claude and ~/.agents.
# Skills and instructions from ~/.claude (CLAUDE.md, personal Claude Code skills) are
# left out on the host. Project skills (.agents/skills) still apply; on the host
# that includes ~/.agents/skills (currently without skills). In the agent-box HOME is
# empty and the project's .claude/skills also apply.
if [ "${AGENT_BOX:-0}" != 1 ]; then
  keep OPENCODE_DISABLE_CLAUDE_CODE=1
fi
# The built-in plugins are all cloud logins (Codex, Copilot, GitLab, Azure...).
keep OPENCODE_DISABLE_DEFAULT_PLUGINS=1
keep OPENCODE_DISABLE_TERMINAL_TITLE=1

# Skills: AGENT_SKILLS_DIRS in skills.paths; Superpowers bootstrap via the
# skills-bootstrap.js plugin (same mechanism as the official 1.x plugin).
setup_skills opencode
oc_extra=()
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  python3 -I "$AGENTS_DIR/lib/skills.py" overlay "$AGENT_HOME/opencode-skills.json" paths
  oc_extra+=("$AGENT_HOME/opencode-skills.json")
fi
render "$XDG_CONFIG_HOME/opencode/opencode.json" \
  "$AGENTS_DIR/opencode/opencode.base.json" \
  "$AGENTS_DIR/opencode/opencode.$AGENT_PROFILE.json" "${oc_extra[@]}"
ln -sfn "$AGENTS_DIR/opencode/plugins/guard.js" "$XDG_CONFIG_HOME/opencode/plugins/guard.js"
rm -f "$XDG_CONFIG_HOME/opencode/plugins/skills-bootstrap.js"
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  ln -sfn "$AGENTS_DIR/opencode/plugins/skills-bootstrap.js" "$XDG_CONFIG_HOME/opencode/plugins/skills-bootstrap.js"
fi
