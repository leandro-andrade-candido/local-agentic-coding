# Functions and paths shared by the E4 benchmark scripts.
# Usage: source "$(dirname "$0")/lib.sh"  (the scripts do this themselves)
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$BENCH_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_DIR/versions.env"

BIN="$LLAMA_CPP_PREFIX/current"
MODEL="${MODEL:-$MODELS_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
RAW="${RAW:-$BENCH_DIR/raw}"
HOST="$LLAMA_SERVER_HOST"
PORT="$LLAMA_SERVER_PORT"
BASE="http://$HOST:$PORT"
mkdir -p "$RAW"

ts() { date +%Y%m%d-%H%M%S; }

# Snapshot of the GPU and memory state (PCIe, replays, clocks, VRAM, RAM).
snapshot() {
  echo "### $(date -Is)"
  nvidia-smi --query-gpu=name,temperature.gpu,clocks.sm,clocks.mem,power.draw,pcie.link.gen.current,pcie.link.width.current,memory.used,memory.total --format=csv
  nvidia-smi -q | grep -A1 -E 'Replays Since Reset' || true
  nvidia-smi -q | grep -E 'Replay Number Rollovers' || true
  grep -E '^(MemTotal|MemFree|MemAvailable|Cached|AnonPages|Mlocked|SwapFree|Unevictable)' /proc/meminfo
}

# Background memory sampler: 1 line per second in CSV.
# Colunas: epoch, vram_used_mib, gpu_util, temp, pcie_gen, mem_available_kib, swap_free_kib, rss_kib(pid), hwm_kib(pid)
# Usage: start_sampler <file.csv> [pid]; stop_sampler
start_sampler() {
  local out="$1" pid="${2:-}"
  (
    echo "epoch,vram_used_mib,gpu_util,temp_c,pcie_gen,mem_available_kib,swap_free_kib,rss_kib,hwm_kib"
    while :; do
      g=$(nvidia-smi --query-gpu=memory.used,utilization.gpu,temperature.gpu,pcie.link.gen.current --format=csv,noheader,nounits | tr -d ' ')
      ma=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
      sf=$(awk '/^SwapFree/{print $2}' /proc/meminfo)
      rss=""; hwm=""
      if [ -n "$pid" ] && [ -r "/proc/$pid/status" ]; then
        rss=$(awk '/^VmRSS/{print $2}' "/proc/$pid/status")
        hwm=$(awk '/^VmHWM/{print $2}' "/proc/$pid/status")
      fi
      echo "$(date +%s),$g,$ma,$sf,$rss,$hwm"
      sleep 1
    done
  ) > "$out" 2>/dev/null &
  SAMPLER_PID=$!
}
stop_sampler() {
  if [ -n "${SAMPLER_PID:-}" ]; then kill "$SAMPLER_PID" 2>/dev/null || true; wait "$SAMPLER_PID" 2>/dev/null || true; SAMPLER_PID=""; fi
}

# Summary of a sampler CSV: VRAM/RSS peaks and minimum available RAM.
sampler_summary() {
  awk -F, 'NR>1{ if($2>v)v=$2; if($8>r)r=$8; if($9>h)h=$9; if(m==""||$6<m)m=$6; if(s==""||$7<s)s=$7; if($4>t)t=$4 }
    END{ printf "peak_vram_mib=%s peak_rss_mib=%.0f peak_hwm_mib=%.0f min_mem_available_mib=%.0f min_swap_free_mib=%.0f max_temp_c=%s\n", v, r/1024, h/1024, m/1024, s/1024, t }' "$1"
}

# Starts llama-server in the background. Usage: start_server <log> [extra args...]
# Sets SERVER_PID. Extra environment variables can be passed via SERVER_ENV="A=1 B=2".
start_server() {
  local log="$1"; shift
  # shellcheck disable=SC2086
  env ${SERVER_ENV:-} "$BIN/llama-server" -m "$MODEL" -a qwen3.6-35b \
    --host "$HOST" --port "$PORT" "$@" > "$log" 2>&1 &
  SERVER_PID=$!
  echo "server pid=$SERVER_PID log=$log" >&2
}

# Waits for /health to answer 200 (or the process to die). Timeout in seconds.
wait_server() {
  local timeout="${1:-600}" t0; t0=$(date +%s)
  while :; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "server died" >&2; return 1; fi
    if curl -fs "$BASE/health" >/dev/null 2>&1; then
      echo "server ready in $(( $(date +%s) - t0 )) s" >&2; return 0
    fi
    if (( $(date +%s) - t0 > timeout )); then echo "timeout waiting for the server" >&2; return 1; fi
    sleep 1
  done
}

# Stops the server by the saved PID (never by name pattern).
stop_server() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID"
    for _ in $(seq 1 60); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$SERVER_PID" 2>/dev/null && kill -9 "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

# Fixed flags of all E4 llama-bench runs (agent context: FA + KV q8_0).
BENCH_COMMON=(-m "$MODEL" -fa 1 -ctk q8_0 -ctv q8_0 -ngl 99 -o jsonl)
