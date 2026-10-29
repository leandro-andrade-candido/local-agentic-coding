#!/usr/bin/env bash
# Pi sem interação, conforme o contrato do eval.
# Uso: agents/pi/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# Saída em <log-dir>: events.jsonl (--mode json), stderr.log, run-meta.json,
# command.txt, guard.log (bloqueios), home/pi (sessão JSONL), métricas do servidor
# e, com AGENT_LOG_REQUESTS=1, requests.jsonl (cada requisição ao modelo).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
parse_run_args "$@"
source "$HERE/env.sh"
cp "$PI_CODING_AGENT_DIR/settings.json" "$LOG_DIR/settings.effective.json"
cp "$PI_CODING_AGENT_DIR/models.json" "$LOG_DIR/models.effective.json"

# --no-approve: ignora .pi/ do repositório (extensões, settings); AGENTS.md ainda é lido.
args=(--mode json --provider local --model "$LLM_MODEL" --thinking medium
      --no-approve "${PI_EXT_ARGS[@]}" "$PROMPT")

run_agent pi -- "$(agent_bin pi pi)" "${args[@]}"
