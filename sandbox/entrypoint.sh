#!/bin/bash
# Entrada do agent-box (PID 1 é o docker-init, via --init).
# 1. HOME é um tmpfs vazio: copia o /etc/skel para shells interativos.
# 2. Se o socket do encaminhador do host estiver montado (/run/agent-box/llm.sock),
#    sobe o encaminhador interno em 127.0.0.1:$BOX_LLM_PORT; os agentes usam
#    LLM_BASE_URL=http://127.0.0.1:<porta> como se o llama-server estivesse ali.
# 3. Executa o comando (padrão: bash de login).
set -euo pipefail
umask 022

if [ -d "${HOME:-}" ] && [ -w "$HOME" ] && [ -z "$(ls -A "$HOME" 2>/dev/null)" ]; then
    cp -rT /etc/skel "$HOME" 2>/dev/null || true
fi

sock=/run/agent-box/llm.sock
if [ -S "$sock" ]; then
    quiet=()
    [ -t 2 ] && quiet=(--quiet)   # sessão interativa: não sujar a tela do agente
    python3 -I /usr/local/lib/agent-box/llm-forward.py box \
        --listen "127.0.0.1:${BOX_LLM_PORT:-9931}" --socket "$sock" --background "${quiet[@]}"
fi

[ $# -gt 0 ] || set -- bash -l
exec "$@"
