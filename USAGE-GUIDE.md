> 🇧🇷 Versão em português: [USAGE-GUIDE.pt-BR.md](USAGE-GUIDE.pt-BR.md)

# Manual usage guide

How to start, use and test the environment on your own. Commands run from the repository root. State as of 2026-11-03: see the stage table in the [README](README.md).

## 1. Starting and stopping the model

```bash
scripts/llm preflight   # checks the GPU (other processes, VRAM, temperature), RAM and the port
scripts/llm start       # starts the service (~35 s); it does not start on its own at boot
scripts/llm health      # 13 checks; all must say "ok"
scripts/llm status      # service state
scripts/llm logs -f     # live log
scripts/llm stop        # frees the GPU and RAM (~22 GB with Q4, ~29 GB with Q6)
```

- **Before using:** close games and NVIDIA Broadcast. The preflight warns when another process is on the GPU.
- **Long runs:** keep a WSL terminal open, because the service may stop when the last terminal closes.
- **For the agents:** `eval "$(scripts/llm env)"` exports `LLM_BASE_URL` and `LLM_API_KEY`. The key lives in `~/.config/local-agentic/llm-api-key`; do not put it in project files.

**Measured performance** (E4, verified, Q4 version): reading a 20k-token prompt from scratch takes ~16 s, and a following turn, ~1 s. Generation runs at 33–37 tok/s with short context and drops to ~21 tok/s with 120k tokens.

## 1.1 Switching the model version (Q4 or Q6)

```bash
scripts/llm model                    # lists the models in models.tsv: installed? in use (*)?
scripts/llm model qwen3.6-35b-q6     # selects Q6 (29.3 GB); takes effect on the next start/restart
scripts/llm restart && scripts/llm health
scripts/llm model --reset            # back to the default (Q4, qwen3.6-35b)
```

- **What changes:** only the loaded file. The name in the API stays `qwen3.6-35b`, so no agent needs reconfiguring. The same profile (`runtime/llama-server.args`) applies to both versions, because it is the same model. Use this switch only between Qwen3.6-35B variants. Another model would require another profile.
- **Where the choice lives:** `~/.config/local-agentic/model`, outside git. The service also reads this file. `LLM_SERVER_MODEL=<alias>` takes precedence, but only for a manual start.
- **Q6 compared to Q4:** in theory slightly better, with reports of more stable tool calls. Estimate, not measured: generation 10–25% slower (~24–28 tok/s with 20k tokens) and prompt reading ~900–1,100 tok/s. Uses ~7 GB more pinned RAM.
- **RAM:** model (~28 GiB) + `--cache-ram` (12 GiB) + ~4 GiB sit close to WSL's ~50 GB limit, and the preflight may warn. If there is swap, reduce `--cache-ram` to `8192` in the profile and adjust the expected value (`scripts/llm health` compares it with the server).
- **To measure as in E4 (server stopped):** `scripts/llm stop`, then `MODEL=~/models/Qwen3.6-35B-A3B-UD-Q6_K.gguf bench/04-final.sh agent Q6-agent` and the same with `tg Q6-tg`; compare with `bench/RESULTS-E4.md`. For quality, run the same task (for example S1–S3) with the same agent on both versions.

## 2. Using an agent on a project (interactive, isolated)

```bash
sandbox/agent-shell.sh codex-local  ~/path/to/project
sandbox/agent-shell.sh claude-local ~/path/to/project
sandbox/agent-shell.sh qwen-code    ~/path/to/project   # also: pi, opencode
sandbox/agent-shell.sh shell        ~/path/to/project   # bash in the same container
```

- **What the container sees:** only the project folder, mounted writable; no internet, none of your credentials and no push. The network reaches only the model server.
- **Superpowers skills:** already mounted. Call one by name, for example by asking it to use the `brainstorming` skill. For your own skills, use `--skills-dir <folder>` before the agent name.
- **Project with a UI (Anthropic's `frontend-design` and `webapp-testing` skills):** run `scripts/fetch-skills.sh frontend` once, then `sandbox/agent-shell.sh --skills-dir ~/.local/opt/skills/profiles/frontend claude-local ~/project`. Ask for them by name ("use the frontend-design skill to…"; "validate the delivery with the webapp-testing skill: start the app, walk through the flow, take screenshots on desktop and mobile and check for console errors") or mention them in `AGENTS.md`. `webapp-testing` uses the image's Playwright and Chromium, works without a network and judges the screen by the DOM and the console; the screenshots are left for you to check. Without `--net`, external fonts and packages do not download; the agent has to use what is in the project.
- **External network (internet, DNS, APIs):** off by default. To enable it for a session, put `--net` before the agent name, for example `sandbox/agent-shell.sh --net codex-local ~/project`. The local model stays reachable. With a network, the agent can download packages and reach APIs, but it can also send out whatever is mounted: use it only on projects without sensitive data and watch the session. In the validation suite and in autonomous mode, keep it off.
- **First use:** if the image does not exist, run `sandbox/build.sh` (~4 GB).
- **Push:** do it yourself, outside the container, after reviewing the diff.

## 2.1 Starting a new project with brainstorming

```bash
mkdir -p ~/new-project && cd ~/new-project && git init -q
cat > AGENTS.md <<'EOT'
# How to work on this project
- Flow: brainstorming → writing-plans → executing-plans (or subagent-driven-development)
  → requesting-code-review → finishing-a-development-branch.
- Always write tests and run them before declaring a task done.
- Design documents and plans live in docs/.
EOT
cd /path/to/local-agentic-coding                    # the repository root
scripts/llm start                                   # if the server is not up
sandbox/agent-shell.sh codex-local ~/new-project    # or claude-local, qwen-code, pi, opencode
```

Inside the agent, ask for the brainstorm by name and describe the pain, not the solution:

> Use the brainstorming skill. I want to build a system for <problem>. Today the pain is <what happens>, for <whom>. A good outcome would be <expected result>.

The agent asks questions one at a time, proposes 2 or 3 approaches and writes a design document to `docs/`. After you approve it:
- `Use the writing-plans skill` generates the task plan.
- `Use the executing-plans skill` implements task by task, with tests.
- `Use the requesting-code-review skill` reviews the result.
- `Use the finishing-a-development-branch skill` closes the branch.

You do the push outside the container.

**Tips for the local model**
- **Call skills by name.** Automatic triggering is less reliable than with Claude.
- **Start new sessions at each phase.** A short context makes the model faster and more accurate; the design document and the plan in `docs/` carry the state from one phase to the next.
- **Open-ended planning is the local model's weakest point.** If the design comes out shallow, one option is to do the brainstorm with a stronger model and execute the plan locally.
- **Little tested:** a first manual use on Nov 2 worked, but without metrics, and the formal comparison (E6) has not been run yet.

## 3. Testing the environment

| What | Command | Expected |
|---|---|---|
| Container isolation | `sandbox/escape-tests.sh` | 150/150 |
| Model tool calling | `scripts/llm test` | `RUNTIME=0`; writes `logs/tool_calls-*.json`; takes 20–40 min |
| Validation suite, no model | `eval/validate.sh` | every task fails after setup and passes with the solution |
| One agent on one task | `EVAL_WRAPPER=sandbox/run-in-box.sh eval/run.sh codex-local S1 my-test` | `eval/runs/my-test/codex-local/S1/result.json` |
| Agent comparison (E6, R1) | `EVAL_WRAPPER=sandbox/run-in-box.sh eval/matrix.sh -r 1 e6-r1 claude-local,codex-local,qwen-code,pi,opencode S1,K1` | ~1–2 h; one run at a time |
| Summary | `python3 -I eval/summarize.py eval/runs/e6-r1` | table by agent and task |
| Grade for T1, T5, T6 | `python3 -I eval/grade.py <result.json> --score N --by NAME` | tasks graded by rubric |

The comparison protocol is in [docs/stages/E6-protocol.md](docs/stages/E6-protocol.md), with rounds R1–R3 and the elimination criteria. The pilot's is in [docs/pilot/PROTOCOL.md](docs/pilot/PROTOCOL.md).

## 4. Known problem: reasoning spiral

With the current configuration (temperature 0.6, no penalty), the model goes into a spiral on ~11% of requests (4 of 35 in the experiment). It reasons until the token limit and does not answer: it can take minutes, or more than 15 with the real limit.

| Configuration (35 calls each) | Spirals | Correct |
|---|---|---|
| Current | 4 | 30 |
| `presence_penalty` 1.5 | 0 | 35 |
| "General" sampling from the model card (temperature 1.0, presence 1.5) | 0 | 35 |
| Current + reasoning budget of 2,048 tokens per request | 0 | 34 |

The raw data is in `logs/e5-raciocinio/` (outside git; the folder name is kept as created). The decision is pending, because the effect on code still needs measuring: the presence penalty punishes repeating names, and code repeats names all the time. To test it yourself:
- **Through the server, for all agents:** add to `runtime/llama-server.policy.args` a line `--presence-penalty 1.5` (replacing the `0` one) or `--reasoning-budget 4096`, then `scripts/llm restart && scripts/llm health`. The health check expects the policy values, so adjust and check.
- **Per request:** send `presence_penalty` or `reasoning_budget_tokens` in the body of the API request.
- **To measure:** run S1–S3 with an agent before and after the change and compare.

## 5. What is verified and what is not

| Part | State |
|---|---|
| Hardware, llama.cpp, model, performance profile (E0–E4) | independently verified |
| Server as a service, key, CORS, disabled routes (E5) | health 13/13; full tool-calling battery and independent verification pending; 26 of 27 calls OK in the partial battery |
| Container (E7) | 150/150 escape tests; host hole fixed; adversarial re-verification of the fix pending |
| Configuration of the 5 agents, skills | static review done; first manual use on Nov 2 with no reported problems; no formal measurement |
| Validation suite | validated without a model (13/13) |
| Agent comparison (E6), full validation and pilots (E8) | not run |
| Q6 version of the model | downloaded and hash-checked on Nov 3; performance and quality not measured |

## 6. Updating

- **llama.cpp:** change `LLAMA_CPP_BUILD` and the hashes in `versions.env`, run `scripts/install-llama-cpp.sh`, then `scripts/llm restart`. To roll back, restore the previous value; the old build stays on disk.
- **Models:** add the line to `models.tsv` (with the HF revision and SHA-256), run `scripts/fetch-model.sh <alias>` and select it with `scripts/llm model <alias>` (section 1.1).
- **Agents:** update the versions in `agents/versions.env` and run `sandbox/build.sh`.
- **Skills:** update `SUPERPOWERS_*` or `ANTHROPIC_SKILLS_COMMIT` in `versions.env` and run `scripts/fetch-skills.sh base frontend`.
