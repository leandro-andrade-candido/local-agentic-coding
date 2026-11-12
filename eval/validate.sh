#!/usr/bin/env bash
# Validates the tasks without an LLM:
#   (a) right after setup.sh, the hidden checks FAIL (bug present / feature missing);
#   (b) after applying the reference solution, the checks PASS
#       (or are "awaiting grade" for the tasks with a rubric: T1, T5 and T6).
# Usage: eval/validate.sh [task ...]     (default: every task in tasks/, smoke/ and skills/)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

tasks=("$@")
if [ ${#tasks[@]} -eq 0 ]; then
    for d in "$here"/tasks/*/ "$here"/smoke/*/ "$here"/skills/*/; do [ -f "$d/task.json" ] && tasks+=("$(basename "$d")"); done
fi

vroot="$EVAL_WORK_ROOT/_validate"
mkdir -p "$vroot"
rc=0
printf '%-32s %-22s %-22s %s\n' TASK "(a) after setup" "(b) after solution" RESULT
for t in "${tasks[@]}"; do
    td="$(resolve_task "$t")"; name="$(basename "$td")"; wd="$vroot/$name"
    if ! "$td/setup.sh" "$wd" >"$vroot/$name.setup.log" 2>&1; then
        printf '%-32s %s\n' "$name" "SETUP ERROR (see $vroot/$name.setup.log)"; rc=1; continue
    fi
    # (a) without an agent transcript; (b) with the simulated transcript from oracle/ (K tasks).
    empty_logs="$(mktemp -d)"
    "$td/check.sh" "$wd" --out "$vroot/$name.a.json" --log "$vroot/$name.a.log" \
        --agent-logs "$empty_logs" >/dev/null 2>&1; a=$?
    rmdir "$empty_logs"
    "$td/setup.sh" "$wd" >>"$vroot/$name.setup.log" 2>&1
    apply_solution "$td" "$wd"
    oracle_logs=(); [ -d "$td/oracle" ] && oracle_logs=(--agent-logs "$td/oracle")
    "$td/check.sh" "$wd" --out "$vroot/$name.b.json" --log "$vroot/$name.b.log" \
        "${oracle_logs[@]}" >/dev/null 2>&1; b=$?
    sa=$( [ $a -eq 1 ] && echo "fails (ok)" || echo "exit $a (WRONG)" )
    case $b in 0) sb="passes (ok)";; 3) sb="awaiting grade (ok)";; *) sb="exit $b (WRONG)";; esac
    if [ $a -eq 1 ] && { [ $b -eq 0 ] || [ $b -eq 3 ]; }; then res=OK; else res=FAILED; rc=1; fi
    printf '%-32s %-22s %-22s %s\n' "$name" "$sa" "$sb" "$res"
    rm -rf "$wd/node_modules" "$wd/.venv"   # sources are kept for inspection
done
echo "details: $vroot/<task>.{a,b}.json and .log"
exit $rc
