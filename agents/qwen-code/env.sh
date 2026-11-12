# shellcheck shell=bash
# Local Qwen Code environment (sourced by run.sh and qwen-local, after lib/common.sh).
# Requires AGENT_HOME to be set. Nothing here reads or writes ~/.qwen.

# Isolated global directory: settings, credentials, sessions, memory, logs.
keep QWEN_HOME="$AGENT_HOME/qwen"
mkdir -p "$QWEN_HOME"

# Telemetry and usage statistics: any value other than true/1 turns them off.
keep QWEN_USAGE_STATISTICS_ENABLED=0
keep QWEN_TELEMETRY_ENABLED=0
# No models.dev catalog (nor daily download): window and output come from the config.
keep QWEN_CODE_MODELS_DEV=off
keep QWEN_CODE_MODELS_DEV_REFRESH=off
# No stream lifetime limit (default 15 min); 32k tokens at ~35 tok/s already exceed that.
keep QWEN_STREAM_MAX_LIFETIME_MS=0
# Automatic title only runs with fastModel; also turned off by variable. [unverified: design doc only]
keep QWEN_DISABLE_AUTO_TITLE=1
# YOLO-without-sandbox warning: isolation comes from the container (E7).
keep QWEN_CODE_SUPPRESS_YOLO_WARNING=1

# Skills: AGENT_SKILLS_DIRS directories in skills.directories (read at the
# "user" level, one level below each directory) and the Superpowers bootstrap in a
# SessionStart hook (additionalContext), like the Claude Code hook.
setup_skills qwen-code
qwen_extra=()
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  python3 -I "$AGENTS_DIR/lib/skills.py" overlay "$AGENT_HOME/qwen-skills.json" directories
  qwen_extra+=("$AGENT_HOME/qwen-skills.json")
fi
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  qwen_extra+=("$AGENTS_DIR/qwen-code/settings.skills-bootstrap.json")
fi
render "$QWEN_HOME/settings.json" \
  "$AGENTS_DIR/qwen-code/settings.base.json" \
  "$AGENTS_DIR/qwen-code/settings.$AGENT_PROFILE.json" "${qwen_extra[@]}"
