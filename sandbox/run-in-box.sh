#!/usr/bin/env bash
# Runs a command in a new agent-box container: the real barrier of E7.
#
# Usage: sandbox/run-in-box.sh [options] -- <command> [arguments...]
#
#   --rw <path>           mounts read-write, at the SAME absolute path (repeatable)
#   --ro <path>           mounts read-only, at the same absolute path (repeatable)
#   --cwd <dir>           working directory (default: the current one, if mounted; else the 1st --rw)
#   --env NAME[=VALUE]    passes one more variable (repeatable)
#   --no-llm              no forwarder to llama-server
#   --tty                 interactive session (docker run -it)
#   --protect-git <repo>  .git pinned in place, .git/config and .git/hooks read-only, and
#                         a .git audit at the end (see sandbox/README.md, "Git")
#   --skills-dir <dir>    personal skills, read-only at /opt/skills/extra-N (repeatable;
#                         BOX_SKILLS_DIRS=dir1:dir2 does the same)
#   --no-skills           no skills (neither the base nor the extra ones)
#
# Skills: the base profile ($SKILLS_PREFIX/profiles/base, from scripts/fetch-skills.sh) is
# mounted read-only at /opt/skills/base; the project's come with the workdir (.agents/skills,
# .claude/skills). AGENT_SKILLS_DIRS lists, separated by ":", those mounted under /opt/skills.
#
# Always: agents/ read-only; container root read-only; HOME, /tmp and /var/tmp on
# tmpfs; --network none (the only way out is the llama-server forwarder);
# --cap-drop ALL; no-new-privileges; memory, CPU and process limits; no Docker socket,
# no host HOME, no host variable other than those listed below.
#
# Set by the wrapper (host values are ignored): AGENT_BOX=1 (the run.sh scripts in the
# autonomous profile refuse to run without it), AGENT_SKILLS_DIRS, LLM_BASE_URL (rewritten to
# the internal forwarder), HOME, TZ (host time zone), TERM (with --tty).
# Passed through from the host: LLM_* (includes LLM_API_KEY; without it, read from LLM_API_KEY_FILE or
# ~/.config/local-agentic/llm-api-key), LOCAL_LLM_API_KEY, the AGENT_* settings
# (except AGENT_BIN/HOME/WORKDIR/LOG_DIR/GUARD), CLAUDE_LOCAL_*, CODEX_LOCAL_*, QWEN_LOCAL_*,
# PI_LOCAL_*, OPENCODE_LOCAL_*, FAKE_ORACLE_*, GIT_AUTHOR_*, GIT_COMMITTER_*, EVAL_TEST_TIMEOUT_S.
#
# Settings: BOX_IMAGE (agent-box:latest), BOX_MEMORY (8g), BOX_CPUS (8), BOX_PIDS (2048),
# BOX_TMP_SIZE (4g), BOX_HOME_SIZE (1g), BOX_ALLOW_STALE=1 (accepts an image with other versions),
# BOX_DRY_RUN=1 (only prints the docker run, without checking the image or starting anything).
#
# Exit: that of the command; 125 = wrapper or Docker error. SIGTERM/SIGINT remove the container.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

rw=() ro=() extra_env=() protect=() skills=() cwd="" llm=1 tty=0 use_skills=1 net="${BOX_NETWORK:-none}"
while [ $# -gt 0 ]; do
    case "$1" in
        --rw) rw+=("${2:?--rw without a path}"); shift 2 ;;
        --ro) ro+=("${2:?--ro without a path}"); shift 2 ;;
        --cwd) cwd="${2:?--cwd without a path}"; shift 2 ;;
        --env) extra_env+=("${2:?--env without a variable}"); shift 2 ;;
        --no-llm) llm=0; shift ;;
        --tty) tty=1; shift ;;
        --protect-git) protect+=("${2:?--protect-git without a path}"); shift 2 ;;
        --skills-dir) skills+=("${2:?--skills-dir without a path}"); shift 2 ;;
        --no-skills) use_skills=0; shift ;;
        --net) net=bridge; shift ;;
        --) shift; break ;;
        -h|--help) box_usage "$0"; exit 0 ;;
        *) box_die "unknown option: $1 (the command comes after --)" ;;
    esac
done
[ $# -gt 0 ] || box_die "missing command (after --)"

# Absolute and normalized, without resolving links: the same path inside and out.
abs() { realpath -m -s -- "$1"; }

# Refuses mounts that would expose the host: root, the whole HOME (or an ancestor of it),
# system and socket directories, Windows drives, credential folders.
check_mount() { # <absolute path>
    local p="$1" real x
    [ -e "$p" ] || box_die "does not exist: $p"
    case "$p" in *,*|*\"*|*$'\n'*) box_die "path with a comma, quote or newline is not supported: $p" ;; esac
    real="$(realpath -m -- "$p")"
    for x in "$p" "$real"; do
        case "$x" in
            /|/tmp|/var|/var/tmp|/home|/mnt|/mnt/?|/mnt/wsl|/mnt/wsl/*|/mnt/wslg|/mnt/wslg/*|\
            /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/var/run|/var/run/*|/etc|/etc/*|\
            /boot|/boot/*|/root|/root/*|/usr|/usr/*|/opt|/var/lib|/var/lib/*)
                box_die "mount refused: $x" ;;
        esac
        case "$HOME/" in "$x"/*) box_die "mount refused: $x contains the host HOME" ;; esac
        case "$x/" in
            "$HOME"/.ssh/*|"$HOME"/.gnupg/*|"$HOME"/.aws/*|"$HOME"/.docker/*|"$HOME"/.kube/*|\
            "$HOME"/.config/gh/*|"$HOME"/.claude/*|"$HOME"/.claude.json/*|"$HOME"/.codex/*|\
            "$HOME"/.git-credentials/*|"$HOME"/.netrc/*|"$HOME"/.npmrc/*|"$HOME"/.pypirc/*|\
            "$HOME"/.local/share/keyrings/*|"$HOME"/.password-store/*)
                box_die "mount refused (credentials): $x" ;;
        esac
    done
}

# Nested .git directories (submodules, embedded repositories) of a project.
nested_git_list() { # <repo>
    find "$1" \( -path "$1/.git" -o -name node_modules -o -name .venv \) -prune \
        -o -name .git -print 2>/dev/null | LC_ALL=C sort
}

# --- image -----------------------------------------------------------------------
dry="${BOX_DRY_RUN:-0}"
if [ "$dry" = 1 ]; then labels="$(agents_versions_hash)|$(id -u)"; else
labels="$(docker image inspect -f \
    '{{index .Config.Labels "local-agentic.agents-versions"}}|{{index .Config.Labels "local-agentic.uid"}}' \
    "$BOX_IMAGE" 2>/dev/null)" || box_die "image $BOX_IMAGE not found: run sandbox/build.sh"
fi
IFS='|' read -r img_hash img_uid <<<"$labels"
if [ "$img_hash" != "$(agents_versions_hash)" ] && [ "${BOX_ALLOW_STALE:-0}" != 1 ]; then
    box_die "image $BOX_IMAGE was built with other agent versions (agents/versions.env changed): run sandbox/build.sh (or BOX_ALLOW_STALE=1)"
fi
[ "$img_uid" = "$(id -u)" ] || box_warn "image built for UID $img_uid; running as $(id -u)"

# --- temporary state (forwarder socket, git audit) ------------------
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
# Short path: the unix socket has a 107-byte limit.
rt_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
[ "${#rt_base}" -le 60 ] || rt_base=/tmp
rt="$(mktemp -d "$rt_base/agent-box.XXXXXX")"

# --- mounts --------------------------------------------------------------------
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

# Skills: base and personal, read-only, outside the working mounts.
skill_dirs=()
if [ "$use_skills" = 1 ]; then
    base="$(skills_prefix)/profiles/base"
    if [ -d "$base" ]; then
        check_mount "$base"
        mounts+=(--mount "type=bind,source=$base,target=/opt/skills/base,readonly")
        skill_dirs+=(/opt/skills/base)
    else
        box_warn "base skills profile missing ($base): run scripts/fetch-skills.sh; continuing without it"
    fi
    IFS=: read -r -a env_skills <<<"${BOX_SKILLS_DIRS:-}"
    n=0
    for p in "${skills[@]}" "${env_skills[@]}"; do
        [ -n "$p" ] || continue
        p="$(abs "$p")"
        [ -d "$p" ] || box_die "--skills-dir is not a directory: $p"
        check_mount "$p"
        n=$((n + 1))
        mounts+=(--mount "type=bind,source=$p,target=/opt/skills/extra-$n,readonly")
        skill_dirs+=("/opt/skills/extra-$n")
    done
fi

git_repos=()
for r in "${protect[@]}"; do
    r="$(abs "$r")"; g="$r/.git"
    if [ -L "$g" ] || [ ! -e "$g" ]; then
        box_warn "$r has no .git directory; nothing to protect"; continue
    fi
    if [ -f "$g" ]; then
        box_warn "$g is a file (worktree or submodule): the real gitdir is outside the container and git does not work inside it"
        continue
    fi
    [ -f "$g/config" ] || box_die "$g/config does not exist"
    mkdir -p "$g/hooks"
    # .git mounted over itself: it becomes a mount point and cannot be renamed or
    # swapped for another .git; config and hooks (and the submodule configs) read-only.
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

# --- environment ---------------------------------------------------------------------
# llama-server key (E5): the file stays outside the container; without LLM_API_KEY in the
# environment, it is read from LLM_API_KEY_FILE (~/.config/local-agentic/llm-api-key). It goes by name
# (-e LLM_API_KEY), never on the command line.
if [ "$llm" = 1 ] && [ -z "${LLM_API_KEY:-}" ]; then
    kf="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}"
    if [ -r "$kf" ]; then
        LLM_API_KEY="$(tr -d '[:space:]' <"$kf")"
        export LLM_API_KEY
    fi
fi
envs=(-e "HOME=/home/agent" -e "TZ=$(host_tz)" -e AGENT_BOX=1
      -e "AGENT_SKILLS_DIRS=$(IFS=:; echo "${skill_dirs[*]}")")
while IFS= read -r v; do
    case "$v" in
        LLM_BASE_URL|AGENT_BOX|AGENT_SKILLS_DIRS|AGENT_BIN|AGENT_HOME|AGENT_WORKDIR|AGENT_LOG_DIR|AGENT_GUARD) ;;
        LLM_*|LOCAL_LLM_API_KEY|AGENT_*|CLAUDE_LOCAL_*|CODEX_LOCAL_*|QWEN_LOCAL_*|PI_LOCAL_*|\
        OPENCODE_LOCAL_*|FAKE_ORACLE_*|GIT_AUTHOR_*|GIT_COMMITTER_*|EVAL_TEST_TIMEOUT_S)
            envs+=(-e "$v") ;;   # no value: docker reads it from the environment (it does not show in ps)
    esac
done < <(compgen -e)
for e in "${extra_env[@]}"; do envs+=(-e "$e"); done
[ "$tty" != 1 ] || envs+=(-e "TERM=${TERM:-xterm-256color}")

# --- llama-server forwarder -------------------------------------------------
if [ "$llm" = 1 ] && [ "$dry" = 1 ]; then
    envs+=(-e "LLM_BASE_URL=<rewritten>" -e "BOX_LLM_PORT=<port>")
    mounts+=(--mount "type=bind,source=<forwarder socket>,target=/run/agent-box,readonly")
elif [ "$llm" = 1 ]; then
    base="${LLM_BASE_URL:-http://127.0.0.1:9931}"
    base="${base%/}"
    re='^http://(127\.0\.0\.1|localhost)(:([0-9]+))?(/.*)?$'
    [[ "$base" =~ $re ]] || box_die "LLM_BASE_URL must be http://127.0.0.1:<port> (the container only reaches the local llama-server): $base"
    port="${BASH_REMATCH[3]:-80}" path="${BASH_REMATCH[4]}"
    mkdir -m 700 "$rt/llm"
    quiet=()
    [ "$tty" != 1 ] || quiet=(--quiet)
    python3 -I "$SANDBOX_DIR/llm-forward.py" host --socket "$rt/llm/llm.sock" \
        --target "127.0.0.1:$port" "${quiet[@]}" </dev/null &
    fwd_pid=$!
    for _ in $(seq 50); do
        [ -S "$rt/llm/llm.sock" ] && break
        kill -0 "$fwd_pid" 2>/dev/null || box_die "the host forwarder did not start"
        sleep 0.1
    done
    [ -S "$rt/llm/llm.sock" ] || box_die "the host forwarder did not create the socket"
    mounts+=(--mount "type=bind,source=$rt/llm,target=/run/agent-box,readonly")
    envs+=(-e "LLM_BASE_URL=http://127.0.0.1:$port$path" -e "BOX_LLM_PORT=$port")
fi

[ "$net" = none ] || echo "agent-box: WARNING: external network enabled (--network $net). The agent can reach the internet and send whatever is mounted." >&2

# --- container --------------------------------------------------------------------
uid="$(id -u)" gid="$(id -g)" mem="${BOX_MEMORY:-8g}"
run=(docker run --rm --init --pull never --runtime runc
     --name "$cname" --label "$BOX_LABEL=1" --hostname agent-box
     --user "$uid:$gid"
     --network "$net"
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
    [ -t 0 ] && [ -t 1 ] || box_die "--tty needs a terminal"
fi
started=1
if [ "$tty" = 1 ]; then
    set +e; "${run[@]}"; rc=$?; set -e
else
    # In the background so that SIGTERM (eval timeout) reaches the trap promptly.
    "${run[@]}" </dev/null &
    set +e; wait "$!"; rc=$?; set -e
fi
finished=1

# --- .git audit (--protect-git) ----------------------------------------------
i=0
for r in "${git_repos[@]}"; do
    g="$r/.git" ts="$(date +%Y%m%d%H%M%S)"
    for f in commondir config.worktree; do
        if [ -e "$g/$f" ] || [ -L "$g/$f" ]; then
            mv -- "$g/$f" "$g/$f.agent-box-quarantine-$ts" || box_warn "could not rename $g/$f"
            box_warn "$g/$f appeared during the session and was renamed to $f.agent-box-quarantine-$ts (it would make the host git read its configuration from elsewhere)"
        fi
    done
    new="$(LC_ALL=C comm -13 "$rt/git-before.$i" <(nested_git_list "$r") || true)"
    if [ -n "$new" ]; then
        box_warn "new nested git repositories in $r (the host git would run their configuration when looking at submodules):"
        sed 's/^/    /' <<<"$new" >&2
        box_warn "review before using git on the host, for example: git -c core.fsmonitor=false -c core.hooksPath=/dev/null status --ignore-submodules=all"
    fi
    i=$((i + 1))
done

exit "$rc"
