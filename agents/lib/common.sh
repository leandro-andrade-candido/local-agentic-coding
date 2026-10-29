# shellcheck shell=bash
# Funções comuns dos run.sh (contrato do eval) e dos lançadores interativos.
# Uso: source "$(dirname "$0")/../lib/common.sh"
#
# Variáveis de ambiente aceitas:
#   LLM_BASE_URL   raiz do llama-server, sem /v1 (padrão http://127.0.0.1:9931)
#   LLM_MODEL      alias do modelo no servidor (padrão qwen3.6-35b)
#   LLM_API_KEY    chave do llama-server; sem ela, lida de LLM_API_KEY_FILE
#                  (padrão ~/.config/local-agentic/llm-api-key). Nunca é impressa.
#   LLM_CONTEXT    janela do servidor em tokens (padrão 131072)
#   LLM_MAX_OUTPUT saída máxima por resposta (padrão 32768)
#   AGENT_PROFILE  interactive | autonomous (run.sh: autonomous; lançadores: interactive)
#   AGENT_BOX=1    marcado pelo entrypoint do agent-box (E7); exigido pelo perfil autonomous
#   AGENT_ALLOW_HOST_AUTONOMOUS=1  INSEGURO: permite o perfil autonomous fora do agent-box
#   AGENT_SKILLS_DIRS  diretórios de skills separados por ":" (ver lib/skills.py)
#   AGENT_SKILLS_BOOTSTRAP=0  não injeta o bootstrap do Superpowers
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
# Chave do llama-server (E5): exigida em todas as rotas, inclusive /metrics.
# No agent-box vem em LLM_API_KEY; no host, do arquivo criado por `scripts/llm key`.
# Os cinco agentes leem LOCAL_LLM_API_KEY (Qwen envKey, Codex env_key, Pi apiKey,
# OpenCode {env:...}, Claude ANTHROPIC_AUTH_TOKEN).
LLM_API_KEY_FILE="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}"
if [ -z "${LLM_API_KEY:-}" ] && [ -r "$LLM_API_KEY_FILE" ]; then
  LLM_API_KEY="$(sed -n '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q}' "$LLM_API_KEY_FILE")"
fi
LOCAL_LLM_API_KEY="${LLM_API_KEY:-${LOCAL_LLM_API_KEY:-}}"
if [ -z "$LOCAL_LLM_API_KEY" ]; then
  echo "aviso: sem chave do llama-server (LLM_API_KEY ou $LLM_API_KEY_FILE); o servidor vai responder 401" >&2
  LOCAL_LLM_API_KEY="sem-chave"
fi
LLM_API_KEY="${LLM_API_KEY:-$LOCAL_LLM_API_KEY}"
AGENT_GUARD="$AGENTS_DIR/lib/guard.py"
SKILLS_PREFIX="${SKILLS_PREFIX:-$HOME/.local/opt/skills}"
export AGENTS_DIR LLM_BASE_URL LLM_MODEL LLM_CONTEXT LLM_MAX_OUTPUT LLM_API_KEY LOCAL_LLM_API_KEY \
  AGENT_GUARD SKILLS_PREFIX

die() { echo "erro: $*" >&2; exit 2; }

# Variáveis que um env.sh define de propósito; só elas (e a lista fixa abaixo)
# chegam ao agente. Uso: keep NOME=valor [NOME=valor...]
AGENT_ENV_KEEP=()
keep() {
  local kv
  for kv in "$@"; do
    export "${kv?}"
    AGENT_ENV_KEEP+=("${kv%%=*}")
  done
}

# Ambiente do agente: equivalente a `env -i` + lista de permitidas, feito com
# `unset` num subshell (os valores, inclusive a chave, nunca vão para a linha de
# comando). Nada da sessão que chamou (CLAUDECODE, CLAUDE_CODE_*, ANTHROPIC_*,
# OPENAI_*, tokens...) passa, a não ser o que o env.sh do agente definiu com keep.
scrub_allowed() { # <nome> [extras...]
  local n="$1"; shift
  case "$n" in LC_*|AGENT_*|GIT_AUTHOR_*|GIT_COMMITTER_*) return 0 ;; esac
  local a
  for a in PATH HOME USER LOGNAME SHELL LANG LANGUAGE TZ TMPDIR TERM COLORTERM NO_COLOR PWD \
           LLM_BASE_URL LLM_MODEL LLM_CONTEXT LLM_MAX_OUTPUT LLM_API_KEY LOCAL_LLM_API_KEY \
           AGENTS_DIR SKILLS_PREFIX "${AGENT_ENV_KEEP[@]}" "$@"; do
    [ "$n" = "$a" ] && return 0
  done
  return 1
}
scrub_env() { # [extras...]  apaga do ambiente (exportado) tudo que não é permitido
  local n
  while IFS= read -r n; do
    scrub_allowed "$n" "$@" || unset "$n" 2>/dev/null || true
  done < <(compgen -e)
}
kept_env_names() { # [extras...]
  local n out=()
  while IFS= read -r n; do scrub_allowed "$n" "$@" && out+=("$n"); done < <(compgen -e)
  printf '%s ' "${out[@]}"
}

# O perfil autonomous aprova tudo (YOLO, bypassPermissions, danger-full-access,
# Pi sem permissões): só roda dentro do agent-box da E7.
require_box_for_autonomous() {
  [ "$AGENT_PROFILE" = autonomous ] || return 0
  [ "${AGENT_DRY_RUN:-0}" = 1 ] && return 0
  if [ "${AGENT_BOX:-0}" = 1 ]; then
    [ -e /.dockerenv ] || [ -e /run/.containerenv ] \
      || die "AGENT_BOX=1 mas não há sinal de container (/.dockerenv); perfil autonomous recusado"
    return 0
  fi
  if [ "${AGENT_ALLOW_HOST_AUTONOMOUS:-0}" = 1 ]; then
    echo "aviso: perfil autonomous NO HOST (AGENT_ALLOW_HOST_AUTONOMOUS=1): o agente aprova tudo sem container. Inseguro." >&2
    return 0
  fi
  die "perfil autonomous só roda dentro do agent-box (sandbox/run-in-box.sh, que marca AGENT_BOX=1). Fora dele use AGENT_PROFILE=interactive; para forçar no host (inseguro): AGENT_ALLOW_HOST_AUTONOMOUS=1"
}

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
  AGENT_PROFILE="${AGENT_PROFILE:-autonomous}"
  case "$AGENT_PROFILE" in interactive|autonomous) ;; *) die "AGENT_PROFILE inválido: $AGENT_PROFILE" ;; esac
  require_box_for_autonomous
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
  case "$AGENT_PROFILE" in interactive|autonomous) ;; *) die "AGENT_PROFILE inválido: $AGENT_PROFILE" ;; esac
  require_box_for_autonomous
  AGENT_HOME="$AGENTS_STATE/$1"
  AGENT_WORKDIR="${AGENT_WORKDIR:-$(pwd -P)}"
  AGENT_LOG_DIR="${AGENT_LOG_DIR:-$AGENT_HOME/logs}"
  mkdir -p "$AGENT_HOME" "$AGENT_LOG_DIR"
  export AGENT_PROFILE AGENT_HOME AGENT_WORKDIR AGENT_LOG_DIR
}

# Skills (AGENT_SKILLS_DIRS) e bootstrap do Superpowers para o agente.
# Exporta AGENT_SKILLS_RESOLVED (diretórios existentes, ":") e
# AGENT_SKILLS_BOOTSTRAP_FILE (vazio se não houver using-superpowers).
setup_skills() { # <agente>
  AGENT_SKILLS_RESOLVED="$(python3 -I "$AGENTS_DIR/lib/skills.py" dirs)"
  AGENT_SKILLS_BOOTSTRAP_FILE=""
  if [ -n "$AGENT_SKILLS_RESOLVED" ] && [ "${AGENT_SKILLS_BOOTSTRAP:-1}" != 0 ]; then
    python3 -I "$AGENTS_DIR/lib/skills.py" bootstrap "$1" "$AGENT_HOME/skills-bootstrap.md"
    [ -s "$AGENT_HOME/skills-bootstrap.md" ] && AGENT_SKILLS_BOOTSTRAP_FILE="$AGENT_HOME/skills-bootstrap.md"
  fi
  export AGENT_SKILLS_RESOLVED AGENT_SKILLS_BOOTSTRAP_FILE
}

# Lançadores: executa o agente com o ambiente limpo (mais o que um terminal interativo usa).
exec_agent_interactive() { # <executável> [args...]
  scrub_env DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR WSL_DISTRO_NAME WSL_INTEROP \
    EDITOR VISUAL TERM_PROGRAM TERM_PROGRAM_VERSION
  exec "$@"
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

# Gera uma config mesclando modelos e trocando @@VAR@@ pelo ambiente.
render() { # <saída> <modelo> [modelo...]
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  python3 -I "$AGENTS_DIR/lib/render.py" "$out" "$@"
}

# Retrato do /metrics do llama-server (exige --metrics e a chave). A chave vai
# pela entrada padrão do curl, fora da linha de comando (ps). Falha não é erro.
metrics_snapshot() { # <arquivo>
  printf 'Authorization: Bearer %s\n' "$LOCAL_LLM_API_KEY" \
    | curl -fsS --max-time 5 -H @- "$LLM_BASE_URL/metrics" -o "$1" 2>/dev/null || rm -f "$1"
}

# Executa o agente no workdir com o ambiente limpo (scrub_env), grava stdout/stderr,
# métricas e metadados. Retorna o código de saída do agente.
run_agent() { # <agente> -- <comando...>
  local harness="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local out="$LOG_DIR/events.jsonl" err="$LOG_DIR/stderr.log"
  {
    echo "# @PROMPT@ = conteúdo de $PROMPT_FILE"
    echo "# ambiente limpo; variáveis repassadas: $(kept_env_names)"
    printf 'cd %q &&' "$WORKDIR"
    local a
    for a in "$@"; do
      if [ "$a" = "$PROMPT" ]; then a=@PROMPT@
      elif [ "${a%%=*}=" != "$a" ] && [ "${a#*=}" = "$PROMPT" ]; then a="${a%%=*}=@PROMPT@"
      fi
      printf ' %q' "$a"
    done
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
  (cd "$WORKDIR" && scrub_env && exec "${pre[@]}" "$@" </dev/null >"$out" 2>"$err") || rc=$?
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
