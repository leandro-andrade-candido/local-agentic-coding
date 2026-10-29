# shellcheck shell=bash
# Ambiente do OpenCode 1.x local (incluído por run.sh e opencode-local, depois de lib/common.sh).
# Exige AGENT_HOME definido. Nada aqui lê ou grava ~/.config/opencode, ~/.local/share/opencode,
# ~/.cache/opencode nem ~/.claude.

# O OpenCode guarda config, dados (sessões, auth.json, logs), cache e estado nos
# diretórios XDG: apontá-los para AGENT_HOME isola tudo. Só vale para o processo
# do OpenCode e seus filhos (comandos que o agente roda também herdam).
export XDG_CONFIG_HOME="$AGENT_HOME/opencode/config"
export XDG_DATA_HOME="$AGENT_HOME/opencode/data"
export XDG_CACHE_HOME="$AGENT_HOME/opencode/cache"
export XDG_STATE_HOME="$AGENT_HOME/opencode/state"
mkdir -p "$XDG_CONFIG_HOME/opencode/plugins" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

export OPENCODE_DISABLE_AUTOUPDATE=1
# Sem buscar o catálogo models.dev: o provedor local está todo na config.
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
# Não ler ~/.claude/CLAUDE.md nem skills de ~/.claude e ~/.agents.
export OPENCODE_DISABLE_CLAUDE_CODE=1
export OPENCODE_DISABLE_EXTERNAL_SKILLS=1
# Plugins internos são todos de login em nuvem (Codex, Copilot, GitLab, Azure...).
export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
export OPENCODE_DISABLE_TERMINAL_TITLE=1

render "$XDG_CONFIG_HOME/opencode/opencode.json" \
  "$AGENTS_DIR/opencode/opencode.base.json" \
  "$AGENTS_DIR/opencode/opencode.$AGENT_PROFILE.json"
ln -sfn "$AGENTS_DIR/opencode/plugins/guard.js" "$XDG_CONFIG_HOME/opencode/plugins/guard.js"
