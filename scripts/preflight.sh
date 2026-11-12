#!/usr/bin/env bash
# llama-server preflight (E5): checks that the machine is ready for the model.
# Read-only: does not stop or change anything. Takes under 1 s (nvidia-smi limited to 2.5 s).
#
# Usage: scripts/preflight.sh
# Exit: 0 = can start (with or without warnings); 2 = blocker (the start would fail):
#   binary or model missing, wrong model size, arguments refused
#   (includes missing key and forbidden flag), port taken by another program.
# Warnings (do not block): another process on the GPU (usage condition: the GPU is
# dedicated to the AI while it is in use; games and NVIDIA Broadcast closed), low free VRAM,
# high temperature or thermal throttling, PCIe below Gen4 or with replays, low available
# RAM in WSL, swap in use, another llama.cpp instance running.
#
# Limits (environment variables):
#   PREFLIGHT_MIN_FREE_VRAM_MIB=7500   idle GPU: ~7,910 MiB free (8,151 - 241 reserved)
#   PREFLIGHT_MAX_TEMP_C=80
#   PREFLIGHT_MAX_SWAP_USED_MIB=1024
#
# The GPU is queried from two sides, in parallel:
#   - Windows nvidia-smi.exe: Windows processes (games, Broadcast), VRAM, PCIe.
#     WSL CUDA work shows up there as PID 4 (System), type C, with no name
#     (observed on Oct 29 with the E4 llama-server running).
#   - WSL nvidia-smi (/usr/lib/wsl/lib): Linux processes with PID and name.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../runtime/common.sh
source "$here/../runtime/common.sh"

WIN_SMI="${WIN_SMI:-/mnt/c/Windows/System32/nvidia-smi.exe}"
WSL_SMI="${WSL_SMI:-/usr/lib/wsl/lib/nvidia-smi}"
min_free_vram="${PREFLIGHT_MIN_FREE_VRAM_MIB:-7500}"
max_temp="${PREFLIGHT_MAX_TEMP_C:-80}"
max_swap="${PREFLIGHT_MAX_SWAP_USED_MIB:-1024}"

n_warn=0 n_block=0
ok()    { printf '  ok        %s\n' "$*"; }
info()  { printf '  info      %s\n' "$*"; }
warn()  { printf '  WARNING   %s\n' "$*"; n_warn=$((n_warn + 1)); }
block() { printf '  BLOCKER   %s\n' "$*"; n_block=$((n_block + 1)); }

tmp="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/preflight.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# GPU first, in the background (it is the slowest step).
if [ -x "$WIN_SMI" ]; then
  (timeout 2.5 "$WIN_SMI" -q 2>/dev/null | tr -d '\r' > "$tmp/win") &
fi
if [ -x "$WSL_SMI" ]; then
  (timeout 2.5 "$WSL_SMI" -q 2>/dev/null > "$tmp/wsl") &
fi

mainpid="$(llm_unit_mainpid)"
llm_resolve_model || true
echo "llama-server preflight ($LLAMA_SERVER_HOST:$LLAMA_SERVER_PORT, model ${MODEL_ALIAS:-?})"
if [ "$mainpid" != 0 ]; then
  info "service $LLM_SERVICE is up (PID $mainpid): VRAM and RAM below already include the server"
fi

# 1. Binary, model, arguments.
bin_ok=false
if [ -x "$LLAMA_SERVER_BIN" ] && [ -f "$LLAMA_CPP_DIR/.complete" ]; then
  ok "llama-server $LLAMA_CPP_BUILD in $LLAMA_CPP_DIR"
  bin_ok=true
else
  block "llama-server $LLAMA_CPP_BUILD not installed in $LLAMA_CPP_DIR (scripts/install-llama-cpp.sh)"
fi

if [ -n "${MODEL_ERROR:-}" ]; then
  block "$MODEL_ERROR"
elif [ ! -f "$MODEL_PATH" ]; then
  block "model missing: $MODEL_PATH (scripts/fetch-model.sh $MODEL_ALIAS)"
else
  size="$(stat -c %s "$MODEL_PATH")"
  if [ "$size" = "$MODEL_BYTES" ]; then
    ok "model $(basename "$MODEL_PATH") ($size bytes, matches models.tsv)"
  else
    block "model $MODEL_PATH is $size bytes; models.tsv says $MODEL_BYTES"
  fi
fi

if $bin_ok && [ -n "${MODEL_PATH:-}" ]; then
  if env LLAMA_SERVER_HOST="$LLAMA_SERVER_HOST" LLAMA_SERVER_PORT="$LLAMA_SERVER_PORT" \
       LLM_API_KEY_FILE="$LLM_API_KEY_FILE" LOCAL_AGENTIC_REPO="$LOCAL_AGENTIC_REPO" \
       python3 -I "$LLAMA_SERVER_ARGS_PY" --bin "$LLAMA_SERVER_BIN" --profile "$LLAMA_SERVER_PROFILE" \
       --policy "$LLAMA_SERVER_POLICY" --model "$MODEL_PATH" --format check 2> "$tmp/args.err"; then
    ok "arguments: profile + policy accepted (key $LLM_API_KEY_FILE, no forbidden route)"
  else
    block "arguments refused: $(grep -m1 '^error:' "$tmp/args.err" | sed 's/^error: //')"
  fi
fi

# 2. Port.
listen="$(ss -Hltnp "sport = :$LLAMA_SERVER_PORT" 2>/dev/null)"
if [ -z "$listen" ]; then
  ok "port $LLAMA_SERVER_PORT free"
else
  lpid="$(grep -o 'pid=[0-9]*' <<< "$listen" | head -n1 | cut -d= -f2)"
  lname="$(grep -o '(("[^"]*"' <<< "$listen" | head -n1 | cut -d'"' -f2)"
  if [ -n "$lpid" ] && [ "$lpid" = "$mainpid" ]; then
    ok "port $LLAMA_SERVER_PORT held by the service itself (PID $lpid)"
  elif [ -n "$lpid" ]; then
    block "port $LLAMA_SERVER_PORT held by ${lname:-?} (PID $lpid), outside the service"
  else
    block "port $LLAMA_SERVER_PORT held by another user's process"
  fi
fi

# 3. Other llama.cpp instances in WSL (they compete for GPU, RAM and CPU).
declare -A wsl_seen=()
while read -r pid comm; do
  [ -n "$pid" ] || continue
  [ "$pid" = "$mainpid" ] && continue
  wsl_seen[$pid]=1
  warn "another llama.cpp instance in WSL: $comm (PID $pid)"
done < <(pgrep -x 'llama-server|llama-bench|llama-cli|llama-batched-bench' -l 2>/dev/null)

# 4. GPU.
wait
smi_parse() { # <file>: key=value lines and "proc<TAB>pid<TAB>tipo<TAB>nome"
  awk '
    function val(l) { sub(/^[^:]*:[ ]?/, "", l); gsub(/[ \t]+$/, "", l); return l }
    /^    [A-Za-z]/ { inproc = ($0 ~ /^    Processes/) }
    /^    FB Memory Usage/ { fb = 4; next }
    fb > 0 { fb--; k = $1; if (k == "Total" || k == "Used" || k == "Free" || k == "Reserved") print "fb_" tolower(k) "=" val($0) + 0; next }
    /PCIe Generation/ { pg = 5; next }
    pg > 0 { pg--; k = $0; sub(/:.*/, "", k); gsub(/^ +| +$/, "", k); gsub(/ /, "_", k); print "gen_" tolower(k) "=" val($0); next }
    /Link Width/ { lw = 2; next }
    lw > 0 { lw--; print "width_" tolower($1) "=" val($0); next }
    /Product Name/ { print "name=" val($0) }
    /Replays Since Reset/ { print "replays=" val($0) }
    /Replay Number Rollovers/ { print "rollovers=" val($0) }
    /GPU Current Temp/ { print "temp=" val($0) + 0 }
    /Slowdown|Power Brake/ { if (val($0) == "Active") { k = $0; sub(/:.*/, "", k); gsub(/^ +| +$/, "", k); print "slowdown=" k } }
    inproc && /Process ID/ { pid = val($0); ptype = ""; next }
    inproc && /^            Type/ { ptype = val($0); next }
    inproc && /^            Name/ { printf "proc\t%s\t%s\t%s\n", pid, ptype, val($0) }
  ' "$1"
}

state_src=""
if [ -s "$tmp/win" ]; then state_src="$tmp/win"
elif [ -s "$tmp/wsl" ]; then state_src="$tmp/wsl"
fi
if [ ! -s "$tmp/win" ]; then
  warn "Windows nvidia-smi.exe did not respond: Windows processes on the GPU (games, Broadcast) not checked"
fi

if [ -n "$state_src" ]; then
  name="" fb_total="" fb_used="" fb_free="" temp="" replays="" rollovers=""
  gen_max="" gen_current="" gen_host_max="" width_current="" slowdowns=()
  while IFS= read -r line; do
    case "$line" in
      proc$'\t'*) ;;
      slowdown=*) slowdowns+=("${line#*=}") ;;
      name=*) name="${line#*=}" ;;
      fb_total=*) fb_total="${line#*=}" ;;
      fb_used=*) fb_used="${line#*=}" ;;
      fb_free=*) fb_free="${line#*=}" ;;
      temp=*) temp="${line#*=}" ;;
      replays=*) replays="${line#*=}" ;;
      rollovers=*) rollovers="${line#*=}" ;;
      gen_max=*) gen_max="${line#*=}" ;;
      gen_current=*) gen_current="${line#*=}" ;;
      gen_host_max=*) gen_host_max="${line#*=}" ;;
      width_current=*) width_current="${line#*=}" ;;
    esac
  done < <(smi_parse "$state_src")

  info "GPU ${name:-?}: ${temp:-?} °C, VRAM used ${fb_used:-?} of ${fb_total:-?} MiB, PCIe Gen${gen_current:-?} (max ${gen_max:-?}, host ${gen_host_max:-?}) ${width_current:-?}"

  # VRAM: only worth comparing with the server stopped.
  if [ "$mainpid" = 0 ] && [ -n "$fb_free" ]; then
    if [ "$fb_free" -lt "$min_free_vram" ]; then
      warn "free VRAM $fb_free MiB (< $min_free_vram): another program is using the GPU; with fixed -ngl/-ncmoe, --fit reduces nothing, and the load may have no headroom or fail"
    else
      ok "free VRAM $fb_free MiB"
    fi
  fi
  if [ -n "$temp" ] && [ "$temp" -ge "$max_temp" ]; then
    warn "GPU at $temp °C (>= $max_temp) before load"
  fi
  for s in "${slowdowns[@]}"; do warn "GPU throttling active: $s"; done
  if [ -n "$gen_max" ] && [ "$gen_max" != "N/A" ] && [ "$gen_max" -lt 4 ]; then
    warn "PCIe max is Gen$gen_max (expected Gen4 since E0: cable/BIOS)"
  fi
  if [ -n "$replays" ] && [ "$replays" != 0 ] && [ "$replays" != "N/A" ]; then
    warn "PCIe has $replays replays since the last driver reset (expected 0; link instability)"
  elif [ -n "$replays" ]; then
    ok "PCIe has no replays"
  fi
  if [ -n "$rollovers" ] && [ "$rollovers" != 0 ] && [ "$rollovers" != "N/A" ]; then
    warn "PCIe has $rollovers replay counter rollovers"
  fi
fi

# Processes on the GPU. WSL: by PID; Windows: everything except WSL's own entry (PID 4).
n_wsl_gpu=0 n_win_other=0 gpu_shared=false
[ ${#wsl_seen[@]} -eq 0 ] || gpu_shared=true
if [ -s "$tmp/wsl" ]; then
  while IFS=$'\t' read -r _ pid ptype pname; do
    n_wsl_gpu=$((n_wsl_gpu + 1))
    if [ "$pid" = "$mainpid" ]; then
      ok "GPU used by the service itself (PID $pid)"
    elif [ -z "${wsl_seen[$pid]:-}" ]; then
      warn "WSL process on the GPU: ${pname##*/} (PID $pid, type $ptype)"
      gpu_shared=true
    fi
  done < <(smi_parse "$tmp/wsl" | grep $'^proc\t')
fi
if [ -s "$tmp/win" ]; then
  while IFS=$'\t' read -r _ pid ptype pname; do
    if [ "$pid" = 4 ] && { [ -z "$pname" ] || [[ "$pname" == *Insufficient* ]]; }; then
      [ "$n_wsl_gpu" -gt 0 ] && continue
      warn "GPU in use by PID 4 (System) with no visible WSL process: other driver use"
      gpu_shared=true
      continue
    fi
    n_win_other=$((n_win_other + 1))
    pname="${pname##*\\}"
    hint=""
    case "${pname,,}" in *broadcast*) hint=" (close NVIDIA Broadcast)" ;; esac
    warn "Windows process on the GPU: ${pname:-no name} (PID $pid, type $ptype)$hint"
    gpu_shared=true
  done < <(smi_parse "$tmp/win" | grep $'^proc\t')
  if [ "$n_win_other" = 0 ]; then
    ok "no Windows process on the GPU"
  fi
fi
if $gpu_shared; then
  info "usage condition: the GPU is dedicated to the AI while it is in use (no games, Broadcast closed)"
fi

# 5. WSL memory.
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
swap_total_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
swap_free_kb="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)"
mem_avail_mib=$((mem_avail_kb / 1024))
swap_used_mib=$(((swap_total_kb - swap_free_kb) / 1024))
cache_ram_mib="$(awk '/^[[:space:]]*#/ {next} ($1 == "--cache-ram" || $1 == "-cram") {print $2; exit}' "$LLAMA_SERVER_PROFILE")"
cache_ram_mib="${cache_ram_mib:-8192}"
[ "$cache_ram_mib" -ge 0 ] 2>/dev/null || cache_ram_mib=0
if [ "$mainpid" = 0 ] && [ -n "${MODEL_BYTES:-}" ]; then
  model_mib=$((MODEL_BYTES / 1048576))
  need_load=$((model_mib + 2048))
  need_full=$((model_mib + cache_ram_mib + 4096))
  if [ "$mem_avail_mib" -lt "$need_load" ]; then
    warn "available WSL RAM ${mem_avail_mib} MiB: loading the model (~${model_mib} MiB of pinned memory) may fail"
  elif [ "$mem_avail_mib" -lt "$need_full" ]; then
    warn "available WSL RAM ${mem_avail_mib} MiB (< ${need_full}: model + --cache-ram ${cache_ram_mib} + 4 GiB); the prompt cache may push into swap"
  else
    ok "available WSL RAM ${mem_avail_mib} MiB"
  fi
else
  info "available WSL RAM ${mem_avail_mib} MiB"
fi
if [ "$swap_used_mib" -gt "$max_swap" ]; then
  warn "swap in use: ${swap_used_mib} MiB (> ${max_swap}): memory under pressure"
else
  ok "swap in use: ${swap_used_mib} MiB"
fi

echo "result: $n_block blocker(s), $n_warn warning(s)"
[ "$n_block" -eq 0 ] || exit 2
exit 0
