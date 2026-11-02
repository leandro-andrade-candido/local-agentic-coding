#!/usr/bin/env bash
# Constrói a imagem agent-box (E7).
#
# Uso: sandbox/build.sh [opções extras do docker build...]
#   ex.: sandbox/build.sh --no-cache
#        sandbox/build.sh --build-arg EXTRA_APT_PACKAGES=build-essential
#
# O contexto de build é um diretório temporário só com os arquivos da imagem e
# agents/versions.env (nada mais do repositório, nem eval/, vai para o daemon).
# A imagem sai com o UID/GID de quem constrói e com o rótulo das versões dos
# agentes; run-in-box.sh recusa uma imagem de outras versões (rode este script
# de novo depois de mudar agents/versions.env).
# Rede: só durante o build (apt, nodejs.org, GitHub do uv, registro npm, PyPI e
# CDN do Playwright para o Chromium).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

uid="$(id -u)" gid="$(id -g)"
[ "$uid" != 0 ] || box_die "não construa como root: a imagem usa o UID de quem constrói"

ctx="$(mktemp -d)"
trap 'rm -rf "$ctx"' EXIT
cp "$SANDBOX_DIR/Dockerfile" "$SANDBOX_DIR/entrypoint.sh" "$SANDBOX_DIR/llm-forward.py" \
   "$SANDBOX_DIR/install-agents.sh" "$SANDBOX_DIR/playwright-requirements.txt" \
   "$AGENTS_DIR/versions.env" "$ctx/"

hash="$(agents_versions_hash)"
echo "agent-box: construindo $BOX_IMAGE (UID $uid, GID $gid, versões $hash)" >&2
docker build --pull=false -t "$BOX_IMAGE" \
    --build-arg "AGENT_UID=$uid" --build-arg "AGENT_GID=$gid" \
    --build-arg "AGENTS_VERSIONS_SHA=$hash" \
    "$@" "$ctx"

docker image inspect -f 'agent-box: pronta: {{.Id}} ({{.Size}} bytes)' "$BOX_IMAGE"
