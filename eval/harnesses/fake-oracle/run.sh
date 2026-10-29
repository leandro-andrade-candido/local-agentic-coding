#!/usr/bin/env bash
# Harness falso para testar o runner de ponta a ponta sem LLM.
# Segue o mesmo contrato dos harnesses reais em agents/<harness>/run.sh:
#   run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
#
# Identifica a tarefa comparando o prompt com os task.md de eval/tasks, eval/smoke e eval/skills
# (não recebe nenhuma variável com o caminho da tarefa, como um agente real) e aplica a
# solução de referência (solution.patch e/ou solution/).
#
# FAKE_ORACLE_MODE: solve (padrão) | noop (não faz nada; a tarefa deve falhar) | sleep:<s>
# (dorme <s> segundos antes de resolver; serve para testar o timeout do runner).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$here/../../lib/common.sh"

workdir="" prompt="" logdir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --workdir) workdir="$2"; shift 2 ;;
        --prompt-file) prompt="$2"; shift 2 ;;
        --log-dir) logdir="$2"; shift 2 ;;
        *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
    esac
done
[ -d "$workdir" ] && [ -f "$prompt" ] && [ -n "$logdir" ] || { echo "uso: $0 --workdir D --prompt-file F --log-dir D" >&2; exit 2; }
mkdir -p "$logdir"
transcript="$logdir/transcript.txt"

task_dir=""
for d in "$EVAL_DIR"/tasks/*/ "$EVAL_DIR"/smoke/*/ "$EVAL_DIR"/skills/*/; do
    if cmp -s "$d/task.md" "$prompt"; then task_dir="${d%/}"; break; fi
done
{
    echo "fake-oracle: $(date -Iseconds)"
    echo "workdir: $workdir"
    echo "LLM_BASE_URL=${LLM_BASE_URL:-} LLM_MODEL=${LLM_MODEL:-} (não usados)"
    echo "tarefa identificada: ${task_dir:-nenhuma}"
} >"$transcript"
[ -n "$task_dir" ] || { echo "prompt não corresponde a nenhuma tarefa" >>"$transcript"; exit 1; }

mode="${FAKE_ORACLE_MODE:-solve}"
case "$mode" in
    noop) echo "modo noop: nada aplicado" >>"$transcript" ;;
    sleep:*) s="${mode#sleep:}"; echo "dormindo ${s}s" >>"$transcript"; sleep "$s"; apply_solution "$task_dir" "$workdir" ;;
    solve) apply_solution "$task_dir" "$workdir"; echo "solução de referência aplicada" >>"$transcript" ;;
    *) echo "FAKE_ORACLE_MODE inválido: $mode" >&2; exit 2 ;;
esac
git -C "$workdir" status --short >>"$transcript" 2>&1 || true

# Tarefas K: transcript simulado (events.jsonl no formato de algum harness) em oracle/.
if [ "$mode" != noop ] && [ -d "$task_dir/oracle" ]; then
    cp -r "$task_dir/oracle/." "$logdir/"
fi

# Exemplo do arquivo opcional de métricas do harness (ver eval/README.md).
cat >"$logdir/agent-metrics.json" <<EOF
{"harness": "fake-oracle", "mode": "$mode", "turns": 1, "tool_calls": 1, "tool_call_errors": 0, "loops_detected": 0}
EOF
