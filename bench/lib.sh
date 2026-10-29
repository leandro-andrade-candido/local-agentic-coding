# Funções e caminhos comuns aos scripts de benchmark da E4.
# Uso: source "$(dirname "$0")/lib.sh"  (os scripts fazem isso sozinhos)
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

# Instantâneo do estado da GPU e da memória (PCIe, replays, clocks, VRAM, RAM).
snapshot() {
  echo "### $(date -Is)"
  nvidia-smi --query-gpu=name,temperature.gpu,clocks.sm,clocks.mem,power.draw,pcie.link.gen.current,pcie.link.width.current,memory.used,memory.total --format=csv
  nvidia-smi -q | grep -A1 -E 'Replays Since Reset' || true
  nvidia-smi -q | grep -E 'Replay Number Rollovers' || true
  grep -E '^(MemTotal|MemFree|MemAvailable|Cached|AnonPages|Mlocked|SwapFree|Unevictable)' /proc/meminfo
}

# Amostrador de memória em segundo plano: 1 linha por segundo em CSV.
# Colunas: epoch, vram_used_mib, gpu_util, temp, pcie_gen, mem_available_kib, swap_free_kib, rss_kib(pid), hwm_kib(pid)
# Uso: start_sampler <arquivo.csv> [pid]; stop_sampler
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

# Resumo de um CSV do amostrador: picos de VRAM/RSS e mínimo de RAM disponível.
sampler_summary() {
  awk -F, 'NR>1{ if($2>v)v=$2; if($8>r)r=$8; if($9>h)h=$9; if(m==""||$6<m)m=$6; if(s==""||$7<s)s=$7; if($4>t)t=$4 }
    END{ printf "pico_vram_mib=%s pico_rss_mib=%.0f pico_hwm_mib=%.0f min_mem_available_mib=%.0f min_swap_free_mib=%.0f max_temp_c=%s\n", v, r/1024, h/1024, m/1024, s/1024, t }' "$1"
}

# Sobe o llama-server em segundo plano. Uso: start_server <log> [args extras...]
# Define SERVER_PID. Variáveis de ambiente extras podem ser passadas via SERVER_ENV="A=1 B=2".
start_server() {
  local log="$1"; shift
  # shellcheck disable=SC2086
  env ${SERVER_ENV:-} "$BIN/llama-server" -m "$MODEL" -a qwen3.6-35b \
    --host "$HOST" --port "$PORT" "$@" > "$log" 2>&1 &
  SERVER_PID=$!
  echo "server pid=$SERVER_PID log=$log" >&2
}

# Espera o /health responder 200 (ou o processo morrer). Timeout em segundos.
wait_server() {
  local timeout="${1:-600}" t0; t0=$(date +%s)
  while :; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "server morreu" >&2; return 1; fi
    if curl -fs "$BASE/health" >/dev/null 2>&1; then
      echo "server pronto em $(( $(date +%s) - t0 )) s" >&2; return 0
    fi
    if (( $(date +%s) - t0 > timeout )); then echo "timeout esperando o server" >&2; return 1; fi
    sleep 1
  done
}

# Encerra o servidor pelo PID salvo (nunca por padrão de nome).
stop_server() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID"
    for _ in $(seq 1 60); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$SERVER_PID" 2>/dev/null && kill -9 "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

# Flags fixas de todos os llama-bench da E4 (contexto do agente: FA + KV q8_0).
BENCH_COMMON=(-m "$MODEL" -fa 1 -ctk q8_0 -ctv q8_0 -ngl 99 -o jsonl)
