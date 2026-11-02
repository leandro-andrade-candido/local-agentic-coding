# Imagem agent-box (E7): os cinco agentes da E6 e as ferramentas das tarefas do eval.
# Construir só com sandbox/build.sh, que monta o contexto (estes arquivos +
# agents/versions.env) e passa UID/GID do usuário e a impressão digital das versões.
#
# Base: Ubuntu 24.04, porque o Python 3.12 do sistema fica em /usr/bin/python3.12,
# o mesmo caminho do host. Os .venv que o eval cria no host (uv venv --python 3.12)
# apontam para esse executável e funcionam dentro do container sem recriar nada.

# ubuntu:24.04 (índice multiplataforma), publicado em 25/10/2026.
FROM ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c

# Usuário sem privilégios com o mesmo UID/GID do dono dos projetos no host.
# O Claude Code recusa bypassPermissions como root.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
# Node 24 LTS (24.22.2, 27/10/2026; a 24.22.1 foi versão de segurança).
# sha256 do SHASUMS256.txt oficial de nodejs.org/dist/v24.22.2/.
ARG NODE_VERSION=24.22.2
ARG NODE_SHA256=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
# uv 0.12.13 (a mesma do host); sha256 do .sha256 publicado no release do GitHub.
ARG UV_VERSION=0.12.13
ARG UV_SHA256=745765a3b6e360ad76743599ae5c42e9278c7edf8bbff9fc76d05bf2623a04dd
# Pacotes extras do apt (ex.: "build-essential" para um projeto com extensões nativas).
ARG EXTRA_APT_PACKAGES=""
# Preenchido pelo build.sh (sha das linhas *_PKG/*_VERSION/*_INTEGRITY de versions.env).
ARG AGENTS_VERSIONS_SHA=""

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Ferramentas: git, ripgrep, fd, jq, curl (métricas do llama-server), Python 3.12,
# coreutils/procps. Sem sudo, sem openssh-client, sem docker.
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

# Navegador para validar a entrega na interface (skill webapp-testing, perfil frontend):
# Playwright para Python num venv próprio, com hashes conferidos, e só o Chromium
# headless shell (o modo headless=True usa ele), com as libs e fontes do sistema.
# `python` (que o Ubuntu não tem) chama esse venv; `python3` continua sendo o do sistema.
# O Playwright não liga o sandbox do Chromium por padrão (o container já isola).
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

# Agentes nas versões fixadas, com o tarball conferido (install-agents.sh).
COPY versions.env install-agents.sh /tmp/agents-build/
RUN set -eux; \
    bash /tmp/agents-build/install-agents.sh /tmp/agents-build/versions.env /opt/agents; \
    rm -rf /tmp/agents-build /root/.npm /root/.cache

# Usuário "agent". A imagem base já traz o usuário "ubuntu" com UID 1000.
RUN set -eux; \
    if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    if ! getent group "${AGENT_GID}" >/dev/null; then groupadd -g "${AGENT_GID}" agent; fi; \
    useradd -m -u "${AGENT_UID}" -g "${AGENT_GID}" -s /bin/bash -d /home/agent agent

# Git sem credenciais nem ajudantes; identidade genérica (o eval e o agent-shell.sh
# sobrepõem por GIT_AUTHOR_*/GIT_COMMITTER_*).
RUN printf '%s\n' \
        '[user]' '	name = agent-box' '	email = agent-box@localhost' \
        '[init]' '	defaultBranch = main' \
        '[credential]' '	helper =' \
        '[advice]' '	detachedHead = false' \
        > /etc/gitconfig

# Sem binários setuid/setgid (o no-new-privileges já os anula; isto é a segunda camada).
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
