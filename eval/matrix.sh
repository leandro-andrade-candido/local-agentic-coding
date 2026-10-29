#!/usr/bin/env bash
# Roda uma matriz harness x tarefa x repetição, SEMPRE em série (uma GPU, um modelo).
#
# Uso: eval/matrix.sh [-r REPETICOES] <run-id> <harnesses> <tarefas>
#   harnesses  lista separada por vírgula (ex.: qwen-code,pi)
#   tarefas    lista separada por vírgula (ex.: T1,T2,S1) ou um grupo: full (T1-T7), smoke (S1-S3),
#              skills (K1-K3), all (os três grupos)
#   -r N       repetições (padrão 3). Cada repetição grava em eval/runs/<run-id>/r<k>/...
#
# A ordem é: repetição -> tarefa -> harness, para que os harnesses se alternem e
# variações de temperatura/carga da máquina não favoreçam um deles.
# Ao final grava eval/runs/<run-id>/summary.md (eval/summarize.py).
# Variáveis de ambiente do eval/run.sh valem aqui também (LLM_*, EVAL_TIMEOUT_MIN ...).
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

echo "=== fim: pass=${tally[pass]:-0} fail=${tally[fail]:-0} aguarda_nota=${tally[pending]:-0} erro=${tally[error]:-0}" >&2
python3 -I "$here/summarize.py" "$here/runs/$run_id" | tee "$here/runs/$run_id/summary.md"
