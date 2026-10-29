# shellcheck shell=bash
# Ambiente do Claude Code apontado para o llama-server local (incluído por run.sh e
# claude-local, depois de lib/common.sh). Exige AGENT_HOME definido.
# Nada aqui lê ou grava ~/.claude nem ~/.claude.json: CLAUDE_CONFIG_DIR leva
# settings, sessões, plugins, credenciais e o .claude.json para outro diretório.
# Variáveis conferidas em code.claude.com/docs/en/env-vars (29/10/2026).

keep CLAUDE_CONFIG_DIR="$AGENT_HOME/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Credenciais e provedores da conta do usuário não podem vazar para esta sessão
# (o run.sh e o lançador também limpam o ambiente; isto vale para o próprio script).
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_BETAS \
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
  ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL

# Backend: endpoint Anthropic /v1/messages do llama-server. A chave do servidor
# (LLM_API_KEY, ver lib/common.sh) vai no cabeçalho Authorization: Bearer.
keep ANTHROPIC_BASE_URL="$LLM_BASE_URL"
keep ANTHROPIC_AUTH_TOKEN="$LOCAL_LLM_API_KEY"

# Todo papel de modelo aponta para o alias local: principal, aliases opus/sonnet/
# haiku (haiku também faz as tarefas de fundo), subagentes.
keep ANTHROPIC_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_OPUS_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_SONNET_MODEL="$LLM_MODEL"
keep ANTHROPIC_DEFAULT_HAIKU_MODEL="$LLM_MODEL"
keep CLAUDE_CODE_SUBAGENT_MODEL="$LLM_MODEL"

# Janela e saída: o ID não começa com "claude-", então o valor vale sozinho.
keep CLAUDE_CODE_MAX_CONTEXT_TOKENS="$LLM_CONTEXT"
# Para ID desconhecido o padrão já é 32000; fica explícito. Aumentar reduz a janela útil antes da compactação.
keep CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000

# Tráfego não essencial, telemetria, relatórios de erro, atualizações, pesquisas.
keep CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
keep DISABLE_TELEMETRY=1
keep DISABLE_ERROR_REPORTING=1
keep DISABLE_AUTOUPDATER=1
keep DISABLE_UPDATES=1
keep CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
# A checagem do fast mode chama api.anthropic.com direto (a do WebFetch sai via skipWebFetchPreflight).
keep CLAUDE_CODE_DISABLE_FAST_MODE=1

# Compatibilidade com o llama-server: sem betas pré-lançamento (context_management,
# strict/defer_loading, output_config.format, task_budget, tool search) e sem nível
# de esforço (output_config.effort).
keep CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
keep CLAUDE_CODE_EFFORT_LEVEL=unset
# Bloco de atribuição no início do system prompt: desde a 2.1.181 é estável dentro
# de uma conversa, mas tem uma impressão digital por conversa; sem ele o prefixo é
# igual entre execuções e o cache de prompt do llama-server (--cache-ram) é reaproveitado.
keep CLAUDE_CODE_ATTRIBUTION_HEADER=0

# Sem memória automática nem tarefas em segundo plano (cada chamada extra disputa o slot único).
keep CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
keep CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1

# Prefill longo: o servidor não manda nenhum byte até o primeiro token.
keep API_TIMEOUT_MS=1800000
keep API_FORCE_IDLE_TIMEOUT=0
keep CLAUDE_STREAM_IDLE_TIMEOUT_MS=1800000

# Amostragem do cartão do modelo. O /v1/messages do llama.cpp repassa temperature,
# top_p, top_k e chat_template_kwargs; o resto vai em extra_params.
# [não verificado] se o Claude Code envia temperature própria e qual valor prevalece na mescla.
keep CLAUDE_CODE_EXTRA_BODY='{"temperature":0.6,"top_p":0.95,"top_k":20,"chat_template_kwargs":{"preserve_thinking":true},"extra_params":{"min_p":0,"presence_penalty":0}}'

# Skills: copiadas para $CLAUDE_CONFIG_DIR/skills (skills pessoais do diretório
# isolado); bootstrap do Superpowers num hook SessionStart, como o do plugin oficial.
setup_skills claude-local
python3 -I "$AGENTS_DIR/lib/skills.py" copy "$CLAUDE_CONFIG_DIR/skills"
claude_extra=()
if [ -n "$AGENT_SKILLS_BOOTSTRAP_FILE" ]; then
  claude_extra+=("$AGENTS_DIR/claude-local/settings.skills-bootstrap.json")
fi
render "$CLAUDE_CONFIG_DIR/settings.json" \
  "$AGENTS_DIR/claude-local/settings.base.json" \
  "$AGENTS_DIR/claude-local/settings.$AGENT_PROFILE.json" "${claude_extra[@]}"

# Conjunto enxuto de ferramentas (reduz o preâmbulo de ~25-31 mil tokens).
# Glob e Grep já ficam fora do padrão no Linux; a busca usa find/grep pelo Bash.
# Com skills, a ferramenta Skill entra (sem ela o modelo não carrega skills).
if [ -n "$AGENT_SKILLS_RESOLVED" ]; then
  CLAUDE_LOCAL_TOOLS="${CLAUDE_LOCAL_TOOLS:-Bash,Read,Edit,Write,Skill}"
else
  CLAUDE_LOCAL_TOOLS="${CLAUDE_LOCAL_TOOLS:-Bash,Read,Edit,Write}"
fi
