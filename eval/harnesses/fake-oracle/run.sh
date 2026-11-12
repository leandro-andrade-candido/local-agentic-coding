#!/usr/bin/env bash
# Fake harness to test the runner end to end without an LLM.
# Follows the same contract as the real harnesses in agents/<harness>/run.sh:
#   run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
#
# Identifies the task by comparing the prompt with the task.md files of eval/tasks, eval/smoke
# and eval/skills (like a real agent, it gets no variable with the task path) and applies the
# reference solution (solution.patch and/or solution/).
#
# FAKE_ORACLE_MODE: solve (default) | noop (does nothing; the task must fail) | sleep:<s>
# (sleeps <s> seconds before solving; used to test the runner timeout).
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
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -d "$workdir" ] && [ -f "$prompt" ] && [ -n "$logdir" ] || { echo "usage: $0 --workdir D --prompt-file F --log-dir D" >&2; exit 2; }
mkdir -p "$logdir"
transcript="$logdir/transcript.txt"

task_dir=""
for d in "$EVAL_DIR"/tasks/*/ "$EVAL_DIR"/smoke/*/ "$EVAL_DIR"/skills/*/; do
    if cmp -s "$d/task.md" "$prompt"; then task_dir="${d%/}"; break; fi
done
{
    echo "fake-oracle: $(date -Iseconds)"
    echo "workdir: $workdir"
    echo "LLM_BASE_URL=${LLM_BASE_URL:-} LLM_MODEL=${LLM_MODEL:-} (not used)"
    echo "task identified: ${task_dir:-none}"
} >"$transcript"
[ -n "$task_dir" ] || { echo "prompt does not match any task" >>"$transcript"; exit 1; }

mode="${FAKE_ORACLE_MODE:-solve}"
case "$mode" in
    noop) echo "noop mode: nothing applied" >>"$transcript" ;;
    sleep:*) s="${mode#sleep:}"; echo "sleeping ${s}s" >>"$transcript"; sleep "$s"; apply_solution "$task_dir" "$workdir" ;;
    solve) apply_solution "$task_dir" "$workdir"; echo "reference solution applied" >>"$transcript" ;;
    *) echo "invalid FAKE_ORACLE_MODE: $mode" >&2; exit 2 ;;
esac
git -C "$workdir" status --short >>"$transcript" 2>&1 || true

# K tasks: simulated transcript (events.jsonl in some harness's format) in oracle/.
if [ "$mode" != noop ] && [ -d "$task_dir/oracle" ]; then
    cp -r "$task_dir/oracle/." "$logdir/"
fi

# Example of the optional harness metrics file (see eval/README.md).
cat >"$logdir/agent-metrics.json" <<EOF
{"harness": "fake-oracle", "mode": "$mode", "turns": 1, "tool_calls": 1, "tool_call_errors": 0, "loops_detected": 0}
EOF
