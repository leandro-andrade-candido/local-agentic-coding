#!/usr/bin/env bash
# Runs a harness x task x repetition matrix, ALWAYS serially (one GPU, one model).
#
# Usage: eval/matrix.sh [-r REPETITIONS] <run-id> <harnesses> <tasks>
#   harnesses  comma-separated list (e.g. qwen-code,pi)
#   tasks      comma-separated list (e.g. T1,T2,S1) or a group: full (T1-T7), smoke (S1-S3),
#              skills (K1-K3), all (the three groups)
#   -r N       repetitions (default 3). Each repetition writes to eval/runs/<run-id>/r<k>/...
#
# The order is repetition -> task -> harness, so the harnesses alternate and
# changes in machine temperature/load do not favor any of them.
# At the end it writes eval/runs/<run-id>/summary.md (eval/summarize.py).
# The eval/run.sh environment variables apply here too (LLM_*, EVAL_TIMEOUT_MIN ...).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

reps=3
while getopts "r:" opt; do
    case "$opt" in r) reps="$OPTARG" ;; *) sed -n '2,14p' "$0" >&2; exit 2 ;; esac
done
shift $((OPTIND - 1))
[ $# -eq 3 ] || { sed -n '2,14p' "$0" >&2; exit 2; }
run_id="$1"; IFS=, read -r -a harnesses <<<"$2"; tasks_arg="$3"

case "$tasks_arg" in
    full) tasks=(T1 T2 T3 T4 T5 T6 T7) ;;
    smoke) tasks=(S1 S2 S3) ;;
    skills) tasks=(K1 K2 K3) ;;
    all) tasks=(S1 S2 S3 K1 K2 K3 T1 T2 T3 T4 T5 T6 T7) ;;
    *) IFS=, read -r -a tasks <<<"$tasks_arg" ;;
esac

total=$(( reps * ${#tasks[@]} * ${#harnesses[@]} )); n=0
declare -A tally=()
for ((k = 1; k <= reps; k++)); do
    for t in "${tasks[@]}"; do
        for h in "${harnesses[@]}"; do
            n=$((n + 1))
            echo "=== [$n/$total] r$k $h $t" >&2
            "$here/run.sh" "$h" "$t" "$run_id/r$k"
            case $? in 0) s=pass;; 1) s=fail;; 3) s=pending;; *) s=error;; esac
            tally[$s]=$(( ${tally[$s]:-0} + 1 ))
        done
    done
done

echo "=== done: pass=${tally[pass]:-0} fail=${tally[fail]:-0} awaiting_grade=${tally[pending]:-0} error=${tally[error]:-0}" >&2
python3 -I "$here/summarize.py" "$here/runs/$run_id" | tee "$here/runs/$run_id/summary.md"
