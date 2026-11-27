# Vision: image input on the local server (2026-11-27)

Status: **done for Q4**, health 17/17. Not yet checked by an independent verifier. Use with real
images in the agents (Claude Code, Codex) and in Natively is still to be tested by the user.

## Why

Clients sent screenshots to the server (Natively on Windows, through the cURL provider), and
the server refused them with `500 image input is not supported - hint: ... provide the mmproj`.
With provider fallback on, Natively then sent the screenshot to another, cloud provider.
Claude Code (pasted images, `Read` on a PNG) and Codex (`input_image`) hit the same refusal.

## What changed

| File | Change |
|---|---|
| `models.tsv` | Two new columns: `local_file` (8, name on disk; `-` = same as `file`) and `mmproj` (9, alias of the model's projector; `-` = none). New row `qwen3.6-35b-mmproj`: `mmproj-F16.gguf` from the same pinned revision (`a483e9e`), 899,283,680 bytes, SHA-256 `8971ee4f…829e887f`, saved as `Qwen3.6-35B-A3B-mmproj-F16.gguf`. The Q4 and Q6 rows both point to it (same model) |
| `scripts/fetch-model.sh` | Uses `local_file` when present |
| `runtime/common.sh` | `llm_vision_choice` and `llm_resolve_mmproj`: switch (`LLM_SERVER_VISION`, then `~/.config/local-agentic/vision`, then **on**) and the projector of the selected model |
| `runtime/llama-server-start.sh` | With vision on and a projector in `models.tsv`: checks that the file exists and has the expected size, then passes `--mmproj`. `--dry-run` shows the vision state |
| `runtime/llama-server-args.py` | New `--mmproj` option, added by the wrapper only. `--mmproj`/`-mm` in the profile or the policy is refused, like `--model`. `--mmproj-url` was already refused (download) |
| `runtime/llama-server.args` | `-ncmoe 38` → `40`; new `--image-max-tokens 2048` |
| `scripts/llm` | `vision [on\|off]`; `model` hides projector rows and refuses one as a model; `health` gains 4 checks (below) |

Kept as they were: the security policy, `--offline`, the key, the loopback-only binding and
the agent configurations. The E7 forwarder copies bytes and has no body-size limit, so large
image requests go through it unchanged.

## Where the projector runs: GPU (option B, chosen by the user)

The E4 profile (`-ncmoe 38`) left ~470 MiB free in CUDA's view. The projector alone is 858 MiB,
plus the encoder's buffers. Moving the routed experts of the last 2 layers to RAM
(`-ncmoe 40`) frees ~1.3 GiB (E4: "1,348 MiB free, ~2% slower").

Measured on 2026-11-27 (Q4, context 131072, nvidia-smi view; CUDA sees about 900 MiB less free):

| State | VRAM used | Free (nvidia-smi) |
|---|---|---|
| E4 profile, no projector (`-ncmoe 38`) | 6,790 MiB | — |
| `-ncmoe 40` + projector, idle after load | 6,774 MiB | 1,137 MiB |
| Peak while encoding a 1920×1080 or 3840×2160 image | 6,976–6,992 MiB | ~920 MiB |

So the headroom at peak is ~200 MiB smaller than E4's. By the same offset as E4, that leaves
roughly 250–300 MiB free in CUDA's view. This is enough on a dedicated GPU (the E4 premise), but
less than the 300–500 MiB band that E4 picked. Another app on the NVIDIA GPU (games, NVIDIA
Broadcast) is now more likely to cause an out-of-memory error.

`-ncmoe 39` was not tried: freeing only one layer (~0.6 GiB) cannot hold the projector.

## Image token cap

`--image-max-tokens 2048` bounds both the encoder's VRAM (which grows with the image) and the
prefill. Measured with synthetic images:

| Image | Prompt tokens (image + ~20 text) | Prompt time | Total (40-token answer) |
|---|---|---|---|
| 1280×720 | 901 | 2.0 s | 2.9 s |
| 1920×1080 | 2,061 | 4.3–4.4 s | 5.4 s |
| 3840×2160 (scaled down by the cap) | 2,001 | 4.5 s | 8.7 s (includes PNG upload and resize) |

A 1080p screenshot fits under the cap at native resolution. Larger images are scaled down.

## Text performance after the change

Text generation: 36.5–37.3 tok/s (300 tokens, short context), the same as the 33–37 tok/s
range of E4. The prefill of long prompts was not re-measured; E4 estimated about 2% slower for
`-ncmoe 40`.

## Health checks added (`scripts/llm health`)

- `input_modalities` in `/v1/models` contains `image` if and only if vision is on;
- a 32×32 PNG (built in memory) is accepted on `/v1/chat/completions` (Natively, Qwen Code),
  `/v1/messages` (Claude Code) and `/v1/responses` (Codex). With vision off, the three must be
  refused. Only the HTTP status is checked: what the model says about the image is a quality
  question, not health.

Result on 2026-11-27: 17 ok, 0 failures, after a clean `stop` + `start`.

## Gotcha: false `--fit` warning after `restart`

The first `scripts/llm restart` with the new profile logged `failed to fit params ... abort`,
and health failed that check. A clean `stop` and then `start` did not log it. The likely cause is
VRAM from the previous process not yet released when the new one measured; this was not
confirmed. If the warning appears again after a restart, run `scripts/llm stop && scripts/llm start`
and run health again before suspecting the profile.

## Switching off

```bash
scripts/llm vision off && scripts/llm restart    # no projector; VRAM as above minus ~1 GiB
scripts/llm vision on  && scripts/llm restart    # default
```

With vision off the profile stays at `-ncmoe 40`, so generation keeps the ~2% cost. To return to
the E4 profile exactly, also set `-ncmoe 38` back in `runtime/llama-server.args`.

## Not done or not measured

- **Q6:** its dense weights on the GPU are larger than Q4's. Whether Q6 plus the projector fits
  the VRAM was not measured. Moving 2 layers of experts to RAM also brings Q6's RAM use (already
  close to the WSL limit) ~1 GiB closer.
- **Image quality** (reading code, UI or text in real screenshots): not measured. The probe images
  were synthetic patterns.
- **Agents:** Claude Code, Codex and Qwen Code with real images are to be tested by the user. For a
  model outside its catalog, Codex uses generic metadata. Whether that metadata allows image input
  was not verified; if Codex refuses to attach images, look there first.
- **Prefill of long prompts** and **long context** with `-ncmoe 40` were not re-measured.
- **Independent verification:** not done.
