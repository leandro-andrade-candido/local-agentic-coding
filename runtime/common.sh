# shellcheck shell=bash
# Definições comuns do serviço do llama-server (E5). Incluído por
# runtime/llama-server-start.sh, scripts/preflight.sh e scripts/llm.
#
# Fontes: versions.env (build, porta, pastas) e models.tsv (arquivo e tamanho do
# modelo). Nada aqui é exportado: o ambiente do llama-server é montado pelo wrapper.
#
# Variáveis aceitas do ambiente (prefixo LLM_, para não cair na limpeza de LLAMA_*):
#   LLM_API_KEY_FILE   arquivo da chave (padrão ~/.config/local-agentic/llm-api-key)
#   LLM_SERVER_MODEL   alias do models.tsv a carregar; vale sobre a escolha gravada por
#                      `scripts/llm model <alias>` (padrão: o -a do perfil da E4)
#
# Dois nomes diferentes:
#   - nome na API (llm_api_alias): sempre o -a do perfil (qwen3.6-35b); é o que os agentes
#     mandam no campo "model", e não muda quando se troca a quantização;
#   - item do models.tsv (llm_model_alias): qual arquivo GGUF carregar (ex.: qwen3.6-35b-q6).

LOCAL_AGENTIC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../versions.env
source "$LOCAL_AGENTIC_REPO/versions.env"

LLAMA_CPP_DIR="$LLAMA_CPP_PREFIX/$LLAMA_CPP_BUILD"
LLAMA_SERVER_BIN="$LLAMA_CPP_DIR/llama-server"
LLAMA_SERVER_PROFILE="$LOCAL_AGENTIC_REPO/runtime/llama-server.args"
LLAMA_SERVER_POLICY="$LOCAL_AGENTIC_REPO/runtime/llama-server.policy.args"
LLAMA_SERVER_ENV_FILE="$LOCAL_AGENTIC_REPO/runtime/llama-server.env"
LLAMA_SERVER_ARGS_PY="$LOCAL_AGENTIC_REPO/runtime/llama-server-args.py"
LLM_API_KEY_FILE="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}"
LLM_SERVICE="llama-server.service"
# Escolha do modelo gravada por `scripts/llm model` (fora do git; lida também pelo serviço).
LLM_MODEL_CHOICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/local-agentic/model"
LLM_BASE_URL_LOCAL="http://$LLAMA_SERVER_HOST:$LLAMA_SERVER_PORT"

# Nome do modelo na API: o primeiro valor de -a/--alias do perfil.
llm_api_alias() {
  awk '/^[[:space:]]*#/ {next} ($1 == "-a" || $1 == "--alias") {split($2, a, ","); print a[1]; exit}' \
    "$LLAMA_SERVER_PROFILE"
}

# Item do models.tsv a carregar: LLM_SERVER_MODEL, senão a escolha gravada, senão o nome na API.
llm_model_alias() {
  if [ -n "${LLM_SERVER_MODEL:-}" ]; then
    printf '%s\n' "$LLM_SERVER_MODEL"
    return
  fi
  local choice=""
  [ -f "$LLM_MODEL_CHOICE_FILE" ] && choice="$(sed -n '1{s/[[:space:]]//g;p}' "$LLM_MODEL_CHOICE_FILE")"
  if [ -n "$choice" ]; then
    printf '%s\n' "$choice"
    return
  fi
  llm_api_alias
}

# Preenche MODEL_ALIAS, MODEL_PATH e MODEL_BYTES a partir do models.tsv.
# Retorna 1 (com a mensagem em MODEL_ERROR) se o alias não estiver no manifesto.
llm_resolve_model() {
  MODEL_ALIAS="$(llm_model_alias)"
  MODEL_PATH="" MODEL_BYTES="" MODEL_ERROR=""
  if [ -z "$MODEL_ALIAS" ]; then
    MODEL_ERROR="perfil sem -a/--alias e LLM_SERVER_MODEL vazio: não sei qual modelo carregar"
    return 1
  fi
  local row
  row="$(awk -F'\t' -v a="$MODEL_ALIAS" '!/^#/ && $1 == a {print $4 "\t" $5; exit}' \
    "$LOCAL_AGENTIC_REPO/models.tsv")"
  if [ -z "$row" ]; then
    MODEL_ERROR="alias '$MODEL_ALIAS' não está em models.tsv"
    return 1
  fi
  MODEL_PATH="$MODELS_DIR/${row%%$'\t'*}"
  MODEL_BYTES="${row#*$'\t'}"
}

# PID principal da unidade (0 se parada ou não instalada).
llm_unit_mainpid() {
  local pid
  pid="$(systemctl --user show -p MainPID --value "$LLM_SERVICE" 2>/dev/null)" || pid=0
  printf '%s\n' "${pid:-0}"
}
