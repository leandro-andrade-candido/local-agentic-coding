#!/usr/bin/env bash
# Non-interactive Qwen Code, following the eval contract.
# Usage: agents/qwen-code/run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
# Output in <log-dir>: events.jsonl (stream-json), stderr.log, run-meta.json,
# command.txt, settings.effective.json, home/qwen (sessions), server metrics
# and, with AGENT_LOG_REQUESTS=1, requests/ (each OpenAI request and response).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
parse_run_args "$@"
source "$HERE/env.sh"
cp "$QWEN_HOME/settings.json" "$LOG_DIR/settings.effective.json"

args=(--prompt="$PROMPT" --output-format stream-json)
if [ "$AGENT_PROFILE" = autonomous ]; then
  args+=(--approval-mode yolo)
fi
if [ "${AGENT_LOG_REQUESTS:-0}" = 1 ]; then
  args+=(--openai-logging --openai-logging-dir "$LOG_DIR/requests")
fi

run_agent qwen-code -- "$(agent_bin qwen-code qwen)" "${args[@]}"
