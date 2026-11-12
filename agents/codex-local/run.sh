#!/usr/bin/env bash
# Non-interactive Codex CLI with the local model, following the eval contract.
# Usage: agents/codex-local/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# Output in <log-dir>: events.jsonl (codex exec --json), stderr.log (progress),
# last-message.txt, run-meta.json, agent-metrics.json, command.txt,
# config.effective.toml, guard.log (blocks), home/codex (isolated CODEX_HOME,
# with the session in sessions/) and server metrics.
#
# The autonomous profile only runs in the agent-box (AGENT_BOX=1). There the Codex
# sandbox is off (danger-full-access): the container is the barrier. Only with
# AGENT_ALLOW_HOST_AUTONOMOUS=1 (unsafe) does CODEX_LOCAL_SANDBOX=workspace-write
# make sense, which turns on the Codex sandbox (bubblewrap) on the host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
parse_run_args "$@"
source "$HERE/env.sh"
cat "$CODEX_HOME/config.toml" "$CODEX_HOME/$AGENT_PROFILE.config.toml" > "$LOG_DIR/config.effective.toml"

args=(exec --json --color never --cd "$WORKDIR" --skip-git-repo-check
      --output-last-message "$LOG_DIR/last-message.txt"
      "${CODEX_COMMON_ARGS[@]}")
if [ -n "${CODEX_LOCAL_SANDBOX:-}" ]; then
  args+=(--sandbox "$CODEX_LOCAL_SANDBOX")
fi
args+=("$PROMPT")

run_agent codex-local -- "$(agent_bin codex-local codex)" "${args[@]}"
