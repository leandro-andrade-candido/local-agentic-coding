#!/usr/bin/env bash
# Step 1 (and final step): PCIe state (replays), GPU and memory.
# Usage: bench/00-baseline.sh <label>   e.g. before | after
source "$(dirname "$0")/lib.sh"
label="${1:-before}"
out="$RAW/00-baseline-$label.txt"
{
  snapshot
  echo
  nvidia-smi -q | grep -A12 -E '^\s+PCI$' | grep -iE 'Generation|Max|Current|Width' || true
  nvidia-smi -q | grep -iE -A2 'Clocks Event Reasons|Clocks Throttle' | head -20 || true
  free -m
  nvidia-smi
} | tee "$out"
