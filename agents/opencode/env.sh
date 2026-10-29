# shellcheck shell=bash
# Ambiente do OpenCode 1.x local (incluído por run.sh e opencode-local, depois de lib/common.sh).
# Exige AGENT_HOME definido. Nada aqui lê ou grava ~/.config/opencode, ~/.local/share/opencode,
# ~/.cache/opencode nem ~/.claude.

# O OpenCode guarda config, dados (sessões, auth.json, logs), cache e estado nos
# diretórios XDG: apontá-los para AGENT_HOME isola tudo. Só vale para o processo
# do OpenCode e seus filhos (comandos que o agente roda também herdam).
keep XDG_CONFIG_HOME="$AGENT_HOME/opencode/config"
keep XDG_DATA_HOME="$AGENT_HOME/opencode/data"
keep XDG_CACHE_HOME="$AGENT_HOME/opencode/cache"
keep XDG_STATE_HOME="$AGENT_HOME/opencode/state"
mkdir -p "$XDG_CONFIG_HOME/opencode/plugins" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

keep OPENCODE_DISABLE_AUTOUPDATE=1
# Sem buscar o catálogo models.dev: o provedor local está todo na config.
keep OPENCODE_DISABLE_MODELS_FETCH=1
keep OPENCODE_DISABLE_LSP_DOWNLOAD=1
# Não ler ~/.claude/CLAUDE.md nem skills de ~/.claude e ~/.agents.
# Skills e instruções de ~/.claude (CLAUDE.md, skills pessoais do Claude Code) ficam
# de fora no host. As skills de projeto (.agents/skills) continuam valendo; no host
# isso inclui ~/.agents/skills (hoje sem skills). No agent-box a HOME é vazia e
# .claude/skills do projeto também vale.
if [ "${AGENT_BOX:-0}" != 1 ]; then
  keep OPENCODE_DISABLE_CLAUDE_CODE=1
fi
# Plugins internos são todos de login em nuvem (Codex, Copilot, GitLab, Azure...).
keep OPENCODE_DISABLE_DEFAULT_PLUGINS=1
keep OPENCODE_DISABLE_TERMINAL_TITLE=1

# Skills: AGENT_SKILLS_DIRS em skills.paths; bootstrap do Superpowers pelo plugin
# skills-bootstrap.js (mesmo mecanismo do plugin oficial da 1.x).
setup_skills opencode
oc_extra=()
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  python3 -I "$AGENTS_DIR/lib/skills.py" overlay "$AGENT_HOME/opencode-skills.json" paths
  oc_extra+=("$AGENT_HOME/opencode-skills.json")
fi
render "$XDG_CONFIG_HOME/opencode/opencode.json" \
  "$AGENTS_DIR/opencode/opencode.base.json" \
  "$AGENTS_DIR/opencode/opencode.$AGENT_PROFILE.json" "${oc_extra[@]}"
ln -sfn "$AGENTS_DIR/opencode/plugins/guard.js" "$XDG_CONFIG_HOME/opencode/plugins/guard.js"
rm -f "$XDG_CONFIG_HOME/opencode/plugins/skills-bootstrap.js"
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  ln -sfn "$AGENTS_DIR/opencode/plugins/skills-bootstrap.js" "$XDG_CONFIG_HOME/opencode/plugins/skills-bootstrap.js"
fi
