#!/usr/bin/env bash
# Valida as tarefas sem LLM:
#   (a) logo após o setup.sh, as verificações ocultas FALHAM (bug presente / recurso ausente);
#   (b) após aplicar a solução de referência, as verificações PASSAM
#       (ou ficam "aguarda nota" nas tarefas com gabarito: T1 e T6).
# Uso: eval/validate.sh [tarefa ...]     (padrão: todas as tarefas de tasks/ e smoke/)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

tasks=("$@")
if [ ${#tasks[@]} -eq 0 ]; then
    for d in "$here"/tasks/*/ "$here"/smoke/*/; do [ -f "$d/task.json" ] && tasks+=("$(basename "$d")"); done
fi

vroot="$EVAL_WORK_ROOT/_validate"
mkdir -p "$vroot"
rc=0
printf '%-32s %-22s %-22s %s\n' TAREFA "(a) após setup" "(b) após solução" RESULTADO
for t in "${tasks[@]}"; do
    td="$(resolve_task "$t")"; name="$(basename "$td")"; wd="$vroot/$name"
    if ! "$td/setup.sh" "$wd" >"$vroot/$name.setup.log" 2>&1; then
        printf '%-32s %s\n' "$name" "ERRO no setup (ver $vroot/$name.setup.log)"; rc=1; continue
    fi
    "$td/check.sh" "$wd" --out "$vroot/$name.a.json" --log "$vroot/$name.a.log" >/dev/null 2>&1; a=$?
    "$td/setup.sh" "$wd" >>"$vroot/$name.setup.log" 2>&1
    apply_solution "$td" "$wd"
    "$td/check.sh" "$wd" --out "$vroot/$name.b.json" --log "$vroot/$name.b.log" >/dev/null 2>&1; b=$?
    sa=$( [ $a -eq 1 ] && echo "falha (ok)" || echo "exit $a (ERRADO)" )
    case $b in 0) sb="passa (ok)";; 3) sb="aguarda nota (ok)";; *) sb="exit $b (ERRADO)";; esac
    if [ $a -eq 1 ] && { [ $b -eq 0 ] || [ $b -eq 3 ]; }; then res=OK; else res=FALHOU; rc=1; fi
    printf '%-32s %-22s %-22s %s\n' "$name" "$sa" "$sb" "$res"
    rm -rf "$wd/node_modules" "$wd/.venv"   # fontes ficam para inspeção
done
echo "detalhes: $vroot/<tarefa>.{a,b}.json e .log"
exit $rc
