#!/usr/bin/env bash
# Instala os cinco agentes na imagem (roda no `docker build`, como root).
# Mesmo layout do agents/install.sh: <prefixo>/<agente>/<versão>, com link "current".
#
# Diferença: o tarball de cada agente é baixado com `npm pack` e o sha512 do
# ARQUIVO é conferido contra o valor fixado em agents/versions.env antes de
# instalar (não depende do que o registro diz no momento). As dependências
# (inclusive os binários nativos em dependências opcionais) vêm do registro e o
# npm confere cada uma contra o integrity publicado.
#
# Uso: install-agents.sh <versions.env> <prefixo>
set -euo pipefail
versions="$1" prefix="$2"
# shellcheck source=/dev/null
source "$versions"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export npm_config_cache="$work/npm-cache" npm_config_update_notifier=false \
       npm_config_fund=false npm_config_audit=false
# O --version de alguns agentes cria arquivos na HOME; nada disso fica na imagem.
export HOME="$work/home"
mkdir -p "$HOME"

sri() {
    python3 -I -c 'import base64, hashlib, sys
print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"
}

install_one() { # <agente> <pacote> <versão> <integridade> <executável>
    local name="$1" pkg="$2" ver="$3" want="$4" exe="$5"
    local dir="$work/$name" dest="$prefix/$name/$ver" tgz got
    mkdir -p "$dir"
    tgz="$(npm pack --json --pack-destination "$dir" "$pkg@$ver" | jq -r '.[0].filename')"
    got="$(sri "$dir/$tgz")"
    if [ "$got" != "$want" ]; then
        echo "erro: integridade de $pkg@$ver não confere" >&2
        echo "  fixada:  $want" >&2
        echo "  arquivo: $got" >&2
        exit 1
    fi
    echo "== $pkg@$ver: integridade confere"
    # Scripts de instalação ligados: Claude Code e OpenCode copiam o binário nativo
    # da plataforma no postinstall (ver agents/README.md).
    npm install --global --prefix "$dest" --no-fund --no-audit --no-update-notifier "$dir/$tgz"
    ln -sfn "$ver" "$prefix/$name/current"
    local v
    v="$("$dest/bin/$exe" --version 2>&1)" || { echo "erro: $exe --version falhou: $v" >&2; exit 1; }
    echo "== $name: $(head -n1 <<<"$v")"
}

install_one qwen-code    "$QWEN_CODE_PKG"   "$QWEN_CODE_VERSION"   "$QWEN_CODE_INTEGRITY"   qwen
install_one pi           "$PI_PKG"          "$PI_VERSION"          "$PI_INTEGRITY"          pi
install_one opencode     "$OPENCODE_PKG"    "$OPENCODE_VERSION"    "$OPENCODE_INTEGRITY"    opencode
install_one claude-local "$CLAUDE_CODE_PKG" "$CLAUDE_CODE_VERSION" "$CLAUDE_CODE_INTEGRITY" claude
install_one codex-local  "$CODEX_PKG"       "$CODEX_VERSION"       "$CODEX_INTEGRITY"       codex

chmod -R a+rX,go-w "$prefix"
