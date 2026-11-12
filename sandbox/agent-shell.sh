#!/usr/bin/env bash
# Interactive agent session inside agent-box, with only the project mounted.
#
# Usage: sandbox/agent-shell.sh [--skills-dir <dir>]... <agent|shell> <project> [agent options...]
#   agent: qwen-code | pi | opencode | claude-local | codex-local
#   shell:  bash in the container, with the same isolation (to run tests, git, etc.)
#   --skills-dir: personal skills, read-only at /opt/skills/extra-N (repeatable)
#   --net: allows external network (internet/DNS). Default: no network, only the local model.
#
# - Mounts <project> read-write at the same absolute path; nothing else from the
#   host HOME. agents/ is mounted read-only (launchers and configuration).
# - Agent profile: AGENT_PROFILE=interactive (the launchers' default) or autonomous.
# - Agent state (sessions, generated config) in
#   ~/.local/state/local-agentic/agent-box/<agent>, separate from the state of the
#   launchers used directly on the host: what the agent writes in the container is
#   never read by an agent running outside it.
# - Skills: base profile at /opt/skills/base, personal ones at /opt/skills/extra-N, the
#   project's (.agents/skills, .claude/skills) come with it; list in AGENT_SKILLS_DIRS.
# - Project .git protected (--protect-git): config and hooks read-only, and an audit
#   at the end of the session. The rest of the project, including the history in .git,
#   can be changed or deleted by the agent: work on a copy or worktree.
# - Codex: its own sandbox (bubblewrap) does not work in the container; the session uses
#   --sandbox danger-full-access, with the profile's approval (on-request).
#   BOX_CODEX_SANDBOX changes the value.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

usage() { box_usage "$0" >&2; exit 2; }
box_args=()
while [ "${1:-}" = --skills-dir ] || [ "${1:-}" = --net ]; do
    if [ "$1" = --net ]; then box_args+=(--net); shift; continue; fi
    box_args+=(--skills-dir "${2:?--skills-dir without a path}")
    shift 2
done
[ $# -ge 2 ] || usage
harness="$1" proj="$2"
shift 2
[ -d "$proj" ] || box_die "project does not exist: $proj"
proj="$(cd "$proj" && pwd)"

case "$harness" in
    qwen-code) launcher=qwen-local ;;
    pi) launcher=pi-local ;;
    opencode) launcher=opencode-local ;;
    claude-local) launcher=claude-local ;;
    codex-local) launcher=codex-local ;;
    shell) launcher="" ;;
    *) usage ;;
esac

# Git identity for commits made in the container: the host's global one (name and
# email only; nothing else from the host configuration enters the container).
if [ -z "${GIT_AUTHOR_NAME:-}" ]; then
    n="$(git config --global --get user.name 2>/dev/null || true)"
    e="$(git config --global --get user.email 2>/dev/null || true)"
    if [ -n "$n" ] && [ -n "$e" ]; then
        export GIT_AUTHOR_NAME="$n" GIT_COMMITTER_NAME="$n" GIT_AUTHOR_EMAIL="$e" GIT_COMMITTER_EMAIL="$e"
    fi
fi

args=(--tty --rw "$proj" --cwd "$proj" --protect-git "$proj" "${box_args[@]}")
if [ -z "$launcher" ]; then
    cmd=(bash -l)
else
    state="${AGENT_BOX_STATE:-$HOME/.local/state/local-agentic/agent-box}"
    mkdir -p "$state/$harness"
    chmod 700 "$state"
    args+=(--rw "$state/$harness" --env "AGENTS_STATE=$state")
    cmd=("$AGENTS_DIR/$harness/$launcher")
    if [ "$harness" = codex-local ]; then
        cmd+=(--sandbox "${BOX_CODEX_SANDBOX:-danger-full-access}")
    fi
fi

exec "$SANDBOX_DIR/run-in-box.sh" "${args[@]}" -- "${cmd[@]}" "$@"
