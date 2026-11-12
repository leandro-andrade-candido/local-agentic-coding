> Translated from the Portuguese original (commit 30666ad).

# Local agentic environment: diagnosis and plan

Phase 1: hardware audit, research on models, runtimes and agents, recommended architecture and execution plan.

- Audit and research: 2026-10-27. Hardware re-verified on 2026-10-29, after adjustments A and B.
- Nothing installed so far. The only download: the `ubuntu:24.04` image (119 MB), used to test the GPU in Docker.

**Evidence level** used throughout the document:

| Label | Meaning |
|---|---|
| **[measured]** | measured on this machine |
| **[verified]** | checked against the primary source |
| **[reported]** | reported by a cited external source |
| **[estimated]** | calculation or extrapolation, still to be measured |
| **[unverified]** | single report |

---

## 1. Summary

| Item | Recommendation |
|---|---|
| Runtime | **llama.cpp (llama-server)**, prebuilt CUDA 12.8 binary for Linux, running in WSL as a user service. The MoE experts stay in RAM; attention and the context cache are on the GPU. **[verified]** |
| Main model | **Qwen3.6-35B-A3B** (Apache-2.0), Unsloth GGUF UD-Q4_K_XL, 22.4 GB. It is the best independent result among the models that fit here. **[verified]** |
| Agent | Chosen by testing **Qwen Code**, **OpenCode** and **Pi**, with Claude Code pointed at the local model as a reference. Likely order: Qwen Code, Pi, OpenCode. The evidence is weak and contradictory, so the choice will be measured. |
| Architecture | Single agent, isolated in a Docker container with the repository mounted. Subagents and a reviewer model are added only if validation shows a gain. |
| Expectation | Good for bounded tasks: fixing a bug, a feature touching a few files, writing tests. Clearly below Claude Code with Claude models on long, ambiguous tasks. The gap will be measured with the same tasks, not assumed. |

| Indicator | Value | Level |
|---|---|---|
| RAM read bandwidth | 65 GB/s (theoretical 89.6) | **[measured]** |
| Free VRAM | 7.9 GB of 8 (was 4.9 before adjustment A) | **[measured]** |
| GPU link | PCIe 4.0 ×8, ~15.8 GB/s theoretical (was 3.0 ×8) | **[measured]** |
| Core downloads | ≈ 26 GB | **[verified]** |

---

## 2. Hardware diagnosis

| Component | Actual state | Consequence for inference |
|---|---|---|
| CPU | AMD Ryzen 9 9900X3D, Zen 5, 12 cores / 24 threads, 96 MB L3. Full AVX-512 (VNNI, BF16, VBMI2). WSL sees 16 threads. **[measured]** | Great for computing the MoE experts. Generation is limited by RAM, not by the CPU. |
| RAM | 61.6 GB DDR5-5600 (2 × 32 GB, dual-channel). WSL limited to 40 GB + 8 GB of swap. Read at 65 GB/s, triad at 47 GB/s, the same with 8 or 16 threads. **[measured]** | The 35B model fits in Q4 to Q6 with room to spare. ~80B models require raising the WSL limit (adjustment C). |
| GPU | RTX 5050 desktop, 8 GB, Blackwell (compute 12.0), 130 W, driver 610.88, CUDA 13.3. No monitor attached, 0 MiB in use, 7.9 GB free. **[measured]** | Fits attention, context cache, buffers and still ~3 GB for experts or for the expert cache. |
| Video | Both monitors (PHL 276E8V and ASM-16QCC) are on the AMD Radeon iGPU. **[measured]** | The NVIDIA GPU stays dedicated to inference. |
| PCIe | Gen4 ×8. The host limit is 4, the GPU accepts up to 5; at idle the link drops to Gen1 (normal power saving). Motherboard JGINYUE B650I Night Devil (mini-ITX), BIOS from Jul 2025. Error counter (replays) at 0. **[measured]** | It is the prefill bottleneck when the experts stay in RAM. Bandwidth doubled compared to Gen3. |
| Disk | ADATA Legend 860 NVMe, 1 TB. 827 GB free on the WSL ext4. **[measured]** | No constraint. Models stay on ext4, never on `/mnt/c`. |
| System | Windows 11 Pro (build 26300), WSL 2.7.14, kernel 6.18, Ubuntu 24.04.4, systemd active. **[measured]** | A user service via `systemctl --user` works. |
| Containers | Docker 29.8 + nvidia-container-toolkit 1.20. The GPU shows up inside the container (tested). **[measured]** | Base ready to isolate the agent. |
| Tools | Node 24, npm, pnpm, uv, Python 3.12, git, gh, rg, fd, jq, gcc. Already installed: Claude Code 2.1.311, Codex CLI 0.154, Gemini CLI 0.65. Missing: llama.cpp, Ollama, bubblewrap, CUDA toolkit (not needed). **[measured]** | Nothing needs `sudo` on the main path. |

### How the hardware limits speed

- **Generation (output tokens).** For each token the model reads the active experts in RAM; on Qwen3.6-35B-A3B in Q4 that is ~0.6 GB per token.
  - With 65 GB/s, the theoretical ceiling is ~100 tok/s.
  - Realistic expectation: **35 to 50 tok/s** with short context. **[estimated]**
- **Prefill (reading the prompt).** In large batches, llama.cpp copies the experts that are in RAM to the GPU on every micro-batch.
  - With 7.9 GB of VRAM, ~14 GB of experts should remain in RAM. That gives ~1.2 s per copy at ~12 GB/s (real Gen4 ×8).
  - With a 2048-token micro-batch, the ceiling is above 1,500 tok/s.
  - Expectation: **500 to 1,000 tok/s**. It may drop if WSL does not use pinned memory. **[estimated]**
- **That is why the size of the agent's prompt matters.** Whenever the cache is lost, the agent reprocesses the entire preamble. At 700 tok/s **[estimated]**:

  | Agent | Preamble | Cost per cache loss |
  |---|---|---|
  | Claude Code | ~30k tokens | ~45 s |
  | OpenCode | ~7.5k tokens | ~11 s |
  | Pi | ~1.4k tokens | ~2 s |

- **Context.** Qwen3.6 has full attention in only 10 of its 40 layers: 20 KiB per token, ~1.3 GB for 128k tokens with a q8_0 cache. **[reported]** Long context is not the problem; the cost is in reprocessing it.

### Hardware adjustments

| Adjustment | State | Gain and risk |
|---|---|---|
| **A.** Monitors on the iGPU | **Done on Oct 29**, verified | +3 GB of VRAM. If any app starts using the NVIDIA GPU to render (Settings › System › Display › Graphics), the VRAM is occupied again. This will be monitored during the tests. |
| **B.** PCIe Gen4 in the BIOS | **Done on Oct 29**, verified | 2× bandwidth in prefill. Stability under load to be confirmed in E4: the replay counter must stay at 0. |
| **C.** WSL limit from 40 to 52 GB | **Applied on Oct 29** in `.wslconfig` (backup in `.wslconfig.bak-20261029`); takes effect after `wsl --shutdown` | Allows the full test, including Qwen3-Coder-Next (80B). Windows keeps ~9.6 GB guaranteed and was using ~17.4 GB (7.7 in Chrome alone): during inference, close heavy apps on Windows. To revert, restore the backup. |

---

## 3. Where each limit lies

A model that writes good code can fail as an agent, and a good agent does not make up for a runtime that loses the cache. The three layers are evaluated separately.

| Layer | What it decides | Situation here |
|---|---|---|
| **Model** | Quality of reasoning and code, adherence to the tool-call format, tendency to loop. | The best model that fits (Qwen3.6-35B-A3B) is well below frontier models. It is the largest source of difference from Claude Code. |
| **Agent** | Size of the fixed prompt, design of the editing tools, loop control, context compaction, permissions. | With the same local models, different agents ranged from 62% to 77% in an independent 16-task test. **[reported]** |
| **Runtime** | Speed, cache reuse between turns, conversion of tool calls, stability. | llama.cpp is the only one with fine control of MoE offload and with checkpoints for hybrid-attention models such as Qwen3.6. |

---

## 4. Inference runtimes

| Runtime | Version | Verdict | Reason |
|---|---|---|---|
| **llama.cpp / llama-server** | v0.7.0 (Oct 15); build b11935 (Oct 27) **[verified]** | **Use** | See the points right below the table. |
| ik_llama.cpp | no releases | Comparison only | A fork focused on CPU and hybrid, but it has an open bug (#1762): Qwen3.6 does not restore checkpoints and reprocesses the whole prompt on every turn, which rules it out as an agent. In one cited benchmark, prefill was slower than mainline. **[reported]** |
| Ollama | 0.40.11 | No | No control over expert offload (open request since 2025). Default context of 4k on GPUs under 24 GB. Open issue of Qwen3.5 ~5× slower than llama.cpp. The Anthropic API has no prompt cache or `count_tokens`. **[reported]** |
| LM Studio | 0.4.x | Possible | Uses the same llama.cpp engine with less control. Free, but closed source. Adds nothing here. |
| vLLM / SGLang | — | No | Built for models fully in VRAM. vLLM's dynamic expert cache was not merged. With 8 GB there is no useful room. |
| KTransformers | 0.7 | No | Does not support Qwen3.5/3.6, Coder-Next, GLM-4.7-Flash, gpt-oss or Gemma 4. |
| llama-swap | v267 | Later | On-demand model switching. Only makes sense if the reviewer model proves its value; llama-server also has its own router. |

Why llama.cpp:
- Control of MoE offload: `--fit`, `-ncmoe`, `-ot`.
- In v0.7.0, an LRU expert cache on the GPU (`--moe-cache-mib`), with up to 2.2× in generation according to the project.
- Native Anthropic `/v1/messages` endpoint and a dedicated parser for Qwen3.
- Context checkpoints for hybrid models.
- CUDA 12.8 binary with native code for Blackwell. MIT license.

**Caveats found during research:**
- Use the CUDA 12.8 build. The 13.4 one may fail with the current driver (CUDA 13.3), and CUDA 13.2 produced corrupted text with Qwen3.6. **[unverified]**
- A q4_0 context cache degrades tool calls; use q8_0. **[reported]**
- When no checkpoint is usable, the server reprocesses the whole prompt without warning; this only shows up with `-lv 4`. It will be monitored during the tests. **[reported]**

---

## 5. Model selection

I prioritized independent, decontaminated benchmarks (SWE-rebench, Artificial Analysis) over vendor numbers, which use their own test harnesses and are not comparable with each other.

### Main: `Qwen/Qwen3.6-35B-A3B`

- **Release:** Apr 2026. 35B parameters in total, 3B active, native context of 262k.
- **License:** Apache-2.0 **[verified]**.
- **Sizes:** UD-Q4_K_XL 22.4 GB · UD-Q6_K 29.3 GB · Q8_0 36.9 GB **[verified]**.
- **Evidence [reported]:**
  - SWE-rebench (May–Jul 2026): **24.7%**, against 17.1% for Qwen3.5-35B and 31.2% for the dense Qwen3.6-27B.
  - Highest coding index among the small models on Artificial Analysis.
  - Most cited local model with OpenCode and Pi.
- **Limitations:**
  - Tool calls get worse with long context.
  - In OpenCode, it sometimes writes the call as text and the session hangs.
  - There are reports of more stability in Q6/Q8 than in Q4.

### Alternative main: `Qwen/Qwen3-Coder-Next`

- **Release:** Jan 2026. 80B in total, 3B active, no reasoning mode.
- **License:** Apache-2.0 **[verified]**.
- **Sizes:** UD-IQ4_XS 38.4 GB · UD-Q4_K_XL 49.6 GB **[verified]**.
- **Evidence:** SWE-rebench (May 6 snapshot): 54.4%, against 53.7% for Qwen3.5-35B in the same snapshot. Never measured in the same period as Qwen3.6. **[reported]**
- **Limitations:** requires adjustment C. Prefill is ~2.4× slower here, because 2.4× more experts go over PCIe. **[estimated]**

### Reviewer / planner: `Qwen/Qwen3.8-27B`

- **Release:** Aug 2026. Dense, with hybrid attention.
- **License:** Apache-2.0 **[verified]**.
- **Size:** UD-Q4_K_XL 17.6 GB **[verified]**.
- **Evidence:** Artificial Analysis Intelligence 28–34, against 18 for Qwen3.6-35B. No SWE-rebench result yet. **[reported]**
- **Limitations:**
  - Being dense, it runs at ~4–8 tok/s here **[estimated]**.
  - It reasons a lot: up to 67k tokens per task at the maximum level.
  - Useful only for reviewing or planning, in short passes.

### Auxiliary

- **Default option:** the main model itself with reasoning turned off (0 GB extra).
- **Alternative:** `Qwen/Qwen3.5-4B` (2.9 GB, Apache-2.0 **[verified]**). Leads the small models in tool calling (BFCL-v3 70.6) **[reported]**.
- **Limitation:** the VRAM cannot hold two models at the same time. The 4B will be used in the stage E3 smoke test.

### Discarded, with the reason

- **GLM-4.7-Flash** (MIT): SWE-rebench and coding index below Qwen3.6, plus template problems.
- **gpt-oss-20b / 120b**: the 120b (~63 GB) does not fit; the 20b trails in independent evaluations.
- **Gemma 4 26B-A4B / 31B**: results very sensitive to the test harness; the dense 31B is slow here.
- **Devstral Small 2 (24B)**: dense and slow here, with no demonstrated advantage.
- **Nemotron 3.5 Lightning 30B-A3B**: fast, but weaker (index 13 against 18).
- **Laguna XS 2.1**: there is a report of a CUDA crash with partial expert offload on an RTX 5060 Ti.
- **To watch:** Nemotron 3.5 Bolt 74B-A9B (no independent evaluation yet) and K2-Horizon MoVA 36B-A4B (support landed in llama.cpp v0.7.0; quantizations still missing).
- **Too large** for ~54 GB in Q4: Qwen3.5-122B, Mistral Small 4, Nemotron Super, DeepSeek V4-Flash, MiniMax M3, GLM-5.3-Flash.

---

## 6. Agents (agentic interfaces)

| Agent | License | Fixed prompt | Subagents · MCP · Skills · Hooks | Isolation |
|---|---|---|---|---|
| **Qwen Code** 0.26.x | Apache-2.0 | to be measured | Yes · Yes · Yes · Yes | Approval modes, sandbox, worktrees |
| **Pi** 1.4 | MIT **[verified]** | ~1.4k | Via add-on · Yes · Yes · TS extensions | **None**: requires a container |
| **OpenCode** 1.19.4 | MIT | ~7.5k | Yes · Yes · Yes (reads `.claude/skills`) · plugins | allow/ask/deny, default allows almost everything |
| Claude Code 2.1.311 (local) | Proprietary | ~25–31k | Yes · Yes · Yes · Yes (the most complete) | Permission rules, bubblewrap sandbox |
| Codex CLI · Crush · Mistral Vibe · Goose · OpenHands | various | — | Vary | Codex has the best sandbox |
| Aider · Roo Code · Continue | — | — | — | — |

How each one does with local models:

- **Qwen Code:** 75% on harness-bench (2nd place). It is from the same family as the model and aims for parity with Claude Code. **[reported]**
- **Pi:** 77% on harness-bench (1st place). It has native integration with llama.cpp. It has no plan mode or permissions. **[reported]**
- **OpenCode:**
  - 64% on harness-bench. Without the cases where the agent read the grader, it drops to ~55%.
  - It has a bug with Qwen3.6 that hangs the session, closed as "not planned" **[verified]**.
  - The 2.x line changed the configuration format six weeks ago.
- **Claude Code (local):**
  - 66% on harness-bench.
  - Works through `/v1/messages`, but Anthropic does not support non-Claude models.
  - Background calls discard the cache. **[reported]**
- **Codex CLI, Crush, Mistral Vibe, Goose, OpenHands:** situational. Codex only speaks the Responses API, which has problems in llama.cpp; Crush has an FSL license.
- **Avoid:** Aider (maintenance mode), Roo Code (archived) and Continue (unmaintained).

**The evidence is contradictory, so the agent will be chosen by testing.**
- OpenCode is the open alternative closest to Claude Code in features.
- Even so, it has a registered bug precisely with Qwen3.6 and was the worst in the only independent test with local models (16 private tasks, on an M3 Max Mac).
- Pi and Qwen Code did better in that test, but the sample is small and the hardware is different.

In stage E6, all four go through the same short test and only the best two move on to full validation. The rest are uninstalled.

---

## 7. Recommended architecture

```
You (WSL terminal or VS Code)
  │  task in natural language
  ▼
┌─ agent-box container (Docker) ───────────────────────────────────────┐
│  Agent: winner of the E6 test, AGENTS.md per project,                │
│         restricted permissions                                       │
│  Tools: shell, git (no push), read/edit, tests, linters              │
│  Repository mounted at /work, no SSH keys or GitHub token            │
└──────────────────────────────────────────────────────────────────────┘
  │  HTTP 127.0.0.1 · OpenAI /v1/chat/completions or Anthropic /v1/messages
  ▼
llama-server (systemd --user)
  Qwen3 tool-call parser, context checkpoints,
  prompt cache in RAM, metrics at /metrics, listens on localhost only
  │
  ├─► GPU · RTX 5050 (7.9 GB)
  │     attention and DeltaNet layers, shared expert, embeddings,
  │     q8_0 context cache, extra experts or LRU expert cache
  │
  └─► CPU + RAM
        routed experts (~14–17 GB in Q4), 12–16 AVX-512 threads,
        context checkpoints

~/models (ext4)    GGUF files, with a manifest of versions and hashes
~/me/local (git)   configs, scripts, evaluation suite, results, docs
```

### Initial server configuration

Starting point, to be calibrated with measurements in stage E4. **[reported]** **[estimated]**

```bash
llama-server -m ~/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf -a qwen3.6-35b \
  --host 127.0.0.1 --port 9931 -np 1 -c 131072 \
  -fa on -ctk q8_0 -ctv q8_0 \
  --fit on -b 4096 -ub 2048 -t 12 -tb 16 \
  --jinja --reasoning-preserve \
  -ctxcp 48 -cms 2048 --cache-ram 12288
# to test: --moe-cache-mib 1024–2048, manual -ncmoe, GGML_OP_OFFLOAD_MIN_BATCH, --no-mmap
# sampling (model card): temp 0.6, top_p 0.95, top_k 20, presence_penalty 0, preserve_thinking
```

### Agents, permissions and extensions

- **Permissions.**
  - Read allowed; edit allowed only inside `/work`.
  - Shell with a blocklist: `git push`, `rm -rf` outside the project, `curl | sh`, `sudo`.
  - The container is the real barrier; the agent's rules are the second layer.
- **Git.** One branch per task, local commits made by the agent and push always manual. The diff is reviewed before the merge.
- **Hooks.** Two to start: a formatter after each edit and the project's tests before the agent declares the task done.
- **Skills and AGENTS.md.** An AGENTS.md template with each project's build, test and lint commands, and a "debugging cycle" skill (reproduce, isolate, fix, validate).
- **MCP.** None at first, because each MCP tool grows the fixed prompt, which is expensive here. It is added only if validation shows something specific is missing.
- **Subagents and reviewer.** Off at first: with a single server slot, each subagent wipes the main agent's cache. They will be tested in stage E8.
- **Local Claude Code.** Used with a separate configuration directory (`CLAUDE_CONFIG_DIR`), without touching your current Claude Code.

---

## 8. Execution plan

**Execution order changed on Oct 29: E7 (container) runs before E6 (agent test).** The E6 test runs the agents in autonomous mode (yolo / `bypassPermissions`), where any command runs without confirmation. Without the container, the only barrier would be each agent's guard, which is just the second layer. The numbering was kept because it is already referenced in documents and scripts.

Each stage ends with an objective check and can be undone on its own. No stage uses `sudo`, unless the local Claude Code is the one chosen and needs bubblewrap; in that case I ask first. Every download above 5 GB will be confirmed beforehand, even after the general approval.

| Stage | What it does | Check | How to undo | Download · time |
|---|---|---|---|---|
| ~~E0~~ | Adjustments A, B and C. **Done on Oct 29** (C takes effect after `wsl --shutdown`). | 7.9 GB of free VRAM and host at Gen4 verified; `free -h` should show ~50 GB. | Cable, BIOS and `.wslconfig` backup. | — |
| E1 | Git repository in this folder: structure, README, version manifest. | `git log` with the initial structure. | Delete `.git` and the created files. | — · minutes |
| E2 | Prebuilt llama.cpp (CUDA 12.8) in `~/.local/opt/llama.cpp/<build>`, with a `current` link. | The GPU shows up as compute 12.0, the CPU shows AVX512 = 1 and `--version` matches. | Swap the link or delete the folder. | ~0.5 GB · minutes |
| E3 | Smoke test with Qwen3.5-4B: chat and tool call via OpenAI and via Anthropic. | 3 correct tool calls on each endpoint. | Delete the GGUF. | 2.9 GB · 15 min |
| E4 | Qwen3.6-35B-A3B Q4 and a `llama-bench` sweep: micro-batch size, offload, threads, expert cache, context of 0, 16k and 64k. Includes the PCIe Gen4 stability check. | Prefill and generation table; chosen profile, justified; PCIe replays at 0. | Delete the GGUF. | 22.4 GB · 1–2 h |
| E5 | llama-server as a user service with the chosen profile, plus a health script. | Restarts on its own, answers on localhost, checkpoint reuse confirmed in the log. | `systemctl --user disable`. | — · 30 min |
| E6 | Short agent test: Qwen Code, OpenCode and Pi (npm, pinned versions) and local Claude Code. Measures fixed prompt, tool errors and 3 small tasks. | Comparison table; 1 or 2 agents move on to E8. | `npm uninstall` of the discarded ones. | ~0.3 GB · 2–3 h |
| E7 | agent-box container, permission rules, hooks, AGENTS.md template, git flow. | Escape tests: the agent cannot push or write outside `/work`. | `docker rmi` and delete the configs. | ~1 GB · 1 h |
| E8 | Full validation (section 9). Optional variations: Q6_K, Coder-Next, 27B reviewer, subagents. | Report with success rate per configuration. | Delete the extra GGUFs. | 0–85 GB · 4–8 h of machine time |
| E9 | Documentation: start, stop, update, revert, problems found and solutions. | You bring the environment up from scratch following only the README. | — | — |

---

## 9. Practical validation

A script runs each task unattended from a fixed commit, runs hidden tests that the agent does not see and records the results in JSON. Each agent and model combination runs each task 2 to 3 times, because results vary between runs.

Repositories used:
- two public projects with a pinned commit, one in Python and one in TypeScript;
- if you authorize it, a **copy** of one of your projects.

| Task | What it tests | Success criterion |
|---|---|---|
| T1 | Explain the architecture of an unfamiliar repository. | Covers at least 7 of 10 facts from an answer key written beforehand. |
| T2 | Fix a planted bug, from a user report. | Hidden tests pass and nothing else breaks. |
| T3 | Implement a feature that touches 3 to 5 files. | Hidden acceptance tests pass. |
| T4 | Write tests for a module without tests. | Tests pass and catch at least 60% of planted mutations. |
| T5 | Investigate a test that fails for a non-obvious cause. | Correct root cause in the report and validated fix. |
| T6 | Plan a complex change before implementing, then implement. | The plan covers the answer-key points and the implementation passes the tests. |
| T7 | Review its own diff, which contains a planted regression. | Finds and fixes the regression. |

- **Metrics per run:** success, human interventions, total time, input and output tokens, prefill and generation speed, tool-call errors, loops, peak RAM and VRAM.
- **End-to-end pilot: a real, private project,** outside this repository. The details are in `PILOTO.local.md`, which is not versioned. It is the first real test of whether the architecture delivers software from start to finish:
  - gather requirements and specification;
  - break into tasks;
  - implement and test;
  - deliver e2e.

  Pilot rules:
  - **The original is never changed.** The work happens on a copy or in a git worktree, inside the agent's container.
  - **Only the project's code is mounted in the container.** Personal and contractual documents that sit next to it are not accessible to the agents.
  - **Nothing from the pilot enters this repository:** neither code nor raw results. Only aggregate metrics.
- **Reference with Claude, guided and conditional.** It is the same activity as the pilot, run with Claude Code and the Claude models of the author's account.
  - It runs only if needed: if the local result is rated satisfactory, it does not run.
  - Before running, the orchestrator reports what will be executed, when, on which copy and the estimated consumption, and waits for approval.
  - It never sends personal or contractual documents.
- **Proposed target to consider the environment ready (adjustable):**
  - at least 5 of the 7 tasks solved without intervention, in 2 of 3 runs;
  - no destructive action;
  - median of at most 1 intervention on the remaining tasks.

---

## 10. Uncertainties and how they will be resolved

| Uncertainty | Why it matters | Test · stage |
|---|---|---|
| Real RAM→GPU copy speed in WSL, which limits pinned memory | May halve prefill. | `llama-bench` sweep with and without `--no-mmap` · E4 |
| PCIe Gen4 stability under load | Link errors cause slowdowns or hangs. | Replay counter before and after the benchmarks · E4 |
| WSL versus native llama-server on Windows | Sources disagree on which is faster in hybrid mode. | Same GGUF on both sides, if WSL disappoints · E4 |
| Windows apps going back to using the NVIDIA GPU | They reoccupy VRAM and the driver may silently spill memory to RAM. | Monitor VRAM during the tests · E4–E5 |
| Gain from the GPU expert cache | Promises up to 2.2× in generation. | `--moe-cache-mib` from 0 to 2048 · E4 |
| Cache hit rate between turns with each agent | Each miss costs from 2 s to 45 s. | `-lv 4` log during E6 |
| Qwen3.6 tool-call bug in OpenCode | May eliminate OpenCode. | Reproduce with the current build and the reported fixes · E6 |
| Q4 versus Q6: stability in tool calls | Reports indicate Q6 is more stable and ~30% slower. | Same tasks on both quantizations · E8 |
| Coder-Next 80B versus Qwen3.6-35B | Never compared in the same benchmark period. | Same tasks, with adjustment C · E8 (optional) |

---

## 11. Decisions

### Made on 2026-10-29

1. **Architecture and the E1–E9 plan approved.** Execution is stage by stage.
   - The core downloads (~26 GB: llama.cpp, Qwen3.5-4B, Qwen3.6-35B) are approved.
   - The optional E8 ones (up to ~85 GB) will be confirmed one by one.
   - I will use the default Qwen3.6 variant, without MTP. In hybrid mode, speculative decoding reads more experts from RAM per step and yielded only ~2% in a published test.
   - The server port is 9931, because 8080 is already used by another local service.
2. **WSL with 52 GB of RAM** (adjustment C), to allow the full test. While AI is being processed, the machine is dedicated to it.
3. **Orchestration only during the build.**
   - Claude Code (this session) is the orchestrator.
   - Specialized parallel agents do only the independent work: validation suite, container, agent configurations, documentation.
   - At the end of each stage, a fresh verifier checks the deliverable. It receives only the stage criteria and where to look, not the orchestrator's conclusions, and records the result in `.md`.
   - Benchmarks and agent tests run serially: there is one GPU and one model, and parallel measurements would be invalid.
   - The final local environment starts with a single agent and sequential review (one executes, another verifies).
4. **Cascade of goals, with an objective criterion.**

   | Level | Agent | Model | Recurring cost | Passes if |
   |---|---|---|---|---|
   | Goal 1 (zero cost) | Single contest in E6 among Qwen Code, Codex CLI, Pi and OpenCode (open source) and Claude Code (closed, free), all with the local model | local | zero | ≥ 5 of 7 tasks without intervention in 2 of 3 runs, no destructive action, and the pilot approved by the author and the orchestrator |
   | Goal 2 | Merged into Goal 1 on Oct 29: local Claude Code competes alongside the open-source ones | — | — | — |
   | Goal 3 | any | local for the most part, cloud for planning and review. Options: Codex with the ChatGPT Go plan (low cost) or Claude | author's subscription | The share of tasks solved locally, to be defined. It goes against the original constraint and is only valid as your explicit decision. |

   If the limit is the model (correct tool calls but wrong solutions), switching agents does not solve it. The next step, in that case, is a larger local model (Coder-Next 80B or Qwen3.8-27B as reviewer) and, after that, Goal 3.
5. **The validation pilot is a real, private project**, outside this repository (see section 9).
6. **Codex added to the plan (Oct 29)**, in two forms that are not mixed:
   - **Codex CLI with the local model:** enters Goal 1 and the E6 test (`agents/codex-local/`).
     - It is open source (Apache-2.0), uses no account or plan, and llama-server has the `/v1/responses` endpoint it requires.
     - Risks to measure: it is tuned for OpenAI models, uses the `apply_patch` edit format and goes through llama.cpp's Responses path, the least tested one.
     - Isolated configuration in its own `CODEX_HOME`; the author's `~/.codex` is not touched.
   - **Codex with OpenAI models through the ChatGPT Go plan:** it is cloud, so it stays as a yardstick in validation and as a Goal 3 option.
     - Before each use, the orchestrator reports what will run and the estimated consumption, and waits for approval.
     - The Go plan limits still need to be confirmed.
     - In the pilot, check contractual confidentiality before sending code to the cloud. Personal documents are never sent.
7. **Agent selection rule (Oct 29).** The main criterion is zero cost, not open source, so the former Goals 1 and 2 became a single contest.
   - **The best measured result wins** in E6 and E8.
   - **In a technical tie, open source wins.** A technical tie is a difference of up to 1 task in 7, within the run-to-run variation.
   - **Local Claude Code risks that weigh in the tiebreak:** it has no official support for non-Claude models (an update may break local use), the fixed prompt is ~25–31k tokens (more expensive on each cache loss) and background calls may discard the cache.
   - **In its favor:** the author already masters the workflow (skills, hooks, subagents, plugins).
   - **Order in E6:** local Claude Code and local Codex run first, to give an early signal with the already-known tools.

8. **Usage condition (Oct 29): GPU dedicated to AI while it is in use.** No games, and NVIDIA Broadcast closed. The server profile uses all the VRAM, keeping only a small margin for driver variations.
   - In a deliberate test, the author opened a game during E4: the server kept working. The measured degradation is recorded in the E4 results.
   - E5 includes a pre-start check that warns when another process is using the GPU.

9. **Superpowers-style workflow and variable pilots (Oct 29).** The author wants to start from a prompt (a narrative of pain points and value deliverables, or an existing project) and arrive at specs, a task plan, contracts and services, as is done today with Claude Code + Superpowers: brainstorm, parallel agents and reviewers.
   - **Skills as mountable profiles**, with no fixed list (see `skills/README.md`). The base is Superpowers v6.4.1 (MIT), pinned in `versions.env`, with 13 skills in `skills/profiles/base.txt`, including `finishing-a-development-branch`. The project's own and personal skills are added on top. Superpowers ships official adaptations for Codex and Pi. **Update (Nov 2):** extra `frontend` profile with `frontend-design` and `webapp-testing` from Anthropic (`anthropics/skills` pinned by commit) and Playwright + Chromium in the agent-box image; `mattpocock/skills` evaluated and not adopted (overlap with Superpowers, and parallel subagents against a single-slot server).
   - **Two ways into the pilot:** an existing project or a new project built from the narrative. The new project may take priority.
   - **E6** measures skills per agent: on-demand loading, automatic triggering and explicit invocation.
   - **E8** measures:
     - the multi-agent flow (`subagent-driven-development`) with 1 and with 2 server slots: time, quality and cache reuse;
     - a reviewer with a clean context;
     - planning (brainstorm, specs, tasks) with a score separate from execution.
   - **Recorded expectation:**
     - "Parallel" agents on a single local model gain clean context, not speed. Long plans turn into multi-hour unsupervised runs.
     - Open-ended planning is the local model's weakest point. If the measurement confirms it, the likely split is to plan in the cloud (Goal 3, for example Codex with the Go plan) and execute locally.

### Pending

- Confirm each download above 5 GB when the corresponding stage arrives.
- At pilot time: authorize, or not, the reference run with Claude.

---

## 12. History

| Date | Event |
|---|---|
| 2026-10-27 | Hardware audit and research (models, runtimes, agents). Download of the `ubuntu:24.04` image (119 MB) to test the GPU in Docker. |
| 2026-10-29 | You moved both monitors to the iGPU and set PCIe to Gen4 in the BIOS. Verified: 0 MiB of VRAM in use, 7.9 GB free, host at Gen4 ×8, replays at 0. |
| 2026-10-29 | Decisions in section 11. `.wslconfig` changed from 40 to 52 GB (backup `.wslconfig.bak-20261029`). Pilot defined (private project). Repository prepared to be published in the future, with no references to private projects. |

---

## Main sources

- **Hugging Face:** model cards and GGUF repositories queried through the API on 2026-10-27: `Qwen/Qwen3.6-35B-A3B`, `Qwen/Qwen3.8-27B`, `Qwen/Qwen3-Coder-Next`, `Qwen/Qwen3.5-4B` and the `unsloth/*-GGUF`.
- **Benchmarks:**
  - SWE-rebench: <https://swe-rebench.com> (window from May 15 to Jul 1, 2026).
  - Artificial Analysis: <https://artificialanalysis.ai> (small-model comparisons, Jun–Oct 2026).
- **llama.cpp:**
  - Releases v0.7.0 and b11935: <https://github.com/ggml-org/llama.cpp/releases>
  - PRs #29887 (expert cache) and #26252 (Qwen3 parser).
  - Blog post on the Anthropic API: <https://huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp> (2026-01-19).
- **Other runtimes:**
  - ik_llama.cpp: issue #1762.
  - Ollama: <https://docs.ollama.com/api/anthropic-compatibility> and issues #11772 and #14579.
  - vLLM: PR #37190.
  - KTransformers: project README.
- **Claude Code:** <https://code.claude.com/docs/en/llm-gateway> and model-config (2026-10-27).
- **Agents:**
  - OpenCode: <https://opencode.ai/docs> and issue #24316 at <https://github.com/anomalyco/opencode> (closed on 2026-10-11 as "not planned").
  - Pi: <https://github.com/earendil-works/pi>
  - Qwen Code: <https://github.com/QwenLM/qwen-code>
- **Agent tests:**
  - harness-bench: <https://neuralnoise.com/2026/harness-bench-wip> (2026-04-28).
  - Preamble measurements: mykolaaleksandrov.dev (2026-06-21) and heyuan110.com (2026-09-06).
- **Practical reports:**
  - insiderllm.com, Qwen3.6 guide (updated 2026-10-16).
  - NVIDIA forum, topic 367721.
  - Qwen3.6 discussions #31 and #51 on Hugging Face.
