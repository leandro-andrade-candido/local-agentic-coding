# shellcheck shell=bash
# Funções compartilhadas da suíte de validação (eval/).
# Uso: source "$(dirname "$0")/../lib/common.sh"  (ou caminho equivalente)
#
# Variáveis de ambiente reconhecidas:
#   EVAL_CACHE      cache de espelhos git, uv e npm   (padrão: eval/.cache)
#   EVAL_WORK_ROOT  raiz dos workdirs das execuções   (padrão: ~/.cache/local-agentic/eval-work)
#   EVAL_OFFLINE=1  proíbe acesso à rede (falha se o cache estiver frio)

set -o pipefail

EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$EVAL_DIR/.." && pwd)"
EVAL_CACHE="${EVAL_CACHE:-$EVAL_DIR/.cache}"
EVAL_WORK_ROOT="${EVAL_WORK_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/local-agentic/eval-work}"
EVAL_PY="python3 -I"

# Identidade e datas fixas: o commit-base do workdir tem sempre o mesmo hash.
export GIT_AUTHOR_NAME="eval" GIT_AUTHOR_EMAIL="eval@localhost"
export GIT_COMMITTER_NAME="eval" GIT_COMMITTER_EMAIL="eval@localhost"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"

log() { printf '[eval %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERRO: $*"; exit 2; }

# json_get <arquivo.json> <chave> [padrão] -> imprime o valor (listas viram uma linha por item)
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

# ensure_mirror <repo>: garante o commit fixado no espelho local (bare, raso).
ensure_mirror() {
    local name="$1" rj url sha mirror
    rj="$(repo_json "$name")"; [ -f "$rj" ] || die "repositório desconhecido: $name"
    url="$(json_get "$rj" url)"; sha="$(json_get "$rj" commit)"
    mirror="$EVAL_CACHE/mirrors/$name.git"
    mkdir -p "$EVAL_CACHE/mirrors"
    if [ ! -d "$mirror" ]; then
        git init -q --bare "$mirror"
    fi
    if ! git --git-dir="$mirror" cat-file -e "$sha^{commit}" 2>/dev/null; then
        [ "${EVAL_OFFLINE:-0}" = 1 ] && die "commit $sha de $name ausente do cache e EVAL_OFFLINE=1"
        log "baixando $name@$sha para o cache"
        git --git-dir="$mirror" fetch -q --depth 1 "$url" "$sha" || die "falha ao baixar $url $sha"
    fi
    echo "$mirror"
}

# Arquivos de instrução para agentes que vêm no upstream. São removidos de todos os
# workdirs para que todos os harnesses partam da mesma informação (e o T1 não vire cópia).
AGENT_DOC_FILES=(AGENTS.md CLAUDE.md GEMINI.md QWEN.md .cursorrules .github/copilot-instructions.md)

# install_python_deps <repo> <workdir>
install_python_deps() {
    local name="$1" wd="$2" req pyver
    req="$EVAL_DIR/repos/$name/requirements.txt"
    pyver="$(json_get "$(repo_json "$name")" python 3.12)"
    export UV_CACHE_DIR="$EVAL_CACHE/uv" UV_PYTHON_DOWNLOADS=never UV_NO_PROGRESS=1
    uv venv -q --python "$pyver" "$wd/.venv" >/dev/null || die "uv venv falhou"
    if ! uv pip install -q --offline --python "$wd/.venv/bin/python" --require-hashes -r "$req" 2>/dev/null; then
        [ "${EVAL_OFFLINE:-0}" = 1 ] && die "dependências Python ausentes do cache e EVAL_OFFLINE=1"
        uv pip install -q --python "$wd/.venv/bin/python" --require-hashes -r "$req" || die "uv pip install falhou"
    fi
}

# install_node_deps <workdir>
install_node_deps() {
    local wd="$1" npmopts=(ci --ignore-scripts --no-audit --no-fund --loglevel=error --cache "$EVAL_CACHE/npm")
    if ! (cd "$wd" && npm "${npmopts[@]}" --offline >/dev/null 2>&1); then
        [ "${EVAL_OFFLINE:-0}" = 1 ] && die "dependências npm ausentes do cache e EVAL_OFFLINE=1"
        (cd "$wd" && npm "${npmopts[@]}" --prefer-offline >/dev/null) || die "npm ci falhou"
    fi
}

# deps_env_dir <repo> -> pasta do ambiente de dependências limpo desse repositório.
# A chave depende só de eval/repos (commit fixado e, no Python, o requirements.txt com
# hashes); o check.py calcula o mesmo caminho dentro do container das verificações.
deps_env_dir() {
    local name="$1" sha key req
    sha="$(json_get "$(repo_json "$name")" commit)"
    req="$EVAL_DIR/repos/$name/requirements.txt"
    if [ -f "$req" ]; then key="$(sha256sum "$req" | cut -c1-8)"; else key=lock; fi
    echo "$EVAL_CACHE/envs/$name-${sha:0:12}-$key"
}

# ensure_deps_env <repo> -> cria (uma vez) e imprime o ambiente limpo: .venv (Python) ou
# node_modules (Node), instalados do cache, fora de qualquer workdir. As verificações
# rodam com ele, nunca com o .venv/node_modules que o agente pôde alterar.
ensure_deps_env() {
    local name="$1" dir kind sha mirror
    dir="$(deps_env_dir "$name")"
    if [ -f "$dir/.complete" ]; then echo "$dir"; return; fi
    kind="$(json_get "$(repo_json "$name")" kind)"
    rm -rf "$dir"; mkdir -p "$dir"
    case "$kind" in
        python) install_python_deps "$name" "$dir" ;;
        node)
            sha="$(json_get "$(repo_json "$name")" commit)"
            mirror="$(ensure_mirror "$name")" || exit 2
            git --git-dir="$mirror" archive --format=tar "$sha" package.json package-lock.json \
                | tar -x -C "$dir" || die "package.json/package-lock.json ausentes em $name"
            install_node_deps "$dir" ;;
        *) die "tipo de repositório desconhecido: $kind" ;;
    esac
    touch "$dir/.complete"
    echo "$dir"
}

# prepare_workdir <task_dir> <workdir>
# Cria um workdir novo: árvore do commit fixado + setup.patch (bug, remoção de testes...),
# commit-base único (sem histórico do upstream, para não revelar o que foi plantado),
# dependências instaladas e, se houver, pending.patch aplicado sem commit (T7).
prepare_workdir() {
    local task_dir wd="$2" tj repo kind mirror sha f
    task_dir="$(cd "$1" && pwd)"
    [ -n "$wd" ] || die "workdir vazio"
    wd="$(realpath -m "$wd")"
    cd "$EVAL_DIR" || die "sem acesso a $EVAL_DIR"   # o cwd pode estar dentro do workdir apagado
    tj="$task_dir/task.json"; [ -f "$tj" ] || die "task.json ausente em $task_dir"
    repo="$(json_get "$tj" repo)"; kind="$(json_get "$(repo_json "$repo")" kind)"
    sha="$(json_get "$(repo_json "$repo")" commit)"
    mirror="$(ensure_mirror "$repo")" || exit 2
    # Ambiente limpo para as verificações: criado antes de qualquer agente rodar.
    ensure_deps_env "$repo" >/dev/null || exit 2

    case "$wd" in /|"$HOME"|"$REPO_ROOT"|"$EVAL_DIR"|"") die "workdir inválido: '$wd'";; esac
    rm -rf "$wd"; mkdir -p "$wd"
    git --git-dir="$mirror" archive --format=tar "$sha" | tar -x -C "$wd" || die "git archive falhou"
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
        git -C "$wd" apply --whitespace=nowarn "$task_dir/setup.patch" || die "setup.patch não aplica"
    fi
    git -C "$wd" add -A
    git -C "$wd" commit -q -m "Initial import" || die "commit-base falhou"

    case "$kind" in
        python) install_python_deps "$repo" "$wd" ;;
        node) install_node_deps "$wd" ;;
        *) die "tipo de repositório desconhecido: $kind" ;;
    esac

    if [ -f "$task_dir/pending.patch" ]; then
        git -C "$wd" apply --whitespace=nowarn "$task_dir/pending.patch" || die "pending.patch não aplica"
    fi
}

# resolve_task <id> -> diretório da tarefa (aceita T2, S1, K1, T2-pypika-..., ou caminho)
resolve_task() {
    local id="$1" d
    if [ -d "$id" ] && [ -f "$id/task.json" ]; then (cd "$id" && pwd); return; fi
    for d in "$EVAL_DIR"/{tasks,smoke,skills}/"$id" "$EVAL_DIR"/{tasks,smoke,skills}/"$id"-*; do
        if [ -f "$d/task.json" ]; then echo "$d"; return; fi
    done
    die "tarefa não encontrada: $id"
}

# resolve_harness <nome> -> caminho do run.sh (eval/harnesses/ tem prioridade sobre agents/)
resolve_harness() {
    local h="$1" p
    for p in "$EVAL_DIR/harnesses/$h/run.sh" "$REPO_ROOT/agents/$h/run.sh"; do
        if [ -x "$p" ]; then echo "$p"; return; fi
    done
    die "harness não encontrado ou não executável: $h (procurado em eval/harnesses/ e agents/)"
}

# apply_solution <task_dir> <workdir>: aplica a solução de referência (usado pelo
# validate.sh e pelo harness fake-oracle). solution.patch é relativo ao commit-base;
# solution/ (opcional) contém arquivos copiados para a raiz do workdir (relatórios).
apply_solution() {
    local task_dir="$1" wd="$2"
    if [ -f "$task_dir/solution.patch" ]; then
        git -C "$wd" apply --whitespace=nowarn "$task_dir/solution.patch" || die "solution.patch não aplica"
    fi
    if [ -d "$task_dir/solution" ]; then
        cp -r "$task_dir/solution/." "$wd/"
    fi
}

# load_llm_api_key: chave do llama-server (E5). Usa LLM_API_KEY do ambiente; senão lê
# LLM_API_KEY_FILE (padrão ~/.config/local-agentic/llm-api-key, criado por scripts/llm key).
# Exporta LLM_API_KEY para o harness (o sandbox/run-in-box.sh repassa LLM_* ao container)
# e para o metrics.py. Nunca imprime a chave. Define LLM_API_KEY_SOURCE: env | file | none.
load_llm_api_key() {
    local f="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}" line
    if [ -n "${LLM_API_KEY:-}" ]; then
        LLM_API_KEY_SOURCE=env
    elif [ -r "$f" ]; then
        # Primeira linha que não é comentário nem vazia (o servidor aceita uma chave por linha).
        line="$(grep -v -E '^[[:space:]]*(#|$)' "$f" | head -n 1)"
        LLM_API_KEY="${line//[[:space:]]/}"
        if [ -n "$LLM_API_KEY" ]; then LLM_API_KEY_SOURCE=file; else LLM_API_KEY_SOURCE=none; fi
    else
        LLM_API_KEY="" LLM_API_KEY_SOURCE=none
    fi
    export LLM_API_KEY LLM_API_KEY_SOURCE
    if [ "$LLM_API_KEY_SOURCE" = none ]; then
        log "AVISO: sem chave do llama-server (LLM_API_KEY ou $f): /metrics e o agente vão receber 401"
    fi
}
