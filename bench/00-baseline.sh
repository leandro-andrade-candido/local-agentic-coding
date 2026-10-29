#!/usr/bin/env bash
# Passo 1 (e passo final): estado do PCIe (replays), GPU e memória.
# Uso: bench/00-baseline.sh <rótulo>   ex.: antes | depois
source "$(dirname "$0")/lib.sh"
label="${1:-antes}"
out="$RAW/00-baseline-$label.txt"
{
  snapshot
  echo
  nvidia-smi -q | grep -A12 -E '^\s+PCI$' | grep -iE 'Generation|Max|Current|Width' || true
  nvidia-smi -q | grep -iE -A2 'Clocks Event Reasons|Clocks Throttle' | head -20 || true
  free -m
  nvidia-smi
} | tee "$out"
