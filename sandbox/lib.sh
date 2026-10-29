# shellcheck shell=bash
# Funções comuns de sandbox/build.sh, run-in-box.sh, agent-shell.sh e escape-tests.sh.
# Uso: source "$(dirname "$(readlink -f "$0")")/lib.sh"

SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SANDBOX_DIR/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
BOX_IMAGE="${BOX_IMAGE:-agent-box:latest}"
# Rótulo comum dos containers: `docker ps -a --filter label=local-agentic.agent-box`
BOX_LABEL="local-agentic.agent-box"

box_die() { echo "agent-box: $*" >&2; exit 125; }
box_warn() { echo "agent-box: aviso: $*" >&2; }

# Impressão digital das versões fixadas dos agentes (linhas *_PKG, *_VERSION e
# *_INTEGRITY de agents/versions.env). Vai como rótulo na imagem; run-in-box.sh
# recusa uma imagem construída com outras versões.
agents_versions_hash() {
    grep -E '^[A-Z_]+_(PKG|VERSION|INTEGRITY)=' "$AGENTS_DIR/versions.env" | sha256sum | cut -c1-16
}

# Fuso do host (as tarefas do chrono dependem dele; ver eval/README.md).
host_tz() {
    if [ -n "${TZ:-}" ]; then echo "$TZ"; return; fi
    if [ -s /etc/timezone ]; then head -n1 /etc/timezone; return; fi
    local z
    z="$(readlink -f /etc/localtime 2>/dev/null || true)"
    case "$z" in */zoneinfo/*) echo "${z#*/zoneinfo/}" ;; *) echo UTC ;; esac
}
