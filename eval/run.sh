#!/usr/bin/env bash
# Executa UMA tarefa com UM harness e grava eval/runs/<run-id>/<harness>/<task-id>/result.json.
#
# Uso: eval/run.sh <harness> <task-id> <run-id>
#   harness  nome em eval/harnesses/ (ex.: fake-oracle) ou em agents/ (ex.: qwen-code)
#   task-id  T1..T7, S1..S3 ou o nome do diretório da tarefa
#   run-id   identificador livre ([A-Za-z0-9._-], pode ter "/" para agrupar: lote1/r1)
#
# Variáveis de ambiente:
#   LLM_BASE_URL (http://127.0.0.1:9931)  LLM_MODEL (qwen3.6-35b)   repassadas ao harness
#   EVAL_TIMEOUT_MIN      sobrepõe o timeout da tarefa (task.json; padrão 30)
#   EVAL_TIMEOUT_S        idem, em segundos (útil para testar o runner)
#   EVAL_SAMPLE_INTERVAL  intervalo do amostrador de RAM/VRAM em segundos (3)
#   EVAL_WORK_ROOT        onde ficam os workdirs (~/.cache/local-agentic/eval-work)
#   EVAL_CLEANUP          deps (padrão: apaga .venv/node_modules do workdir no fim) | all | none
#   EVAL_FORCE=1          sobrescreve um result.json existente
#
# Saída: 0 passou, 1 falhou, 3 aguarda nota do gabarito, 2 erro de infraestrutura.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

[ $# -eq 3 ] || { sed -n '2,20p' "$0" >&2; exit 2; }
harness="$1"; task_arg="$2"; run_id="$3"
[[ "$run_id" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$run_id" != *..* ]] && [[ "$run_id" != /* ]] \
    || die "run-id inválido: $run_id"
[[ "$harness" =~ ^[A-Za-z0-9._-]+$ ]] || die "nome de harness inválido: $harness"

task_dir="$(resolve_task "$task_arg")" || exit 2
harness_sh="$(resolve_harness "$harness")" || exit 2
tj="$task_dir/task.json"
task_id="$(json_get "$tj" id)"
repo="$(json_get "$tj" repo)"
timeout_min="${EVAL_TIMEOUT_MIN:-$(json_get "$tj" timeout_min 30)}"
timeout_s="${EVAL_TIMEOUT_S:-$(( timeout_min * 60 ))}"   # EVAL_TIMEOUT_S: só para testes do runner

export LLM_BASE_URL="${LLM_BASE_URL:-http://127.0.0.1:9931}"
export LLM_MODEL="${LLM_MODEL:-qwen3.6-35b}"

out="$EVAL_DIR/runs/$run_id/$harness/$task_id"
work="$EVAL_WORK_ROOT/$run_id/$harness/$task_id"
wd="$work/repo"
if [ -f "$out/result.json" ] && [ "${EVAL_FORCE:-0}" != 1 ]; then
    die "já existe $out/result.json (use EVAL_FORCE=1 para sobrescrever)"
fi

# Uma execução por vez: uma GPU, um modelo. Uma segunda chamada espera a primeira.
mkdir -p "$EVAL_CACHE"
exec 9>"$EVAL_CACHE/run.lock"
if ! flock -n 9; then
    log "outra execução em andamento; aguardando o lock ($EVAL_CACHE/run.lock)"
    flock 9
fi

rm -rf "$out" "$work"
mkdir -p "$out" "$work/agent-logs"
started_at="$(date -Iseconds)"
log "$harness / $task_id / $run_id  (timeout ${timeout_min} min)"

# 1. Workdir novo a partir do commit fixado.
t0=$(date +%s.%N)
setup_ok=true
if ! "$task_dir/setup.sh" "$wd" >"$out/setup.log" 2>&1; then
    setup_ok=false
    log "ERRO no setup (ver $out/setup.log)"
fi
setup_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")

baseline=""; start_ref=""
if $setup_ok; then
    baseline="$(git -C "$wd" rev-parse HEAD)"
    # Estado inicial inclui mudanças não commitadas do setup (T7); o diff do agente parte daqui.
    start_ref="$(git -C "$wd" stash create 2>/dev/null || true)"
    start_ref="${start_ref:-$baseline}"
    cp "$task_dir/task.md" "$work/prompt.md"
fi

agent_rc=""; timed_out=false; agent_wall_s=""
if $setup_ok; then
    # 2. Métricas do servidor antes, amostrador de memória durante, métricas depois.
    $EVAL_PY "$here/lib/metrics.py" snapshot "$LLM_BASE_URL" "$out/metrics.before.prom"
    $EVAL_PY "$here/lib/sampler.py" --out "$out/resources.json" --tsv "$out/resources.tsv" \
        --interval "${EVAL_SAMPLE_INTERVAL:-3}" 9>&- &
    sampler_pid=$!

    # 3. Agente, com timeout de parede. O timeout mata o grupo de processos inteiro.
    log "agente iniciado ($harness_sh)"
    t0=$(date +%s.%N)
    (cd "$wd" && exec timeout -k 30 "$timeout_s" "$harness_sh" \
        --workdir "$wd" --prompt-file "$work/prompt.md" --log-dir "$work/agent-logs") \
        </dev/null >"$out/agent.stdout" 2>"$out/agent.stderr" 9>&-
    agent_rc=$?
    agent_wall_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")
    case $agent_rc in 124|137) timed_out=true;; esac
    log "agente terminou: exit $agent_rc em ${agent_wall_s}s$($timed_out && echo ' (TIMEOUT)')"

    kill -TERM "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null
    $EVAL_PY "$here/lib/metrics.py" snapshot "$LLM_BASE_URL" "$out/metrics.after.prom"

    # 4. Diff do agente (inclui arquivos novos), capturado antes das verificações.
    tmp_index="$(mktemp)"; rm -f "$tmp_index"
    GIT_INDEX_FILE="$tmp_index" git -C "$wd" add -A >/dev/null 2>&1
    GIT_INDEX_FILE="$tmp_index" git -C "$wd" diff --cached --binary "$start_ref" >"$out/agent.patch"
    numstat="$(GIT_INDEX_FILE="$tmp_index" git -C "$wd" diff --cached --numstat "$start_ref")"
    rm -f "$tmp_index"
    agent_commits="$(git -C "$wd" rev-list --count "$baseline..HEAD" 2>/dev/null || echo 0)"
    cp -r "$work/agent-logs" "$out/agent-logs"

    # 5. Verificações ocultas.
    log "verificações ocultas"
    t0=$(date +%s.%N)
    "$task_dir/check.sh" "$wd" --baseline "$baseline" --out "$out/checks.json" --log "$out/check.log" \
        >"$out/check.stdout" 2>"$out/check.stderr" 9>&-
    check_rc=$?
    check_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")
fi
finished_at="$(date -Iseconds)"

# 6. result.json
eval_commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
eval_dirty="$( [ -n "$(git -C "$REPO_ROOT" status --porcelain -- eval 2>/dev/null)" ] && echo true || echo false)"
M_RUN_ID="$run_id" M_HARNESS="$harness" M_TASK_ID="$task_id" M_TASK_DIR="${task_dir#"$REPO_ROOT"/}" \
M_TASK_TITLE="$(json_get "$tj" title)" M_TASK_CATEGORY="$(json_get "$tj" category)" M_REPO="$repo" \
M_REPO_COMMIT="$(json_get "$(repo_json "$repo")" commit)" M_SETUP_OK="$setup_ok" M_SETUP_S="$setup_s" \
M_AGENT_WALL_S="${agent_wall_s:-}" M_CHECK_S="${check_s:-}" M_TIMEOUT_S="$timeout_s" \
M_AGENT_EXIT_CODE="${agent_rc:-}" M_TIMED_OUT="$timed_out" M_AGENT_COMMITS="${agent_commits:-}" \
M_NUMSTAT="${numstat:-}" M_STARTED_AT="$started_at" M_FINISHED_AT="$finished_at" \
M_LLM_BASE_URL="$LLM_BASE_URL" M_LLM_MODEL="$LLM_MODEL" M_WORKDIR="$wd" M_BASELINE="$baseline" \
M_EVAL_COMMIT="$eval_commit" M_EVAL_DIRTY="$eval_dirty" M_HOSTNAME="$(hostname)" M_KERNEL="$(uname -r)" \
$EVAL_PY - "$out/meta.json" <<'PY'
import json, os, sys
m = {k[2:].lower(): v for k, v in os.environ.items() if k.startswith("M_")}
def num(v):
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return None
for k in ("setup_s", "agent_wall_s", "check_s", "timeout_s", "agent_exit_code", "agent_commits"):
    m[k] = num(m.get(k, "")) if m.get(k, "") != "" else None
for k in ("setup_ok", "timed_out", "eval_dirty"):
    m[k] = m.get(k) == "true"
files = ins = dels = 0
for line in m.pop("numstat", "").splitlines():
    a, d, _ = line.split("\t", 2)
    files += 1
    ins += int(a) if a.isdigit() else 0
    dels += int(d) if d.isdigit() else 0
m["diff"] = {"files_changed": files, "insertions": ins, "deletions": dels}
with open(sys.argv[1], "w") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
PY
$EVAL_PY "$here/lib/result.py" "$out"

# 7. Limpeza do workdir (as fontes ficam para inspeção; dependências pesadas saem).
case "${EVAL_CLEANUP:-deps}" in
    all) rm -rf "$work" ;;
    deps) rm -rf "$wd/node_modules" "$wd/.venv" ;;
    none) ;;
esac

status="$(json_get "$out/result.json" status)"
log "resultado: $status  ->  ${out#"$REPO_ROOT"/}/result.json"
case "$status" in pass) exit 0;; fail) exit 1;; pending_grading) exit 3;; *) exit 2;; esac
