> Translated from the Portuguese original (commit 30666ad).

# E4: Qwen3.6-35B-A3B benchmark and llama-server profile

> **Independent verification (Oct 29, 12:11–12:31):** all 7 claims passed ([`docs/verifications/E4.md`](../docs/verifications/E4.md)). Some magnitudes here came out larger than the re-measured ones, without changing any conclusion:
> - `MIN_BATCH=1024`: ~2.2× on pp128.
> - `-t 16` vs `-t 8`: −18 to 19% on generation.
> - `--moe-cache-mib 1024`: −22% on generation.
> - When measuring, discard the first 1–2 requests after load, which are ~10% slower.

Run on 2026-10-29, from 10:36 to 12:05. llama.cpp build `b11982` (CUDA 12.8). Model `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (22.35 GB). Method and commands in [`README.md`](README.md); raw outputs in `bench/raw/` (outside git).

## Summary

**Chosen profile** ([`runtime/llama-server.args`](../runtime/llama-server.args) + [`runtime/llama-server.env`](../runtime/llama-server.env)):

```
-np 1 -c 131072 -fa on -ctk q8_0 -ctv q8_0 -ngl 99 -ncmoe 38 --fit on --fit-target 384
-b 4096 -ub 4096 -t 8 -tb 12 -lm dio --jinja --reasoning-preserve
-ctxcp 48 -cms 2048 --cache-ram 12288 --metrics --temp 0.6 --top-p 0.95 --top-k 20
environment: GGML_OP_OFFLOAD_MIN_BATCH=1024
```

**What an agent will feel** (real server, requests with tools and chat template):

| Situation | 20k tokens of context | 64k | ~120k |
|---|---|---|---|
| Cold prompt (cache loss): prefill time | **16.2 s** (1,242 tok/s) | **58.2 s** (1,100 tok/s) | **128.6 s** (934 tok/s) |
| Warm turn (+350 to 450 tokens appended) | **1.0 to 1.2 s** | 1.2 to 1.3 s | 1.3 to 1.5 s |
| Return to a conversation after another one (prompt cache in RAM) | 0.41 s | — | 0.48 s |
| Generation | **30 to 32 tok/s** | 25 to 26 tok/s | 21 to 23 tok/s |
| Generation with short context | 34 to 37 tok/s | | |

**Verdicts**
- **PCIe Gen4 ×8 stable:** replay counter at 0 before, during and after ~1.5 h of load, including the period with a game using the GPU. **[measured]**
- **`--moe-cache-mib`: do not use.** With 1024 MiB generation dropped 36%; with 2048 MiB, 21%. The CPU computes the experts faster than PCIe can bring them to the GPU. **[measured]**
- **Cache reuse between turns works:** the next turn reprocesses only what was appended (444 tokens out of 20,618), and the main conversation comes back from the RAM cache after a detour (39 tokens reprocessed). **[measured]**

**Surprises**
1. **For short turns, computing the experts on the CPU is faster than copying them to the GPU.** Batch of 128 tokens: 384 tok/s on the CPU vs 141 tok/s copying over PCIe. The crossover is at ~1,000 tokens, hence `GGML_OP_OFFLOAD_MIN_BATCH=1024`.
2. **Prefill pays a fixed cost of ~0.9 to 1.2 s per micro-batch,** almost independent of size. A micro-batch of 4096 gives +45% on long prompts compared to 2048.
3. **Pinned memory (`-lm dio`/`none`) speeds up prefill by 10 to 27%** compared to the default `mmap`. But `-lm none` takes ~2.5 min to load, vs ~30 s with `dio`.
4. **16 threads is the worst value for generation** (−20 to 30%). 6 to 8 threads is the best.
5. **More expert layers on the GPU yield little:** ~1 to 1.5% per layer. Generation is limited by the CPU↔GPU exchange at each layer, not by RAM bandwidth.

## Usage premise and measurement conditions

**Premise decided by the user:** when the AI is in use, the GPU is dedicated to it (no games, NVIDIA Broadcast closed). That is why the profile uses the whole GPU and leaves only ~470 MiB of headroom for driver/WDDM variations, not for other apps. If another app uses the NVIDIA GPU at the same time, performance drops by half (section 11).

**Interference during E4 and what was done**

| When | What | Affected runs | Handling |
|---|---|---|---|
| ~10:39–10:40 (time reported by the orchestrator: "10:5x–11:0x") | SHA-256 check of the GGUF by the orchestrator (1 core + RAM bandwidth) | By my timestamps, only the `--fit` loads (which measure memory, not speed). By the reported window, also `E-threads`, `D-smallturn`, `D3`, `F-depth` (10:54–11:07) | `E` and `D` redone at 11:42 (`E2`, `D2`), `F` redone at 11:12 (`F2`); same conclusions. `D3` was not redone: the server confirmed the effect afterwards |
| 11:08–11:09 | Unidentified external load: queue of 37 to 55 threads and −6 GB of free RAM for ~4 s, twice (`raw/02-G-tgnoise.vmstat`) | `G-tgnoise` (2 of 10 samples at 12 and 16 tok/s) | Redone (`G2`, no spikes) and `burstmon.sh` monitor kept on for the rest of the session |
| **11:26–~11:37** | **Game (Dota 2) on the NVIDIA GPU** (C+G, 100% of the GPU, 126 W, ~2 GB of VRAM), seen in the Windows `nvidia-smi` | `03-CONTAMINADO-jogo-M2048-ub2048`, `03-CONTAMINADO-jogo-FINAL-64k-ncmoe40` | Redone with the GPU free; the contaminated ones were kept as separate data (section 11) |
| 11:26–~11:47 | NVIDIA Broadcast as a compute process on the NVIDIA GPU: 144 MiB, 1 to 3% usage with the GPU idle (up to ~14% in peaks) | `M2048-rerun`, `FINAL-64k-ncmoe40`, `E2-threads`, `D2-smallturn` | Kept with a caveat: generation possibly 2 to 5% lower and noisier. Closed by the user; the runs from 11:47 on are clean |
| The whole session | Other local services in containers (periodic healthchecks) | Spikes of 15 to 26 threads lasting a few ms in `burstmon` | Negligible |

Before 11:26 VRAM started from 0 MiB with 0% usage in all runs. After that it started from 144 MiB (Broadcast). From 11:47 on, from 0 MiB again (`raw/03-*.csv`, first line).

## 1. PCIe and machine state

| Moment | Link | Replays | GPU | VRAM used | Available RAM |
|---|---|---|---|---|---|
| 10:38 (before) | Gen4 ×8 | 0 | 31 °C, P8 | 0 MiB | 48.8 GiB |
| 11:37 (right after the game) | Gen4 ×8 | 0 | 53 °C | 144 MiB (Broadcast) | 48.5 GiB |
| 11:41 | Gen4 ×8 | 0 | 54 °C | 144 MiB | — |
| 12:05 (final, after the 128k load) | Gen4 ×8 | 0 | 40 °C, P8 | 0 MiB | — |

- Thermal slowdown counters (`SW/HW Thermal Slowdown`) at 0 µs for the whole session. Only the 130 W power cap acted (`SW Power Capping`), which is normal under load.
- **Verdict: Gen4 ×8 stable.** There was no CUDA error, corrupted text or link drop.

## 2. Where the experts live

**What `--fit` chooses** (`01-fit.sh`, context 131072, KV q8_0, default headroom of 1024 MiB; CUDA sees 7,062 MiB free out of 8,150):

| Micro-batch | `--fit` choice | Own VRAM | Model | Context (KV + recurrent state) | Compute buffer |
|---|---|---|---|---|---|
| 512 | 37 expert layers in RAM + 1 partial | 5,854 MiB | 3,987 | 1,422 | 444 |
| 1024 | 38 + 1 partial | 5,870 | 3,815 | 1,422 | 632 |
| 2048 | 38 + 1 partial | 5,954 | 3,523 | 1,422 | 1,008 |
| 4096 | **bad:** 2 whole layers (with attention) on the CPU | 5,949 | 2,562 | 1,418 | 1,968 |

- With all experts in RAM, the dense weights take 2,038 MiB on the GPU. Each expert layer costs 464 to 560 MiB (UD varies the quantization per layer).
- KV for 131072 tokens in q8_0: 1,360 MiB, or 10.6 KiB per token (only 10 full-attention layers; the plan estimated 20 KiB). Recurrent state (DeltaNet): 63 MiB.
- With a micro-batch of 4096, keeping only dense weights would leave 1,023 MiB free, 1 MiB below the default headroom. That is why `--fit` took whole layers off the GPU, the worst possible outcome. With explicit `-ngl 99 -ncmoe` this does not happen.

**Gain per layer on the GPU** (`llama-bench`, `mmap`, micro-batch 2048, 12 threads):

| `-ncmoe` | pp2048 (tok/s) | tg (tok/s) |
|---|---|---|
| 40 | 968 | 32.2 (1 valid sample; the other, 12.1, was an external spike) |
| 38 | 1,013 | 35.0 |
| 36 | 1,055 | 36.5 |
| 34 | 1,088 | 37.2 |

With micro-batch 4096, 8 threads and `dio`: tg of 36.1 (`-ncmoe 40`) vs 36.7 (`-ncmoe 38`). **Each layer yields ~1 to 1.5%.** Generation is not limited by RAM bandwidth (the theoretical ceiling would be ~100 tok/s). The limit is the fixed cost of ~76 CPU↔GPU exchanges per token. **[measured / interpretation]**

**Choice:** `-ncmoe 38` with micro-batch 4096. It takes 6,571 MiB and leaves **472 MiB free** in CUDA's view (`raw/03-K2-ncmoe38.log`), within the 300 to 500 MiB headroom decided for a dedicated GPU. Alternative tested: `--fit` with a headroom of 384 MiB and free layers chose 1 layer + 1 partial (6,450 MiB, 594 free). Performance is equivalent, but I preferred the explicit value because it does not depend on the `--fit` heuristic changing between versions.

## 3. Micro-batch: fixed cost per micro-batch

`llama-bench`, `-ncmoe 38`, `mmap`, tok/s:

| Micro-batch | pp512 | pp2048 | pp4096 |
|---|---|---|---|
| 512 | 378 | 301 ± 99 | 357 |
| 1024 | 388 | 638 | 590 |
| 2048 | 389 | 1,013 | 1,009 |
| 4096 | 366 | 1,020 | **1,477** |

- The time per micro-batch follows `t ≈ fixed cost + n / ~2,450 tok/s`. The fixed cost is **~1.2 s with `mmap`** and **~0.86 s with pinned memory** (`dio`). **[measured]**
- The fixed cost is attributed to the transfer of the experts from RAM to the GPU. From the implied rate, either not all 18 GB are copied on every micro-batch, or the copy overlaps with computation. The mechanism was not verified.
- On the server, with the 20k-token cold prompt: **16.5 s with micro-batch 4096 vs 22.0 s with 2048** (−25%). Generation does not change.
- Cost of micro-batch 4096: +1.1 GB of compute buffer on the GPU (2,114 vs 1,008 MiB) and +576 MiB pinned in RAM (1,152 vs 576 MiB).

## 4. Load mode: mmap vs pinned memory

`llama-bench`, `-ncmoe 38`, tok/s:

| Mode | Micro-batch | pp512 | pp4096 | tg64 | Load time |
|---|---|---|---|---|---|
| `mmap` (default) | 2048 | 406 | 1,015 | 35.0 | ~6 s (file in the page cache) |
| `mmap` | 4096 | 378 | 1,240 (1,402 / 1,079) | 33.7 | |
| `none` (pinned memory) | 2048 | 460 | 1,114 | 35.6 | **~2.5 min** (GPU idle, RAM stable) |
| `none` | 4096 | 461 | 1,573 | 33.8 | |
| `dio` (DirectIO + pinned memory) | 2048 | 465 | 1,128 | 27.9 * | **~30 to 34 s** on the server |
| `dio` | 4096 | **480** | **1,620** | 19.4 * | |

\* Generation with `dio` had isolated slow samples (22.7 and 6.4 tok/s) at a moment of external memory pressure. In the following runs with `dio`, generation stayed at 33 to 37 tok/s.

- With pinned memory, the expert weights go to a `CUDA_Host` buffer (19,275 MiB with `-ncmoe 40`), which shows up as `Shmem` in `/proc/meminfo`. llama.cpp itself warns: *"tensor overrides to CPU are used with mmap enabled - consider using --load-mode none for better performance"*.
- `mlock` was not tested: the `memlock` limit is 64 MiB and only goes up with `sudo`. Pinned memory already prevents swapping.
- `--no-host` (repacking the weights for the CPU) and `GGML_CUDA_REGISTER_HOST` were not tested (open questions).

## 5. Short turns: CPU vs copy to the GPU

An agent appends 100 to 2,000 tokens per turn. By default, any batch of 32 tokens or more copies the experts to the GPU (`GGML_OP_OFFLOAD_MIN_BATCH=32`). `llama-bench`, `-ncmoe 40`, micro-batch 4096, `dio`, tok/s (`D2`, 11:42, with the Broadcast caveat):

| Batch | Copying to the GPU (default) | On the CPU, 8 threads (`-nopo 1`) | On the CPU, 12 threads | `MIN_BATCH=1024`, 12 threads (`D3`) |
|---|---|---|---|---|
| 128 | 141 | 371 | 372 | **384** |
| 512 | 451 | 504 ± 172 | 568 | **580** |
| 1024 | 744 | 761 | 694 | 730 (already goes to the GPU) |
| 2048 | 1,135 | 786 | 675 ± 117 | **1,116** |
| 4096 | — | — | — | **1,510** |

- On the CPU, time grows ~1.2 ms per token. Through the GPU, there is the fixed cost of ~0.9 s. **The crossover is at ~1,000 tokens.** **[measured]**
- `GGML_OP_OFFLOAD_MIN_BATCH=1024` combines the best of both paths: **2.7× faster on batches of 128** and +29% on batches of 512, losing nothing on large batches.
- For the CPU path, 12 threads (`-tb 12`) give a little more than 8. 16 threads was worse and unstable (`D`: pp128 of 131 ± 52).
- On the server, warm turns of 346 to 444 tokens take 1.0 to 1.2 s (20k) and 1.3 to 1.5 s (120k). That time includes creating 2 to 3 checkpoints (63 MiB each) and the template.

## 6. Generation threads

`llama-bench` tg128, micro-batch 4096, `dio`, tok/s:

| Threads | `E` (10:54, `-ncmoe 40`) | `E` (`-ncmoe 38`) | `E2` (11:42, Broadcast active) | `G2` (11:09, clean, 10 repetitions) |
|---|---|---|---|---|
| 6 | 32.7 ± 5.3 | 37.0 | 35.7 | |
| 8 | 36.1 | 36.7 | 32.1 ± 3.8 | **34.9 ± 2.4** |
| 12 | 33.8 | 35.1 | 33.1 | |
| 16 | 26.9 ± 4.0 | 29.1 ± 4.9 | 24.8 | |

- 6 to 8 threads give the best result, 12 is ~3 to 5% lower and 16 loses 20 to 30%.
- WSL sees 16 vCPUs (8 cores × 2 SMT, 1 L3 of 96 MB) and Hyper-V does not pin vCPUs to cores. So it is not possible to choose the CCD with the 3D cache by affinity.
- Choice: **`-t 8`** for generation and **`-tb 12`** for the batches on the CPU.

## 7. Depth curve

`llama-bench` `F2` (11:12–11:17, clean), `-ncmoe 40`, micro-batch 4096, `dio`, `MIN_BATCH=1024`, tok/s:

| Depth | pp512 (CPU path, 12 threads) | pp4096 (GPU path) | tg128 (8 threads) |
|---|---|---|---|
| 0 | 580 | 1,622 | 34.9 |
| 16,384 | 600 | 1,209 (1,388 / 1,030) | 33.6 |
| 65,536 | 518 | 843 (751 / 935) | 24.4 (27.0 / 20.5 / 25.6) |

- pp4096 at depth alternates between repetitions in a repeating pattern (fast/slow at 16k, slow/fast at 64k). The table shows both samples.
- On the server, with real prompts, generation was 30 to 32 tok/s with 20k of context, 25 to 26 with 64k and 21 to 23 with ~120k.

## 8. Expert cache on the GPU (`--moe-cache-mib`)

Server, `-ncmoe 40`, micro-batch 2048 (so the 2 GiB cache fits), 4 requests of 256 tokens:

| Cache | Generation (tok/s) | Mean | Hit rate (batch ≤ 8) | Sent to the GPU during the test | Peak VRAM |
|---|---|---|---|---|---|
| 0 | 33.4 / 36.8 / 35.9 / 36.3 | **35.6** | — | — | 4,728 MiB |
| 1024 MiB | 23.4 / 22.6 / 23.1 / 22.7 | 22.9 (**−36%**) | 43.5% | 343 GB | 5,862 MiB |
| 2048 MiB (redone, Broadcast active) | 29.6 / 28.7 / 25.7 / 28.6 | 28.1 (**−21%**) | 60.7% | 239 GB | 6,887 MiB |

- **Verdict: do not use.** Even with a 60% hit rate, each miss sends the expert over PCIe, and that is slower than computing on the CPU (Zen 5 with AVX-512).
- The "up to 2.2×" promise holds for machines where CPU computation is the bottleneck, which is not the case here.
- The run contaminated by the game (2048 MiB) was even worse: 4.5 to 28 tok/s, 123 s load and 7,857 MiB of VRAM (section 11).

## 9. Agent-turn simulation

`agent_turns.py` through `/v1/chat/completions`, with the chat template and 8 tools (as in a coding agent). Sequence:
1. Cold prompt: system + tools + a large pasted source file (`argparse.py`; more files for 64k and 120k).
2. Two warm turns: the model's reply (reasoning + tool call) is sent back, and the tool result and a user message are appended.
3. A different parallel conversation (like a subagent or a title request).
4. The return to the main conversation.

| Run (profile) | Cold: tokens | Cold: prefill | Turn 2: reprocessed / cached | Turn 2: time | Turn 3 | Detour (1,427 tokens) | Return: reprocessed | Return: time | Generation |
|---|---|---|---|---|---|---|---|---|---|
| `S1` (`-ncmoe 40`, micro-batch 4096) | 20,065 | 16.5 s | 444 / 20,174 | 1.24 s | 346: 1.02 s | 2.45 s | 39 | 0.43 s | 32.0 to 32.9 |
| `M0` (`-ncmoe 40`, micro-batch **2048**) | 20,065 | 22.0 s | 444 / 20,174 | 1.19 s | 346: 1.04 s | 2.44 s | 39 | 0.41 s | 30.8 to 31.7 |
| **`FINAL-20k-ncmoe38`** | 20,065 | **16.2 s** | 444 / 20,174 | **1.19 s** | 346: **1.03 s** | 2.47 s | 39 | **0.41 s** | 30.4 to 31.8 |
| `FINAL-64k-ncmoe40` (Broadcast active) | 64,065 | **58.2 s** | 444 / 64,146 | 1.29 s | 346: 1.24 s | — | — | — | 24.8 to 26.3 |
| `FINAL-128k-ncmoe40` | 120,065 | 127.5 s | 444 / 120,191 | 1.48 s | 349: 1.39 s | 2.75 s | 39 | 0.50 s | 20.6 to 21.4 |
| **`FINAL-128k-ncmoe38`** | 120,065 | **128.6 s** | 444 / 120,191 | **1.45 s** | 349: **1.30 s** | 2.47 s | 42 | **0.48 s** | 21.4 to 22.6 |

**What the log shows** (`-lv 4`, `raw/03-S1-agent.log`):
- **Cold prompt:** checkpoints created at positions 1,585, 15,969 (end − 4,096) and 20,061 (end − 4), 62.8 MiB each. That is, not every 2,048 tokens: `-cms` is only the minimum spacing. In the warm turns, 2 or 3 checkpoints per turn.
- **Turn 2:** `selected slot by LCP similarity, f_sim_best = 0.978, f_keep = 1.000`. The resent history matched the cache token by token, including the reasoning and the tool call generated by the model itself (an effect of `--reasoning-preserve`). There was no need to restore a checkpoint.
- **Detour:** the other conversation shares only ~1,011 tokens (the tools block), fewer than the first checkpoint (1,585). That is why the log records `forcing full prompt re-processing due to lack of cache data`, as expected for a different conversation. Before that, the main conversation was saved to the prompt cache: 21,212 tokens, 283 MiB of state + 9 checkpoints = 849 MiB, in 0.6 s.
- **Return:** the main conversation was restored from the RAM cache; only 39 tokens were reprocessed.
- **Without `-lv 4`:** the log only shows the line `selected slot by LCP similarity ... f_keep`. The checkpoints and the full-reprocessing warning do not appear. To check cache reuse without `-lv 4`, use `timings.cache_n`/`prompt_n` from the responses or `llamacpp:prompt_tokens_total` in `/metrics`.

**Real cost of a cache loss** (cold prompt, final profile): **~16 s for 20k tokens, ~58 s for 64k and ~2 min 9 s for 120k.** With the agents' preamble (section 2 of the plan), that gives ~25 s in Claude Code (~30k), ~6 s in OpenCode (~7.5k) and ~1.5 s in Pi (~1.4k). **[estimated from the measured]**

Tool calls came back well formed in all cold and warm turns up to ~123k of context; there was no corrupted text. Some 120k turns hit the 1,200-token output limit during reasoning.

## 10. Memory and temperature under load

Final profile (`-ncmoe 38`, micro-batch 4096, `dio`), runs `FINAL-20k-ncmoe38` and `FINAL-128k-ncmoe38`:

| Resource | Value |
|---|---|
| VRAM (`nvidia-smi`) | **6,794 to 6,796 MiB**, flat from load up to 123k tokens of context (289 samples in ~5 min) |
| VRAM (CUDA's view) | model 3,035 + context 1,422 + compute 2,114 = 6,571 MiB; **472 MiB free**; WDDM reserves ~1,090 MiB that CUDA does not use |
| Spill to shared memory | There was none: VRAM below the total, stable generation (21 to 22 tok/s sustained with 120k) |
| Process RAM (RSS) | 19.6 GiB after load; peak of 22.5 GiB |
| Pinned memory (`CUDA_Host`) | ~17.9 GiB of experts + 1.1 GiB of compute buffer |
| Minimum `MemAvailable` | 26.0 GiB (of 51 GiB visible in WSL), with the prompt cache still small |
| Swap | ~200 MB was used once during the `llama-bench` runs with `none`/`dio` (other processes); no growth in the server tests |
| GPU temperature | maximum of **82 °C** in ~6 min of continuous load; 0 µs of thermal slowdown; only the 130 W cap acted |
| Server load until it responds | 32 to 34 s |

**Worst-case RAM budget** **[estimated]**: ~20 GiB of the process + up to 3 GiB of checkpoints (48 × 63 MiB) + up to 12 GiB of prompt cache = ~35 GiB. ~16 GiB of the 51 GiB of WSL remain for the agent container, builds and tests.

**VRAM headroom with 128k:** the server reserves the 131072-token KV and the compute buffers at load. VRAM did not grow with depth (measured up to 123k). The 472 MiB headroom holds for a full context.

`llama-bench` showed up to 7.6 GB at high depths because it sizes context and buffers on every test. That number does not represent the server.

Alternative in case the headroom turns out short in E5: `-ncmoe 40` (1,348 MiB free, ~2% slower) or micro-batch 2048 (+1.1 GB free, cold prompt 33% slower).

## 11. Separate data: the GPU shared with a game

The user opened a game (Dota 2) on the NVIDIA GPU between ~11:26 and ~11:37, on purpose, to see the effect. Two runs coincided with it and were kept as `raw/03-CONTAMINADO-jogo-*`. The comparison is with the same measurements redone with the GPU free:

| Measure | GPU free | With the game | Change |
|---|---|---|---|
| Load until it responds (`-ncmoe 40`, micro-batch 4096) | 34 s | 89 s | 2.6× slower |
| 64k cold prompt | 58.2 s (1,100 tok/s) | 109.3 s (586 tok/s) | **−47%** |
| Warm turns with 64k | 1.29 / 1.24 s | 1.91 / 1.77 s | +45% |
| Generation with 64k | 24.8 to 26.3 tok/s | 11.8 to 12.1 tok/s | **−53%** |
| Total VRAM (`nvidia-smi`) | 5,941 MiB | 7,815 MiB (game ~2 GB + server) | 336 MiB from the total |
| Maximum temperature | 78 °C | 83 °C | |
| Expert cache 2048 MiB: generation | 25.7 to 29.6 tok/s | 4.5 to 28.3 tok/s | one request at 4.5 tok/s |
| Expert cache 2048 MiB: load | 31 s | 123 s | |

- **There was no failure:** no CUDA error, no out-of-memory, no drop. Tool calls remained valid and cache reuse worked the same (444 tokens reprocessed out of 64k).
- **Performance drops by half** because the GPU is time-shared with the game (100% usage by the game).
- **Gotcha:** with the game open, CUDA kept reporting 7,062 MiB free to `--fit`. On WSL/WDDM `--fit` does not see the VRAM of other processes and does not protect against them.
- **With the final profile** (`-ncmoe 38`, ~1 GB more VRAM), server + game would exceed the card's total. The Windows driver tends to push part of the memory to system RAM, which should make it even worse. **[estimated, not measured]**
- **Recommendation:** do not play or use apps on the NVIDIA GPU during inference (the adopted premise). If unavoidable, stop the server or restart it with `-ncmoe 40`.

**NVIDIA Broadcast** as a compute process: 144 MiB of VRAM and 1 to 3% usage with the GPU idle (peaks of ~14%). It is a likely source of generation noise in the runs from 11:26–11:47 (`E2`, `D2`, `M2048-rerun`, `FINAL-64k-ncmoe40`). It must stay closed while the AI is in use.

## 12. Chosen profile, flag by flag

| Flag | Value | Why |
|---|---|---|
| `-np` | 1 | One agent at a time. More slots would split context and cache and invalidate reuse between turns |
| `-c` | 131072 | Requested context. KV costs only 1,360 MiB in q8_0 (10 full-attention layers) |
| `-fa` | on | Required by the quantized V cache |
| `-ctk` / `-ctv` | q8_0 | q4_0 degrades tool calls (plan research). q8_0 fits with room to spare |
| `-ngl` | 99 | Attention, DeltaNet, shared expert and output on the GPU |
| `-ncmoe` | 38 | Experts of layers 0 to 37 in RAM and of the last 2 on the GPU. Uses VRAM down to ~470 MiB of headroom (dedicated GPU premise). Gain of ~2 to 3% (section 2) |
| `--fit` / `--fit-target` | on / 384 | Only checks the headroom at load. With explicit `-ngl`/`-ncmoe` it changes nothing: if the headroom is missing, it logs `failed to fit params ... abort` and loads anyway. The E5 health script must look for this warning |
| `-b` / `-ub` | 4096 / 4096 | The fixed cost of ~0.9 s per micro-batch makes a micro-batch of 4096 give +45% prefill. 20k cold prompt: 16.2 s vs 22.0 s with 2048 |
| `-t` | 8 | Best generation (6 to 8). 12 is ~3 to 5% lower and 16 loses 20 to 30% |
| `-tb` | 12 | Batches under 1,024 tokens run on the CPU (via `MIN_BATCH`), and 12 threads give a little more than 8 on that path |
| `-lm` | dio | Pinned memory: +10 to 27% prefill vs `mmap`. Loads in ~30 s (`none` takes ~2.5 min) and does not occupy 22 GB of page cache |
| `--jinja` | (default) | Model template with the Qwen3 tool-call parser |
| `--reasoning-preserve` | (default) | The resent history matches the cache token by token (`f_keep = 1.000`), without restoring a checkpoint |
| `-ctxcp` | 48 | Up to 48 checkpoints of 63 MiB (~3 GB of RAM). Each turn creates 2 or 3 |
| `-cms` | 2048 | Kept from the plan: allows checkpoints closer than the default 8192. In the tests, the checkpoints ended up at the end of each prompt (and at the start of the last micro-batch), and the effect of `-cms` was not isolated (open question 9) |
| `--cache-ram` | 12288 | Keeps whole conversations in RAM (849 MiB for 21k tokens with 9 checkpoints; ~2 to 2.5 GiB estimated for 120k) and returns them in ~0.4 s after a detour |
| `--metrics` | | `/metrics` for the validation runner |
| `--temp` / `--top-p` / `--top-k` | 0.6 / 0.95 / 20 | Plan default (model card). Not measured in E4 and the agent can override per request |
| `-lv 4` | commented out | For debugging only: shows checkpoints and full reprocessing (~10 KB per request, without the contents) |
| `GGML_OP_OFFLOAD_MIN_BATCH` | 1024 | Batches under 1,024 tokens compute the experts on the CPU: short turns up to 2.7× faster |

## 13. Expected speeds (final profile, dedicated GPU)

| Operation | Speed |
|---|---|
| Long-prompt prefill (cold) | ~1,240 tok/s with 20k, ~1,100 with 64k, ~930 with 120k (average over the whole prompt) |
| Warm turn of 300 to 500 tokens | 1.0 to 1.5 s, from 20k to 120k of context |
| Warm turn of ~100 tokens | ~0.3 to 0.5 s **[estimated]** |
| Generation | 34 to 37 tok/s with short context, 30 to 32 with 20k, 25 to 26 with 64k, 21 to 23 with 120k |
| Server load | ~33 s until `/health` |

## 14. Open questions

1. **Mechanism of the fixed cost per micro-batch** (~0.9 s with pinned memory). The implied rate exceeds the Gen4 ×8 bandwidth if all experts were copied. Understanding this may lead to a better tuning, for example a different `GGML_OP_OFFLOAD_MIN_BATCH` per layer.
2. **`--no-host` (repacking for the CPU) and `GGML_CUDA_REGISTER_HOST`** were not tested. Repacking could speed up the CPU path in short turns and in generation, but would take pinned memory away from prefill.
3. **Fast/slow alternation of pp4096 at depth** in `llama-bench` (1,388 / 1,030 at 16k). The server did not show this on cold prompts, but it was not investigated.
4. **The external load at 11:08** (queue of ~40 threads and −6 GB for ~4 s) was not identified. If it is periodic, it will show up as a stutter in generation; `burstmon.sh` can stay on in E6.
5. **Sampling:** llama.cpp's default `min_p` (0.05) was kept. Check on the Qwen3.6 card whether the recommended value is `min_p = 0` and whether `presence_penalty` changes anything in long sessions.
6. **Prompt cache with several agents or subagents:** 12 GiB hold ~5 conversations of 120k or ~14 of 20k **[estimated]**. Measure the real hit rate in E6, with `-lv 4` temporarily on.
7. **WSL vs native llama-server on Windows** (plan uncertainty): it was not necessary. WSL delivered what was expected (prefill ~1,200 to 1,600 tok/s, generation ~35 tok/s).
8. **`--fit` behavior with insufficient headroom and explicit flags:** it only logs the warning, without preventing the load. The E5 health script must check for the `failed to fit params` line and VRAM usage.
9. **Effect of `-cms 2048`:** the checkpoints appeared at the end of each prompt, not every 2,048 tokens. It remains to test an agent that edits or compacts the history in the middle (E6) to know whether a smaller `-cms` helps and whether 48 checkpoints are enough.
