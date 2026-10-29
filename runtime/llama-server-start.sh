#!/usr/bin/env bash
# Inicia o llama-server com o perfil da E4 e a política da E5 (ExecStart da unidade
# systemd --user; também roda à mão).
#
# Uso: runtime/llama-server-start.sh [--dry-run]
#   --dry-run  mostra o ambiente, o pré-voo e a linha de comando final (com o caminho
#              da chave, nunca a chave) e sai sem iniciar nada.
#
# Passos:
#   1. Limpa do ambiente LLAMA_*, HF_TOKEN, MTMD_BACKEND_DEVICE e GGML_*: o llama-server
#      lê LLAMA_ARG_* como flags, e a política não pode ser contornada por fora.
#      Depois carrega runtime/llama-server.env (variáveis do perfil da E4).
#   2. Confere binário (build do versions.env) e modelo (existe, tamanho do models.tsv).
#   3. Monta os argumentos: -m <modelo> + runtime/llama-server.args (E4) +
#      runtime/llama-server.policy.args (E5), por runtime/llama-server-args.py.
#   4. Pré-voo (scripts/preflight.sh): avisos não impedem; bloqueio (código 2) impede.
#      LLM_PREFLIGHT=off pula o pré-voo.
#   5. exec: o llama-server fica com o PID deste processo (o systemd o encerra pelo PID).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "erro: argumento desconhecido: $1 (uso: $0 [--dry-run])" >&2; exit 2 ;;
esac
preflight_mode="${LLM_PREFLIGHT:-warn}"

# 1. Ambiente.
removed=()
while IFS= read -r var; do
  case "$var" in
    LLAMA_*|GGML_*|HF_TOKEN|MTMD_BACKEND_DEVICE) unset "$var"; removed+=("$var") ;;
  esac
done < <(compgen -e)
[ ${#removed[@]} -eq 0 ] || echo "nota: removidas do ambiente: ${removed[*]}" >&2

# shellcheck source=common.sh
source "$here/common.sh"

die() { echo "erro: $*" >&2; exit 2; }

env_shown=()
if [ -f "$LLAMA_SERVER_ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || die "$LLAMA_SERVER_ENV_FILE: linha inválida: $line"
    name="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    case "$name" in
      LLAMA_*|HF_TOKEN|MTMD_BACKEND_DEVICE)
        die "$LLAMA_SERVER_ENV_FILE: $name não pode vir por variável (contornaria a política)" ;;
    esac
    export "$name=$value"
    env_shown+=("$name=$value")
  done < "$LLAMA_SERVER_ENV_FILE"
fi

# 2. Binário e modelo.
[ -x "$LLAMA_SERVER_BIN" ] && [ -f "$LLAMA_CPP_DIR/.complete" ] \
  || die "llama-server do build $LLAMA_CPP_BUILD não instalado em $LLAMA_CPP_DIR (scripts/install-llama-cpp.sh)"
llm_resolve_model || die "$MODEL_ERROR"
[ -f "$MODEL_PATH" ] || die "modelo ausente: $MODEL_PATH (scripts/fetch-model.sh $MODEL_ALIAS)"
size="$(stat -c %s "$MODEL_PATH")"
[ "$size" = "$MODEL_BYTES" ] \
  || die "tamanho do modelo $MODEL_PATH: $size bytes, esperado $MODEL_BYTES (models.tsv)"

# 3. Argumentos (a chave nunca passa por aqui: só o caminho do arquivo).
builder=(env LLAMA_SERVER_HOST="$LLAMA_SERVER_HOST" LLAMA_SERVER_PORT="$LLAMA_SERVER_PORT"
         LLM_API_KEY_FILE="$LLM_API_KEY_FILE" LOCAL_AGENTIC_REPO="$LOCAL_AGENTIC_REPO"
         python3 -I "$LLAMA_SERVER_ARGS_PY" --bin "$LLAMA_SERVER_BIN"
         --profile "$LLAMA_SERVER_PROFILE" --policy "$LLAMA_SERVER_POLICY" --model "$MODEL_PATH")
args_file="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/llama-server-args.XXXXXX")"
trap 'rm -f "$args_file"' EXIT
"${builder[@]}" --format nul > "$args_file" || die "argumentos recusados (ver acima)"
mapfile -d '' -t args < "$args_file"
rm -f "$args_file"
trap - EXIT

# 4. Pré-voo.
if $dry_run; then
  echo "# build: $LLAMA_CPP_BUILD  modelo: $MODEL_ALIAS ($MODEL_BYTES bytes, tamanho conferido)"
  echo "# ambiente (runtime/llama-server.env): ${env_shown[*]:-nenhum}"
  echo "# chave: --api-key-file $LLM_API_KEY_FILE (conteúdo não exibido)"
  echo "# pré-voo:"
  rc=0
  "$LOCAL_AGENTIC_REPO/scripts/preflight.sh" | sed 's/^/#   /' || rc=$?   # pipefail: rc do pré-voo
  [ "$rc" -ne 2 ] || echo "#   (o início real pararia aqui: pré-voo bloqueou)"
  echo "# comando:"
  "${builder[@]}" --format shell 2>/dev/null | sed "1s|^|${env_shown[*]:+${env_shown[*]} }|"
  exit 0
fi

case "$preflight_mode" in
  off) echo "nota: pré-voo desligado (LLM_PREFLIGHT=off)" >&2 ;;
  *)
    rc=0
    "$LOCAL_AGENTIC_REPO/scripts/preflight.sh" || rc=$?
    [ "$rc" -ne 2 ] || die "pré-voo bloqueou o início (LLM_PREFLIGHT=off para ignorar)"
    ;;
esac

# 5. Execução.
echo "iniciando llama-server $LLAMA_CPP_BUILD: $MODEL_ALIAS em $LLM_BASE_URL_LOCAL" >&2
exec "$LLAMA_SERVER_BIN" "${args[@]}"
