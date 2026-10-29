#!/usr/bin/env python3
"""Métricas Prometheus do llama-server (GET <base>/metrics; exige --metrics no servidor).

Uso:
    python3 -I metrics.py snapshot <base_url> <saida.prom>   # nunca falha; sem servidor, não grava o .prom
    python3 -I metrics.py delta <antes.prom> <depois.prom>    # imprime JSON com as diferenças

Chave (E5: o servidor exige a chave em todas as rotas, inclusive /metrics): enviada como
"Authorization: Bearer <chave>", lida de LLM_API_KEY ou LOCAL_LLM_API_KEY. Nunca é impressa.
Quando o snapshot falha, o motivo vai para <saida.prom>.err e aparece no result.json
(llm.available=false, llm.reason), em vez de sumir sem aviso.

Contadores usados (nomes do llama-server):
    llamacpp:prompt_tokens_total            tokens de prompt processados (prefill; não conta cache)
    llamacpp:prompt_seconds_total           tempo de prefill
    llamacpp:tokens_predicted_total         tokens gerados
    llamacpp:tokens_predicted_seconds_total tempo de geração
    llamacpp:n_decode_total                 chamadas de decode
Qualquer outro contador *_total também entra em "counters_delta".
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def metrics_url(base: str) -> str:
    base = base.rstrip("/")
    if base.endswith("/v1"):
        base = base[:-3]
    return base + "/metrics"


def api_key() -> str:
    return (os.environ.get("LLM_API_KEY") or os.environ.get("LOCAL_LLM_API_KEY") or "").strip()


def snapshot(base: str, out: str) -> int:
    err = out + ".err"
    for p in (out, err):
        if os.path.exists(p):
            os.remove(p)
    key = api_key()
    req = urllib.request.Request(metrics_url(base))
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    reason = None
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = resp.read().decode("utf-8", errors="replace")
        if "llamacpp:" not in body:
            reason = f"resposta sem métricas do llama-server (HTTP {resp.status}; servidor sem --metrics?)"
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            reason = (f"HTTP {e.code}: " + ("chave inválida" if key else
                      "sem chave (defina LLM_API_KEY ou crie ~/.config/local-agentic/llm-api-key)"))
        elif e.code == 404:
            reason = "HTTP 404: /metrics desligado (servidor sem --metrics)"
        else:
            reason = f"HTTP {e.code}"
    except (urllib.error.URLError, OSError, ValueError) as e:
        reason = f"servidor indisponível ({getattr(e, 'reason', e)})"
    if reason:
        print(f"[metrics] AVISO: sem métricas de {metrics_url(base)}: {reason}", file=sys.stderr)
        with open(err, "w") as f:
            f.write(reason + "\n")
        return 0
    with open(out, "w") as f:
        f.write(body)
    return 0


def _reason(path: str) -> str | None:
    try:
        with open(path + ".err") as f:
            return f.read().strip() or None
    except OSError:
        return None


def parse(path: str) -> dict[str, float]:
    vals: dict[str, float] = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                key, value = line.rsplit(None, 1)
                vals[key] = float(value)
            except ValueError:
                continue
    return vals


def delta(before: str, after: str) -> dict:
    if not (os.path.exists(before) and os.path.exists(after)):
        reasons = [r for r in (_reason(before), _reason(after)) if r]
        missing = [os.path.basename(p) for p in (before, after) if not os.path.exists(p)]
        return {"available": False,
                "reason": "; ".join(dict.fromkeys(reasons)) or f"snapshot ausente: {', '.join(missing)}"}
    b, a = parse(before), parse(after)
    counters = {k: a[k] - b.get(k, 0.0) for k in a if k.endswith("_total")}
    reset = any(v < 0 for v in counters.values())

    def d(name: str):
        v = counters.get(name)
        return None if v is None or reset else v

    tin, tout = d("llamacpp:prompt_tokens_total"), d("llamacpp:tokens_predicted_total")
    pin, pout = d("llamacpp:prompt_seconds_total"), d("llamacpp:tokens_predicted_seconds_total")
    return {
        "available": True,
        "counter_reset": reset,  # servidor reiniciado durante a execução: deltas inválidos
        "tokens_in": None if tin is None else int(tin),
        "tokens_out": None if tout is None else int(tout),
        "prefill_seconds": None if pin is None else round(pin, 2),
        "gen_seconds": None if pout is None else round(pout, 2),
        "prefill_tps": round(tin / pin, 1) if tin and pin else None,
        "gen_tps": round(tout / pout, 1) if tout and pout else None,
        "decode_calls": None if d("llamacpp:n_decode_total") is None else int(d("llamacpp:n_decode_total")),
        "counters_delta": {k: round(v, 3) for k, v in sorted(counters.items())},
    }


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "snapshot":
        return snapshot(sys.argv[2], sys.argv[3])
    if len(sys.argv) == 4 and sys.argv[1] == "delta":
        print(json.dumps(delta(sys.argv[2], sys.argv[3]), indent=2))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
