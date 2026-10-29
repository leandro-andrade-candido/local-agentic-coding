#!/usr/bin/env bash
# Instala um agente na versão fixada em agents/versions.env, isolado em
# $AGENTS_PREFIX/<agente>/<versão> (npm --global --prefix), e aponta o link
# "current" para ela. Versões anteriores ficam no disco: para voltar, aponte
# "current" para a antiga.
#
# Nada roda com a HOME real: o npm (cache, ~/.npmrc, scripts de instalação) e o
# `<agente> --version` rodam com ambiente limpo, HOME temporária e as variáveis
# de isolamento de cada agente apontando para ela (alguns agentes criam arquivos
# na HOME já no --version). Assim ~/.claude, ~/.claude.json, ~/.codex, ~/.qwen,
# ~/.pi, ~/.config/opencode e o prefixo global do npm (nvm) não são tocados.
#
# Integridade: o tarball do agente é baixado com `npm pack` e o sha512 do ARQUIVO
# é conferido contra versions.env antes de instalar (mesmo método de
# sandbox/install-agents.sh). As dependências vêm do registro e o npm confere
# cada uma contra o integrity publicado.
#
# Uso: agents/install.sh <qwen-code|pi|opencode|claude-local|codex-local|all>
# Desinstalar: rm -rf "$AGENTS_PREFIX/<agente>"
set -euo pipefail
AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS_DIR/versions.env"

work="$(mktemp -d "${TMPDIR:-/tmp}/agents-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"

# Ambiente limpo e HOME descartável para tudo que o npm e os agentes executam.
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

install_one() { # <agente> <pacote> <versão> <integridade> <executável>
  local name="$1" pkg="$2" ver="$3" want="$4" exe="$5"
  local dest="$AGENTS_PREFIX/$name/$ver" dir="$work/$name" tgz got
  if [ ! -x "$dest/bin/$exe" ]; then
    mkdir -p "$dir"
    tgz="$(isolated npm pack --json --pack-destination "$dir" "$pkg@$ver" | jq -r '.[0].filename')"
    got="$(sri "$dir/$tgz")"
    if [ "$got" != "$want" ]; then
      echo "erro: integridade de $pkg@$ver não confere" >&2
      echo "  fixada:  $want" >&2
      echo "  arquivo: $got" >&2
      exit 1
    fi
    echo "== $pkg@$ver: integridade confere"
    mkdir -p "$dest"
    # --global com --prefix: pacote em $dest/lib/node_modules, executável em $dest/bin.
    # Scripts de instalação ligados: Claude Code e OpenCode copiam o binário nativo
    # da plataforma no postinstall (lidos nos tarballs; só mexem em node_modules).
    isolated npm install --global --prefix "$dest" --no-fund --no-audit --no-update-notifier "$dir/$tgz"
  fi
  ln -sfn "$ver" "$AGENTS_PREFIX/$name/current"
  echo "instalado: $dest  (current -> $ver)"
  local v
  v="$(cd "$work" && isolated "$dest/bin/$exe" --version 2>&1)" || { echo "erro: $exe --version falhou: $v" >&2; exit 1; }
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
  *) echo "uso: $0 <qwen-code|pi|opencode|claude-local|codex-local|all>" >&2; exit 2 ;;
esac
