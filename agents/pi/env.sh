# shellcheck shell=bash
# Local Pi environment (sourced by run.sh and pi-local, after lib/common.sh).
# Requires AGENT_HOME to be set. Nothing here reads or writes ~/.pi.

# Isolated agent directory: models.json, settings.json, auth.json, trust.json, sessions.
keep PI_CODING_AGENT_DIR="$AGENT_HOME/pi"
mkdir -p "$PI_CODING_AGENT_DIR"
# No automatic network activity (model catalog), no version check,
# no install telemetry and no attribution headers.
keep PI_OFFLINE=1
keep PI_SKIP_VERSION_CHECK=1
keep PI_TELEMETRY=0

render "$PI_CODING_AGENT_DIR/models.json" "$AGENTS_DIR/pi/models.json"
render "$PI_CODING_AGENT_DIR/settings.json" \
  "$AGENTS_DIR/pi/settings.base.json" \
  "$AGENTS_DIR/pi/settings.$AGENT_PROFILE.json"

PI_EXT_ARGS=(-e "$AGENTS_DIR/pi/extensions/guard.ts")
# Skills: the skills.ts extension hands AGENT_SKILLS_RESOLVED to Pi
# (resources_discover) and injects the Superpowers bootstrap (context event),
# like the official .pi/extensions/superpowers.ts extension.
setup_skills pi
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  PI_EXT_ARGS+=(-e "$AGENTS_DIR/pi/extensions/skills.ts")
fi
if [ "${AGENT_LOG_REQUESTS:-0}" = 1 ]; then
  keep AGENT_REQUEST_LOG="$AGENT_LOG_DIR/requests.jsonl"
  PI_EXT_ARGS+=(-e "$AGENTS_DIR/pi/extensions/request-log.ts")
fi
