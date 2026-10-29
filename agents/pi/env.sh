# shellcheck shell=bash
# Ambiente do Pi local (incluído por run.sh e pi-local, depois de lib/common.sh).
# Exige AGENT_HOME definido. Nada aqui lê ou grava ~/.pi.

# Diretório do agente isolado: models.json, settings.json, auth.json, trust.json, sessões.
keep PI_CODING_AGENT_DIR="$AGENT_HOME/pi"
mkdir -p "$PI_CODING_AGENT_DIR"
# Sem atividade de rede automática (catálogo de modelos), sem checagem de versão,
# sem telemetria de instalação nem cabeçalhos de atribuição.
keep PI_OFFLINE=1
keep PI_SKIP_VERSION_CHECK=1
keep PI_TELEMETRY=0

render "$PI_CODING_AGENT_DIR/models.json" "$AGENTS_DIR/pi/models.json"
render "$PI_CODING_AGENT_DIR/settings.json" \
  "$AGENTS_DIR/pi/settings.base.json" \
  "$AGENTS_DIR/pi/settings.$AGENT_PROFILE.json"

PI_EXT_ARGS=(-e "$AGENTS_DIR/pi/extensions/guard.ts")
# Skills: a extensão skills.ts entrega AGENT_SKILLS_RESOLVED ao Pi
# (resources_discover) e injeta o bootstrap do Superpowers (evento context),
# como a extensão oficial .pi/extensions/superpowers.ts.
setup_skills pi
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  PI_EXT_ARGS+=(-e "$AGENTS_DIR/pi/extensions/skills.ts")
fi
if [ "${AGENT_LOG_REQUESTS:-0}" = 1 ]; then
  keep AGENT_REQUEST_LOG="$AGENT_LOG_DIR/requests.jsonl"
  PI_EXT_ARGS+=(-e "$AGENTS_DIR/pi/extensions/request-log.ts")
fi
