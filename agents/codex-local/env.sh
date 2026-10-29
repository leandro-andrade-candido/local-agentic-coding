# shellcheck shell=bash
# Ambiente do Codex CLI apontado para o llama-server local (incluído por run.sh e
# codex-local, depois de lib/common.sh). Exige AGENT_HOME definido.
# Nada aqui lê ou grava ~/.codex (onde fica o login ChatGPT do uso diário):
# CODEX_HOME leva config, auth, regras, sessões, logs e estado para outro lugar.

keep CODEX_HOME="$AGENT_HOME/codex"
mkdir -p "$CODEX_HOME/rules"

# Credenciais da OpenAI não podem chegar a esta sessão (nem ao servidor local);
# o run.sh e o lançador também limpam o ambiente.
unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL OPENAI_ORG_ID OPENAI_PROJECT_ID

# Compactação automática a 75% da janela.
keep CODEX_AUTO_COMPACT=$(( LLM_CONTEXT * 3 / 4 ))

render "$CODEX_HOME/config.toml" "$AGENTS_DIR/codex-local/config.base.toml"

# Skills: copiadas para $CODEX_HOME/skills (local "user" que o Codex 0.165 ainda lê;
# a doc atual cita ~/.agents/skills, que fica na HOME real). Bootstrap do Superpowers
# em developer_instructions (chave de topo, inserida no início do config.toml).
setup_skills codex-local
python3 -I "$AGENTS_DIR/lib/skills.py" copy "$CODEX_HOME/skills"
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  python3 -I -c 'import json, sys
cfg, boot = sys.argv[1], sys.argv[2]
text = open(cfg, encoding="utf-8").read()
line = "developer_instructions = " + json.dumps(open(boot, encoding="utf-8").read()) + "\n"
open(cfg, "w", encoding="utf-8").write(line + text)' "$CODEX_HOME/config.toml" "$AGENT_SKILLS_BOOTSTRAP_FILE"
fi
# Perfis nativos do Codex: --profile <nome> sobrepõe $CODEX_HOME/<nome>.config.toml.
cp "$AGENTS_DIR/codex-local/interactive.config.toml" "$CODEX_HOME/interactive.config.toml"
cp "$AGENTS_DIR/codex-local/autonomous.config.toml" "$CODEX_HOME/autonomous.config.toml"
# Regras de execução: base nos dois perfis, instalações bloqueadas só no autonomous.
# O nome local.rules deixa o default.rules (aprovações "sempre" da TUI) intacto.
if [ "$AGENT_PROFILE" = autonomous ]; then
  render "$CODEX_HOME/rules/local.rules" \
    "$AGENTS_DIR/codex-local/rules/base.rules" "$AGENTS_DIR/codex-local/rules/autonomous.rules"
else
  render "$CODEX_HOME/rules/local.rules" "$AGENTS_DIR/codex-local/rules/base.rules"
fi

# --dangerously-bypass-hook-trust: o Codex só roda hooks não gerenciados depois de
# "confiar" no hash deles; o único hook é a guarda gerada acima.
CODEX_COMMON_ARGS=(--profile "$AGENT_PROFILE" --model "$LLM_MODEL" --dangerously-bypass-hook-trust)
