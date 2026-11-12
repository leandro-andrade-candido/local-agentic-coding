#!/usr/bin/env bash
# Installs an agent at the version pinned in agents/versions.env, isolated in
# $AGENTS_PREFIX/<agent>/<version> (npm --global --prefix), and points the
# "current" link at it. Earlier versions stay on disk: to roll back, point
# "current" at the old one.
#
# Nothing runs with the real HOME: npm (cache, ~/.npmrc, install scripts) and
# `<agent> --version` run with a clean environment, a temporary HOME and each
# agent's isolation variables pointing at it (some agents create files in HOME
# already at --version). So ~/.claude, ~/.claude.json, ~/.codex, ~/.qwen,
# ~/.pi, ~/.config/opencode and npm's global prefix (nvm) are not touched.
#
# Integrity: the agent tarball is downloaded with `npm pack` and the sha512 of the
# FILE is checked against versions.env before installing (same method as
# sandbox/install-agents.sh). Dependencies come from the registry and npm checks
# each one against the published integrity.
#
# Usage: agents/install.sh <qwen-code|pi|opencode|claude-local|codex-local|all>
# Uninstall: rm -rf "$AGENTS_PREFIX/<agent>"
set -euo pipefail
AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS_DIR/versions.env"

work="$(mktemp -d "${TMPDIR:-/tmp}/agents-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"

# Clean environment and disposable HOME for everything npm and the agents run.
isolated() {
  env -i PATH="$PATH" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" TMPDIR="$work" \
    HOME="$work/home" \
    XDG_CONFIG_HOME="$work/home/.config" XDG_DATA_HOME="$work/home/.local/share" \
    XDG_CACHE_HOME="$work/home/.cache" XDG_STATE_HOME="$work/home/.local/state" \
    QWEN_HOME="$work/home/qwen" CODEX_HOME="$work/home/codex" \
    CLAUDE_CONFIG_DIR="$work/home/claude" PI_CODING_AGENT_DIR="$work/home/pi" \
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 \
    npm_config_cache="$work/npm-cache" npm_config_update_notifier=false \
    npm_config_fund=false npm_config_audit=false \
    "$@"
}

sri() {
  python3 -I -c 'import base64, hashlib, sys
print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"
}

install_one() { # <agent> <package> <version> <integrity> <executable>
  local name="$1" pkg="$2" ver="$3" want="$4" exe="$5"
  local dest="$AGENTS_PREFIX/$name/$ver" dir="$work/$name" tgz got
  if [ ! -x "$dest/bin/$exe" ]; then
    mkdir -p "$dir"
    tgz="$(isolated npm pack --json --pack-destination "$dir" "$pkg@$ver" | jq -r '.[0].filename')"
    got="$(sri "$dir/$tgz")"
    if [ "$got" != "$want" ]; then
      echo "error: integrity of $pkg@$ver does not match" >&2
      echo "  pinned:  $want" >&2
      echo "  file:    $got" >&2
      exit 1
    fi
    echo "== $pkg@$ver: integrity OK"
    mkdir -p "$dest"
    # --global with --prefix: package in $dest/lib/node_modules, executable in $dest/bin.
    # Install scripts enabled: Claude Code and OpenCode copy the platform's native
    # binary in postinstall (read from the tarballs; they only touch node_modules).
    isolated npm install --global --prefix "$dest" --no-fund --no-audit --no-update-notifier "$dir/$tgz"
  fi
  ln -sfn "$ver" "$AGENTS_PREFIX/$name/current"
  echo "installed: $dest  (current -> $ver)"
  local v
  v="$(cd "$work" && isolated "$dest/bin/$exe" --version 2>&1)" || { echo "error: $exe --version failed: $v" >&2; exit 1; }
  echo "== $name: $(head -n1 <<<"$v")"
}

case "${1:-}" in
  qwen-code) install_one qwen-code "$QWEN_CODE_PKG" "$QWEN_CODE_VERSION" "$QWEN_CODE_INTEGRITY" qwen ;;
  pi) install_one pi "$PI_PKG" "$PI_VERSION" "$PI_INTEGRITY" pi ;;
  opencode) install_one opencode "$OPENCODE_PKG" "$OPENCODE_VERSION" "$OPENCODE_INTEGRITY" opencode ;;
  claude-local) install_one claude-local "$CLAUDE_CODE_PKG" "$CLAUDE_CODE_VERSION" "$CLAUDE_CODE_INTEGRITY" claude ;;
  codex-local) install_one codex-local "$CODEX_PKG" "$CODEX_VERSION" "$CODEX_INTEGRITY" codex ;;
  all)
    for a in qwen-code pi opencode claude-local codex-local; do "$0" "$a"; done ;;
  *) echo "usage: $0 <qwen-code|pi|opencode|claude-local|codex-local|all>" >&2; exit 2 ;;
esac
