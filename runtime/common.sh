# shellcheck shell=bash
# Shared definitions for the llama-server service (E5). Sourced by
# runtime/llama-server-start.sh, scripts/preflight.sh and scripts/llm.
#
# Sources: versions.env (build, port, directories) and models.tsv (model file and
# size). Nothing here is exported: the llama-server environment is built by the wrapper.
#
# Variables accepted from the environment (LLM_ prefix, so they survive the LLAMA_* cleanup):
#   LLM_API_KEY_FILE   key file (default ~/.config/local-agentic/llm-api-key)
#   LLM_SERVER_MODEL   models.tsv alias to load; overrides the choice saved by
#                      `scripts/llm model <alias>` (default: the -a of the E4 profile)
#   LLM_SERVER_VISION  on|off; overrides the choice saved by `scripts/llm vision`
#                      (default: on, which loads the model's projector from models.tsv)
#
# Two different names:
#   - API name (llm_api_alias): always the profile's -a (qwen3.6-35b); it is what the agents
#     send in the "model" field, and it does not change when the quantization is switched;
#   - models.tsv entry (llm_model_alias): which GGUF file to load (e.g. qwen3.6-35b-q6).

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
# Model choice saved by `scripts/llm model` (outside git; also read by the service).
LLM_MODEL_CHOICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/local-agentic/model"
# Vision switch saved by `scripts/llm vision on|off` (missing file = on).
LLM_VISION_CHOICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/local-agentic/vision"
LLM_BASE_URL_LOCAL="http://$LLAMA_SERVER_HOST:$LLAMA_SERVER_PORT"

# Model name in the API: the first value of the profile's -a/--alias.
llm_api_alias() {
  awk '/^[[:space:]]*#/ {next} ($1 == "-a" || $1 == "--alias") {split($2, a, ","); print a[1]; exit}' \
    "$LLAMA_SERVER_PROFILE"
}

# models.tsv entry to load: LLM_SERVER_MODEL, else the saved choice, else the API name.
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

# Fills MODEL_ALIAS, MODEL_PATH and MODEL_BYTES from models.tsv.
# Returns 1 (with the message in MODEL_ERROR) if the alias is not in the manifest.
llm_resolve_model() {
  MODEL_ALIAS="$(llm_model_alias)"
  MODEL_PATH="" MODEL_BYTES="" MODEL_ERROR=""
  if [ -z "$MODEL_ALIAS" ]; then
    MODEL_ERROR="profile has no -a/--alias and LLM_SERVER_MODEL is empty: do not know which model to load"
    return 1
  fi
  local row
  row="$(awk -F'\t' -v a="$MODEL_ALIAS" '!/^#/ && $1 == a {print $4 "\t" $5; exit}' \
    "$LOCAL_AGENTIC_REPO/models.tsv")"
  if [ -z "$row" ]; then
    MODEL_ERROR="alias '$MODEL_ALIAS' is not in models.tsv"
    return 1
  fi
  MODEL_PATH="$MODELS_DIR/${row%%$'\t'*}"
  MODEL_BYTES="${row#*$'\t'}"
}

# Vision switch: LLM_SERVER_VISION (on|off), else the choice saved by `scripts/llm vision`,
# else on. Prints on or off; anything else counts as invalid (returns 1).
llm_vision_choice() {
  local v="${LLM_SERVER_VISION:-}"
  if [ -z "$v" ] && [ -f "$LLM_VISION_CHOICE_FILE" ]; then
    v="$(sed -n '1{s/[[:space:]]//g;p}' "$LLM_VISION_CHOICE_FILE")"
  fi
  case "${v:-on}" in
    on|off) printf '%s\n' "${v:-on}" ;;
    *) printf '%s\n' "$v"; return 1 ;;
  esac
}

# Fills VISION (on|off), MMPROJ_ALIAS, MMPROJ_PATH and MMPROJ_BYTES for MODEL_ALIAS
# (call llm_resolve_model first). The projector is column 9 (mmproj) of the model's row;
# its own row gives the file (column 8, local_file, else column 4) and the size.
# With vision off, or a model without a projector ("-"), MMPROJ_PATH stays empty.
# Returns 1 (message in MMPROJ_ERROR) on an invalid switch or a dangling alias.
llm_resolve_mmproj() {
  VISION="" MMPROJ_ALIAS="" MMPROJ_PATH="" MMPROJ_BYTES="" MMPROJ_ERROR=""
  if ! VISION="$(llm_vision_choice)"; then
    MMPROJ_ERROR="invalid vision switch '$VISION' (accepted: on, off)"
    return 1
  fi
  [ "$VISION" = on ] || return 0
  local tsv="$LOCAL_AGENTIC_REPO/models.tsv" row
  MMPROJ_ALIAS="$(awk -F'\t' -v a="$MODEL_ALIAS" '!/^#/ && $1 == a {print $9; exit}' "$tsv")"
  if [ -z "$MMPROJ_ALIAS" ] || [ "$MMPROJ_ALIAS" = "-" ]; then
    MMPROJ_ALIAS=""
    return 0
  fi
  row="$(awk -F'\t' -v a="$MMPROJ_ALIAS" \
    '!/^#/ && $1 == a {f = ($8 != "" && $8 != "-") ? $8 : $4; print f "\t" $5; exit}' "$tsv")"
  if [ -z "$row" ]; then
    MMPROJ_ERROR="projector alias '$MMPROJ_ALIAS' (of $MODEL_ALIAS) is not in models.tsv"
    return 1
  fi
  MMPROJ_PATH="$MODELS_DIR/${row%%$'\t'*}"
  MMPROJ_BYTES="${row#*$'\t'}"
}

# Main PID of the unit (0 if stopped or not installed).
llm_unit_mainpid() {
  local pid
  pid="$(systemctl --user show -p MainPID --value "$LLM_SERVICE" 2>/dev/null)" || pid=0
  printf '%s\n' "${pid:-0}"
}
