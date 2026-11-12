# E6: agent comparison (protocol)

Picks the zero-cost agent that uses the local model. The contenders are local Claude Code, local Codex, Qwen Code, Pi and OpenCode. The decision rule is in the plan (section 11, item 7): the best measured result wins, and in a technical tie the open-source agent wins.

## Why elimination rounds

5 agents × 6 tests × 2 repetitions = 60 runs. At ~5–15 min each on the local model (estimated), that would be 5 to 15 hours. The rounds drop early the agents that do not even work, and keep the repetitions for the finalists.

| Round | Agents | Tests | Repetitions | Runs | Estimated time |
|---|---|---|---|---|---|
| R1. Does it work? | all 5; local Claude Code and local Codex first | S1 (short bug) and K1 (explicit skill call) | 1 | 10 | ~1–2 h |
| R2. Quality | those that passed R1 | S2, S3, K2 and K3 | 1 | up to 16 | ~2–3 h |
| R3. Variance | the best 2 or 3 | S1–S3 | +2 | up to 18 | ~2–4 h |

Before R1, `agents/measure-preamble.sh` measures the size of each agent's first request: it is the cost of every cache miss.

## Elimination criteria in R1

An agent is out if any of these happens:
- it does not start in the container, or the generated configuration is rejected;
- more than 2 tool-format errors (`RUNTIME`) in one run;
- a loop is detected (`loops_suspected` ≥ 1 with more than 5 repetitions) or the time limit is exceeded in S1;
- it does not load the skill in K1 when the skill is called by name.

## Measurements per run

Written by `eval/run.sh` to `result.json` and `agent-metrics.json`:
- **result:** success on the hidden tests;
- **wall-clock time;**
- **tokens:** prompt and generated, from `/metrics`;
- **cache:** reused (`cache_n`) versus reprocessed (`prompt_n`);
- **tools:** calls, errors and loops;
- **memory:** peak RAM and VRAM.

The warm-up before the metrics snapshot is already automatic.

## Run conditions

- **Isolation:** always in the container (`EVAL_WRAPPER=sandbox/run-in-box.sh`), one run at a time.
- **Dedicated GPU:** no games and no NVIDIA Broadcast. `scripts/llm preflight` runs before each round.
- **Long runs:** keep one WSL terminal open, because with lingering off the service may stop when the last terminal closes.
- **Identifiers:** `e6-r1`, `e6-r2`, `e6-r3`.

## Output

`docs/stages/E6.md`: a table per agent and round, with the size of the first request, the success rate, the times, the cache use and the errors; the eliminated agents and why; the decision; and the 1 or 2 agents that go on to E8. The independent verification of E6 redoes a sample of the runs.
