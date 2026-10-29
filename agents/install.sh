#!/usr/bin/env bash
# Instala um agente na versão fixada em agents/versions.env, isolado em
# $AGENTS_PREFIX/<agente>/<versão> (npm --global --prefix), e aponta o link
# "current" para ela. Não toca no prefixo global do npm (~/.nvm/...), em ~/.npmrc
# nem nas configurações dos agentes (~/.claude, ~/.qwen, ~/.config/opencode, ~/.pi).
# Versões anteriores ficam no disco: para voltar, aponte "current" para a antiga.
#
# Uso: agents/install.sh <qwen-code|pi|opencode|claude-local|all>
# Desinstalar: rm -rf "$AGENTS_PREFIX/<agente>"
set -euo pipefail
AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS_DIR/versions.env"

install_one() { # <agente> <pacote> <versão> <integridade> <executável>
  local name="$1" pkg="$2" ver="$3" integrity="$4" exe="$5"
  local dest="$AGENTS_PREFIX/$name/$ver"
  # Confere a integridade publicada no registro antes de instalar
  # (o npm também confere o tarball contra esse valor durante a instalação).
  local published
  published="$(npm view "$pkg@$ver" dist.integrity)"
  if [ "$published" != "$integrity" ]; then
    echo "erro: integridade de $pkg@$ver mudou no registro" >&2
    echo "  esperada:  $integrity" >&2
    echo "  publicada: $published" >&2
    exit 1
  fi
  if [ ! -x "$dest/bin/$exe" ]; then
    mkdir -p "$dest"
    # --global com --prefix: pacote em $dest/lib/node_modules, executável em $dest/bin.
    # Os scripts de instalação ficam ligados: Claude Code e OpenCode usam
    # postinstall para copiar o binário nativo da plataforma (conferido no tarball).
    npm install --global --prefix "$dest" --no-fund --no-audit --no-update-notifier \
      "$pkg@$ver"
  fi
  ln -sfn "$ver" "$AGENTS_PREFIX/$name/current"
  echo "instalado: $dest  (current -> $ver)"
  "$dest/bin/$exe" --version || true
}

case "${1:-}" in
  qwen-code) install_one qwen-code "$QWEN_CODE_PKG" "$QWEN_CODE_VERSION" "$QWEN_CODE_INTEGRITY" qwen ;;
  pi) install_one pi "$PI_PKG" "$PI_VERSION" "$PI_INTEGRITY" pi ;;
  opencode) install_one opencode "$OPENCODE_PKG" "$OPENCODE_VERSION" "$OPENCODE_INTEGRITY" opencode ;;
  claude-local) install_one claude-local "$CLAUDE_CODE_PKG" "$CLAUDE_CODE_VERSION" "$CLAUDE_CODE_INTEGRITY" claude ;;
  all)
    for a in qwen-code pi opencode claude-local; do "$0" "$a"; done ;;
  *) echo "uso: $0 <qwen-code|pi|opencode|claude-local|all>" >&2; exit 2 ;;
esac
