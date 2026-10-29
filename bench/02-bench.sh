#!/usr/bin/env bash
# Executa um llama-bench com as flags fixas da E4 (FA, KV q8_0, -ngl 99) e
# um amostrador de VRAM/RAM em paralelo. Saídas em raw/<rótulo>.{jsonl,log,csv}.
# Uso: [VAR=valor ...] bench/02-bench.sh <rótulo> [flags do llama-bench]
#   ex.: bench/02-bench.sh ncmoe -ncmoe 40,38,36 -ub 2048 -b 4096 -p 512,2048 -n 128 -r 2 -t 12
# Variáveis de ambiente (ex.: GGML_OP_OFFLOAD_MIN_BATCH) passam direto ao llama-bench.
source "$(dirname "$0")/lib.sh"
label="$1"; shift
out="$RAW/02-$label"
{
  echo "# $(date -Is)"
  echo "# env: GGML_OP_OFFLOAD_MIN_BATCH=${GGML_OP_OFFLOAD_MIN_BATCH:-<padrão>} GGML_CUDA_REGISTER_HOST=${GGML_CUDA_REGISTER_HOST:-<padrão>}"
  echo "# cmd: $BIN/llama-bench ${BENCH_COMMON[*]} $*"
} > "$out.log"
start_sampler "$out.csv"
trap stop_sampler EXIT
t0=$(date +%s)
"$BIN/llama-bench" "${BENCH_COMMON[@]}" "$@" > "$out.jsonl" 2>> "$out.log"
rc=$?
stop_sampler
echo "# duração: $(( $(date +%s) - t0 )) s, rc=$rc" >> "$out.log"
echo "# $(sampler_summary "$out.csv")" | tee -a "$out.log"
python3 -I "$BENCH_DIR/summarize.py" "$out.jsonl"
