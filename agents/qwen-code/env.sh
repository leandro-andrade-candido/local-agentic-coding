# shellcheck shell=bash
# Ambiente do Qwen Code local (incluído por run.sh e qwen-local, depois de lib/common.sh).
# Exige AGENT_HOME definido. Nada aqui lê ou grava ~/.qwen.

# Diretório global isolado: settings, credenciais, sessões, memória, logs.
export QWEN_HOME="$AGENT_HOME/qwen"
mkdir -p "$QWEN_HOME"

# Telemetria e estatísticas de uso: qualquer valor diferente de true/1 desliga.
export QWEN_USAGE_STATISTICS_ENABLED=0
export QWEN_TELEMETRY_ENABLED=0
# Sem catálogo models.dev (nem download diário): janela e saída vêm da config.
export QWEN_CODE_MODELS_DEV=off
export QWEN_CODE_MODELS_DEV_REFRESH=off
# Sem limite de vida do stream (padrão 15 min); 32k tokens a ~35 tok/s já passam disso.
export QWEN_STREAM_MAX_LIFETIME_MS=0
# Título automático só roda com fastModel; desligado também por variável. [não verificado: só no doc de design]
export QWEN_DISABLE_AUTO_TITLE=1
# Aviso de YOLO sem sandbox: o isolamento vem do container (E7).
export QWEN_CODE_SUPPRESS_YOLO_WARNING=1

render "$QWEN_HOME/settings.json" \
  "$AGENTS_DIR/qwen-code/settings.base.json" \
  "$AGENTS_DIR/qwen-code/settings.$AGENT_PROFILE.json"
