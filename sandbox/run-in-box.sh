#!/usr/bin/env bash
# Executa um comando num container agent-box novo: a barreira real da E7.
#
# Uso: sandbox/run-in-box.sh [opções] -- <comando> [argumentos...]
#
#   --rw <caminho>        monta com leitura e escrita, no MESMO caminho absoluto (repetível)
#   --ro <caminho>        monta só leitura, no mesmo caminho absoluto (repetível)
#   --cwd <dir>           diretório de trabalho (padrão: o atual, se estiver montado; senão o 1º --rw)
#   --env NOME[=VALOR]    repassa mais uma variável (repetível)
#   --no-llm              sem o encaminhador para o llama-server
#   --tty                 sessão interativa (docker run -it)
#   --protect-git <repo>  .git preso no lugar, .git/config e .git/hooks só leitura, e
#                         auditoria do .git no fim (ver sandbox/README.md, "Git")
#
# Sempre: agents/ só leitura; raiz do container só leitura; HOME, /tmp e /var/tmp em
# tmpfs; --network none (o único caminho para fora é o encaminhador do llama-server);
# --cap-drop ALL; no-new-privileges; limites de memória, CPU e processos; sem o socket
# do Docker, sem a HOME do host, sem nenhuma variável do host além das listadas abaixo.
#
# Variáveis repassadas: LLM_* (LLM_BASE_URL reescrita para o encaminhador interno),
# LOCAL_LLM_API_KEY, AGENT_* (menos AGENT_BIN/HOME/WORKDIR/LOG_DIR/GUARD), CLAUDE_LOCAL_*,
# CODEX_LOCAL_*, QWEN_LOCAL_*, PI_LOCAL_*, OPENCODE_LOCAL_*, FAKE_ORACLE_*, GIT_AUTHOR_*,
# GIT_COMMITTER_*, EVAL_TEST_TIMEOUT_S; TZ (fuso do host); TERM (com --tty).
#
# Ajustes: BOX_IMAGE (agent-box:latest), BOX_MEMORY (8g), BOX_CPUS (8), BOX_PIDS (2048),
# BOX_TMP_SIZE (4g), BOX_HOME_SIZE (1g), BOX_ALLOW_STALE=1 (aceita imagem de outras versões),
# BOX_DRY_RUN=1 (só mostra o docker run, sem conferir a imagem nem subir nada).
#
# Saída: a do comando; 125 = erro do wrapper ou do Docker. SIGTERM/SIGINT removem o container.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

rw=() ro=() extra_env=() protect=() cwd="" llm=1 tty=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rw) rw+=("${2:?--rw sem caminho}"); shift 2 ;;
        --ro) ro+=("${2:?--ro sem caminho}"); shift 2 ;;
        --cwd) cwd="${2:?--cwd sem caminho}"; shift 2 ;;
        --env) extra_env+=("${2:?--env sem variável}"); shift 2 ;;
        --no-llm) llm=0; shift ;;
        --tty) tty=1; shift ;;
        --protect-git) protect+=("${2:?--protect-git sem caminho}"); shift 2 ;;
        --) shift; break ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) box_die "opção desconhecida: $1 (o comando vem depois de --)" ;;
    esac
done
[ $# -gt 0 ] || box_die "falta o comando (depois de --)"

# Absoluto e normalizado, sem resolver links: o mesmo caminho dentro e fora.
abs() { realpath -m -s -- "$1"; }

# Recusa montagens que exporiam o host: raiz, HOME inteira (ou um ancestral dela),
# diretórios de sistema e de sockets, discos do Windows, pastas de credenciais.
check_mount() { # <caminho absoluto>
    local p="$1" real x
    [ -e "$p" ] || box_die "não existe: $p"
    case "$p" in *,*|*\"*|*$'\n'*) box_die "caminho com vírgula, aspas ou quebra de linha não é suportado: $p" ;; esac
    real="$(realpath -m -- "$p")"
    for x in "$p" "$real"; do
        case "$x" in
            /|/tmp|/var|/var/tmp|/home|/mnt|/mnt/?|/mnt/wsl|/mnt/wsl/*|/mnt/wslg|/mnt/wslg/*|\
            /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/var/run|/var/run/*|/etc|/etc/*|\
            /boot|/boot/*|/root|/root/*|/usr|/usr/*|/opt|/var/lib|/var/lib/*)
                box_die "montagem recusada: $x" ;;
        esac
        case "$HOME/" in "$x"/*) box_die "montagem recusada: $x contém a HOME do host" ;; esac
        case "$x/" in
            "$HOME"/.ssh/*|"$HOME"/.gnupg/*|"$HOME"/.aws/*|"$HOME"/.docker/*|"$HOME"/.kube/*|\
            "$HOME"/.config/gh/*|"$HOME"/.claude/*|"$HOME"/.claude.json/*|"$HOME"/.codex/*|\
            "$HOME"/.git-credentials/*|"$HOME"/.netrc/*|"$HOME"/.npmrc/*|"$HOME"/.pypirc/*|\
            "$HOME"/.local/share/keyrings/*|"$HOME"/.password-store/*)
                box_die "montagem recusada (credenciais): $x" ;;
        esac
    done
}

# .git aninhados (submódulos, repositórios embutidos) de um projeto.
nested_git_list() { # <repo>
    find "$1" \( -path "$1/.git" -o -name node_modules -o -name .venv \) -prune \
        -o -name .git -print 2>/dev/null | LC_ALL=C sort
}

# --- imagem -----------------------------------------------------------------------
dry="${BOX_DRY_RUN:-0}"
if [ "$dry" = 1 ]; then labels="$(agents_versions_hash)|$(id -u)"; else
labels="$(docker image inspect -f \
    '{{index .Config.Labels "local-agentic.agents-versions"}}|{{index .Config.Labels "local-agentic.uid"}}' \
    "$BOX_IMAGE" 2>/dev/null)" || box_die "imagem $BOX_IMAGE não encontrada: rode sandbox/build.sh"
fi
IFS='|' read -r img_hash img_uid <<<"$labels"
if [ "$img_hash" != "$(agents_versions_hash)" ] && [ "${BOX_ALLOW_STALE:-0}" != 1 ]; then
    box_die "a imagem $BOX_IMAGE foi construída com outras versões dos agentes (agents/versions.env mudou): rode sandbox/build.sh (ou BOX_ALLOW_STALE=1)"
fi
[ "$img_uid" = "$(id -u)" ] || box_warn "imagem construída para o UID $img_uid; rodando como $(id -u)"

# --- estado temporário (socket do encaminhador, auditoria do git) ------------------
started=0 finished=0 fwd_pid="" rt=""
cname="agent-box-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
cleanup() {
    if [ "$started" = 1 ] && [ "$finished" != 1 ]; then
        docker rm -f "$cname" >/dev/null 2>&1 || true
    fi
    if [ -n "$fwd_pid" ]; then
        kill "$fwd_pid" 2>/dev/null || true
        wait "$fwd_pid" 2>/dev/null || true
    fi
    [ -z "$rt" ] || rm -rf "$rt"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
# Caminho curto: o socket unix tem limite de 107 bytes.
rt_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
[ "${#rt_base}" -le 60 ] || rt_base=/tmp
rt="$(mktemp -d "$rt_base/agent-box.XXXXXX")"

# --- montagens --------------------------------------------------------------------
mounts=(--mount "type=bind,source=$AGENTS_DIR,target=$AGENTS_DIR,readonly")
rw_abs=() ro_abs=()
for p in "${ro[@]}"; do
    p="$(abs "$p")"; check_mount "$p"; ro_abs+=("$p")
    mounts+=(--mount "type=bind,source=$p,target=$p,readonly")
done
for p in "${rw[@]}"; do
    p="$(abs "$p")"; check_mount "$p"; rw_abs+=("$p")
    mounts+=(--mount "type=bind,source=$p,target=$p")
done

git_repos=()
for r in "${protect[@]}"; do
    r="$(abs "$r")"; g="$r/.git"
    if [ -L "$g" ] || [ ! -e "$g" ]; then
        box_warn "$r não tem diretório .git; nada a proteger"; continue
    fi
    if [ -f "$g" ]; then
        box_warn "$g é um arquivo (worktree ou submódulo): o gitdir real fica fora do container e o git não funciona lá dentro"
        continue
    fi
    [ -f "$g/config" ] || box_die "$g/config não existe"
    mkdir -p "$g/hooks"
    # .git montado sobre si mesmo: vira ponto de montagem e não pode ser renomeado nem
    # trocado por outro .git; config e hooks (e os config de submódulos) só leitura.
    mounts+=(--mount "type=bind,source=$g,target=$g"
             --mount "type=bind,source=$g/config,target=$g/config,readonly"
             --mount "type=bind,source=$g/hooks,target=$g/hooks,readonly")
    if [ -d "$g/modules" ]; then
        while IFS= read -r m; do
            mounts+=(--mount "type=bind,source=$m,target=$m,readonly")
        done < <(find "$g/modules" -name config -type f 2>/dev/null)
    fi
    nested_git_list "$r" >"$rt/git-before.${#git_repos[@]}"
    git_repos+=("$r")
done

if [ -z "$cwd" ]; then
    for p in "${rw_abs[@]}" "${ro_abs[@]}"; do
        case "$PWD/" in "$p"/*) cwd="$PWD"; break ;; esac
    done
    [ -n "$cwd" ] || cwd="${rw_abs[0]:-/tmp}"
fi
cwd="$(abs "$cwd")"

# --- ambiente ---------------------------------------------------------------------
envs=(-e "HOME=/home/agent" -e "TZ=$(host_tz)")
while IFS= read -r v; do
    case "$v" in
        LLM_BASE_URL|AGENT_BIN|AGENT_HOME|AGENT_WORKDIR|AGENT_LOG_DIR|AGENT_GUARD) ;;
        LLM_*|LOCAL_LLM_API_KEY|AGENT_*|CLAUDE_LOCAL_*|CODEX_LOCAL_*|QWEN_LOCAL_*|PI_LOCAL_*|\
        OPENCODE_LOCAL_*|FAKE_ORACLE_*|GIT_AUTHOR_*|GIT_COMMITTER_*|EVAL_TEST_TIMEOUT_S)
            envs+=(-e "$v") ;;   # sem valor: o docker lê do ambiente (não aparece no ps)
    esac
done < <(compgen -e)
for e in "${extra_env[@]}"; do envs+=(-e "$e"); done
[ "$tty" != 1 ] || envs+=(-e "TERM=${TERM:-xterm-256color}")

# --- encaminhador do llama-server -------------------------------------------------
if [ "$llm" = 1 ] && [ "$dry" = 1 ]; then
    envs+=(-e "LLM_BASE_URL=<reescrita>" -e "BOX_LLM_PORT=<porta>")
    mounts+=(--mount "type=bind,source=<socket do encaminhador>,target=/run/agent-box,readonly")
elif [ "$llm" = 1 ]; then
    base="${LLM_BASE_URL:-http://127.0.0.1:9931}"
    base="${base%/}"
    re='^http://(127\.0\.0\.1|localhost)(:([0-9]+))?(/.*)?$'
    [[ "$base" =~ $re ]] || box_die "LLM_BASE_URL precisa ser http://127.0.0.1:<porta> (o container só alcança o llama-server local): $base"
    port="${BASH_REMATCH[3]:-80}" path="${BASH_REMATCH[4]}"
    mkdir -m 700 "$rt/llm"
    quiet=()
    [ "$tty" != 1 ] || quiet=(--quiet)
    python3 -I "$SANDBOX_DIR/llm-forward.py" host --socket "$rt/llm/llm.sock" \
        --target "127.0.0.1:$port" "${quiet[@]}" </dev/null &
    fwd_pid=$!
    for _ in $(seq 50); do
        [ -S "$rt/llm/llm.sock" ] && break
        kill -0 "$fwd_pid" 2>/dev/null || box_die "o encaminhador do host não subiu"
        sleep 0.1
    done
    [ -S "$rt/llm/llm.sock" ] || box_die "o encaminhador do host não criou o socket"
    mounts+=(--mount "type=bind,source=$rt/llm,target=/run/agent-box,readonly")
    envs+=(-e "LLM_BASE_URL=http://127.0.0.1:$port$path" -e "BOX_LLM_PORT=$port")
fi

# --- container --------------------------------------------------------------------
uid="$(id -u)" gid="$(id -g)" mem="${BOX_MEMORY:-8g}"
run=(docker run --rm --init --pull never --runtime runc
     --name "$cname" --label "$BOX_LABEL=1" --hostname agent-box
     --user "$uid:$gid"
     --network none
     --read-only
     --tmpfs "/tmp:rw,exec,nosuid,nodev,size=${BOX_TMP_SIZE:-4g},mode=1777"
     --tmpfs "/var/tmp:rw,exec,nosuid,nodev,size=512m,mode=1777"
     --tmpfs "/home/agent:rw,exec,nosuid,nodev,size=${BOX_HOME_SIZE:-1g},uid=$uid,gid=$gid,mode=0700"
     --cap-drop ALL --security-opt no-new-privileges
     --pids-limit "${BOX_PIDS:-2048}" --memory "$mem" --memory-swap "$mem" --cpus "${BOX_CPUS:-8}"
     --oom-score-adj 500 --ipc private --ulimit core=0
     --workdir "$cwd"
     "${mounts[@]}" "${envs[@]}")
[ "$tty" != 1 ] || run+=(-it)
run+=("$BOX_IMAGE" "$@")
if [ "$dry" = 1 ]; then
    printf '%q ' "${run[@]}"; echo
    exit 0
fi

if [ "$tty" = 1 ]; then
    [ -t 0 ] && [ -t 1 ] || box_die "--tty precisa de um terminal"
fi
started=1
if [ "$tty" = 1 ]; then
    set +e; "${run[@]}"; rc=$?; set -e
else
    # Em segundo plano para que SIGTERM (timeout do eval) chegue logo ao trap.
    "${run[@]}" </dev/null &
    set +e; wait "$!"; rc=$?; set -e
fi
finished=1

# --- auditoria do .git (--protect-git) ----------------------------------------------
i=0
for r in "${git_repos[@]}"; do
    g="$r/.git" ts="$(date +%Y%m%d%H%M%S)"
    for f in commondir config.worktree; do
        if [ -e "$g/$f" ] || [ -L "$g/$f" ]; then
            mv -- "$g/$f" "$g/$f.agent-box-quarentena-$ts" || box_warn "não consegui renomear $g/$f"
            box_warn "$g/$f apareceu na sessão e foi renomeado para $f.agent-box-quarentena-$ts (faria o git do host ler a configuração de outro lugar)"
        fi
    done
    new="$(LC_ALL=C comm -13 "$rt/git-before.$i" <(nested_git_list "$r") || true)"
    if [ -n "$new" ]; then
        box_warn "repositórios git aninhados novos em $r (o git do host executaria a configuração deles ao olhar submódulos):"
        sed 's/^/    /' <<<"$new" >&2
        box_warn "revise antes de usar git no host, por exemplo: git -c core.fsmonitor=false -c core.hooksPath=/dev/null status --ignore-submodules=all"
    fi
    i=$((i + 1))
done

exit "$rc"
