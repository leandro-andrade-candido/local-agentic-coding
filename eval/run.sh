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
#   LLM_API_KEY           chave do llama-server; se vazia, lida de LLM_API_KEY_FILE
#                         (~/.config/local-agentic/llm-api-key). Exportada para o harness e
#                         usada no /metrics; nunca impressa (result.json só diz a origem)
#   EVAL_TIMEOUT_MIN      sobrepõe o timeout da tarefa (task.json; padrão 30)
#   EVAL_TIMEOUT_S        idem, em segundos (útil para testar o runner)
#   EVAL_SAMPLE_INTERVAL  intervalo do amostrador de RAM/VRAM em segundos (3)
#   EVAL_WORK_ROOT        onde ficam os workdirs (~/.cache/local-agentic/eval-work)
#   EVAL_CLEANUP          deps (padrão: apaga .venv/node_modules do workdir no fim) | all | none
#   EVAL_FORCE=1          sobrescreve um result.json existente
#   EVAL_WARMUP=0         desliga o pedido de aquecimento antes de medir (padrão: liga, só
#                         para harnesses reais; ver E4, M4)
#   EVAL_WRAPPER          ex.: sandbox/run-in-box.sh: agente, captura do diff e verificações
#                         rodam cada um num container novo (ver sandbox/README.md)
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
load_llm_api_key   # exporta LLM_API_KEY (o run-in-box.sh repassa LLM_* ao container)
if [ -n "${EVAL_WRAPPER:-}" ]; then
    EVAL_WRAPPER="$(realpath -e "$EVAL_WRAPPER")" && [ -x "$EVAL_WRAPPER" ] \
        || die "EVAL_WRAPPER não executável: $EVAL_WRAPPER"
fi

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
# Ambiente limpo de dependências (criado pelo setup, fora do workdir): as verificações
# usam ele, não o .venv/node_modules que o agente pôde alterar.
deps_env="$(deps_env_dir "$repo")"
# Pastas de skills que o agente enxergou (para a verificação skill_usage dos K1-K3).
if [ -n "${EVAL_WRAPPER:-}" ]; then skills_seen=/opt/skills; else skills_seen="${AGENT_SKILLS_DIRS:-}"; fi

# E7: com EVAL_WRAPPER, tudo que executa ou lê o que o agente produziu roda num
# container novo, e o host não executa nada do workdir depois que o agente o tocou:
# o agente (só workdir, log-dir e prompt montados; nunca eval/), a captura do diff
# (um .git/config plantado executaria comando no git do host) e as verificações
# (os testes ocultos importam o código do agente). Sem a variável, os prefixos
# ficam vazios e nada muda.
box_agent=() box_post=() box_check=()
if [ -n "${EVAL_WRAPPER:-}" ]; then
    box_agent=("$EVAL_WRAPPER" --rw "$wd" --rw "$work/agent-logs" --ro "$work/prompt.md")
    # Harnesses de teste (eval/harnesses/, sem LLM) leem as soluções de referência.
    case "$harness_sh" in "$EVAL_DIR"/harnesses/*) box_agent+=(--ro "$EVAL_DIR") ;; esac
    box_agent+=(--)
    # Captura do diff: workdir SÓ LEITURA e $out NÃO montado. Assim o git do agente
    # (fsmonitor/filtros/hooks), mesmo se executar aqui, não enxerga nem escreve em
    # nenhum caminho do host; o diff sai pela stdout (tar) e o host grava com boxio.
    box_post=("$EVAL_WRAPPER" --no-llm --no-skills --ro "$wd" --)
    # Verificações: $out NÃO é montado (o código do agente roda nos testes ocultos e
    # forjaria checks.json/veredito se pudesse escrevê-lo). O grader (eval/lib, a pasta
    # da tarefa com hidden/ e solução) entra só leitura; o transcrito já higienizado
    # ($out/agent-logs) entra só leitura. O resultado sai por um tar na stdout e o host
    # grava checks.json com boxio. box_check_mounts são passados ao wrapper; o comando
    # (check.sh) é montado pela chamada contida mais abaixo.
    box_check=("$EVAL_WRAPPER" --no-llm --no-skills --rw "$wd" \
               --ro "$EVAL_DIR/lib" --ro "$EVAL_DIR/repos" --ro "$task_dir" --ro "$deps_env" \
               --ro "$out/agent-logs" --)
fi

agent_rc=""; timed_out=false; agent_wall_s=""
if $setup_ok; then
    # 2. Aquecimento (E4, M4: o 1º pedido depois da carga gera ~10% mais devagar), só para
    #    harnesses reais; fica antes do snapshot "antes", portanto fora dos deltas.
    #    Métricas do servidor antes, amostrador de memória durante, métricas depois.
    case "$harness_sh" in
        "$EVAL_DIR"/harnesses/*) ;;
        *) [ "${EVAL_WARMUP:-1}" = 1 ] && $EVAL_PY "$here/lib/metrics.py" warmup "$LLM_BASE_URL" "$LLM_MODEL" "$out/warmup.json" ;;
    esac
    $EVAL_PY "$here/lib/metrics.py" snapshot "$LLM_BASE_URL" "$out/metrics.before.prom"
    $EVAL_PY "$here/lib/sampler.py" --out "$out/resources.json" --tsv "$out/resources.tsv" \
        --interval "${EVAL_SAMPLE_INTERVAL:-3}" 9>&- &
    sampler_pid=$!

    # 3. Agente, com timeout de parede. O timeout mata o grupo de processos inteiro.
    log "agente iniciado ($harness_sh${EVAL_WRAPPER:+, no container})"
    t0=$(date +%s.%N)
    (cd "$wd" && exec timeout -k 30 "$timeout_s" "${box_agent[@]}" "$harness_sh" \
        --workdir "$wd" --prompt-file "$work/prompt.md" --log-dir "$work/agent-logs") \
        </dev/null >"$out/agent.stdout" 2>"$out/agent.stderr" 9>&-
    agent_rc=$?
    agent_wall_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")
    case $agent_rc in 124|137) timed_out=true;; esac
    log "agente terminou: exit $agent_rc em ${agent_wall_s}s$($timed_out && echo ' (TIMEOUT)')"

    kill -TERM "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null
    $EVAL_PY "$here/lib/metrics.py" snapshot "$LLM_BASE_URL" "$out/metrics.after.prom"

    # 4. Diff do agente (inclui arquivos novos), capturado antes das verificações.
    # Roda no container com o workdir só leitura; a config do agente é neutralizada
    # (fsmonitor/hooks/filtros off, config de sistema/global ignorada) e os objetos
    # e o índice vão para um tmpfs do container. Emite um tar (agent.patch,
    # numstat.txt, commits.txt) na stdout; o host grava com boxio, sem seguir symlink.
    post_tar="$work/diff.tar"
    "${box_post[@]}" bash -c '
        set -e
        wd="$1"; ref="$2"; base="$3"
        t="$(mktemp -d)"; trap "rm -rf \"$t\"" EXIT
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        export GIT_INDEX_FILE="$t/index" GIT_OBJECT_DIRECTORY="$t/objects"
        export GIT_ALTERNATE_OBJECT_DIRECTORIES="$wd/.git/objects"
        mkdir -p "$t/objects"
        gf="-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.fileMode=false"
        gf="$gf -c core.autocrlf=false -c core.attributesFile=/dev/null -c core.pager=cat"
        git -C "$wd" $gf add -A >/dev/null 2>&1 || true
        git -C "$wd" $gf diff --cached --binary --no-ext-diff --no-textconv "$ref" >"$t/agent.patch" 2>/dev/null || :
        git -C "$wd" $gf diff --cached --numstat --no-ext-diff "$ref" >"$t/numstat.txt" 2>/dev/null || :
        git -C "$wd" $gf rev-list --count "$base..HEAD" >"$t/commits.txt" 2>/dev/null || echo 0 >"$t/commits.txt"
        tar -C "$t" -cf - agent.patch numstat.txt commits.txt' \
        _ "$wd" "$start_ref" "$baseline" 9>&- >"$post_tar" || log "aviso: captura do diff falhou"
    diff_out="$($EVAL_PY "$here/lib/boxio.py" extract-diff "$post_tar" "$out")"
    agent_commits="$(printf '%s\n' "$diff_out" | head -n1)"
    numstat="$(printf '%s\n' "$diff_out" | tail -n +2)"
    rm -f "$post_tar"
    # agent-logs vem do container do agente (ele a monta rw): copia só arquivos
    # regulares, sem seguir nem recriar symlinks.
    $EVAL_PY "$here/lib/boxio.py" copy-logs "$work/agent-logs" "$out/agent-logs"

    # 5. Verificações ocultas.
    log "verificações ocultas"
    t0=$(date +%s.%N)
    if [ -n "${EVAL_WRAPPER:-}" ]; then
        # No container, sem $out montado: o check.sh grava num tmpfs do container e o
        # resultado sai num tar pela stdout. O host grava checks.json/check.log com boxio,
        # então o veredito vem do grader, não de um checks.json que o agente pudesse plantar.
        check_tar="$work/checks.tar"
        "${box_check[@]}" bash -c '
            set -u
            od="$(mktemp -d)"
            "$1" "$2" --baseline "$3" --out "$od/checks.json" --log "$od/check.log" \
                --deps-env "$4" --agent-logs "$5" --skills-dirs "$6" \
                >"$od/check.stdout" 2>"$od/check.stderr"
            echo $? >"$od/check.rc"
            [ -e "$od/check.log" ] || : >"$od/check.log"
            tar -C "$od" -cf - checks.json check.log check.stdout check.stderr check.rc 2>/dev/null' \
            _ "$task_dir/check.sh" "$wd" "$baseline" "$deps_env" "$out/agent-logs" "$skills_seen" \
            9>&- >"$check_tar" || log "aviso: container das verificações saiu com erro"
        check_rc="$($EVAL_PY "$here/lib/boxio.py" extract-checks "$check_tar" "$out")"
        rm -f "$check_tar"
    else
        "$task_dir/check.sh" "$wd" --baseline "$baseline" --out "$out/checks.json" --log "$out/check.log" \
            --deps-env "$deps_env" --agent-logs "$out/agent-logs" --skills-dirs "$skills_seen" \
            >"$out/check.stdout" 2>"$out/check.stderr" 9>&-
        check_rc=$?
    fi
    check_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")
fi
finished_at="$(date -Iseconds)"

# E7 (item 7 da verificação): box_post e box_check podem rodar código do agente com
# $out montado. Antes de o host ler ou escrever qualquer coisa em $out, varre e apaga
# todo symlink plantado ali. Depois disso nada mais do agente roda, então as escritas
# seguintes (meta.json, result.json) não têm corrida; ainda assim são feitas sem seguir
# symlink (boxio / os.replace).
[ -d "$out" ] && $EVAL_PY "$here/lib/boxio.py" sanitize "$out"

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
M_SANDBOX="${EVAL_WRAPPER:-}" M_LLM_API_KEY_SOURCE="${LLM_API_KEY_SOURCE:-none}" \
EVAL_LIB="$here/lib" $EVAL_PY - "$out/meta.json" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["EVAL_LIB"])
import boxio  # escrita sem seguir symlink
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
boxio.write_json_atomic(sys.argv[1], m)
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
