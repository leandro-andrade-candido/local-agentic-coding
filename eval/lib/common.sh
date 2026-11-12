# shellcheck shell=bash
# Shared functions of the validation suite (eval/).
# Usage: source "$(dirname "$0")/../lib/common.sh"  (or an equivalent path)
#
# Recognized environment variables:
#   EVAL_CACHE      cache of git mirrors, uv and npm  (default: eval/.cache)
#   EVAL_WORK_ROOT  root of the run workdirs          (default: ~/.cache/local-agentic/eval-work)
#   EVAL_OFFLINE=1  forbids network access (fails if the cache is cold)

set -o pipefail

EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$EVAL_DIR/.." && pwd)"
EVAL_CACHE="${EVAL_CACHE:-$EVAL_DIR/.cache}"
EVAL_WORK_ROOT="${EVAL_WORK_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/local-agentic/eval-work}"
EVAL_PY="python3 -I"

# Fixed identity and dates: the workdir base commit always has the same hash.
export GIT_AUTHOR_NAME="eval" GIT_AUTHOR_EMAIL="eval@localhost"
export GIT_COMMITTER_NAME="eval" GIT_COMMITTER_EMAIL="eval@localhost"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"

log() { printf '[eval %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }

# json_get <file.json> <key> [default] -> prints the value (lists become one line per item)
json_get() {
    $EVAL_PY - "$1" "$2" "${3-}" <<'PY'
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
val = data
for part in key.split("."):
    if isinstance(val, dict) and part in val:
        val = val[part]
    else:
        val = default
        break
if isinstance(val, list):
    print("\n".join(str(v) for v in val))
elif isinstance(val, bool):
    print("true" if val else "false")
elif val is not None:
    print(val)
PY
}

repo_json() { echo "$EVAL_DIR/repos/$1/repo.json"; }

# ensure_mirror <repo>: makes sure the pinned commit is in the local mirror (bare, shallow).
ensure_mirror() {
    local name="$1" rj url sha mirror
    rj="$(repo_json "$name")"; [ -f "$rj" ] || die "unknown repository: $name"
    url="$(json_get "$rj" url)"; sha="$(json_get "$rj" commit)"
    mirror="$EVAL_CACHE/mirrors/$name.git"
    mkdir -p "$EVAL_CACHE/mirrors"
    if [ ! -d "$mirror" ]; then
        git init -q --bare "$mirror"
    fi
    if ! git --git-dir="$mirror" cat-file -e "$sha^{commit}" 2>/dev/null; then
        [ "${EVAL_OFFLINE:-0}" = 1 ] && die "commit $sha of $name missing from the cache and EVAL_OFFLINE=1"
        log "downloading $name@$sha into the cache"
        git --git-dir="$mirror" fetch -q --depth 1 "$url" "$sha" || die "failed to download $url $sha"
    fi
    echo "$mirror"
}

# Agent instruction files shipped by the upstream. They are removed from every
# workdir so all harnesses start from the same information (and T1 does not become a copy).
AGENT_DOC_FILES=(AGENTS.md CLAUDE.md GEMINI.md QWEN.md .cursorrules .github/copilot-instructions.md)

# install_python_deps <repo> <workdir>
install_python_deps() {
    local name="$1" wd="$2" req pyver
    req="$EVAL_DIR/repos/$name/requirements.txt"
    pyver="$(json_get "$(repo_json "$name")" python 3.12)"
    export UV_CACHE_DIR="$EVAL_CACHE/uv" UV_PYTHON_DOWNLOADS=never UV_NO_PROGRESS=1
    uv venv -q --python "$pyver" "$wd/.venv" >/dev/null || die "uv venv failed"
    if ! uv pip install -q --offline --python "$wd/.venv/bin/python" --require-hashes -r "$req" 2>/dev/null; then
        [ "${EVAL_OFFLINE:-0}" = 1 ] && die "Python dependencies missing from the cache and EVAL_OFFLINE=1"
        uv pip install -q --python "$wd/.venv/bin/python" --require-hashes -r "$req" || die "uv pip install failed"
    fi
}

# install_node_deps <workdir>
install_node_deps() {
    local wd="$1" npmopts=(ci --ignore-scripts --no-audit --no-fund --loglevel=error --cache "$EVAL_CACHE/npm")
    if ! (cd "$wd" && npm "${npmopts[@]}" --offline >/dev/null 2>&1); then
        [ "${EVAL_OFFLINE:-0}" = 1 ] && die "npm dependencies missing from the cache and EVAL_OFFLINE=1"
        (cd "$wd" && npm "${npmopts[@]}" --prefer-offline >/dev/null) || die "npm ci failed"
    fi
}

# deps_env_dir <repo> -> directory of the clean dependency environment for this repository.
# The key depends only on eval/repos (pinned commit and, for Python, the requirements.txt with
# hashes); check.py computes the same path inside the checks container.
deps_env_dir() {
    local name="$1" sha key req
    sha="$(json_get "$(repo_json "$name")" commit)"
    req="$EVAL_DIR/repos/$name/requirements.txt"
    if [ -f "$req" ]; then key="$(sha256sum "$req" | cut -c1-8)"; else key=lock; fi
    echo "$EVAL_CACHE/envs/$name-${sha:0:12}-$key"
}

# ensure_deps_env <repo> -> creates (once) and prints the clean environment: .venv (Python) or
# node_modules (Node), installed from the cache, outside any workdir. The checks run
# with it, never with the .venv/node_modules the agent could have changed.
ensure_deps_env() {
    local name="$1" dir kind sha mirror
    dir="$(deps_env_dir "$name")"
    if [ -f "$dir/.complete" ]; then echo "$dir"; return; fi
    kind="$(json_get "$(repo_json "$name")" kind)"
    mkdir -p "$(dirname "$dir")"
    # Lock: another setup (another run or validate.sh) may be creating the same environment.
    (
        flock 8
        if [ ! -f "$dir/.complete" ]; then
            rm -rf "$dir"; mkdir -p "$dir"
            case "$kind" in
                python) install_python_deps "$name" "$dir" ;;
                node)
                    sha="$(json_get "$(repo_json "$name")" commit)"
                    mirror="$(ensure_mirror "$name")" || exit 2
                    git --git-dir="$mirror" archive --format=tar "$sha" package.json package-lock.json \
                        | tar -x -C "$dir" || die "package.json/package-lock.json missing in $name"
                    install_node_deps "$dir" ;;
                *) die "unknown repository kind: $kind" ;;
            esac
            touch "$dir/.complete"
        fi
    ) 8>"$dir.lock" || exit 2
    echo "$dir"
}

# prepare_workdir <task_dir> <workdir>
# Creates a fresh workdir: tree of the pinned commit + setup.patch (bug, removed tests...),
# a single base commit (no upstream history, so what was planted is not revealed),
# installed dependencies and, if present, pending.patch applied without a commit (T7).
prepare_workdir() {
    local task_dir wd="$2" tj repo kind mirror sha f
    task_dir="$(cd "$1" && pwd)"
    [ -n "$wd" ] || die "empty workdir"
    wd="$(realpath -m "$wd")"
    cd "$EVAL_DIR" || die "cannot access $EVAL_DIR"   # the cwd may be inside the deleted workdir
    tj="$task_dir/task.json"; [ -f "$tj" ] || die "task.json missing in $task_dir"
    repo="$(json_get "$tj" repo)"; kind="$(json_get "$(repo_json "$repo")" kind)"
    sha="$(json_get "$(repo_json "$repo")" commit)"
    mirror="$(ensure_mirror "$repo")" || exit 2
    # Clean environment for the checks: created before any agent runs.
    ensure_deps_env "$repo" >/dev/null || exit 2

    case "$wd" in /|"$HOME"|"$REPO_ROOT"|"$EVAL_DIR"|"") die "invalid workdir: '$wd'";; esac
    rm -rf "$wd"; mkdir -p "$wd"
    git --git-dir="$mirror" archive --format=tar "$sha" | tar -x -C "$wd" || die "git archive failed"
    for f in "${AGENT_DOC_FILES[@]}"; do rm -f "$wd/$f"; done

    git -C "$wd" init -q -b main
    cat >> "$wd/.git/info/exclude" <<'EOF'
.venv/
node_modules/
__pycache__/
.pytest_cache/
coverage/
*.pyc
EOF
    if [ -f "$task_dir/setup.patch" ]; then
        git -C "$wd" apply --whitespace=nowarn "$task_dir/setup.patch" || die "setup.patch does not apply"
    fi
    git -C "$wd" add -A
    git -C "$wd" commit -q -m "Initial import" || die "base commit failed"

    case "$kind" in
        python) install_python_deps "$repo" "$wd" ;;
        node) install_node_deps "$wd" ;;
        *) die "unknown repository kind: $kind" ;;
    esac

    if [ -f "$task_dir/pending.patch" ]; then
        git -C "$wd" apply --whitespace=nowarn "$task_dir/pending.patch" || die "pending.patch does not apply"
    fi
}

# resolve_task <id> -> task directory (accepts T2, S1, K1, T2-pypika-..., or a path)
resolve_task() {
    local id="$1" d
    if [ -d "$id" ] && [ -f "$id/task.json" ]; then (cd "$id" && pwd); return; fi
    for d in "$EVAL_DIR"/{tasks,smoke,skills}/"$id" "$EVAL_DIR"/{tasks,smoke,skills}/"$id"-*; do
        if [ -f "$d/task.json" ]; then echo "$d"; return; fi
    done
    die "task not found: $id"
}

# resolve_harness <name> -> path of run.sh (eval/harnesses/ takes precedence over agents/)
resolve_harness() {
    local h="$1" p
    for p in "$EVAL_DIR/harnesses/$h/run.sh" "$REPO_ROOT/agents/$h/run.sh"; do
        if [ -x "$p" ]; then echo "$p"; return; fi
    done
    die "harness not found or not executable: $h (searched eval/harnesses/ and agents/)"
}

# apply_solution <task_dir> <workdir>: applies the reference solution (used by
# validate.sh and by the fake-oracle harness). solution.patch is relative to the base commit;
# solution/ (optional) holds files copied to the workdir root (reports).
apply_solution() {
    local task_dir="$1" wd="$2"
    if [ -f "$task_dir/solution.patch" ]; then
        git -C "$wd" apply --whitespace=nowarn "$task_dir/solution.patch" || die "solution.patch does not apply"
    fi
    if [ -d "$task_dir/solution" ]; then
        cp -r "$task_dir/solution/." "$wd/"
    fi
}

# load_llm_api_key: llama-server key (E5). Uses LLM_API_KEY from the environment; otherwise reads
# LLM_API_KEY_FILE (default ~/.config/local-agentic/llm-api-key, created by scripts/llm key).
# Exports LLM_API_KEY for the harness (sandbox/run-in-box.sh passes LLM_* to the container)
# and for metrics.py. Never prints the key. Sets LLM_API_KEY_SOURCE: env | file | none.
load_llm_api_key() {
    local f="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}" line
    if [ -n "${LLM_API_KEY:-}" ]; then
        LLM_API_KEY_SOURCE=env
    elif [ -r "$f" ]; then
        # First line that is neither a comment nor empty (the server accepts one key per line).
        line="$(grep -v -E '^[[:space:]]*(#|$)' "$f" | head -n 1)"
        LLM_API_KEY="${line//[[:space:]]/}"
        if [ -n "$LLM_API_KEY" ]; then LLM_API_KEY_SOURCE=file; else LLM_API_KEY_SOURCE=none; fi
    else
        LLM_API_KEY="" LLM_API_KEY_SOURCE=none
    fi
    export LLM_API_KEY LLM_API_KEY_SOURCE
    if [ "$LLM_API_KEY_SOURCE" = none ]; then
        log "WARNING: no llama-server key (LLM_API_KEY or $f): /metrics and the agent will get 401"
    fi
}
