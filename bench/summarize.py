#!/usr/bin/env python3
"""Resume saídas JSONL do llama-bench em tabela Markdown.
Uso: python3 -I bench/summarize.py raw/02-*.jsonl
"""
import json
import sys


def test_name(r):
    p, n, d = r.get("n_prompt", 0), r.get("n_gen", 0), r.get("n_depth", 0)
    t = f"pp{p}" if p and not n else (f"tg{n}" if n and not p else f"pp{p}+tg{n}")
    return t + (f" @ d{d}" if d else "")


def main(paths):
    print("| arquivo | ncmoe | ub | b | t | load | nopo | nohost | teste | tok/s | ± |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for path in paths:
        name = path.rsplit("/", 1)[-1].replace(".jsonl", "")
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                r = json.loads(line)
                load = r.get("load_mode", r.get("use_mmap", ""))
                print(f"| {name} | {r.get('n_cpu_moe', '')} | {r.get('n_ubatch')} | {r.get('n_batch')} | "
                      f"{r.get('n_threads')} | {load} | {int(bool(r.get('no_op_offload', 0)))} | "
                      f"{int(bool(r.get('no_host', 0)))} | {test_name(r)} | "
                      f"{r['avg_ts']:.1f} | {r['stddev_ts']:.1f} |")


if __name__ == "__main__":
    main(sys.argv[1:])
