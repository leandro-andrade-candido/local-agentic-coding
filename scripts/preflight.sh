#!/usr/bin/env bash
# Pré-voo do llama-server (E5): confere se a máquina está pronta para o modelo.
# Só lê: não encerra nem altera nada. Leva menos de 1 s (nvidia-smi limitado a 2,5 s).
#
# Uso: scripts/preflight.sh
# Saída: 0 = pode iniciar (com ou sem avisos); 2 = bloqueio (o início falharia):
#   binário ou modelo ausente, tamanho do modelo errado, argumentos recusados
#   (inclui chave ausente e flag proibida), porta ocupada por outro programa.
# Avisos (não bloqueiam): outro processo na GPU (condição de uso: a GPU fica dedicada
# à IA enquanto ela é usada; jogos e NVIDIA Broadcast fechados), VRAM livre baixa,
# temperatura alta ou redução térmica, PCIe abaixo de Gen4 ou com replays, pouca RAM
# disponível no WSL, swap em uso, outra instância do llama.cpp rodando.
#
# Limites (variáveis de ambiente):
#   PREFLIGHT_MIN_FREE_VRAM_MIB=7500   GPU sem nada: ~7.910 MiB livres (8.151 - 241 reservados)
#   PREFLIGHT_MAX_TEMP_C=80
#   PREFLIGHT_MAX_SWAP_USED_MIB=1024
#
# A GPU é consultada por dois lados, em paralelo:
#   - nvidia-smi.exe do Windows: processos do Windows (jogos, Broadcast), VRAM, PCIe.
#     O trabalho CUDA do WSL aparece lá como PID 4 (System), tipo C, sem nome
#     (observado em 29/10 com o llama-server da E4 no ar).
#   - nvidia-smi do WSL (/usr/lib/wsl/lib): processos do Linux com PID e nome.
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
warn()  { printf '  AVISO     %s\n' "$*"; n_warn=$((n_warn + 1)); }
block() { printf '  BLOQUEIO  %s\n' "$*"; n_block=$((n_block + 1)); }

tmp="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/preflight.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# GPU primeiro, em segundo plano (é o passo mais lento).
if [ -x "$WIN_SMI" ]; then
  (timeout 2.5 "$WIN_SMI" -q 2>/dev/null | tr -d '\r' > "$tmp/win") &
fi
if [ -x "$WSL_SMI" ]; then
  (timeout 2.5 "$WSL_SMI" -q 2>/dev/null > "$tmp/wsl") &
fi

mainpid="$(llm_unit_mainpid)"
llm_resolve_model || true
echo "pré-voo do llama-server ($LLAMA_SERVER_HOST:$LLAMA_SERVER_PORT, modelo ${MODEL_ALIAS:-?})"
if [ "$mainpid" != 0 ]; then
  info "serviço $LLM_SERVICE no ar (PID $mainpid): VRAM e RAM abaixo já incluem o servidor"
fi

# 1. Binário, modelo, argumentos.
bin_ok=false
if [ -x "$LLAMA_SERVER_BIN" ] && [ -f "$LLAMA_CPP_DIR/.complete" ]; then
  ok "llama-server $LLAMA_CPP_BUILD em $LLAMA_CPP_DIR"
  bin_ok=true
else
  block "llama-server $LLAMA_CPP_BUILD não instalado em $LLAMA_CPP_DIR (scripts/install-llama-cpp.sh)"
fi

if [ -n "${MODEL_ERROR:-}" ]; then
  block "$MODEL_ERROR"
elif [ ! -f "$MODEL_PATH" ]; then
  block "modelo ausente: $MODEL_PATH (scripts/fetch-model.sh $MODEL_ALIAS)"
else
  size="$(stat -c %s "$MODEL_PATH")"
  if [ "$size" = "$MODEL_BYTES" ]; then
    ok "modelo $(basename "$MODEL_PATH") ($size bytes, igual ao models.tsv)"
  else
    block "modelo $MODEL_PATH com $size bytes; models.tsv diz $MODEL_BYTES"
  fi
fi

if $bin_ok && [ -n "${MODEL_PATH:-}" ]; then
  if env LLAMA_SERVER_HOST="$LLAMA_SERVER_HOST" LLAMA_SERVER_PORT="$LLAMA_SERVER_PORT" \
       LLM_API_KEY_FILE="$LLM_API_KEY_FILE" LOCAL_AGENTIC_REPO="$LOCAL_AGENTIC_REPO" \
       python3 -I "$LLAMA_SERVER_ARGS_PY" --bin "$LLAMA_SERVER_BIN" --profile "$LLAMA_SERVER_PROFILE" \
       --policy "$LLAMA_SERVER_POLICY" --model "$MODEL_PATH" --format check 2> "$tmp/args.err"; then
    ok "argumentos: perfil + política aceitos (chave $LLM_API_KEY_FILE, nenhuma rota proibida)"
  else
    block "argumentos recusados: $(grep -m1 '^erro:' "$tmp/args.err" | sed 's/^erro: //')"
  fi
fi

# 2. Porta.
listen="$(ss -Hltnp "sport = :$LLAMA_SERVER_PORT" 2>/dev/null)"
if [ -z "$listen" ]; then
  ok "porta $LLAMA_SERVER_PORT livre"
else
  lpid="$(grep -o 'pid=[0-9]*' <<< "$listen" | head -n1 | cut -d= -f2)"
  lname="$(grep -o '(("[^"]*"' <<< "$listen" | head -n1 | cut -d'"' -f2)"
  if [ -n "$lpid" ] && [ "$lpid" = "$mainpid" ]; then
    ok "porta $LLAMA_SERVER_PORT ocupada pelo próprio serviço (PID $lpid)"
  elif [ -n "$lpid" ]; then
    block "porta $LLAMA_SERVER_PORT ocupada por ${lname:-?} (PID $lpid), fora do serviço"
  else
    block "porta $LLAMA_SERVER_PORT ocupada por processo de outro usuário"
  fi
fi

# 3. Outras instâncias do llama.cpp no WSL (disputam GPU, RAM e CPU).
declare -A wsl_seen=()
while read -r pid comm; do
  [ -n "$pid" ] || continue
  [ "$pid" = "$mainpid" ] && continue
  wsl_seen[$pid]=1
  warn "outra instância do llama.cpp no WSL: $comm (PID $pid)"
done < <(pgrep -x 'llama-server|llama-bench|llama-cli|llama-batched-bench' -l 2>/dev/null)

# 4. GPU.
wait
smi_parse() { # <arquivo>: linhas chave=valor e "proc<TAB>pid<TAB>tipo<TAB>nome"
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
  warn "nvidia-smi.exe do Windows não respondeu: processos do Windows na GPU (jogos, Broadcast) não conferidos"
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

  info "GPU ${name:-?}: ${temp:-?} °C, VRAM usada ${fb_used:-?} de ${fb_total:-?} MiB, PCIe Gen${gen_current:-?} (máx. ${gen_max:-?}, host ${gen_host_max:-?}) ${width_current:-?}"

  # VRAM: só faz sentido comparar com o servidor parado.
  if [ "$mainpid" = 0 ] && [ -n "$fb_free" ]; then
    if [ "$fb_free" -lt "$min_free_vram" ]; then
      warn "VRAM livre $fb_free MiB (< $min_free_vram): outro programa está usando a GPU; com -ngl/-ncmoe fixos o --fit não reduz nada, e a carga pode ficar sem folga ou falhar"
    else
      ok "VRAM livre $fb_free MiB"
    fi
  fi
  if [ -n "$temp" ] && [ "$temp" -ge "$max_temp" ]; then
    warn "GPU a $temp °C (>= $max_temp) antes da carga"
  fi
  for s in "${slowdowns[@]}"; do warn "GPU com redução ativa: $s"; done
  if [ -n "$gen_max" ] && [ "$gen_max" != "N/A" ] && [ "$gen_max" -lt 4 ]; then
    warn "PCIe com máximo Gen$gen_max (esperado Gen4 desde a E0: cabo/BIOS)"
  fi
  if [ -n "$replays" ] && [ "$replays" != 0 ] && [ "$replays" != "N/A" ]; then
    warn "PCIe com $replays replays desde o último reset do driver (esperado 0; instabilidade do link)"
  elif [ -n "$replays" ]; then
    ok "PCIe sem replays"
  fi
  if [ -n "$rollovers" ] && [ "$rollovers" != 0 ] && [ "$rollovers" != "N/A" ]; then
    warn "PCIe com $rollovers estouros do contador de replays"
  fi
fi

# Processos na GPU. WSL: por PID; Windows: tudo menos a entrada do próprio WSL (PID 4).
n_wsl_gpu=0 n_win_other=0 gpu_shared=false
[ ${#wsl_seen[@]} -eq 0 ] || gpu_shared=true
if [ -s "$tmp/wsl" ]; then
  while IFS=$'\t' read -r _ pid ptype pname; do
    n_wsl_gpu=$((n_wsl_gpu + 1))
    if [ "$pid" = "$mainpid" ]; then
      ok "GPU usada pelo próprio serviço (PID $pid)"
    elif [ -z "${wsl_seen[$pid]:-}" ]; then
      warn "processo do WSL na GPU: ${pname##*/} (PID $pid, tipo $ptype)"
      gpu_shared=true
    fi
  done < <(smi_parse "$tmp/wsl" | grep $'^proc\t')
fi
if [ -s "$tmp/win" ]; then
  while IFS=$'\t' read -r _ pid ptype pname; do
    if [ "$pid" = 4 ] && { [ -z "$pname" ] || [[ "$pname" == *Insufficient* ]]; }; then
      [ "$n_wsl_gpu" -gt 0 ] && continue
      warn "GPU em uso pelo PID 4 (System) sem processo do WSL visível: outro uso do driver"
      gpu_shared=true
      continue
    fi
    n_win_other=$((n_win_other + 1))
    pname="${pname##*\\}"
    hint=""
    case "${pname,,}" in *broadcast*) hint=" (feche o NVIDIA Broadcast)" ;; esac
    warn "processo do Windows na GPU: ${pname:-sem nome} (PID $pid, tipo $ptype)$hint"
    gpu_shared=true
  done < <(smi_parse "$tmp/win" | grep $'^proc\t')
  if [ "$n_win_other" = 0 ]; then
    ok "nenhum processo do Windows na GPU"
  fi
fi
if $gpu_shared; then
  info "condição de uso: a GPU fica dedicada à IA enquanto ela é usada (sem jogos, Broadcast fechado)"
fi

# 5. Memória do WSL.
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
    warn "RAM disponível no WSL ${mem_avail_mib} MiB: o carregamento do modelo (~${model_mib} MiB em memória fixada) pode falhar"
  elif [ "$mem_avail_mib" -lt "$need_full" ]; then
    warn "RAM disponível no WSL ${mem_avail_mib} MiB (< ${need_full}: modelo + --cache-ram ${cache_ram_mib} + 4 GiB); o cache de prompts pode empurrar para o swap"
  else
    ok "RAM disponível no WSL ${mem_avail_mib} MiB"
  fi
else
  info "RAM disponível no WSL ${mem_avail_mib} MiB"
fi
if [ "$swap_used_mib" -gt "$max_swap" ]; then
  warn "swap em uso: ${swap_used_mib} MiB (> ${max_swap}): memória sob pressão"
else
  ok "swap em uso: ${swap_used_mib} MiB"
fi

echo "resultado: $n_block bloqueio(s), $n_warn aviso(s)"
[ "$n_block" -eq 0 ] || exit 2
exit 0
