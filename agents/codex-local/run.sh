#!/usr/bin/env bash
# Codex CLI com o modelo local, sem interação, conforme o contrato do eval.
# Uso: agents/codex-local/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# Saída em <log-dir>: events.jsonl (codex exec --json), stderr.log (progresso),
# last-message.txt, run-meta.json, agent-metrics.json, command.txt,
# config.effective.toml, guard.log (bloqueios), home/codex (CODEX_HOME isolado,
# com a sessão em sessions/) e métricas do servidor.
#
# CODEX_LOCAL_SANDBOX=workspace-write mantém o sandbox do Codex (bubblewrap) no
# perfil autonomous, para rodar fora do container (no host, os namespaces de
# usuário funcionam). Dentro do container da E7 deixe vazio.
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
