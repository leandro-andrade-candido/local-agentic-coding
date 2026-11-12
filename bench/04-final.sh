#!/usr/bin/env bash
# Validates the final profile by reading runtime/llama-server.args and runtime/llama-server.env,
# exactly as the E5 systemd unit will.
# Usage: bench/04-final.sh <mode> [label]   (mode: agent | deep | tg | load; see 03-server.sh)
source "$(dirname "$0")/lib.sh"
mode="${1:-agent}"; label="${2:-FINAL-$mode}"
mapfile -t ARGS < <(grep -vE '^\s*(#|$)' "$REPO_DIR/runtime/llama-server.args" | tr -s ' ' '\n')
SERVER_ENV="$(grep -vE '^\s*(#|$)' "$REPO_DIR/runtime/llama-server.env" | tr '\n' ' ')"
export SERVER_ENV
exec "$BENCH_DIR/03-server.sh" "$label" "$mode" "${ARGS[@]}"
