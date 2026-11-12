# shellcheck shell=bash
# Shared functions for sandbox/build.sh, run-in-box.sh, agent-shell.sh and escape-tests.sh.
# Usage: source "$(dirname "$(readlink -f "$0")")/lib.sh"

SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SANDBOX_DIR/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
BOX_IMAGE="${BOX_IMAGE:-agent-box:latest}"
# Common container label: `docker ps -a --filter label=local-agentic.agent-box`
BOX_LABEL="local-agentic.agent-box"

box_die() { echo "agent-box: $*" >&2; exit 125; }
box_warn() { echo "agent-box: warning: $*" >&2; }

# Fingerprint of the pinned agent versions (*_PKG, *_VERSION and *_INTEGRITY lines
# of agents/versions.env). It goes into the image as a label; run-in-box.sh
# refuses an image built with other versions.
agents_versions_hash() {
    grep -E '^[A-Z_]+_(PKG|VERSION|INTEGRITY)=' "$AGENTS_DIR/versions.env" | sha256sum | cut -c1-16
}

# Prefix of the skills materialized by scripts/fetch-skills.sh (SKILLS_PREFIX from the
# root versions.env; the environment variable overrides it).
skills_prefix() {
    if [ -n "${SKILLS_PREFIX:-}" ]; then echo "$SKILLS_PREFIX"; return; fi
    (set +eu; source "$REPO_ROOT/versions.env" >/dev/null 2>&1; echo "${SKILLS_PREFIX:-$HOME/.local/opt/skills}")
}

# The script's header comment, used as help.
box_usage() { awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$1"; }

# Host time zone (the chrono tasks depend on it; see eval/README.md).
host_tz() {
    if [ -n "${TZ:-}" ]; then echo "$TZ"; return; fi
    if [ -s /etc/timezone ]; then head -n1 /etc/timezone; return; fi
    local z
    z="$(readlink -f /etc/localtime 2>/dev/null || true)"
    case "$z" in */zoneinfo/*) echo "${z#*/zoneinfo/}" ;; *) echo UTC ;; esac
}
