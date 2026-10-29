#!/usr/bin/env bash
# Passo 2: o que o --fit escolhe para o contexto do agente (131072, KV q8_0).
# Sobe o servidor, registra o log de carga e a VRAM em uso, e encerra.
# Uso: bench/01-fit.sh <rótulo> [flags extras do llama-server]
#   ex.: bench/01-fit.sh ub2048 -ub 2048 -b 4096
source "$(dirname "$0")/lib.sh"
label="$1"; shift
log="$RAW/01-fit-$label.log"
start_server "$log" -np 1 -c 131072 -fa on -ctk q8_0 -ctv q8_0 --fit on -t 12 -tb 16 "$@"
trap stop_server EXIT
wait_server 900
sleep 2
{
  echo "### nvidia-smi após carga ($label)"
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv
  echo "### RSS do servidor"
  grep -E '^(VmRSS|VmHWM|VmLck|VmPin)' "/proc/$SERVER_PID/status" || true
  echo "### props"
  curl -s "$BASE/props" | jq -c '{n_ctx: .default_generation_settings.n_ctx, total_slots, model_path}' || true
} | tee "$RAW/01-fit-$label.txt"
echo "### linhas relevantes do log"
grep -iE 'fit|n_cpu_moe|ncmoe|offload|layers|MiB|buffer size|CUDA0|free|n_ctx|n_ubatch|n_batch|graph|checkpoint|cache' "$log" | grep -v '^srv  *log_server_r' | head -120
