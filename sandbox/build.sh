#!/usr/bin/env bash
# Builds the agent-box image (E7).
#
# Usage: sandbox/build.sh [extra docker build options...]
#   e.g.: sandbox/build.sh --no-cache
#        sandbox/build.sh --build-arg EXTRA_APT_PACKAGES=build-essential
#
# The build context is a temporary directory with only the image files and
# agents/versions.env (nothing else from the repository, not even eval/, goes to the daemon).
# The image gets the UID/GID of whoever builds it and a label with the agent
# versions; run-in-box.sh refuses an image with other versions (run this script
# again after changing agents/versions.env).
# Network: only during the build (apt, nodejs.org, uv's GitHub, npm registry, PyPI and
# the Playwright CDN for Chromium).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

uid="$(id -u)" gid="$(id -g)"
[ "$uid" != 0 ] || box_die "do not build as root: the image uses the UID of whoever builds it"

ctx="$(mktemp -d)"
trap 'rm -rf "$ctx"' EXIT
cp "$SANDBOX_DIR/Dockerfile" "$SANDBOX_DIR/entrypoint.sh" "$SANDBOX_DIR/llm-forward.py" \
   "$SANDBOX_DIR/install-agents.sh" "$SANDBOX_DIR/playwright-requirements.txt" \
   "$AGENTS_DIR/versions.env" "$ctx/"

hash="$(agents_versions_hash)"
echo "agent-box: building $BOX_IMAGE (UID $uid, GID $gid, versions $hash)" >&2
docker build --pull=false -t "$BOX_IMAGE" \
    --build-arg "AGENT_UID=$uid" --build-arg "AGENT_GID=$gid" \
    --build-arg "AGENTS_VERSIONS_SHA=$hash" \
    "$@" "$ctx"

docker image inspect -f 'agent-box: ready: {{.Id}} ({{.Size}} bytes)' "$BOX_IMAGE"
