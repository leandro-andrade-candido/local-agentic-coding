#!/usr/bin/env bash
# Runs ONE task with ONE harness and writes eval/runs/<run-id>/<harness>/<task-id>/result.json.
#
# Usage: eval/run.sh <harness> <task-id> <run-id>
#   harness  name in eval/harnesses/ (e.g. fake-oracle) or in agents/ (e.g. qwen-code)
#   task-id  T1..T7, S1..S3, K1..K3 or the task directory name
#   run-id   free identifier ([A-Za-z0-9._-], may contain "/" to group: batch1/r1)
#
# Environment variables:
#   LLM_BASE_URL (http://127.0.0.1:9931)  LLM_MODEL (qwen3.6-35b)   passed to the harness
#   LLM_API_KEY           llama-server key; if empty, read from LLM_API_KEY_FILE
#                         (~/.config/local-agentic/llm-api-key). Exported to the harness and
#                         used for /metrics; never printed (result.json only records the source)
#   EVAL_TIMEOUT_MIN      overrides the task timeout (task.json; default 30)
#   EVAL_TIMEOUT_S        same, in seconds (useful for testing the runner)
#   EVAL_SAMPLE_INTERVAL  RAM/VRAM sampler interval in seconds (3)
#   EVAL_WORK_ROOT        where the workdirs live (~/.cache/local-agentic/eval-work)
#   EVAL_CLEANUP          deps (default: deletes the workdir .venv/node_modules at the end) | all | none
#   EVAL_FORCE=1          overwrites an existing result.json
#   EVAL_WARMUP=0         disables the warm-up request before measuring (default: on, only
#                         for real harnesses; see E4, M4)
#   EVAL_WRAPPER          e.g. sandbox/run-in-box.sh: the agent, the diff capture and the checks
#                         each run in a fresh container (see sandbox/README.md)
#
# Exit: 0 passed, 1 failed, 3 awaiting rubric grade, 2 infrastructure error.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

[ $# -eq 3 ] || { sed -n '2,20p' "$0" >&2; exit 2; }
harness="$1"; task_arg="$2"; run_id="$3"
[[ "$run_id" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$run_id" != *..* ]] && [[ "$run_id" != /* ]] \
    || die "invalid run-id: $run_id"
[[ "$harness" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid harness name: $harness"

task_dir="$(resolve_task "$task_arg")" || exit 2
harness_sh="$(resolve_harness "$harness")" || exit 2
tj="$task_dir/task.json"
task_id="$(json_get "$tj" id)"
repo="$(json_get "$tj" repo)"
timeout_min="${EVAL_TIMEOUT_MIN:-$(json_get "$tj" timeout_min 30)}"
timeout_s="${EVAL_TIMEOUT_S:-$(( timeout_min * 60 ))}"   # EVAL_TIMEOUT_S: only for runner tests

export LLM_BASE_URL="${LLM_BASE_URL:-http://127.0.0.1:9931}"
export LLM_MODEL="${LLM_MODEL:-qwen3.6-35b}"
load_llm_api_key   # exports LLM_API_KEY (run-in-box.sh passes LLM_* to the container)
if [ -n "${EVAL_WRAPPER:-}" ]; then
    EVAL_WRAPPER="$(realpath -e "$EVAL_WRAPPER")" && [ -x "$EVAL_WRAPPER" ] \
        || die "EVAL_WRAPPER not executable: $EVAL_WRAPPER"
fi

out="$EVAL_DIR/runs/$run_id/$harness/$task_id"
work="$EVAL_WORK_ROOT/$run_id/$harness/$task_id"
wd="$work/repo"
if [ -f "$out/result.json" ] && [ "${EVAL_FORCE:-0}" != 1 ]; then
    die "$out/result.json already exists (use EVAL_FORCE=1 to overwrite)"
fi

# One run at a time: one GPU, one model. A second call waits for the first.
mkdir -p "$EVAL_CACHE"
exec 9>"$EVAL_CACHE/run.lock"
if ! flock -n 9; then
    log "another run in progress; waiting for the lock ($EVAL_CACHE/run.lock)"
    flock 9
fi

rm -rf "$out" "$work"
mkdir -p "$out" "$work/agent-logs"
started_at="$(date -Iseconds)"
log "$harness / $task_id / $run_id  (timeout ${timeout_min} min)"

# 1. Fresh workdir from the pinned commit.
t0=$(date +%s.%N)
setup_ok=true
if ! "$task_dir/setup.sh" "$wd" >"$out/setup.log" 2>&1; then
    setup_ok=false
    log "setup ERROR (see $out/setup.log)"
fi
setup_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")

baseline=""; start_ref=""
if $setup_ok; then
    baseline="$(git -C "$wd" rev-parse HEAD)"
    # The initial state includes uncommitted setup changes (T7); the agent diff starts here.
    start_ref="$(git -C "$wd" stash create 2>/dev/null || true)"
    start_ref="${start_ref:-$baseline}"
    cp "$task_dir/task.md" "$work/prompt.md"
fi
# Clean dependency environment (created by setup, outside the workdir): the checks
# use it, not the .venv/node_modules the agent could have changed.
deps_env="$(deps_env_dir "$repo")"
# Skill directories the agent could see (for the skill_usage check of K1-K3).
if [ -n "${EVAL_WRAPPER:-}" ]; then skills_seen=/opt/skills; else skills_seen="${AGENT_SKILLS_DIRS:-}"; fi

# E7: with EVAL_WRAPPER, everything that executes or reads what the agent produced runs in a
# fresh container, and the host executes nothing from the workdir after the agent touched it:
# the agent (only workdir, log-dir and prompt mounted; never eval/), the diff capture
# (a planted .git/config would run a command in the host's git) and the checks
# (the hidden tests import the agent's code). Without the variable, the prefixes
# stay empty and nothing changes.
box_agent=() box_post=() box_check=()
if [ -n "${EVAL_WRAPPER:-}" ]; then
    box_agent=("$EVAL_WRAPPER" --rw "$wd" --rw "$work/agent-logs" --ro "$work/prompt.md")
    # Test harnesses (eval/harnesses/, no LLM) read the reference solutions.
    case "$harness_sh" in "$EVAL_DIR"/harnesses/*) box_agent+=(--ro "$EVAL_DIR") ;; esac
    box_agent+=(--)
    # Diff capture: workdir READ-ONLY and $out NOT mounted. So the agent's git
    # (fsmonitor/filters/hooks), even if it runs here, neither sees nor writes any
    # host path; the diff leaves through stdout (tar) and the host writes it with boxio.
    box_post=("$EVAL_WRAPPER" --no-llm --no-skills --ro "$wd" --)
    # Checks: $out is NOT mounted (the agent's code runs in the hidden tests and
    # would forge checks.json/the verdict if it could write it). The grader (eval/lib, the
    # task directory with hidden/ and the solution) is mounted read-only; the already
    # sanitized transcript ($out/agent-logs) is read-only. The result leaves as a tar on stdout
    # and the host writes checks.json with boxio. These mounts are passed to the wrapper; the
    # command (check.sh) is built by the contained call further below.
    box_check=("$EVAL_WRAPPER" --no-llm --no-skills --rw "$wd" \
               --ro "$EVAL_DIR/lib" --ro "$EVAL_DIR/repos" --ro "$task_dir" --ro "$deps_env" \
               --ro "$out/agent-logs" --)
fi

agent_rc=""; timed_out=false; agent_wall_s=""
if $setup_ok; then
    # 2. Warm-up (E4, M4: the 1st request after loading generates ~10% slower), only for
    #    real harnesses; it comes before the "before" snapshot, so it stays out of the deltas.
    #    Server metrics before, memory sampler during, metrics after.
    case "$harness_sh" in
        "$EVAL_DIR"/harnesses/*) ;;
        *) [ "${EVAL_WARMUP:-1}" = 1 ] && $EVAL_PY "$here/lib/metrics.py" warmup "$LLM_BASE_URL" "$LLM_MODEL" "$out/warmup.json" ;;
    esac
    $EVAL_PY "$here/lib/metrics.py" snapshot "$LLM_BASE_URL" "$out/metrics.before.prom"
    $EVAL_PY "$here/lib/sampler.py" --out "$out/resources.json" --tsv "$out/resources.tsv" \
        --interval "${EVAL_SAMPLE_INTERVAL:-3}" 9>&- &
    sampler_pid=$!

    # 3. Agent, with a wall-clock timeout. The timeout kills the whole process group.
    log "agent started ($harness_sh${EVAL_WRAPPER:+, in the container})"
    t0=$(date +%s.%N)
    (cd "$wd" && exec timeout -k 30 "$timeout_s" "${box_agent[@]}" "$harness_sh" \
        --workdir "$wd" --prompt-file "$work/prompt.md" --log-dir "$work/agent-logs") \
        </dev/null >"$out/agent.stdout" 2>"$out/agent.stderr" 9>&-
    agent_rc=$?
    agent_wall_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")
    case $agent_rc in 124|137) timed_out=true;; esac
    log "agent finished: exit $agent_rc in ${agent_wall_s}s$($timed_out && echo ' (TIMEOUT)')"

    kill -TERM "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null
    $EVAL_PY "$here/lib/metrics.py" snapshot "$LLM_BASE_URL" "$out/metrics.after.prom"

    # 4. Agent diff (includes new files), captured before the checks.
    # Runs in the container with the workdir read-only; the agent's config is neutralized
    # (fsmonitor/hooks/filters off, system/global config ignored) and the objects
    # and index go to a container tmpfs. Emits a tar (agent.patch,
    # numstat.txt, commits.txt) on stdout; the host writes it with boxio, without following symlinks.
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
        _ "$wd" "$start_ref" "$baseline" 9>&- >"$post_tar" || log "warning: diff capture failed"
    diff_out="$($EVAL_PY "$here/lib/boxio.py" extract-diff "$post_tar" "$out")"
    agent_commits="$(printf '%s\n' "$diff_out" | head -n1)"
    numstat="$(printf '%s\n' "$diff_out" | tail -n +2)"
    rm -f "$post_tar"
    # agent-logs comes from the agent container (mounted rw there): copy regular
    # files only, without following or recreating symlinks.
    $EVAL_PY "$here/lib/boxio.py" copy-logs "$work/agent-logs" "$out/agent-logs"

    # 5. Hidden checks.
    log "hidden checks"
    t0=$(date +%s.%N)
    if [ -n "${EVAL_WRAPPER:-}" ]; then
        # In the container, without $out mounted: check.sh writes to a container tmpfs and the
        # result leaves as a tar on stdout. The host writes checks.json/check.log with boxio,
        # so the verdict comes from the grader, not from a checks.json the agent could plant.
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
            9>&- >"$check_tar" || log "warning: the checks container exited with an error"
        # check_rc is kept only for debugging: the verdict comes from the checks.json read by the grader.
        # shellcheck disable=SC2034
        check_rc="$($EVAL_PY "$here/lib/boxio.py" extract-checks "$check_tar" "$out")"
        rm -f "$check_tar"
    else
        "$task_dir/check.sh" "$wd" --baseline "$baseline" --out "$out/checks.json" --log "$out/check.log" \
            --deps-env "$deps_env" --agent-logs "$out/agent-logs" --skills-dirs "$skills_seen" \
            >"$out/check.stdout" 2>"$out/check.stderr" 9>&-
        # shellcheck disable=SC2034
        check_rc=$?
    fi
    check_s=$(python3 -c "import sys;print(round($(date +%s.%N)-$t0,1))")
fi
finished_at="$(date -Iseconds)"

# E7 (verification item 7): box_post and box_check may run agent code with
# $out mounted. Before the host reads or writes anything in $out, it scans and deletes
# every symlink planted there. After that no agent code runs, so the following
# writes (meta.json, result.json) have no race; they are still done without following
# symlinks (boxio / os.replace).
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
import boxio  # writes without following symlinks
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

# 7. Workdir cleanup (sources are kept for inspection; heavy dependencies are removed).
case "${EVAL_CLEANUP:-deps}" in
    all) rm -rf "$work" ;;
    deps) rm -rf "$wd/node_modules" "$wd/.venv" ;;
    none) ;;
esac

status="$(json_get "$out/result.json" status)"
log "result: $status  ->  ${out#"$REPO_ROOT"/}/result.json"
case "$status" in pass) exit 0;; fail) exit 1;; pending_grading) exit 3;; *) exit 2;; esac
