#!/usr/bin/env python3
"""Samples RAM and VRAM usage at fixed intervals until it receives SIGTERM/SIGINT.

Usage: python3 -I sampler.py --out summary.json --tsv series.tsv [--interval 3]

- Used RAM = MemTotal - MemAvailable (/proc/meminfo), in MiB; also used swap.
- Used VRAM = nvidia-smi --query-gpu=memory.used (sum over GPUs), in MiB. Read-only;
  if nvidia-smi is missing or fails, the VRAM fields stay null.
- RSS of the llama-server process (if running), in MiB.
The summary has the first sample's value (baseline) and the peak.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import time

STOP = False


def _stop(*_):
    global STOP
    STOP = True


def meminfo() -> dict:
    out = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, rest = line.split(":", 1)
            out[key] = int(rest.split()[0]) / 1024.0  # kB -> MiB
    return out


def vram(nvsmi: str | None) -> tuple[float, float] | None:
    if not nvsmi:
        return None
    try:
        res = subprocess.run([nvsmi, "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10)
        if res.returncode != 0:
            return None
        used = total = 0.0
        for line in res.stdout.strip().splitlines():
            u, t = (float(x) for x in line.split(","))
            used, total = used + u, total + t
        return used, total
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def process_rss(name: str) -> float | None:
    total, found = 0.0, False
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as f:
                if f.read().strip() != name:
                    continue
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        total += int(line.split()[1]) / 1024.0
                        found = True
        except OSError:
            continue
    return total if found else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--tsv")
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("--process", default="llama-server")
    a = ap.parse_args()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    nvsmi = shutil.which("nvidia-smi")
    tsv = open(a.tsv, "w") if a.tsv else None
    if tsv:
        tsv.write("t_s\tram_used_mib\tswap_used_mib\tvram_used_mib\tproc_rss_mib\n")

    t0 = time.time()
    s = {"samples": 0, "ram_first": None, "ram_peak": None, "swap_peak": None, "vram_first": None,
         "vram_peak": None, "vram_total": None, "rss_peak": None, "ram_total": None}
    while True:
        mi = meminfo()
        ram = mi["MemTotal"] - mi["MemAvailable"]
        swap = mi.get("SwapTotal", 0.0) - mi.get("SwapFree", 0.0)
        v = vram(nvsmi)
        rss = process_rss(a.process)
        s["samples"] += 1
        s["ram_total"] = mi["MemTotal"]
        s["ram_first"] = ram if s["ram_first"] is None else s["ram_first"]
        s["ram_peak"] = max(ram, s["ram_peak"] or 0.0)
        s["swap_peak"] = max(swap, s["swap_peak"] or 0.0)
        if v:
            s["vram_first"] = v[0] if s["vram_first"] is None else s["vram_first"]
            s["vram_peak"] = max(v[0], s["vram_peak"] or 0.0)
            s["vram_total"] = v[1]
        if rss is not None:
            s["rss_peak"] = max(rss, s["rss_peak"] or 0.0)
        if tsv:
            tsv.write(f"{time.time() - t0:.1f}\t{ram:.0f}\t{swap:.0f}\t{'' if not v else f'{v[0]:.0f}'}\t"
                      f"{'' if rss is None else f'{rss:.0f}'}\n")
            tsv.flush()
        # Sleeps in short slices to respond quickly to SIGTERM.
        deadline = time.time() + a.interval
        while not STOP and time.time() < deadline:
            time.sleep(0.2)
        if STOP:
            break

    r = lambda x: None if x is None else round(x)  # noqa: E731
    summary = {
        "interval_s": a.interval, "samples": s["samples"], "duration_s": round(time.time() - t0, 1),
        "ram_total_mib": r(s["ram_total"]), "ram_used_mib_first": r(s["ram_first"]),
        "ram_used_mib_peak": r(s["ram_peak"]), "swap_used_mib_peak": r(s["swap_peak"]),
        "vram_available": s["vram_peak"] is not None, "vram_total_mib": r(s["vram_total"]),
        "vram_used_mib_first": r(s["vram_first"]), "vram_used_mib_peak": r(s["vram_peak"]),
        "process": a.process, "process_rss_mib_peak": r(s["rss_peak"]),
    }
    with open(a.out, "w") as f:
        json.dump(summary, f, indent=2)
    if tsv:
        tsv.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
