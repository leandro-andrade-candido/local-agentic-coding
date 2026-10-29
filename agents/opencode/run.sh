#!/usr/bin/env bash
# OpenCode 1.x sem interação, conforme o contrato do eval.
# Uso: agents/opencode/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# Saída em <log-dir>: events.jsonl (run --format json), stderr.log, run-meta.json,
# command.txt, opencode.effective.json, guard.log (bloqueios), home/opencode
# (sessões em SQLite e logs em data/opencode/log) e métricas do servidor.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
parse_run_args "$@"
source "$HERE/env.sh"
cp "$XDG_CONFIG_HOME/opencode/opencode.json" "$LOG_DIR/opencode.effective.json"
# Não usar OPENCODE_DISABLE_PROJECT_CONFIG: além de opencode.json/.opencode do
# repositório, ele também deixa de carregar o AGENTS.md do projeto (session/instruction.ts).

# --title fixo: título explícito pula a geração por LLM (chamada extra no slot único).
args=(run --format json --model "llamacpp/$LLM_MODEL" --dir "$WORKDIR"
      --title "eval $(date +%Y%m%dT%H%M%S)" --print-logs --log-level INFO)
if [ "$AGENT_PROFILE" = autonomous ]; then
  args+=(--auto)
fi
args+=("$PROMPT")

run_agent opencode -- "$(agent_bin opencode opencode)" "${args[@]}"
