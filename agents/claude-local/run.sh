#!/usr/bin/env bash
# Claude Code com o modelo local, sem interação, conforme o contrato do eval.
# Uso: agents/claude-local/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# Saída em <log-dir>: events.jsonl (stream-json), stderr.log, run-meta.json,
# command.txt, settings.effective.json, guard.log (bloqueios), home/claude
# (CLAUDE_CONFIG_DIR isolado, com a transcrição JSONL em projects/) e métricas.
#
# CLAUDE_LOCAL_TOOLS muda o conjunto de ferramentas (padrão Bash,Read,Edit,Write;
# "default" = conjunto completo do Claude Code). CLAUDE_LOCAL_BARE=1 usa --bare
# (prompt mínimo, sem hooks/skills/CLAUDE.md descobertos) [não verificado com
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
      # Só o settings.json do CLAUDE_CONFIG_DIR: hooks e permissões do repositório não carregam.
      --setting-sources user
      # Contexto por usuário/máquina sai do system prompt: prefixo igual entre execuções.
      --exclude-dynamic-system-prompt-sections)
if [ "$AGENT_PROFILE" = autonomous ]; then
  args+=(--permission-mode bypassPermissions)
fi
if [ "${CLAUDE_LOCAL_BARE:-0}" = 1 ]; then
  args+=(--bare --settings "$CLAUDE_CONFIG_DIR/settings.json")
fi
args+=("$PROMPT")

run_agent claude-local -- "$(agent_bin claude-local claude)" "${args[@]}"
