# agent-box image (E7): the five E6 agents and the tools for the eval tasks.
# Build only with sandbox/build.sh, which assembles the context (these files +
# agents/versions.env) and passes the user's UID/GID and the versions fingerprint.
#
# Base: Ubuntu 24.04, because the system Python 3.12 lives at /usr/bin/python3.12,
# the same path as on the host. The .venv directories that the eval creates on the host
# (uv venv --python 3.12) point to that executable and work inside the container
# without recreating anything.

# ubuntu:24.04 (multi-platform index), published on 2026-10-25.
FROM ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c

# Unprivileged user with the same UID/GID as the owner of the projects on the host.
# Claude Code refuses bypassPermissions as root.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
# Node 24 LTS (24.22.2, 2026-10-27; 24.22.1 was a security release).
# sha256 from the official SHASUMS256.txt at nodejs.org/dist/v24.22.2/.
ARG NODE_VERSION=24.22.2
ARG NODE_SHA256=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
# uv 0.12.13 (the same as the host); sha256 from the .sha256 published in the GitHub release.
ARG UV_VERSION=0.12.13
ARG UV_SHA256=745765a3b6e360ad76743599ae5c42e9278c7edf8bbff9fc76d05bf2623a04dd
# Extra apt packages (e.g. "build-essential" for a project with native extensions).
ARG EXTRA_APT_PACKAGES=""
# Filled in by build.sh (sha of the *_PKG/*_VERSION/*_INTEGRITY lines of versions.env).
ARG AGENTS_VERSIONS_SHA=""

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Tools: git, ripgrep, fd, jq, curl (llama-server metrics), Python 3.12,
# coreutils/procps. No sudo, no openssh-client, no docker.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq ripgrep fd-find tree less file patch \
        procps psmisc xz-utils unzip tzdata \
        python3 python3-venv \
        ${EXTRA_APT_PACKAGES}; \
    ln -s /usr/bin/fdfind /usr/local/bin/fd; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f /tmp/node.tar.xz /usr/local/CHANGELOG.md /usr/local/LICENSE /usr/local/README.md; \
    node --version; npm --version

RUN set -eux; \
    curl -fsSLo /tmp/uv.tar.gz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"; \
    echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/uv.tar.gz -C /usr/local/bin --strip-components=1 --no-same-owner \
        uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx; \
    rm /tmp/uv.tar.gz; \
    uv --version

# Browser to validate the delivery in the UI (webapp-testing skill, frontend profile):
# Playwright for Python in its own venv, with verified hashes, and only the Chromium
# headless shell (headless=True mode uses it), with the system libs and fonts.
# `python` (which Ubuntu does not have) calls that venv; `python3` remains the system one.
# Playwright does not enable the Chromium sandbox by default (the container already isolates).
COPY playwright-requirements.txt /tmp/playwright-requirements.txt
RUN set -eux; \
    uv venv -q --python /usr/bin/python3.12 /opt/playwright; \
    uv pip install -q --python /opt/playwright/bin/python --require-hashes \
        -r /tmp/playwright-requirements.txt; \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
        /opt/playwright/bin/playwright install --with-deps --only-shell chromium; \
    printf '#!/bin/sh\nexec /opt/playwright/bin/python "$@"\n' > /usr/local/bin/python; \
    chmod 0755 /usr/local/bin/python; \
    chmod -R a+rX /opt/ms-playwright; \
    rm -rf /tmp/playwright-requirements.txt /root/.cache /var/lib/apt/lists/*

# Agents at the pinned versions, with the tarball verified (install-agents.sh).
COPY versions.env install-agents.sh /tmp/agents-build/
RUN set -eux; \
    bash /tmp/agents-build/install-agents.sh /tmp/agents-build/versions.env /opt/agents; \
    rm -rf /tmp/agents-build /root/.npm /root/.cache

# User "agent". The base image already ships the "ubuntu" user with UID 1000.
RUN set -eux; \
    if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    if ! getent group "${AGENT_GID}" >/dev/null; then groupadd -g "${AGENT_GID}" agent; fi; \
    useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash -d /home/agent agent

# Git without credentials or helpers; generic identity (the eval and agent-shell.sh
# override it through GIT_AUTHOR_*/GIT_COMMITTER_*).
RUN printf '%s\n' \
        '[user]' '	name = agent-box' '	email = agent-box@localhost' \
        '[init]' '	defaultBranch = main' \
        '[credential]' '	helper =' \
        '[advice]' '	detachedHead = false' \
        > /etc/gitconfig

# No setuid/setgid binaries (no-new-privileges already neutralizes them; this is the second layer).
RUN find / -xdev -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true

COPY entrypoint.sh /usr/local/bin/agent-box-entrypoint
COPY llm-forward.py /usr/local/lib/agent-box/llm-forward.py
RUN chmod 0755 /usr/local/bin/agent-box-entrypoint && chmod 0644 /usr/local/lib/agent-box/llm-forward.py

ENV HOME=/home/agent \
    AGENTS_PREFIX=/opt/agents \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NO_UPDATE_NOTIFIER=1 \
    DO_NOT_TRACK=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_PYTHON_DOWNLOADS=never \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

LABEL local-agentic.agent-box="1" \
      local-agentic.agents-versions="${AGENTS_VERSIONS_SHA}" \
      local-agentic.uid="${AGENT_UID}" \
      local-agentic.gid="${AGENT_GID}" \
      local-agentic.node="${NODE_VERSION}" \
      local-agentic.uv="${UV_VERSION}"

USER ${AGENT_UID}:${AGENT_GID}
WORKDIR /
ENTRYPOINT ["/usr/local/bin/agent-box-entrypoint"]
CMD ["bash", "-l"]
