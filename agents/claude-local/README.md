# Claude Code com o modelo local (claude-local)

Desde 29/10 disputa a Meta 1 junto com os agentes abertos (em empate técnico,
vence o aberto). É o Claude Code apontado para o endpoint Anthropic
(`/v1/messages`) do llama-server. A Anthropic
não dá suporte a modelos que não sejam Claude; tudo aqui é configuração de
gateway documentada, mas o comportamento com o Qwen3.6 só a E6 mostra.

| Item | Valor |
|---|---|
| Versão fixada | **2.1.308** (`@anthropic-ai/claude-code`, canal `stable` do npm, 22/10/2026) **[verificado: npm]** |
| Alternativa | `latest` = 2.1.312 (27/10). O Claude Code do dia a dia (2.1.311) não é usado nem alterado |
| Licença | Proprietária ("© Anthropic PBC. All rights reserved"; termos em code.claude.com/docs/en/legal-and-compliance) |
| Executável | `claude` (binário nativo de ~292 MB, copiado pelo `postinstall` do pacote da plataforma) |

## Instalação

```bash
agents/install.sh claude-local
# = npm install --global --prefix ~/.local/opt/agents/claude-local/2.1.308 @anthropic-ai/claude-code@2.1.308
```

O `postinstall` (`install.cjs`) só liga ou copia o binário da plataforma dentro
de `node_modules`; não grava em `~/.claude` nem em `~/.local/bin` **[verificado: tarball]**.
Para reaproveitar o binário já instalado em vez de baixar outro:
`AGENT_BIN="$(command -v claude)" agents/claude-local/claude-local` (a versão
então segue a do dia a dia, que se atualiza sozinha).

## Isolamento da configuração

`CLAUDE_CONFIG_DIR` move settings, sessões, plugins, credenciais **e o
`.claude.json`** para outro diretório **[verificado: docs env-vars e claude-directory]**.

- Interativo: `~/.local/state/local-agentic/agents/claude-local/claude`.
- Eval: `<log-dir>/home/claude` (transcrição JSONL em `projects/`).
- `env.sh` também remove do ambiente `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`
  e as seleções de Bedrock/Vertex/Foundry, para a conta do usuário não vazar
  para o servidor local nem a sessão local cair na nuvem.
- `~/.claude` e `~/.claude.json` não são lidos: o `CLAUDE.md` pessoal e os plugins
  do dia a dia ficam de fora. O `CLAUDE.md`/`AGENTS.md` do projeto continua valendo.

## Variáveis (`env.sh`)

Todas conferidas na página de variáveis (code.claude.com/docs/en/env-vars) em 29/10/2026.

| Variável | Valor | Para quê |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `$LLM_BASE_URL` (sem `/v1`) | endpoint Anthropic do llama-server |
| `ANTHROPIC_AUTH_TOKEN` | fictícia | vai como `Authorization: Bearer`; o servidor não confere |
| `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_MODEL` | `qwen3.6-35b` | modelo principal |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`, `_SONNET_`, `_HAIKU_` | idem | aliases; o haiku também faz as tarefas de fundo |
| `CLAUDE_CODE_SUBAGENT_MODEL` | idem | subagentes e agentes de workflow |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | 131072 | janela presumida; sem ela o ID desconhecido vale 200k e a compactação passa do limite do servidor. Vale sozinha porque o ID não começa com `claude-` |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | 32000 | padrão para ID desconhecido, explícito |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | 1 | atualizações, telemetria, relatórios de erro, feature flags, notas de versão |
| `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` | 1 | redundante com a anterior, explícito |
| `DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` | 1 | versão fixa |
| `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` | 1 | sem pesquisa de qualidade |
| `CLAUDE_CODE_DISABLE_FAST_MODE` | 1 | a checagem do fast mode chama `api.anthropic.com` direto, ignorando o `BASE_URL` |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | 1 | tira `context_management`, `strict`/`defer_loading`, `output_config.format`, `task_budget` e tool search, que o llama.cpp não conhece |
| `CLAUDE_CODE_EFFORT_LEVEL` | `unset` | não envia `output_config.effort` |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | 0 | tira o bloco de atribuição do início do system prompt (ver abaixo) |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY` | 1 | sem memória automática |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` | 1 | sem tarefas em segundo plano disputando o slot único |
| `API_TIMEOUT_MS` | 1800000 | espera pelos cabeçalhos; o prefill de ~100k tokens leva minutos |
| `API_FORCE_IDLE_TIMEOUT` | 0 | desliga o corte de 5 min sem bytes |
| `CLAUDE_STREAM_IDLE_TIMEOUT_MS` | 1800000 | vigias de stream (teto de 30 min) |
| `CLAUDE_CODE_EXTRA_BODY` | temperature 0.6, top_p 0.95, top_k 20, `chat_template_kwargs.preserve_thinking`, `extra_params: {min_p: 0, presence_penalty: 0}` | amostragem do cartão; o `/v1/messages` do llama.cpp repassa `temperature`, `top_p`, `top_k`, `chat_template_kwargs` e o objeto `extra_params` **[verificado: server-chat.cpp b11982]** |

Fora da lista, de propósito: `DISABLE_NON_ESSENTIAL_MODEL_CALLS` (não existe na
documentação atual) e `DISABLE_PROMPT_CACHING` (só afeta marcadores
`cache_control`, que o llama.cpp ignora).

**Bloco de atribuição:** o Claude Code põe no início do system prompt um bloco com
a versão e uma impressão digital da conversa. Desde a 2.1.181 ele é estável dentro
da conversa quando há `ANTHROPIC_BASE_URL`, então o cache de um turno para o outro
funciona mesmo com ele. Com `0`, o prefixo também fica igual **entre** execuções e o
`--cache-ram` do llama-server reaproveita o preâmbulo de uma tarefa para a próxima
**[verificado: docs llm-gateway-protocol, "System prompt attribution block"]**.

## Preâmbulo enxuto

| Medida | Efeito |
|---|---|
| `--tools "Bash,Read,Edit,Write"` (`CLAUDE_LOCAL_TOOLS`) | só as ferramentas essenciais. Sem `Agent` não há subagentes; Glob/Grep já ficam fora do padrão no Linux (busca por `find`/`grep` no Bash); as ferramentas de tarefas não vêm para IDs desconhecidos |
| `--exclude-dynamic-system-prompt-sections` | contexto por usuário/máquina sai do system prompt e vai para a primeira mensagem |
| `--setting-sources user` | só o `settings.json` do diretório isolado; hooks e permissões do repositório não carregam |
| `CLAUDE_LOCAL_BARE=1` → `--bare` | prompt mínimo, só Bash/leitura/edição, sem hooks, skills, CLAUDE.md nem lembretes de sistema. **Não verificado** com `ANTHROPIC_AUTH_TOKEN` (a doc fala em `ANTHROPIC_API_KEY` ou `apiKeyHelper`) |

Os ~25–31 mil tokens do plano são do conjunto completo; o tamanho com o
conjunto enxuto é a primeira medida da E6.

## Permissões

Arquivo `settings.json` gerado em `CLAUDE_CONFIG_DIR` (escopo user).
Regras `deny` valem em todos os modos, inclusive `bypassPermissions`; o hook
`PreToolUse` que sai com código 2 bloqueia antes das regras
**[verificado: docs permissions e permission-modes]**. Regra `Bash(...)` sem `*`
casa o comando exato e comandos compostos são separados, então `Bash(sh)` pega o
`sh` de `curl ... | sh`.

| | interactive (`claude-local`) | autonomous (`run.sh`) |
|---|---|---|
| Modo | `acceptEdits`: edições e comandos de arquivo comuns no diretório de trabalho sem perguntar; Bash pergunta | `--permission-mode bypassPermissions` (exige usuário não root) |
| Negado | WebSearch, `git push`, `sudo`, `su`, `doas`, `sh`/`bash`/`zsh`/`dash` sem argumentos, `rm -rf /`, `~`, `$HOME` | os mesmos + WebFetch + instalações pela rede |
| Pergunta | WebFetch | — |
| Hook | `lib/guard.py` em todo Bash | idem |

Só usamos chaves e tipos conferidos em `settings-reference`: um valor de tipo
errado faz o Claude Code ignorar o arquivo inteiro, e com ele as permissões.

## Uso não interativo

```bash
agents/claude-local/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# executa: claude -p --output-format stream-json --verbose --model qwen3.6-35b \
#   --tools Bash,Read,Edit,Write --setting-sources user \
#   --exclude-dynamic-system-prompt-sections --permission-mode bypassPermissions <prompt>
```

Saída 0 em sucesso e diferente de 0 em falha; negações aparecem como
`permission_denied` no stream e em `permission_denials` no resultado final
**[verificado: docs headless]**.

## Medir o preâmbulo

`agents/measure-preamble.sh claude-local`: o `usage` da primeira mensagem do
assistente no stream (`input_tokens` + `cache_read_input_tokens`; no llama.cpp o
`input_tokens` é só a parte não reaproveitada do cache) e o `/metrics`.

## Riscos com backend local

- **Thinking:** para ID desconhecido o Claude Code manda o formato adaptativo de
  thinking. O llama.cpp só converte `thinking.type == "enabled"` (vira limite de
  tokens de raciocínio); o adaptativo é ignorado e o modelo pensa sem limite, o
  padrão do template. Com `MAX_THINKING_TOKENS` o Claude Code passaria a mandar
  um orçamento, e o llama.cpp cortaria o raciocínio nele.
- **Preserve thinking:** os blocos `thinking` voltam no histórico e o llama.cpp os
  converte em `reasoning_content`; o servidor b11982 já liga `preserve_reasoning`
  por padrão. Falta medir se o prefixo bate entre turnos.
- **Recursos que dependem da Anthropic** não funcionam: WebSearch, fast mode,
  artifacts, remote control, notificações push, classificador do modo `auto`.
- **Chamadas de fundo** (resumos, títulos, checagens) usam o modelo principal e
  disputam o slot único; o conjunto enxuto reduz, mas não zera.

## Testar primeiro na E6 (não verificado)

- Ida e volta completa no `/v1/messages`: `tool_use`, `tool_result`, blocos `thinking`
  sem assinatura, `count_tokens`.
- Se o Claude Code manda `temperature` própria e qual valor vence na mescla com
  `CLAUDE_CODE_EXTRA_BODY` (ver a linha de parâmetros do slot com `llama-server --verbose`).
- Limiar real de compactação com janela 131072 e saída 32000 (`/context` no interativo).
- Tamanho do preâmbulo com `--tools Bash,Read,Edit,Write` e com `--bare`.
- Segunda execução igual reaproveita o preâmbulo (`cache_read_input_tokens` alto).
- Primeiro uso interativo com `CLAUDE_CONFIG_DIR` novo: telas de boas-vindas e tema.
- Tráfego de inicialização (`HEAD /api/hello`) recebe 404 do llama-server sem efeito.
