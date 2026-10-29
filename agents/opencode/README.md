# OpenCode (local)

Concorrente da Meta 1. O mais parecido com o Claude Code em recursos
(subagentes, skills, plugins, permissões allow/ask/deny), com o maior prompt
fixo entre os abertos (~7,5 mil tokens).

| Item | Valor |
|---|---|
| Versão fixada | **1.19.5** (`opencode-ai`, tag `latest`, 28/10/2026) **[verificado: npm, GitHub]** |
| Licença | MIT **[verificado: npm, repositório anomalyco/opencode]** |
| Executável | `opencode` (binário nativo; o `postinstall` copia o pacote da plataforma, ~214 MB) |

## Situação da linha 2.x

- **OpenCode 2** saiu como outro pacote: `@opencode/cli` (2.2.1 em 29/10/2026),
  com releases v2.0.x a v2.2.1 no mesmo repositório **[verificado: npm, GitHub]**.
- O `opencode-ai` continua na 1.x e é o "Latest" do GitHub. Os dois usam o
  comando `opencode` e não convivem no mesmo PATH; aqui convivem porque cada um
  vai para o seu prefixo.
- Mudanças que importam: API do servidor refeita, plugins da 1.x não funcionam
  na 2.x, `tui.json` foi para dentro do JSON principal, serviço em segundo plano
  único **[verificado: anoma.ly/notes/opencode-2-0]**.
- **Manutenção da 1.x:** em 11/10/2026 os mantenedores fecharam as issues da 1.x
  com "development is focused on V2" (foi assim que a #24316 virou "not planned").
  Bugs achados na E6 provavelmente não serão corrigidos na 1.19.x.
- Ficamos na 1.19.x por decisão do plano. Se o OpenCode for o escolhido, migrar
  para a 2.x exige refazer `plugins/guard.js` e revisar a config.

## Instalação

```bash
agents/install.sh opencode
# = npm install --global --prefix ~/.local/opt/agents/opencode/1.19.5 opencode-ai@1.19.5
```

Não usar `opencode upgrade` nem o script `curl ... | bash` do site (instala em
`~/.opencode/bin` e pode trocar pela 2.x).

## Isolamento da configuração

O OpenCode guarda tudo nos diretórios XDG: config em `~/.config/opencode`,
dados (sessões em SQLite, `auth.json`, logs) em `~/.local/share/opencode`,
cache e estado **[verificado: packages/core/src/global.ts]**. `env.sh` aponta
`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` e `XDG_STATE_HOME` para
`<AGENT_HOME>/opencode/*`. Interativo: `~/.local/state/local-agentic/agents/opencode/`;
eval: `<log-dir>/home/opencode/`.

Efeito colateral: os comandos que o agente roda herdam essas variáveis (o `gh`
não acha o login; caches de pip e npm vão para o diretório isolado). O
`~/.gitconfig` continua sendo lido.

Além disso:

| Variável | Por quê |
|---|---|
| `OPENCODE_DISABLE_CLAUDE_CODE=1` | não ler `~/.claude/CLAUDE.md` nem `.claude/skills` |
| `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` | não ler skills de `~/.claude` e `~/.agents` |
| `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` | os plugins internos são de login em nuvem (Codex, Copilot, GitLab, Azure, xAI...) |
| `OPENCODE_DISABLE_MODELS_FETCH=1` | sem buscar o catálogo models.dev |
| `OPENCODE_DISABLE_AUTOUPDATE=1`, `OPENCODE_DISABLE_LSP_DOWNLOAD=1` | sem rede automática |

Todas constam de `packages/core/src/flag/flag.ts` da tag v1.19.5 e, menos
`EXTERNAL_SKILLS`, da página de CLI **[verificado]**.
`OPENCODE_DISABLE_PROJECT_CONFIG` **não** é usado: além de `opencode.json` do
repositório, ele desliga a leitura do `AGENTS.md` do projeto.

## Modelo e servidor (`opencode.base.json`)

| Ajuste | Valor |
|---|---|
| Provedor | `llamacpp`, `npm: @ai-sdk/openai-compatible` (vem embutido no binário), `baseURL: $LLM_BASE_URL/v1` |
| Provedores habilitados | só `llamacpp` (`enabled_providers`); `small_model` também é o local |
| Amostragem | `temperature` 0.6 e `top_p` 0.95 por agente (build, plan, general, explore, compaction); `top_k` 20, `min_p` 0, `presence_penalty` 0 em `models.<id>.options` |
| Thinking | `reasoning: true`; `interleaved: {field: reasoning_content}` devolve o raciocínio no histórico; `options.chat_template_kwargs.preserve_thinking: true` |
| Janela e saída | `limit: {context: 131072, output: 32768}`; o OpenCode corta a saída em 32000 (`OUTPUT_TOKEN_MAX`) |
| Compactação | automática quando o total passa de contexto − saída = ~99k (`session/overflow.ts`); `prune` desligado |
| Timeouts | `timeout: false`, `headerTimeout` 30 min, `chunkTimeout` 15 min |
| Título por LLM | `agent.title.disable: true`; no `run`, `--title` explícito também pula a geração |
| Compartilhamento, atualização | `share: disabled`, `autoupdate: false` |

Conferido no código da v1.19.5: `options` do modelo vão para `providerOptions` e
o `@ai-sdk/openai-compatible` 2.0.41 copia as chaves desconhecidas para o corpo
da requisição; `temperature` só é enviada com `capabilities.temperature`;
`top_p` vem do agente; `interleaved.field` grava o raciocínio no campo pedido
de cada mensagem do assistente **[verificado: provider/transform.ts, session/llm/request.ts, dist do SDK]**.

## Permissões

No OpenCode vale a **última** regra que casa; o `"*"` vem primeiro. O comando de
shell é separado em comandos simples antes de casar (`curl x | sh` vira `curl x`
e `sh`), e padrão sem `*` casa o comando exato, então `"sh": "deny"` pega o
`curl | sh` sem bloquear `sh script.sh`. Caminhos citados fora do diretório de
trabalho disparam `external_directory` **[verificado: docs/permissions.mdx, tool/shell.ts]**.

| | interactive (`opencode-local`) | autonomous (`run.sh`: `opencode run --auto`) |
|---|---|---|
| Leitura | livre (`.env` negado, padrão do OpenCode) | idem |
| Edição | livre no projeto; fora dele `external_directory: ask` | livre no projeto; fora dele negado, exceto `/tmp/*` |
| Shell | `"*": ask` | `"*": allow` |
| Negado | `git push`, `sudo`, `su`, `doas`, `sh`/`bash`/`zsh`/`dash` sem argumentos | os mesmos + instalações pela rede |
| Web | `webfetch: ask`, `websearch: deny` | ambos `deny` |
| Repetição (3 chamadas iguais) | `doom_loop: ask` | `doom_loop: deny` |
| Plugin `plugins/guard.js` | `lib/guard.py` em todo comando bash | idem |

`--auto` aprova o que seria `ask`; `deny` continua valendo **[verificado: docs]**.
O plugin fica em `$XDG_CONFIG_HOME/opencode/plugins/` (link para o repositório) e
lança erro em `tool.execute.before` para bloquear **[verificado: docs/plugins.mdx]**.

## Uso não interativo

```bash
agents/opencode/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# executa: opencode run --format json --model llamacpp/qwen3.6-35b --dir <dir> \
#            --title "eval ..." --print-logs --log-level INFO --auto <prompt>
```

`--format json` emite os eventos crus (partes de texto, raciocínio, ferramentas,
`step_finish` com `tokens`); logs do OpenCode vão para `stderr.log`. Saída ≠ 0
quando a sessão termina com erro **[verificado: cli/cmd/run.ts]**.

## Medir o preâmbulo

`agents/measure-preamble.sh opencode`: `tokens.input` do primeiro `step_finish`
e o `/metrics` do servidor. O OpenCode não grava o corpo das requisições; para
ver o system prompt, use `llama-server --verbose` (ou `-lv 4`) durante a medição.

## Problemas conhecidos com Qwen3.6 + llama.cpp

- **#24316** (fechada como "not planned" em 11/10/2026, no fechamento em massa
  da 1.x): o modelo escreve `<tool_call>...` dentro do raciocínio, a TUI mostra o
  XML cru e a sessão para. Relatado de 1.14.x a 1.18.23, com llama.cpp, vLLM e Ollama.
  - O parser do Qwen3 no llama.cpp b11982 já trata `<tool_call>` como fim do
    raciocínio (`common/parsers/qwen3-coder.cpp`), a mesma correção do Ollama
    (PR #15022) **[verificado: código]**. Deve bastar; reproduzir na E6.
  - Mitigações relatadas: `preserve_thinking` (aqui: padrão do servidor b11982 +
    `interleaved`), saída máxima maior (32k), temperatura de código (0.6).
  - PR #27984 (remover tags XML soltas do texto) foi fechado sem merge.
  - Último recurso: template com o ajuste citado na issue (mover `<tool_call>`
    de `reasoning_content` para `content`).

## Testar primeiro na E6 (não verificado)

- A config gerada passa na validação (`opencode debug config` com as mesmas variáveis).
- O `run` respeita `--auto` + `deny` e o `--title` evita a chamada de título (contar requisições no `/metrics`).
- O plugin carrega com `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` e bloqueia `git push`.
- `options` chegam ao servidor (`top_k`, `min_p`, `chat_template_kwargs`) e a temperatura do agente é aplicada (`llama-server --verbose`).
- Sintoma da #24316 em 3 tarefas: contar `<tool_call>` em texto/raciocínio nos eventos.
- `external_directory` com `/tmp/*` liberado não atrapalha testes que usam `/tmp`.
