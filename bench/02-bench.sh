#!/usr/bin/env bash
# Runs a llama-bench with the fixed E4 flags (FA, KV q8_0, -ngl 99) and
# a VRAM/RAM sampler in parallel. Outputs in raw/<label>.{jsonl,log,csv}.
# Usage: [VAR=value ...] bench/02-bench.sh <label> [llama-bench flags]
#   e.g.: bench/02-bench.sh ncmoe -ncmoe 40,38,36 -ub 2048 -b 4096 -p 512,2048 -n 128 -r 2 -t 12
# Environment variables (e.g. GGML_OP_OFFLOAD_MIN_BATCH) pass straight through to llama-bench.
source "$(dirname "$0")/lib.sh"
label="$1"; shift
out="$RAW/02-$label"
{
  echo "# $(date -Is)"
  echo "# env: GGML_OP_OFFLOAD_MIN_BATCH=${GGML_OP_OFFLOAD_MIN_BATCH:-<default>} GGML_CUDA_REGISTER_HOST=${GGML_CUDA_REGISTER_HOST:-<default>}"
  echo "# cmd: $BIN/llama-bench ${BENCH_COMMON[*]} $*"
} > "$out.log"
start_sampler "$out.csv"
trap stop_sampler EXIT
t0=$(date +%s)
"$BIN/llama-bench" "${BENCH_COMMON[@]}" "$@" > "$out.jsonl" 2>> "$out.log"
rc=$?
stop_sampler
echo "# duration: $(( $(date +%s) - t0 )) s, rc=$rc" >> "$out.log"
echo "# $(sampler_summary "$out.csv")" | tee -a "$out.log"
python3 -I "$BENCH_DIR/summarize.py" "$out.jsonl"
