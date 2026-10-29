# shellcheck shell=bash
# Funções comuns dos run.sh (contrato do eval) e dos lançadores interativos.
# Uso: source "$(dirname "$0")/../lib/common.sh"
#
# Variáveis de ambiente aceitas:
#   LLM_BASE_URL   raiz do llama-server, sem /v1 (padrão http://127.0.0.1:9931)
#   LLM_MODEL      alias do modelo no servidor (padrão qwen3.6-35b)
#   LLM_CONTEXT    janela do servidor em tokens (padrão 131072)
#   LLM_MAX_OUTPUT saída máxima por resposta (padrão 32768)
#   AGENT_PROFILE  interactive | autonomous (run.sh: autonomous; lançadores: interactive)
#   AGENT_BIN      caminho do executável, para usar um binário fora de $AGENTS_PREFIX
#   AGENT_TIMEOUT  limite de tempo da execução (formato do `timeout`, ex.: 30m); vazio = sem limite
#   AGENT_LOG_REQUESTS=1  grava cada requisição ao modelo, quando o agente permite
#   AGENT_DRY_RUN=1       gera a configuração e mostra o comando, sem executar

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "$AGENTS_DIR/versions.env"

LLM_BASE_URL="${LLM_BASE_URL:-$LLM_BASE_URL_DEFAULT}"
LLM_BASE_URL="${LLM_BASE_URL%/}"
LLM_BASE_URL="${LLM_BASE_URL%/v1}"
LLM_MODEL="${LLM_MODEL:-$LLM_MODEL_DEFAULT}"
LLM_CONTEXT="${LLM_CONTEXT:-$LLM_CONTEXT_DEFAULT}"
LLM_MAX_OUTPUT="${LLM_MAX_OUTPUT:-$LLM_MAX_OUTPUT_DEFAULT}"
# O llama-server local não exige chave, mas todos os clientes exigem algum valor.
# Nunca use uma chave real aqui: ela seria enviada ao servidor local.
LOCAL_LLM_API_KEY="${LOCAL_LLM_API_KEY:-sk-local-no-key}"
AGENT_GUARD="$AGENTS_DIR/lib/guard.py"
export AGENTS_DIR LLM_BASE_URL LLM_MODEL LLM_CONTEXT LLM_MAX_OUTPUT LOCAL_LLM_API_KEY AGENT_GUARD

die() { echo "erro: $*" >&2; exit 2; }

# Contrato com o eval: run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
parse_run_args() {
  WORKDIR="" PROMPT_FILE="" LOG_DIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir) WORKDIR="${2:-}"; shift 2 ;;
      --workdir=*) WORKDIR="${1#*=}"; shift ;;
      --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
      --prompt-file=*) PROMPT_FILE="${1#*=}"; shift ;;
      --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
      --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
      -h|--help)
        echo "uso: $0 --workdir <dir> --prompt-file <arquivo> --log-dir <dir>"; exit 0 ;;
      *) die "argumento desconhecido: $1" ;;
    esac
  done
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] || die "--workdir inexistente: '$WORKDIR'"
  [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || die "--prompt-file inexistente: '$PROMPT_FILE'"
  [ -n "$LOG_DIR" ] || die "--log-dir obrigatório"
  mkdir -p "$LOG_DIR"
  WORKDIR="$(cd "$WORKDIR" && pwd -P)"
  LOG_DIR="$(cd "$LOG_DIR" && pwd -P)"
  PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd -P)/$(basename "$PROMPT_FILE")"
  # O prompt vai como argumento de linha de comando; o Linux limita cada
  # argumento a 128 KiB (MAX_ARG_STRLEN).
  local bytes
  bytes="$(wc -c < "$PROMPT_FILE")"
  [ "$bytes" -gt 0 ] || die "prompt vazio: $PROMPT_FILE"
  [ "$bytes" -lt 120000 ] || die "prompt com $bytes bytes; o limite é ~120 KB"
  PROMPT="$(cat "$PROMPT_FILE")"
  # Um prompt que começa com "-" seria lido como opção pelos CLIs; uma quebra
  # de linha no início evita isso sem mudar o conteúdo para o modelo.
  case "$PROMPT" in -*) PROMPT=$'\n'"$PROMPT" ;; esac
  AGENT_PROFILE="${AGENT_PROFILE:-autonomous}"
  case "$AGENT_PROFILE" in interactive|autonomous) ;; *) die "AGENT_PROFILE inválido: $AGENT_PROFILE" ;; esac
  # Estado do agente (config gerada, sessões): novo a cada execução, dentro do log.
  AGENT_HOME="$LOG_DIR/home"
  mkdir -p "$AGENT_HOME"
  export WORKDIR LOG_DIR PROMPT AGENT_PROFILE AGENT_HOME
  export AGENT_WORKDIR="$WORKDIR" AGENT_LOG_DIR="$LOG_DIR"
}

# Para os lançadores interativos: estado persistente fora do repositório e das
# configurações globais do usuário.
setup_interactive() { # <agente>
  AGENT_PROFILE="${AGENT_PROFILE:-interactive}"
  AGENT_HOME="$AGENTS_STATE/$1"
  AGENT_WORKDIR="${AGENT_WORKDIR:-$(pwd -P)}"
  AGENT_LOG_DIR="${AGENT_LOG_DIR:-$AGENT_HOME/logs}"
  mkdir -p "$AGENT_HOME" "$AGENT_LOG_DIR"
  export AGENT_PROFILE AGENT_HOME AGENT_WORKDIR AGENT_LOG_DIR
}

# Caminho do executável fixado. AGENT_BIN sobrepõe.
agent_bin() { # <agente> <executável>
  local bin="${AGENT_BIN:-$AGENTS_PREFIX/$1/current/bin/$2}"
  if [ ! -x "$bin" ] && [ "${AGENT_DRY_RUN:-0}" != 1 ]; then
    die "$bin não encontrado; rode: agents/install.sh $1"
  fi
  printf '%s' "$bin"
}

agent_version() { # <agente>
  readlink "$AGENTS_PREFIX/$1/current" 2>/dev/null || echo "desconhecida"
}

# Gera um JSON mesclando modelos e trocando @@VAR@@ pelo ambiente.
render() { # <saída> <modelo> [modelo...]
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  python3 -I "$AGENTS_DIR/lib/render.py" "$out" "$@"
}

# Retrato do /metrics do llama-server (exige --metrics). Falha não é erro.
metrics_snapshot() { # <arquivo>
  curl -fsS --max-time 5 "$LLM_BASE_URL/metrics" -o "$1" 2>/dev/null || rm -f "$1"
}

# Executa o agente no workdir, grava stdout/stderr, métricas e metadados.
# Retorna o código de saída do agente.
run_agent() { # <agente> -- <comando...>
  local harness="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local out="$LOG_DIR/events.jsonl" err="$LOG_DIR/stderr.log"
  {
    echo "# @PROMPT@ = conteúdo de $PROMPT_FILE"
    printf 'cd %q &&' "$WORKDIR"
    local a
    for a in "$@"; do printf ' %q' "${a//"$PROMPT"/@PROMPT@}"; done
    echo
  } > "$LOG_DIR/command.txt"
  if [ "${AGENT_DRY_RUN:-0}" = 1 ]; then
    cat "$LOG_DIR/command.txt"
    return 0
  fi
  local -a pre=()
  if [ -n "${AGENT_TIMEOUT:-}" ]; then pre=(timeout --kill-after=30 "$AGENT_TIMEOUT"); fi
  metrics_snapshot "$LOG_DIR/metrics-before.prom"
  local start end rc=0
  start="$(date -Iseconds)"
  local t0=$SECONDS
  (cd "$WORKDIR" && exec "${pre[@]}" "$@" </dev/null >"$out" 2>"$err") || rc=$?
  end="$(date -Iseconds)"
  metrics_snapshot "$LOG_DIR/metrics-after.prom"
  jq -n \
    --arg harness "$harness" --arg version "$(agent_version "$harness")" \
    --arg profile "$AGENT_PROFILE" --arg model "$LLM_MODEL" --arg base_url "$LLM_BASE_URL" \
    --arg workdir "$WORKDIR" --arg prompt_file "$PROMPT_FILE" \
    --arg start "$start" --arg end "$end" \
    --argjson seconds "$((SECONDS - t0))" --argjson exit_code "$rc" \
    '{harness:$harness, version:$version, profile:$profile, model:$model, base_url:$base_url,
      workdir:$workdir, prompt_file:$prompt_file, start:$start, end:$end,
      wall_seconds:$seconds, exit_code:$exit_code}' > "$LOG_DIR/run-meta.json"
  # Métricas do lado do cliente para o eval (agent-metrics.json); nunca muda o código de saída.
  python3 -I "$AGENTS_DIR/lib/agent_metrics.py" "$harness" "$LOG_DIR" 2>>"$err" || true
  return "$rc"
}
