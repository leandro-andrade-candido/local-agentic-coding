# shellcheck shell=bash
# Common functions for the run.sh scripts (eval contract) and the interactive launchers.
# Usage: source "$(dirname "$0")/../lib/common.sh"
#
# Accepted environment variables:
#   LLM_BASE_URL   llama-server root, without /v1 (default http://127.0.0.1:9931)
#   LLM_MODEL      model alias on the server (default qwen3.6-35b)
#   LLM_API_KEY    llama-server key; without it, read from LLM_API_KEY_FILE
#                  (default ~/.config/local-agentic/llm-api-key). Never printed.
#   LLM_CONTEXT    server window in tokens (default 131072)
#   LLM_MAX_OUTPUT maximum output per response (default 32768)
#   AGENT_PROFILE  interactive | autonomous (run.sh: autonomous; launchers: interactive)
#   AGENT_BOX=1    set by the agent-box entrypoint (E7); required by the autonomous profile
#   AGENT_ALLOW_HOST_AUTONOMOUS=1  UNSAFE: allows the autonomous profile outside the agent-box
#   AGENT_SKILLS_DIRS  skills directories separated by ":" (see lib/skills.py)
#   AGENT_SKILLS_BOOTSTRAP=0  do not inject the Superpowers bootstrap
#   AGENT_BIN      executable path, to use a binary outside $AGENTS_PREFIX
#   AGENT_TIMEOUT  run time limit (`timeout` format, e.g. 30m); empty = no limit
#   AGENT_LOG_REQUESTS=1  record each request to the model, when the agent allows it
#   AGENT_DRY_RUN=1       generate the configuration and show the command, without running

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "$AGENTS_DIR/versions.env"

LLM_BASE_URL="${LLM_BASE_URL:-$LLM_BASE_URL_DEFAULT}"
LLM_BASE_URL="${LLM_BASE_URL%/}"
LLM_BASE_URL="${LLM_BASE_URL%/v1}"
LLM_MODEL="${LLM_MODEL:-$LLM_MODEL_DEFAULT}"
LLM_CONTEXT="${LLM_CONTEXT:-$LLM_CONTEXT_DEFAULT}"
LLM_MAX_OUTPUT="${LLM_MAX_OUTPUT:-$LLM_MAX_OUTPUT_DEFAULT}"
# llama-server key (E5): required on every route, including /metrics.
# In the agent-box it arrives in LLM_API_KEY; on the host, from the file created by `scripts/llm key`.
# The five agents read LOCAL_LLM_API_KEY (Qwen envKey, Codex env_key, Pi apiKey,
# OpenCode {env:...}, Claude ANTHROPIC_AUTH_TOKEN).
LLM_API_KEY_FILE="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}"
if [ -z "${LLM_API_KEY:-}" ] && [ -r "$LLM_API_KEY_FILE" ]; then
  LLM_API_KEY="$(sed -n '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q}' "$LLM_API_KEY_FILE")"
fi
LOCAL_LLM_API_KEY="${LLM_API_KEY:-${LOCAL_LLM_API_KEY:-}}"
if [ -z "$LOCAL_LLM_API_KEY" ]; then
  echo "warning: no llama-server key (LLM_API_KEY or $LLM_API_KEY_FILE); the server will answer 401" >&2
  LOCAL_LLM_API_KEY="no-key"
fi
LLM_API_KEY="${LLM_API_KEY:-$LOCAL_LLM_API_KEY}"
AGENT_GUARD="$AGENTS_DIR/lib/guard.py"
SKILLS_PREFIX="${SKILLS_PREFIX:-$HOME/.local/opt/skills}"
export AGENTS_DIR LLM_BASE_URL LLM_MODEL LLM_CONTEXT LLM_MAX_OUTPUT LLM_API_KEY LOCAL_LLM_API_KEY \
  AGENT_GUARD SKILLS_PREFIX

die() { echo "error: $*" >&2; exit 2; }

# Variables that an env.sh sets on purpose; only they (and the fixed list below)
# reach the agent. Usage: keep NAME=value [NAME=value...]
AGENT_ENV_KEEP=()
keep() {
  local kv
  for kv in "$@"; do
    export "${kv?}"
    AGENT_ENV_KEEP+=("${kv%%=*}")
  done
}

# Agent environment: equivalent to `env -i` + an allowlist, done with `unset`
# in a subshell (the values, including the key, never go on the command line).
# Nothing from the calling session (CLAUDECODE, CLAUDE_CODE_*, ANTHROPIC_*,
# OPENAI_*, tokens...) gets through, except what the agent's env.sh set with keep.
scrub_allowed() { # <name> [extras...]
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
scrub_env() { # [extras...]  remove from the (exported) environment everything not allowed
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

# The autonomous profile approves everything (YOLO, bypassPermissions,
# danger-full-access, Pi without permissions): it only runs inside the E7 agent-box.
require_box_for_autonomous() {
  [ "$AGENT_PROFILE" = autonomous ] || return 0
  [ "${AGENT_DRY_RUN:-0}" = 1 ] && return 0
  if [ "${AGENT_BOX:-0}" = 1 ]; then
    [ -e /.dockerenv ] || [ -e /run/.containerenv ] \
      || die "AGENT_BOX=1 but there is no sign of a container (/.dockerenv); autonomous profile refused"
    return 0
  fi
  if [ "${AGENT_ALLOW_HOST_AUTONOMOUS:-0}" = 1 ]; then
    echo "warning: autonomous profile ON THE HOST (AGENT_ALLOW_HOST_AUTONOMOUS=1): the agent approves everything without a container. Unsafe." >&2
    return 0
  fi
  die "the autonomous profile only runs inside the agent-box (sandbox/run-in-box.sh, which sets AGENT_BOX=1). Outside it use AGENT_PROFILE=interactive; to force it on the host (unsafe): AGENT_ALLOW_HOST_AUTONOMOUS=1"
}

# Contract with the eval: run.sh --workdir <dir> --prompt-file <file> --log-dir <dir>
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
        echo "usage: $0 --workdir <dir> --prompt-file <file> --log-dir <dir>"; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] || die "--workdir does not exist: '$WORKDIR'"
  [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || die "--prompt-file does not exist: '$PROMPT_FILE'"
  [ -n "$LOG_DIR" ] || die "--log-dir is required"
  AGENT_PROFILE="${AGENT_PROFILE:-autonomous}"
  case "$AGENT_PROFILE" in interactive|autonomous) ;; *) die "invalid AGENT_PROFILE: $AGENT_PROFILE" ;; esac
  require_box_for_autonomous
  mkdir -p "$LOG_DIR"
  WORKDIR="$(cd "$WORKDIR" && pwd -P)"
  LOG_DIR="$(cd "$LOG_DIR" && pwd -P)"
  PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd -P)/$(basename "$PROMPT_FILE")"
  # The prompt goes as a command-line argument; Linux limits each
  # argument to 128 KiB (MAX_ARG_STRLEN).
  local bytes
  bytes="$(wc -c < "$PROMPT_FILE")"
  [ "$bytes" -gt 0 ] || die "empty prompt: $PROMPT_FILE"
  [ "$bytes" -lt 120000 ] || die "prompt has $bytes bytes; the limit is ~120 KB"
  PROMPT="$(cat "$PROMPT_FILE")"
  # A prompt that starts with "-" would be read as an option by the CLIs; a
  # newline at the start avoids that without changing the content for the model.
  case "$PROMPT" in -*) PROMPT=$'\n'"$PROMPT" ;; esac
  # Agent state (generated config, sessions): new on every run, inside the log.
  AGENT_HOME="$LOG_DIR/home"
  mkdir -p "$AGENT_HOME"
  export WORKDIR LOG_DIR PROMPT AGENT_PROFILE AGENT_HOME
  export AGENT_WORKDIR="$WORKDIR" AGENT_LOG_DIR="$LOG_DIR"
}

# For the interactive launchers: persistent state outside the repository and the
# user's global settings.
setup_interactive() { # <agent>
  AGENT_PROFILE="${AGENT_PROFILE:-interactive}"
  case "$AGENT_PROFILE" in interactive|autonomous) ;; *) die "invalid AGENT_PROFILE: $AGENT_PROFILE" ;; esac
  require_box_for_autonomous
  AGENT_HOME="$AGENTS_STATE/$1"
  AGENT_WORKDIR="${AGENT_WORKDIR:-$(pwd -P)}"
  AGENT_LOG_DIR="${AGENT_LOG_DIR:-$AGENT_HOME/logs}"
  mkdir -p "$AGENT_HOME" "$AGENT_LOG_DIR"
  export AGENT_PROFILE AGENT_HOME AGENT_WORKDIR AGENT_LOG_DIR
}

# Skills (AGENT_SKILLS_DIRS) and the Superpowers bootstrap for the agent.
# Exports AGENT_SKILLS_RESOLVED (existing directories, ":") and
# AGENT_SKILLS_BOOTSTRAP_FILE (empty if there is no using-superpowers).
setup_skills() { # <agent>
  AGENT_SKILLS_RESOLVED="$(python3 -I "$AGENTS_DIR/lib/skills.py" dirs)"
  AGENT_SKILLS_BOOTSTRAP_FILE=""
  if [ -n "$AGENT_SKILLS_RESOLVED" ] && [ "${AGENT_SKILLS_BOOTSTRAP:-1}" != 0 ]; then
    python3 -I "$AGENTS_DIR/lib/skills.py" bootstrap "$1" "$AGENT_HOME/skills-bootstrap.md"
    [ -s "$AGENT_HOME/skills-bootstrap.md" ] && AGENT_SKILLS_BOOTSTRAP_FILE="$AGENT_HOME/skills-bootstrap.md"
  fi
  export AGENT_SKILLS_RESOLVED AGENT_SKILLS_BOOTSTRAP_FILE
}

# Launchers: run the agent with a clean environment (plus what an interactive terminal uses).
exec_agent_interactive() { # <executable> [args...]
  scrub_env DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR WSL_DISTRO_NAME WSL_INTEROP \
    EDITOR VISUAL TERM_PROGRAM TERM_PROGRAM_VERSION
  exec "$@"
}

# Path of the pinned executable. AGENT_BIN overrides it.
agent_bin() { # <agent> <executable>
  local bin="${AGENT_BIN:-$AGENTS_PREFIX/$1/current/bin/$2}"
  if [ ! -x "$bin" ] && [ "${AGENT_DRY_RUN:-0}" != 1 ]; then
    die "$bin not found; run: agents/install.sh $1"
  fi
  printf '%s' "$bin"
}

agent_version() { # <agent>
  readlink "$AGENTS_PREFIX/$1/current" 2>/dev/null || echo "unknown"
}

# Generates a config by merging templates and replacing @@VAR@@ from the environment.
render() { # <output> <template> [template...]
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  python3 -I "$AGENTS_DIR/lib/render.py" "$out" "$@"
}

# Snapshot of the llama-server /metrics (needs --metrics and the key). The key
# goes through curl's stdin, off the command line (ps). Failure is not an error.
metrics_snapshot() { # <file>
  printf 'Authorization: Bearer %s\n' "$LOCAL_LLM_API_KEY" \
    | curl -fsS --max-time 5 -H @- "$LLM_BASE_URL/metrics" -o "$1" 2>/dev/null || rm -f "$1"
}

# Runs the agent in the workdir with a clean environment (scrub_env), records stdout/stderr,
# metrics and metadata. Returns the agent's exit code.
run_agent() { # <agent> -- <command...>
  local harness="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local out="$LOG_DIR/events.jsonl" err="$LOG_DIR/stderr.log"
  {
    echo "# @PROMPT@ = contents of $PROMPT_FILE"
    echo "# clean environment; variables passed through: $(kept_env_names)"
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
  # Client-side metrics for the eval (agent-metrics.json); never changes the exit code.
  python3 -I "$AGENTS_DIR/lib/agent_metrics.py" "$harness" "$LOG_DIR" 2>>"$err" || true
  return "$rc"
}
