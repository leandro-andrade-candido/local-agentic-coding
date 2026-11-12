#!/bin/bash
# agent-box entrypoint (PID 1 is docker-init, via --init).
# 1. HOME is an empty tmpfs: copies /etc/skel for interactive shells.
# 2. If the host forwarder socket is mounted (/run/agent-box/llm.sock), starts
#    the internal forwarder on 127.0.0.1:$BOX_LLM_PORT; agents use
#    LLM_BASE_URL=http://127.0.0.1:<port> as if llama-server were there.
# 3. Runs the command (default: login bash).
set -euo pipefail
umask 022

if [ -d "${HOME:-}" ] && [ -w "$HOME" ] && [ -z "$(ls -A "$HOME" 2>/dev/null)" ]; then
    cp -rT /etc/skel "$HOME" 2>/dev/null || true
fi

sock=/run/agent-box/llm.sock
if [ -S "$sock" ]; then
    quiet=()
    [ -t 2 ] && quiet=(--quiet)   # interactive session: do not clutter the agent's screen
    python3 -I /usr/local/lib/agent-box/llm-forward.py box \
        --listen "127.0.0.1:${BOX_LLM_PORT:-9931}" --socket "$sock" --background "${quiet[@]}"
fi

[ $# -gt 0 ] || set -- bash -l
exec "$@"
