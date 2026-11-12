#!/usr/bin/env bash
# Non-interactive Claude Code with the local model, following the eval contract.
# Usage: agents/claude-local/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# Output in <log-dir>: events.jsonl (stream-json), stderr.log, run-meta.json,
# command.txt, settings.effective.json, guard.log (blocks), home/claude
# (isolated CLAUDE_CONFIG_DIR, with the JSONL transcript in projects/) and metrics.
#
# CLAUDE_LOCAL_TOOLS changes the tool set (default Bash,Read,Edit,Write;
# "default" = Claude Code's full set). CLAUDE_LOCAL_BARE=1 uses --bare
# (minimal prompt, no hooks/skills/CLAUDE.md discovered) [unverified with
# ANTHROPIC_AUTH_TOKEN].
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
parse_run_args "$@"
source "$HERE/env.sh"
cp "$CLAUDE_CONFIG_DIR/settings.json" "$LOG_DIR/settings.effective.json"

args=(-p --output-format stream-json --verbose
      --model "$LLM_MODEL"
      --tools "$CLAUDE_LOCAL_TOOLS"
      # Only the settings.json from CLAUDE_CONFIG_DIR: the repository's hooks and permissions do not load.
      --setting-sources user
      # Per-user/machine context is removed from the system prompt: identical prefix across runs.
      --exclude-dynamic-system-prompt-sections)
if [ "$AGENT_PROFILE" = autonomous ]; then
  args+=(--permission-mode bypassPermissions)
fi
if [ "${CLAUDE_LOCAL_BARE:-0}" = 1 ]; then
  args+=(--bare --settings "$CLAUDE_CONFIG_DIR/settings.json")
fi
args+=("$PROMPT")

run_agent claude-local -- "$(agent_bin claude-local claude)" "${args[@]}"
