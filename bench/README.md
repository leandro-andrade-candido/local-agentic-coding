# E4 benchmarks

Calibration of `llama-server` for Qwen3.6-35B-A3B on this machine: where the experts live, micro-batch, load mode, threads, short turns, context depth, expert cache and agent-turn simulation.

Results, chosen profile and rationale: [`RESULTS-E4.md`](RESULTS-E4.md). Final profile: [`../runtime/llama-server.args`](../runtime/llama-server.args) and [`../runtime/llama-server.env`](../runtime/llama-server.env).

## Prerequisites

- llama.cpp installed by E2 (`$LLAMA_CPP_PREFIX/current`, read from `versions.env`).
- Model `~/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (`MODELS_DIR` in `versions.env`).
- `jq`, `curl` and `python3` (standard library only).
- **Dedicated GPU during the measurements.** Before starting, check on Windows (`/mnt/c/Windows/System32/nvidia-smi.exe`) that no other process is using the NVIDIA GPU: no game, no NVIDIA Broadcast. In this E4, a game and Broadcast came up in the middle of the measurements (see `RESULTS-E4.md`).
- Close heavy apps on Windows. Run the measurements in series, one at a time: there is one GPU and one model.

## Files

| File | What it does |
|---|---|
| `lib.sh` | Paths (from `versions.env`), VRAM/RAM/temperature sampler (1 s, CSV), starting and stopping the server **by PID** |
| `00-baseline.sh <label>` | PCIe replays, link generation and width, clocks, VRAM and RAM |
| `01-fit.sh <label> [flags]` | Starts the server with `--fit on -c 131072 -ctk q8_0 -ctv q8_0` and records what `--fit` chose (use `-lv 4`) |
| `02-bench.sh <label> [flags]` | `llama-bench` with fixed flags (`-fa 1 -ctk q8_0 -ctv q8_0 -ngl 99 -o jsonl`) and a sampler in parallel |
| `summarize.py` | Markdown table from the `llama-bench` JSONL files |
| `03-server.sh <label> <mode> [flags]` | Starts `llama-server`, measures with real requests (`tg`, `agent`, `deep` or `load`) and exits |
| `04-final.sh <mode> [label]` | Same as the previous one, but reads the flags from `runtime/llama-server.args` and the environment from `runtime/llama-server.env`, as E5 will |
| `agent_turns.py` | Simulates agent turns through `/v1/chat/completions` with tools: large cold prompt, 2 warm turns, parallel conversation and return |
| `tg_requests.py` | 4 requests generating exactly 256 tokens (`ignore_eos`) and reads `timings.predicted_per_second` |
| `burstmon.sh <file>` | Records the most active processes when the run queue exceeds 14 threads (detects external load) |
| `raw/` | Raw outputs (outside git): JSONL, server logs, sampler CSV, `vmstat` |

Naming convention in `raw/`: `02-*` are `llama-bench`; `03-*` are `llama-server`; `03-CONTAMINADO-jogo-*` ("contaminated by game") are the runs that coincided with the game (kept as separate data).

## How to reproduce

All commands run from the repository root. Total time: ~1.5 h of machine time.

```bash
# 1. Initial state (repeat at the end: the PCIe replays must stay at 0)
bench/00-baseline.sh before

# 2. What --fit chooses for 131072 context, per micro-batch
for ub in 512 1024 2048 4096; do bench/01-fit.sh ub$ub -ub $ub -b 4096 -lv 4; done

# 3. Experts on the GPU (-ncmoe) and micro-batch
bench/02-bench.sh A-ncmoe -ncmoe 40,38,36 -ub 2048 -b 4096 -p 512,2048 -n 128 -r 2 -t 12
bench/02-bench.sh A2-ncmoe-vram -ncmoe 38,37,36,35,34 -ub 2048 -b 4096 -p 2048 -n 32 -r 3 -t 12
bench/02-bench.sh B-ub -ncmoe 38 -ub 512,1024,2048,4096 -b 4096 -p 512,2048,4096 -n 0 -r 2 -t 12

# 4. Load mode (mmap = pageable memory; none/dio = pinned memory)
bench/02-bench.sh C-loadmode -ncmoe 38 -lm mmap,none,dio -ub 2048,4096 -b 4096 -p 512,4096 -n 64 -r 2 -t 12

# 5. Generation threads
bench/02-bench.sh E2-threads -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 6,8,12,16 -p 0 -n 128 -r 3
bench/02-bench.sh G2-tgnoise -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 8 -p 0 -n 128 -r 10

# 6. Short turns: experts copied to the GPU (nopo 0) vs computed on the CPU (nopo 1)
bench/02-bench.sh D2-smallturn -lm dio -ncmoe 40 -ub 4096 -b 4096 -nopo 0,1 -t 8,12 -p 128,512,1024,2048 -r 3
GGML_OP_OFFLOAD_MIN_BATCH=1024 bench/02-bench.sh D3-minbatch1024 -lm dio -ncmoe 40 -ub 4096 -b 4096 \
  -t 8,12 -p 128,512,1024,2048,4096 -n 0 -r 3

# 7. Context depth (65536 takes ~1 min per repetition just to fill the context)
GGML_OP_OFFLOAD_MIN_BATCH=1024 bench/02-bench.sh F2-depth-tg -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 8 \
  -p 0 -n 128 -d 16384,65536 -r 3
GGML_OP_OFFLOAD_MIN_BATCH=1024 bench/02-bench.sh F2-depth-pp -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 12 \
  -p 512,4096 -n 0 -d 16384,65536 -r 2

# 8. Expert cache on the GPU (only exists in llama-server). Micro-batch 2048 to fit 2 GiB of cache.
P="-np 1 -c 131072 -fa on -ctk q8_0 -ctv q8_0 -ngl 99 -ncmoe 40 -b 4096 -ub 2048 -t 8 -tb 12 -lm dio --jinja -ctxcp 48 -cms 2048 --cache-ram 12288 --metrics -lv 4"
for mc in 0 1024 2048; do
  SERVER_ENV="GGML_OP_OFFLOAD_MIN_BATCH=1024" bench/03-server.sh M$mc-ub2048 tg $P --moe-cache-mib $mc
done   # in zsh, use ${=P} instead of $P

# 9. Final profile, from the runtime/ files: agent turns with 20k, 64k and ~120k tokens
bench/04-final.sh agent FINAL-20k-ncmoe38
bench/04-final.sh deep FINAL-64k
DEEP_TARGET=120000 DEEP_DETOUR=1 \
DEEP_FILES=/usr/lib/python3.12/argparse.py,/usr/lib/python3.12/typing.py,/usr/lib/python3.12/tarfile.py,/usr/lib/python3.12/_pydecimal.py \
  bench/04-final.sh deep FINAL-128k-ncmoe38

# 10. Final state
bench/00-baseline.sh after

# Summary of all llama-bench runs
python3 -I bench/summarize.py bench/raw/02-*.jsonl
```

To see whether external load contaminated a measurement, leave the monitor running in parallel and stop it by PID:

```bash
bench/burstmon.sh bench/raw/burstmon.log & BM=$!
# ... measurements ...
kill $BM
```

## Method and cautions

- **`llama-bench` for sweeps, `llama-server` for what only exists in it.** The expert cache, the context checkpoints, the prompt cache and the chat template with tools only exist in the server.
- **VRAM: trust the server, not `llama-bench`.** `llama-bench` sizes the context by the test (`p + n + d`) and showed peaks of up to 7.6 GB at high depths. The server reserves everything at load (131072 KV included), and VRAM stayed flat from load up to 123k tokens of context.
- **Requests timed by the server itself.** The server numbers come from `timings` in each response (`prompt_n`, `prompt_ms`, `predicted_per_second`, `cache_n`); wall time includes HTTP and the template.
- **Repetitions.** I used `-r 2` or `-r 3` (`-r 10` to measure noise). Isolated slow samples show up under external load; when they exist, the results table shows the range, not just the mean.
- **Server always stopped by the saved PID** (`stop_server` in `lib.sh`), never by name pattern.
- **External processes.** Other local services in containers run on WSL all the time; `burstmon.sh` and `vmstat` show when something external competes for CPU or RAM.
