#!/usr/bin/env python3
"""Mede a geração (tg) pelo llama-server com requisições reais: N pedidos curtos,
cada um gerando exatamente --n tokens (ignore_eos), com prompts diferentes.
Lê timings.predicted_per_second de cada resposta.

Uso: python3 -I bench/tg_requests.py --out raw/x.jsonl [--base URL] [--n 256] [--reqs 4]
"""
import argparse
import json
import time
import urllib.request

PROMPTS = [
    "Write a Python function that parses an ISO-8601 duration string and returns total seconds. Include tests.",
    "Explain, with a code example in TypeScript, how to debounce an async function and cancel pending calls.",
    "Refactor this loop into a list comprehension and explain the complexity: result=[]\nfor x in data:\n  if x%3==0: result.append(x*x)",
    "Write a bash script that finds the 10 largest files under a directory, skipping .git, and prints human sizes.",
    "Implement an LRU cache class in Python without functools, with get/put in O(1), and explain the design.",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:9931")
    ap.add_argument("--n", type=int, default=256)
    ap.add_argument("--reqs", type=int, default=4)
    ap.add_argument("--label", default="tg")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    with open(a.out, "a") as out:
        for i in range(a.reqs):
            payload = {"model": "qwen3.6-35b", "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}],
                       "max_tokens": a.n, "ignore_eos": True, "temperature": 0.6, "top_p": 0.95, "top_k": 20,
                       "seed": i, "cache_prompt": False}
            req = urllib.request.Request(a.base + "/v1/chat/completions", data=json.dumps(payload).encode(),
                                         headers={"Content-Type": "application/json"})
            t0 = time.time()
            with urllib.request.urlopen(req, timeout=600) as r:
                resp = json.load(r)
            t = resp.get("timings", {})
            rec = {"label": a.label, "req": i, "wall_s": round(time.time() - t0, 2),
                   "prompt_n": t.get("prompt_n"), "prompt_tps": t.get("prompt_per_second"),
                   "predicted_n": t.get("predicted_n"), "predicted_tps": t.get("predicted_per_second")}
            out.write(json.dumps(rec) + "\n")
            print(json.dumps(rec))
            if i == 0:
                txt = (resp["choices"][0]["message"].get("content") or "")[:300]
                rsn = (resp["choices"][0]["message"].get("reasoning_content") or "")[:300]
                print("amostra do texto (checar se não é lixo):", json.dumps(rsn or txt))


if __name__ == "__main__":
    main()
