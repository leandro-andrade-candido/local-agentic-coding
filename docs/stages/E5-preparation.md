> Translated from the Portuguese original (commit 30666ad).

# E5: preparing the llama-server service

Prepared on Oct 29, 2026, while E4 and its verification were using port 9931 and the GPU. Nothing was installed or started: only the key was created, and the `--dry-run` and the preflight were run. Requirements met: [`E5-requirements.md`](E5-requirements.md), plus the E7 request to keep the dangerous routes disabled.

## Division of responsibilities

| File | Owner | Content |
|---|---|---|
| `runtime/llama-server.args` | E4 | performance: context, offload, batches, threads, cache, `--metrics` and the `--temp/--top-p/--top-k` sampling |
| `runtime/llama-server.env` | E4 | `GGML_OP_OFFLOAD_MIN_BATCH=1024` |
| `runtime/llama-server.policy.args` | E5 | security and defaults: host, port, key, CORS, `--no-agent`, `--offline`, `--min-p 0`, `--presence-penalty 0`, `-n 32768` |
| `runtime/llama-server-args.py` | E5 | builds the final line and applies the rules below |
| `runtime/llama-server-start.sh` | E5 | wrapper: environment, checks, preflight and `exec` |
| `runtime/llama-server.service.in` | E5 | template of the `systemd --user` unit |
| `runtime/common.sh` | E5 | common paths and functions (versions.env, models.tsv, unit PID) |
| `scripts/llm` | E5 | single command: key, install, start/stop, health, test |
| `scripts/preflight.sh` | E5 | preflight (read-only, ~0.2 s) |

`scripts/tool_calls.py` gained `--api-key-file` (and uses `$LLM_API_KEY` if no key is passed), so the key does not appear on the command line (`ps`). `--api-key` is still accepted.

## How the command line is built

`-m <model>` + profile (E4) + policy (E5), in this order.

- **Model:** the name in the API is always the profile's `-a` (`qwen3.6-35b`). The `models.tsv` entry to load comes from `LLM_SERVER_MODEL` (only for a manual start), otherwise from the choice saved by `scripts/llm model <alias>` in `~/.config/local-agentic/model` (which also applies to the service), otherwise from the `-a` itself. This way, switching Q4 for Q6 changes nothing for the agents (added on Nov 3). The file and size come from `models.tsv`, and the folder from `MODELS_DIR` in `versions.env`. If the file is missing or the size does not match, the wrapper refuses to start. The SHA-256 is not recomputed (22 GB); `scripts/fetch-model.sh` is what checks the hash.
- **Binary:** `$LLAMA_CPP_PREFIX/$LLAMA_CPP_BUILD/llama-server`, with the `.complete` marker. It uses the build from `versions.env`, not the `current` link.
- **Overlap:** in b11982 the last occurrence of each flag wins (`common/arg.cpp`), and each repetition produces the warning `DEPRECATED: argument specified multiple times`. The builder groups the aliases using the binary's own help (`-n` = `--predict` = `--n-predict`; `_` becomes `-`, as in llama.cpp). When a flag is in both files, **the policy wins**: the profile's one is removed from the line and, if the value differs, a note is left in the log. With the current files there is no flag in both. The policy brings only what the profile lacks.
- **Refusals** (code 2, the service does not come up):
  - a flag unknown to the build, or repeated in the same file;
  - a forbidden flag, in the profile or in the policy (below);
  - a security flag in the profile (host, port, key, CORS, `--no-agent`, `--offline`, `--ui`, SSL);
  - `--host` outside loopback;
  - `--cors-origins *` or a list of origins;
  - a key that is missing, readable by other users, stored inside the repository, or with whitespace at the ends;
  - a final line without `--metrics`, `--temp`, `--top-p`, `--top-k`, `--min-p`, `--presence-penalty` or `-n`: these may come from the profile or the policy, but cannot be missing.
- **Environment:** the wrapper removes `LLAMA_*`, `GGML_*`, `HF_TOKEN` and `MTMD_BACKEND_DEVICE` from the environment, because llama-server reads `LLAMA_ARG_*` as flags and the policy cannot be bypassed from outside. It then loads `runtime/llama-server.env`, refusing any `LLAMA_*` in it. `${...}` values in the files only accept `LLAMA_SERVER_HOST`, `LLAMA_SERVER_PORT` and `LLM_API_KEY_FILE`.

### Final line (`scripts/llm dry-run`, Oct 29, final E4 profile)

```
GGML_OP_OFFLOAD_MIN_BATCH=1024 ~/.local/opt/llama.cpp/b11982/llama-server \
  -m ~/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf -a qwen3.6-35b -np 1 -c 131072 \
  -fa on -ctk q8_0 -ctv q8_0 -ngl 99 -ncmoe 38 --fit on --fit-target 384 -b 4096 -ub 4096 \
  -t 8 -tb 12 -lm dio --jinja --reasoning-preserve -ctxcp 48 -cms 2048 --cache-ram 12288 \
  --metrics --temp 0.6 --top-p 0.95 --top-k 20 \
  --host 127.0.0.1 --port 9931 --api-key-file ~/.config/local-agentic/llm-api-key \
  --cors-origins http://127.0.0.1:9931 --no-cors-credentials --no-agent --offline \
  --min-p 0 --presence-penalty 0 -n 32768
```

## Security (checked in the b11982 code, commit `8a199ad`)

- **Key.** `--api-key-file` reads one key per line (lines with `#` are comments). The server accepts `Authorization: Bearer <key>` (OpenAI) or `x-api-key` (Anthropic) and compares byte by byte. Only `/health`, `/v1/health` and the web interface files are public. **`/metrics`, `/props`, `/slots` and `/v1/models` require the key** (`server-http.cpp`).
- **Key file.** `~/.config/local-agentic/llm-api-key`, mode 0600, folder 0700, one line (`sk-llama-` + 64 hex). It is created by `scripts/llm key`, which never prints the key. The wrapper and the unit only know the path; the command line shows `--api-key-file <path>`.
- **CORS.** `--cors-origins` goes literally into `Access-Control-Allow-Origin`: the "comma-separated list" in the help is not handled. For this reason the policy uses a single origin, the server's own. The special value `localhost` would accept any localhost port. With `--no-cors-credentials`, the preflight answers `Allow-Credentials: false`. The main barrier is the key: a browser cannot put `Authorization` on a simple request.
- **Disabled routes** (E7 request: the container's forwarder exposes all routes to the agents). All are already disabled in b11982. The policy adds `--no-agent`, which in the code empties `--tools` and turns off the CORS proxy. The builder refuses:

  | Flag | Route or effect |
  |---|---|
  | `--props` | `POST /props` answers 501 without it |
  | `--slot-save-path` | `POST /slots/<id>?action=save\|restore` answers 501 without it |
  | `-ag/--agent`, `--tools`, `--tools-runtime`, `--mcp-servers-*` | built-in tools (`exec_shell_command`, `write_file`…) and MCP; `/tools` answers 403 |
  | `--ui-mcp-proxy` | `/cors-proxy` answers 403 |
  | `--media-path`, `--path` | reading local files and a static file server |
  | `--connect` | peer-to-peer tunnel out of the machine |
  | `--log-prompts-dir` | prompts written to disk |
  | `--api-key` | key visible in `ps` and in git |
  | `-hf`, `-mu`, `-dr`, `--models-dir`, `--models-preset`, `--fim-*` presets, etc. | downloads and router mode |
  | `--cors-credentials`, `--reuse-port` | credentials in CORS; another process on the same port |

  `GET /slots` (monitoring, no writes) stays enabled.
- **`-n 32768`** is only the default. In b11982, the request's `max_tokens` wins and is not capped by `-n` (`server-context.cpp`, "the per-request limit takes priority").
- **Web interface** stays enabled at `http://127.0.0.1:9931`: it loads without a key and asks for the key to chat. To turn it off, `--no-ui` in the policy.

## Preflight (`scripts/preflight.sh`)

Read-only, never kills anything, ~0.2 s. It runs on `scripts/llm start` and `restart`, in the terminal, and again inside the unit, before the `exec`. Code 0 = may start, with or without warnings; code 2 = blocker.

| Item | Blocks | Warns |
|---|---|---|
| Build binary and `.complete` marker | missing | — |
| Model | missing or with a size different from `models.tsv` | — |
| Arguments (builder in `check` mode) | refused (includes missing key and forbidden flag) | — |
| Port 9931 | in use by another process | — |
| Another llama.cpp instance (`llama-server`, `llama-bench`…) | — | always |
| Processes on the GPU | — | from Windows (games, NVIDIA Broadcast) or from WSL outside the service |
| Free VRAM, with the service stopped | — | < 7,500 MiB (with nothing on the GPU: 7,910) |
| Temperature and thermal throttling | — | ≥ 80 °C, or any active `Slowdown` |
| PCIe (`nvidia-smi -q`) | — | maximum below Gen4, replays > 0, counter rollovers > 0 |
| WSL RAM, with the service stopped | — | `MemAvailable` < model + 2 GiB (loading may fail) or < model + `--cache-ram` + 4 GiB |
| Swap | — | > 1 GiB in use |

Limits can be changed with `PREFLIGHT_MIN_FREE_VRAM_MIB`, `PREFLIGHT_MAX_TEMP_C` and `PREFLIGHT_MAX_SWAP_USED_MIB`. `LLM_PREFLIGHT=off` in the unit's environment skips the preflight (`systemctl --user edit llama-server`).

**How the GPU is read.** The Windows `nvidia-smi.exe` shows the Windows processes. CUDA work from WSL appears there as **PID 4 (System), type C, unnamed**, observed on Oct 29 with the E4 llama-server up; with an idle GPU, the list is empty. The WSL `nvidia-smi` (`/usr/lib/wsl/lib`) shows the Linux processes with PID and name. The preflight cross-references the two: PID 4 is attributed to WSL when there is a WSL process on the GPU, and the unit's main PID is recognized as the service itself.

With an idle GPU (Oct 29): 0 blockers, 0 warnings, free VRAM 7,910 MiB, PCIe Gen4 without replays, available RAM 49,586 MiB. With the E4 verifier's server up, the port gave a blocker and there were 3 warnings (another instance, free VRAM 4,791 MiB, RAM below recommended), and no Windows process was flagged.

## `systemd --user` unit

| Item | Value | Why |
|---|---|---|
| `Type` | `exec` | the wrapper does `exec`, and llama-server becomes the `MainPID`: stopping is a signal to the PID (solves the E3 `pkill` problem) |
| `ExecStartPost` | `scripts/llm wait-ready --timeout 600` | the start only finishes with `GET /health` = 200 (model loaded); gives up if the process dies |
| `TimeoutStartSec` | 11 min | ~30 s load in E4 with `-lm dio`; mmap took ~2.5 min |
| `Restart` | `on-failure`, 10 s growing up to 5 min in 5 steps | signal, exit ≠ 0, wait failure |
| `RestartPreventExitStatus` | 2 | wrapper refusal (configuration, preflight): restarting does not help |
| `StartLimitBurst` / `IntervalSec` | 5 in 30 min | avoids a loop; `scripts/llm start` does `reset-failed` |
| `KillMode` / `KillSignal` | `mixed` / `SIGTERM` | SIGTERM only to llama-server (clean shutdown); SIGKILL to the group after 90 s |
| Logs | journald, `SyslogIdentifier=llama-server` | `scripts/llm logs [-f]` |
| Hardening | `NoNewPrivileges`, `UMask=0077` | `ProtectSystem`/`PrivateTmp` require namespaces and were not tested with the WSL `/dev/dxg` |
| `[Install]` | `WantedBy=default.target` | only with `scripts/llm install --enable` |

`versions.env` and the argument files are read at every start: if the profile changed, `scripts/llm restart` is enough. `scripts/llm install` again is only needed if the repository moves or the unit template changes. `LimitMEMLOCK` was not touched: E4 loads with `-lm dio` in a shell with `ulimit -l` of 64 MiB, and the user manager's default is larger (6.8 GB). `systemd-analyze --user verify` on the generated unit: no errors.

## Commands

```bash
scripts/llm key                  # creates the key if it does not exist; prints the path
scripts/llm install --dry-run    # shows the unit and runs systemd-analyze verify
scripts/llm install [--enable]   # writes ~/.config/systemd/user/llama-server.service + daemon-reload
scripts/llm start | stop | restart | status
scripts/llm logs [-f] [-n N]
scripts/llm health               # availability, latency and policy on the server
scripts/llm test [--reps N]      # tool_calls.py; JSON in logs/tool_calls-<date>.json
scripts/llm preflight
scripts/llm dry-run              # final command line, without starting
eval "$(scripts/llm env)"        # LLM_BASE_URL, LLM_MODEL, LLM_API_KEY and LOCAL_LLM_API_KEY
```

`scripts/llm env` prints `export LLM_API_KEY="$(cat <path>)"`: the key is only read at the `eval`, and the command's output does not contain it.

`scripts/llm health` checks:

- `/health` without a key;
- `/v1/models` and `/metrics` with the key;
- a 1-token chat, with the latency;
- 401 without the key;
- `/props` matches the final line (sampling, `max_tokens`, `n_ctx`, `total_slots`, `endpoint_props=false`, `cors_proxy_enabled=false`, `endpoint_metrics=true`);
- `POST /props` answers 501;
- `POST /slots/0?action=<invalid>` answers 501: without `--slot-save-path` the answer comes before the action is looked at; with it enabled, it would be 400, and nothing is written in either case;
- `/tools` and `/cors-proxy` answer 403;
- CORS for another origin is denied;
- the server listens only on loopback;
- the current run's log has no `failed to fit params`.

The 1-token chat occupies the single slot: run it with the agents stopped.

## Installation (when the port and the GPU are free)

```bash
scripts/llm install --dry-run && scripts/llm install
scripts/llm start          # preflight + waits for the model to load
scripts/llm health
scripts/llm test           # first real run of tool_calls.py against Qwen3.6-35B
```

## How to undo

```bash
scripts/llm uninstall
# the same, by hand:
scripts/llm stop; systemctl --user disable llama-server.service
rm ~/.config/systemd/user/llama-server.service; systemctl --user daemon-reload
# optional: rm ~/.config/local-agentic/llm-api-key
```

To change the key: delete the file, run `scripts/llm key` and `scripts/llm restart`, and redo `eval "$(scripts/llm env)"` in the agents' terminals.

## Pending changes in `agents/` and `eval/` (not applied here)

Without them, the agents send the dummy key (401) and the `/metrics` snapshots vanish without an error, because `/metrics` now requires the key.

1. `agents/lib/common.sh`, in place of the line `LOCAL_LLM_API_KEY="${LOCAL_LLM_API_KEY:-sk-local-no-key}"` and the comment above it:
   ```bash
   # llama-server key (E5): LLM_API_KEY (in the container it comes from the environment), otherwise
   # the file from scripts/llm key. Never a cloud key: it would be sent to the local server.
   LLM_API_KEY_FILE="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}"
   if [ -z "${LLM_API_KEY:-}" ] && [ -r "$LLM_API_KEY_FILE" ]; then
     LLM_API_KEY="$(cat "$LLM_API_KEY_FILE")"
   fi
   LOCAL_LLM_API_KEY="${LLM_API_KEY:-${LOCAL_LLM_API_KEY:-sk-local-no-key}}"
   ```
   The five agents already read `LOCAL_LLM_API_KEY`: Qwen Code through `envKey`, Codex through `env_key`, Pi through `apiKey`, OpenCode through `{env:...}` and Claude Code through `ANTHROPIC_AUTH_TOKEN`, which goes as Bearer.
2. `agents/lib/common.sh`, `metrics_snapshot`, with the key through standard input, out of `ps`:
   ```bash
   printf 'Authorization: Bearer %s\n' "$LOCAL_LLM_API_KEY" \
     | curl -fsS --max-time 5 -H @- "$LLM_BASE_URL/metrics" -o "$1" 2>/dev/null || rm -f "$1"
   ```
3. `eval/lib/metrics.py`, `snapshot()`: build a `urllib.request.Request(metrics_url(base))` with `Authorization: Bearer` + `os.environ.get("LLM_API_KEY") or os.environ.get("LOCAL_LLM_API_KEY")` and pass it to `urlopen`.
4. `eval/run.sh`, after `export LLM_MODEL=...` (line 41): the same block as item 1, ending in `export LLM_API_KEY`. `sandbox/run-in-box.sh` already forwards `LLM_*` to the container.
5. Texts that say "dummy key, the server does not check it": `agents/claude-local/env.sh` and `README.md`, `agents/qwen-code/README.md` and `agents/pi/README.md`.

## What to verify with the server up

1. A real `scripts/llm install` and `scripts/llm start`: time until ready and `wait-ready` seeing `$MAINPID` inside `ExecStartPost`.
2. `scripts/llm health` all `ok`, in particular `/props` with the defaults from the final line and the log without `failed to fit params`.
3. `scripts/llm test`: first real run, with no `RUNTIME`/`TRUNCADO` (now printed as TRUNCATED), with the JSON in `logs/`.
4. Automatic restart: `kill -9` on the `MainPID` → back in ~10 s (`systemctl --user show -p NRestarts llama-server`).
5. Clean stop: `scripts/llm stop` in under 90 s, no SIGKILL in the journal, free VRAM back to ~7,910 MiB (`scripts/llm preflight`).
6. Preflight inside the unit: `nvidia-smi.exe` (WSL interop) answers from systemd. In the journal, the warning that the Windows `nvidia-smi.exe` did not respond must not appear.
7. Service lifetime: with `Linger=no`, check whether it stops when the last WSL terminal closes or on WSL's idle shutdown. Do not turn lingering on without deciding, per the dedicated-GPU rule.
8. `ps -o args -p <MainPID>` shows only the key path; `--offline` does not cause an error at startup.
9. Checkpoint reuse in the log in a multi-turn agent session (E5 verification in the plan). It may require `-lv 4`, currently commented out in the profile.
10. From the Windows browser: the interface at `http://127.0.0.1:9931` loads and asks for the key; a `fetch` from another origin is blocked.
11. With items 1–4 of the previous section applied: `metrics-before.prom`/`metrics.before.prom` non-empty in an eval run, and agents without 401.
12. From inside the E7 container, through the forwarder: `POST /props` and `POST /slots/0?action=save` refused, `/tools` and `/cors-proxy` with 403.
