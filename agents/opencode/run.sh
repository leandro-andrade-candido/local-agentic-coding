#!/usr/bin/env bash
# Non-interactive OpenCode 1.x, following the eval contract.
# Usage: agents/opencode/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# Output in <log-dir>: events.jsonl (run --format json), stderr.log, run-meta.json,
# command.txt, opencode.effective.json, guard.log (blocks), home/opencode
# (sessions in SQLite and logs in data/opencode/log) and server metrics.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
parse_run_args "$@"
source "$HERE/env.sh"
cp "$XDG_CONFIG_HOME/opencode/opencode.json" "$LOG_DIR/opencode.effective.json"
# Do not use OPENCODE_DISABLE_PROJECT_CONFIG: besides the repository's
# opencode.json/.opencode, it also stops loading the project's AGENTS.md (session/instruction.ts).

# Fixed --title: an explicit title skips the LLM generation (extra call on the single slot).
args=(run --format json --model "llamacpp/$LLM_MODEL" --dir "$WORKDIR"
      --title "eval $(date +%Y%m%dT%H%M%S)" --print-logs --log-level INFO)
if [ "$AGENT_PROFILE" = autonomous ]; then
  args+=(--auto)
fi
args+=("$PROMPT")

run_agent opencode -- "$(agent_bin opencode opencode)" "${args[@]}"
