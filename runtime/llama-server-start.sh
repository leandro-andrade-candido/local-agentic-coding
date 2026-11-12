#!/usr/bin/env bash
# Starts llama-server with the E4 profile and the E5 policy (ExecStart of the
# systemd --user unit; can also be run by hand).
#
# Usage: runtime/llama-server-start.sh [--dry-run]
#   --dry-run  shows the environment, the preflight and the final command line (with the
#              key path, never the key) and exits without starting anything.
#
# Steps:
#   1. Clears LLAMA_*, HF_TOKEN, MTMD_BACKEND_DEVICE and GGML_* from the environment:
#      llama-server reads LLAMA_ARG_* as flags, and the policy must not be bypassable from outside.
#      Then loads runtime/llama-server.env (E4 profile variables).
#   2. Checks the binary (build from versions.env) and the model (exists, size from models.tsv).
#   3. Builds the arguments: -m <model> + runtime/llama-server.args (E4) +
#      runtime/llama-server.policy.args (E5), via runtime/llama-server-args.py.
#   4. Preflight (scripts/preflight.sh): warnings do not stop it; a blocker (exit code 2) does.
#      LLM_PREFLIGHT=off skips the preflight.
#   5. exec: llama-server keeps this process's PID (systemd stops it by PID).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "error: unknown argument: $1 (usage: $0 [--dry-run])" >&2; exit 2 ;;
esac
preflight_mode="${LLM_PREFLIGHT:-warn}"

# 1. Environment.
removed=()
while IFS= read -r var; do
  case "$var" in
    LLAMA_*|GGML_*|HF_TOKEN|MTMD_BACKEND_DEVICE) unset "$var"; removed+=("$var") ;;
  esac
done < <(compgen -e)
[ ${#removed[@]} -eq 0 ] || echo "note: removed from the environment: ${removed[*]}" >&2

# shellcheck source=common.sh
source "$here/common.sh"

die() { echo "error: $*" >&2; exit 2; }

env_shown=()
if [ -f "$LLAMA_SERVER_ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || die "$LLAMA_SERVER_ENV_FILE: invalid line: $line"
    name="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    case "$name" in
      LLAMA_*|HF_TOKEN|MTMD_BACKEND_DEVICE)
        die "$LLAMA_SERVER_ENV_FILE: $name cannot come from a variable (it would bypass the policy)" ;;
    esac
    export "$name=$value"
    env_shown+=("$name=$value")
  done < "$LLAMA_SERVER_ENV_FILE"
fi

# 2. Binary and model.
[ -x "$LLAMA_SERVER_BIN" ] && [ -f "$LLAMA_CPP_DIR/.complete" ] \
  || die "llama-server for build $LLAMA_CPP_BUILD not installed in $LLAMA_CPP_DIR (scripts/install-llama-cpp.sh)"
llm_resolve_model || die "$MODEL_ERROR"
[ -f "$MODEL_PATH" ] || die "model missing: $MODEL_PATH (scripts/fetch-model.sh $MODEL_ALIAS)"
size="$(stat -c %s "$MODEL_PATH")"
[ "$size" = "$MODEL_BYTES" ] \
  || die "model size $MODEL_PATH: $size bytes, expected $MODEL_BYTES (models.tsv)"

# 3. Arguments (the key never passes through here: only the file path).
builder=(env LLAMA_SERVER_HOST="$LLAMA_SERVER_HOST" LLAMA_SERVER_PORT="$LLAMA_SERVER_PORT"
         LLM_API_KEY_FILE="$LLM_API_KEY_FILE" LOCAL_AGENTIC_REPO="$LOCAL_AGENTIC_REPO"
         python3 -I "$LLAMA_SERVER_ARGS_PY" --bin "$LLAMA_SERVER_BIN"
         --profile "$LLAMA_SERVER_PROFILE" --policy "$LLAMA_SERVER_POLICY" --model "$MODEL_PATH")
args_file="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/llama-server-args.XXXXXX")"
trap 'rm -f "$args_file"' EXIT
"${builder[@]}" --format nul > "$args_file" || die "arguments refused (see above)"
mapfile -d '' -t args < "$args_file"
rm -f "$args_file"
trap - EXIT

# 4. Preflight.
if $dry_run; then
  echo "# build: $LLAMA_CPP_BUILD  model: $MODEL_ALIAS ($MODEL_BYTES bytes, size checked)"
  echo "# environment (runtime/llama-server.env): ${env_shown[*]:-none}"
  echo "# key: --api-key-file $LLM_API_KEY_FILE (content not shown)"
  echo "# preflight:"
  rc=0
  "$LOCAL_AGENTIC_REPO/scripts/preflight.sh" | sed 's/^/#   /' || rc=$?   # pipefail: rc of the preflight
  [ "$rc" -ne 2 ] || echo "#   (the real start would stop here: preflight blocked)"
  echo "# command:"
  "${builder[@]}" --format shell 2>/dev/null | sed "1s|^|${env_shown[*]:+${env_shown[*]} }|"
  exit 0
fi

case "$preflight_mode" in
  off) echo "note: preflight disabled (LLM_PREFLIGHT=off)" >&2 ;;
  *)
    rc=0
    "$LOCAL_AGENTIC_REPO/scripts/preflight.sh" || rc=$?
    [ "$rc" -ne 2 ] || die "preflight blocked the start (LLM_PREFLIGHT=off to ignore)"
    ;;
esac

# 5. Execution.
echo "starting llama-server $LLAMA_CPP_BUILD: $MODEL_ALIAS at $LLM_BASE_URL_LOCAL" >&2
exec "$LLAMA_SERVER_BIN" "${args[@]}"
