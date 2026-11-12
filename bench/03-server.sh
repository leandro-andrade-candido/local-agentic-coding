#!/usr/bin/env bash
# Steps 6-8: starts llama-server with the given flags, measures with real requests and exits.
# Usage: [SERVER_ENV="GGML_OP_OFFLOAD_MIN_BATCH=1024"] bench/03-server.sh <label> <mode> [llama-server flags]
#   mode: tg     -> 4 requests generating 256 tokens (tg_requests.py)
#         agent  -> agent-turn simulation (agent_turns.py --detour) + tg
#         deep   -> agent turns with a cold prompt of ~64k tokens (3 pasted files);
#                   DEEP_TARGET=120000 DEEP_DETOUR=1 DEEP_FILES=a,b,c change the size, the detour and the files
#         load   -> only loads, records memory and exits
# Outputs: raw/03-<label>.{log,csv,jsonl,txt}
source "$(dirname "$0")/lib.sh"
label="$1"; mode="$2"; shift 2
out="$RAW/03-$label"
: > "$out.jsonl"
{ echo "# $(date -Is)"; echo "# env: ${SERVER_ENV:-<none>}"; echo "# flags: $*"; } > "$out.txt"
t0=$(date +%s)
start_server "$out.log" "$@"
trap 'stop_sampler; stop_server' EXIT
start_sampler "$out.csv" "$SERVER_PID"
wait_server 900
echo "# load until /health: $(( $(date +%s) - t0 )) s" | tee -a "$out.txt"
{ echo "### after load"; nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
  grep -E '^(VmRSS|VmHWM)' "/proc/$SERVER_PID/status"
  grep -E '^(MemAvailable|Cached|Shmem|AnonPages)' /proc/meminfo; } >> "$out.txt"
case "$mode" in
  tg)    python3 -I "$BENCH_DIR/tg_requests.py" --base "$BASE" --label "$label" --out "$out.jsonl" ;;
  agent) python3 -I "$BENCH_DIR/agent_turns.py" --base "$BASE" --detour --out "$out.jsonl"
         python3 -I "$BENCH_DIR/tg_requests.py" --base "$BASE" --label "$label" --out "$out.jsonl" ;;
  deep)  python3 -I "$BENCH_DIR/agent_turns.py" --base "$BASE" --target "${DEEP_TARGET:-64000}" ${DEEP_DETOUR:+--detour} \
           --file "${DEEP_FILES:-/usr/lib/python3.12/argparse.py,/usr/lib/python3.12/typing.py,/usr/lib/python3.12/tarfile.py}" \
           --out "$out.jsonl" ;;
  load)  sleep 3 ;;
esac
{ echo "### end"; nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
  grep -E '^(VmRSS|VmHWM)' "/proc/$SERVER_PID/status"
  curl -s "$BASE/metrics" | grep -E '^llamacpp:(prompt_tokens_total|tokens_predicted_total|n_decode_total)' || true; } >> "$out.txt"
stop_sampler
echo "# $(sampler_summary "$out.csv")" | tee -a "$out.txt"
stop_server
grep -E 'memory breakdown|CUDA0 \(RTX|  - Host' "$out.log" | tail -3 >> "$out.txt"
cat "$out.txt"
