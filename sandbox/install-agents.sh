#!/usr/bin/env bash
# Installs the five agents into the image (runs in `docker build`, as root).
# Same layout as agents/install.sh: <prefix>/<agent>/<version>, with a "current" link.
#
# Difference: each agent's tarball is downloaded with `npm pack` and the sha512 of
# the FILE is checked against the value pinned in agents/versions.env before
# installing (it does not depend on what the registry says at the moment). The
# dependencies (including native binaries in optional dependencies) come from the
# registry and npm checks each one against the published integrity.
#
# Usage: install-agents.sh <versions.env> <prefix>
set -euo pipefail
versions="$1" prefix="$2"
# shellcheck source=/dev/null
source "$versions"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export npm_config_cache="$work/npm-cache" npm_config_update_notifier=false \
       npm_config_fund=false npm_config_audit=false
# --version of some agents creates files in HOME; none of it stays in the image.
export HOME="$work/home"
mkdir -p "$HOME"

sri() {
    python3 -I -c 'import base64, hashlib, sys
print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"
}

install_one() { # <agent> <package> <version> <integrity> <executable>
    local name="$1" pkg="$2" ver="$3" want="$4" exe="$5"
    local dir="$work/$name" dest="$prefix/$name/$ver" tgz got
    mkdir -p "$dir"
    tgz="$(npm pack --json --pack-destination "$dir" "$pkg@$ver" | jq -r '.[0].filename')"
    got="$(sri "$dir/$tgz")"
    if [ "$got" != "$want" ]; then
        echo "error: integrity of $pkg@$ver does not match" >&2
        echo "  pinned:  $want" >&2
        echo "  file:    $got" >&2
        exit 1
    fi
    echo "== $pkg@$ver: integrity matches"
    # Install scripts enabled: Claude Code and OpenCode copy the platform's native
    # binary in postinstall (see agents/README.md).
    npm install --global --prefix "$dest" --no-fund --no-audit --no-update-notifier "$dir/$tgz"
    ln -sfn "$ver" "$prefix/$name/current"
    local v
    v="$("$dest/bin/$exe" --version 2>&1)" || { echo "error: $exe --version failed: $v" >&2; exit 1; }
    echo "== $name: $(head -n1 <<<"$v")"
}

install_one qwen-code    "$QWEN_CODE_PKG"   "$QWEN_CODE_VERSION"   "$QWEN_CODE_INTEGRITY"   qwen
install_one pi           "$PI_PKG"          "$PI_VERSION"          "$PI_INTEGRITY"          pi
install_one opencode     "$OPENCODE_PKG"    "$OPENCODE_VERSION"    "$OPENCODE_INTEGRITY"    opencode
install_one claude-local "$CLAUDE_CODE_PKG" "$CLAUDE_CODE_VERSION" "$CLAUDE_CODE_INTEGRITY" claude
install_one codex-local  "$CODEX_PKG"       "$CODEX_VERSION"       "$CODEX_INTEGRITY"       codex

chmod -R a+rX,go-w "$prefix"
