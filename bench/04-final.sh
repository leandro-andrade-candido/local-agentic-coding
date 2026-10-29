#!/usr/bin/env bash
# Valida o perfil final lendo runtime/llama-server.args e runtime/llama-server.env,
# exatamente como a unidade systemd da E5 fará.
# Uso: bench/04-final.sh <modo> [rótulo]   (modo: agent | deep | tg | load; ver 03-server.sh)
source "$(dirname "$0")/lib.sh"
mode="${1:-agent}"; label="${2:-FINAL-$mode}"
mapfile -t ARGS < <(grep -vE '^\s*(#|$)' "$REPO_DIR/runtime/llama-server.args" | tr -s ' ' '\n')
SERVER_ENV="$(grep -vE '^\s*(#|$)' "$REPO_DIR/runtime/llama-server.env" | tr '\n' ' ')"
export SERVER_ENV
exec "$BENCH_DIR/03-server.sh" "$label" "$mode" "${ARGS[@]}"
