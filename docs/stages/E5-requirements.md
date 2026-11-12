> Translated from the Portuguese original (commit 30666ad).

# E5: server requirements gathered before the stage

Requests that arrived from the other workstreams up to Oct 29, to go into the `llama-server` service together with the profile chosen in E4 (`runtime/llama-server.args`).

| Requirement | Source | Reason |
|---|---|---|
| `--api-key-file` with the key outside git; agents receive the key through `LLM_API_KEY` | E1–E3 verification | A server without a key is reachable from the Windows browser |
| Restricted `--cors-origins` and `--no-cors-credentials` | E1–E3 verification | The default CORS accepts any origin, with credentials |
| `--metrics` | validation suite and agent configuration | The only measure of tokens and speed that applies to all 5 agents |
| The card's sampling as the server default: `--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0` | agent configuration | Codex does not send sampling, and other agents may not either. The llama.cpp default is temperature 0.8 with `min_p` 0.05. |
| `-n 32768` as the default output limit | `codex-local` configuration | Codex does not send `max_output_tokens`, and long tool arguments cannot be cut off |
| `-np 1`, `-t` and `-tb` calibrated | E3 and E4 | The defaults are 4 slots and 8 threads; in E4, 6–8 threads were better for generation |
| `--reasoning-preserve` | plan | Redundant in b11982, which already turns `preserve_reasoning` on by default; it can be made explicit |
| First real run of `scripts/tool_calls.py` against Qwen3.6-35B, with JSON output | E1–E3 verification | It is the first tool-call test of the main model |
| `systemd --user` service with automatic restart and stop by PID | E3 | Avoids the `pkill` problem |
| Check before starting (preflight): warn if another process is using the GPU (a game, NVIDIA Broadcast, etc.), with free VRAM, temperature and available RAM, by querying the Windows `nvidia-smi.exe` | E4, the author's test with a game and Broadcast | Decided usage condition: the GPU is dedicated to AI while it is in use. The check makes it visible when that condition does not hold |
