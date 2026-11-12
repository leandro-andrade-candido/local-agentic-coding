#!/usr/bin/env bash
# Non-interactive Pi, following the eval contract.
# Usage: agents/pi/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# Output in <log-dir>: events.jsonl (--mode json), stderr.log, run-meta.json,
# command.txt, guard.log (blocks), home/pi (JSONL session), server metrics
# and, with AGENT_LOG_REQUESTS=1, requests.jsonl (each request to the model).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
parse_run_args "$@"
source "$HERE/env.sh"
cp "$PI_CODING_AGENT_DIR/settings.json" "$LOG_DIR/settings.effective.json"
cp "$PI_CODING_AGENT_DIR/models.json" "$LOG_DIR/models.effective.json"

# --no-approve: ignores the repository's .pi/ (extensions, settings); AGENTS.md is still read.
args=(--mode json --provider local --model "$LLM_MODEL" --thinking medium
      --no-approve "${PI_EXT_ARGS[@]}" "$PROMPT")

run_agent pi -- "$(agent_bin pi pi)" "${args[@]}"
