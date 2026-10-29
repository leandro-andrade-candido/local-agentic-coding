# shellcheck shell=bash
# Ambiente do Qwen Code local (incluído por run.sh e qwen-local, depois de lib/common.sh).
# Exige AGENT_HOME definido. Nada aqui lê ou grava ~/.qwen.

# Diretório global isolado: settings, credenciais, sessões, memória, logs.
keep QWEN_HOME="$AGENT_HOME/qwen"
mkdir -p "$QWEN_HOME"

# Telemetria e estatísticas de uso: qualquer valor diferente de true/1 desliga.
keep QWEN_USAGE_STATISTICS_ENABLED=0
keep QWEN_TELEMETRY_ENABLED=0
# Sem catálogo models.dev (nem download diário): janela e saída vêm da config.
keep QWEN_CODE_MODELS_DEV=off
keep QWEN_CODE_MODELS_DEV_REFRESH=off
# Sem limite de vida do stream (padrão 15 min); 32k tokens a ~35 tok/s já passam disso.
keep QWEN_STREAM_MAX_LIFETIME_MS=0
# Título automático só roda com fastModel; desligado também por variável. [não verificado: só no doc de design]
keep QWEN_DISABLE_AUTO_TITLE=1
# Aviso de YOLO sem sandbox: o isolamento vem do container (E7).
keep QWEN_CODE_SUPPRESS_YOLO_WARNING=1

# Skills: diretórios de AGENT_SKILLS_DIRS em skills.directories (lidos no nível
# "user", um nível abaixo de cada diretório) e bootstrap do Superpowers num hook
# SessionStart (additionalContext), como o hook do Claude Code.
setup_skills qwen-code
qwen_extra=()
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  python3 -I "$AGENTS_DIR/lib/skills.py" overlay "$AGENT_HOME/qwen-skills.json" directories
  qwen_extra+=("$AGENT_HOME/qwen-skills.json")
fi
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  qwen_extra+=("$AGENTS_DIR/qwen-code/settings.skills-bootstrap.json")
fi
render "$QWEN_HOME/settings.json" \
  "$AGENTS_DIR/qwen-code/settings.base.json" \
  "$AGENTS_DIR/qwen-code/settings.$AGENT_PROFILE.json" "${qwen_extra[@]}"
