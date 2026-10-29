# Pi (local)

Concorrente da Meta 1. Agente mínimo (4 ferramentas, prompt de ~1,4 mil
tokens), extensível em TypeScript, primeiro lugar no harness-bench com modelos
locais. Não tem permissões nem sandbox: o isolamento real é o container da E7.

| Item | Valor |
|---|---|
| Versão fixada | **1.4.0** (`@earendil-works/pi-coding-agent`, tag `latest`, 21/10/2026) **[verificado: npm]** |
| Nome antigo | `@mariozechner/pi-coding-agent` (parado em 0.73.1); o repositório passou para `earendil-works/pi` |
| Licença | MIT **[verificado: LICENSE e npm]** |
| Requisito | Node ≥ 22.19 (aqui: 24.21) |
| Tamanho | ~23 MB, mais dependências `@earendil-works/pi-*` |
| Executável | `pi` |

## Instalação

```bash
agents/install.sh pi
# = npm install --global --prefix ~/.local/opt/agents/pi/1.4.0 @earendil-works/pi-coding-agent@1.4.0
```

Não usar `pi update` (atualiza o próprio Pi); trocar a versão em `agents/versions.env`.

## Isolamento da configuração

- `PI_CODING_AGENT_DIR` muda o diretório do agente (padrão `~/.pi/agent`):
  `models.json`, `settings.json`, `auth.json`, `trust.json`, sessões **[verificado: docs/environment-variables.md]**.
- Interativo: `~/.local/state/local-agentic/agents/pi/pi`. Eval: `<log-dir>/home/pi`.
- `models.json` e `settings.json` são regerados a cada início.
- Continuam valendo: `AGENTS.md`/`CLAUDE.md` do diretório e dos ancestrais (sempre,
  mesmo sem confiança no projeto) e `.pi/` do projeto se ele for confiável. O
  eval usa `--no-approve` e `defaultProjectTrust: never`, que ignoram `.pi/`.

## Arquivos

| Arquivo | Função |
|---|---|
| `models.json` | Provedor `local` (llama-server, `openai-completions`) e o modelo |
| `settings.base.json` | Modelo padrão, thinking, compactação, timeouts, telemetria, extensões embutidas |
| `settings.interactive.json` / `settings.autonomous.json` | Confiança em `.pi/` do projeto |
| `extensions/guard.ts` | Permissões (o Pi não tem): lista de bloqueio, shell pergunta, escrita fora do projeto |
| `extensions/request-log.ts` | Grava cada requisição (`AGENT_LOG_REQUESTS=1`) |
| `env.sh`, `run.sh`, `pi-local` | Ambiente, contrato do eval, lançador interativo |

## Modelo e servidor

O provedor embutido `llama.cpp` do Pi exige o **modo router** do llama-server
(servidor iniciado sem `-m`) **[verificado: docs/llama-cpp.md]**. O nosso servidor
roda com um modelo fixo, então o provedor é declarado em `models.json` como
endpoint compatível, e o embutido fica desligado (`-builtin:llama.cpp`). Ele
também tentaria `http://127.0.0.1:8080`, que aqui já é usada por outro serviço local.

| Ajuste | Valor | Campo |
|---|---|---|
| Endpoint | `$LLM_BASE_URL/v1`, `api: openai-completions` | `providers.local` |
| Chave | `$LOCAL_LLM_API_KEY` (o Pi interpola `$NOME`) | `apiKey` |
| Thinking | `thinkingFormat: qwen-chat-template`: envia `chat_template_kwargs.enable_thinking` e `preserve_thinking: true` | `compat` |
| Papel `developer` | desligado (`supportsDeveloperRole: false`, usa `system`; ver issue #10741) | `compat` |
| Amostragem | temperature 0.6, top_p 0.95, top_k 20, min_p 0, presence_penalty 0 (mesclados no corpo) | `samplingParams` |
| Saída máxima | 32768 | `maxTokens` |
| Janela | 131072 | `contextWindow` |
| Compactação | quando sobram < 32768 livres (~98k usados); mantém 20k recentes | `compaction.reserveTokens`, `keepRecentTokens` |
| Timeouts | 15 min sem bytes | `httpIdleTimeoutMs: 900000` |
| Cache warming | desligado (requisições extras) | `cacheWarming: off` |

Campos conferidos em `docs/models-configuration.md` e `docs/settings.md` da tag
v1.4.0 **[verificado]**. No código (`pi-ai/src/api/openai-completions.ts`), o
formato `qwen-chat-template` envia `enable_thinking` conforme o nível de thinking
(o eval usa `--thinking medium`, que só liga o thinking) e `preserve_thinking: true`,
e o raciocínio volta no histórico pelo mesmo campo em que chegou
(`reasoning_content` no llama.cpp) **[verificado: código]**.

## Telemetria e rede

`PI_OFFLINE=1` (sem atualização automática do catálogo de modelos),
`PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY=0`, `enableInstallTelemetry: false`,
`enableAnalytics: false` **[verificado: docs]**. Extensões embutidas desligadas:
`builtin:mcp` e `builtin:llama.cpp`. `codemode` e `tool_search` existem mas ficam
inativas (fora de `defaultTools`). O Pi não tem busca na web.

## Permissões (extensão `guard.ts`)

| | interactive (`pi-local`) | autonomous (`run.sh`, ou sem interface) |
|---|---|---|
| Leitura | livre | livre |
| `write`/`edit` no projeto | livre | livre |
| `write`/`edit` fora do projeto | pergunta | bloqueado |
| `bash` | passa pela guarda; comandos que não sejam leitura simples (`ls`, `cat`, `rg`, `git status/diff/log`...) perguntam | passa pela guarda |
| Bloqueado (melhor esforço) | `lib/guard.py`: padrões de `git push`, `sudo`, `curl \| sh`, `rm` fora do projeto | o mesmo + instalações pela rede |

A extensão usa o evento `tool_call` e devolve `{ block: true, reason }`; a
confirmação usa `ctx.ui.confirm` **[verificado: tipos em core/extensions/types.ts]**.
Se a guarda faltar ou falhar, o comando é bloqueado.

## Skills (AGENT_SKILLS_DIRS)

- **Descoberta:** a extensão `extensions/skills.ts` devolve os diretórios de
  `AGENT_SKILLS_DIRS` no evento `resources_discover` (mesmo mecanismo da extensão
  oficial `.pi/extensions/superpowers.ts` do Superpowers) **[verificado: tipos da 1.4]**.
  O Pi também lê `.agents/skills` do projeto e `~/.agents/skills`.
- **Sob demanda:** só nome e descrição no prompt; o modelo lê o `SKILL.md` com `read`
  quando a tarefa pede **[verificado: docs skills.md]**.
- **Chamada explícita:** `/skill:nome` (argumentos depois do nome viram pedido).
- **Bootstrap do Superpowers:** a mesma extensão insere o `using-superpowers` + mapa
  (`pi/superpowers-tools.md`, texto da extensão oficial) como primeira mensagem do
  usuário no evento `context`, no início e depois de compactação.
- **Não verificado (E6):** carga de `-e skills.ts` em `--mode json`; o modelo lê o
  `SKILL.md` sozinho.

> **Perfil autonomous só no agent-box.** O `run.sh` recusa `AGENT_PROFILE=autonomous`
> fora do container da E7 (que marca `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> força no host e é inseguro. O ambiente do agente é limpo (`env -i` + lista de
> permitidas) e a chave do llama-server vem de `LLM_API_KEY` ou do arquivo da E5
> (ver `agents/README.md`).

## Uso não interativo

```bash
agents/pi/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# executa: pi --mode json --provider local --model qwen3.6-35b --thinking medium \
#             --no-approve -e agents/pi/extensions/guard.ts <prompt>
```

`--mode json` escreve JSONL: cabeçalho da sessão, `agent_start`, `turn_*`,
`message_*` (com `usage`), `tool_*`, `agent_end`, `agent_settled`, e sai
**[verificado: docs/json.md]**. A sessão completa fica em `home/pi/sessions/`.

## Medir o preâmbulo

`agents/measure-preamble.sh pi`: `requests.jsonl` guarda o corpo exato de cada
requisição (extensão `request-log.ts`, evento `before_provider_request`); o
`usage` do primeiro `message_end` do assistente dá os tokens.

## Problemas conhecidos com Qwen3.6 + llama.cpp

- Nenhum relato específico de Qwen3.6 no repositório do Pi até 29/10. Relacionados:
  #10741 (aberta: o Pi manda o papel `developer` e alguns servidores recusam;
  mitigado com `supportsDeveloperRole: false`) e #10522 (login do llama.cpp
  embutido, que não usamos).
- Sem permissões nem modo plano: tudo depende da extensão e do container.

## Testar primeiro na E6 (não verificado)

- `models.json` e `settings.json` aceitos sem erro (`pi --list-models local`).
- A requisição sai com `chat_template_kwargs` e os `samplingParams` (ver `requests.jsonl`).
- Carregar a extensão com `-e` fora de um pacote: o `import type` precisa ser
  apagado pelo carregador (jiti) sem resolver `@earendil-works/pi-coding-agent`.
- `ctx.ui.confirm` no TUI e o bloqueio sem interface (`--mode json`).
- Código de saída do `pi --mode json` quando o modelo falha ou o servidor cai.
- Reaproveitamento do cache entre turnos (`cached_tokens` no `usage`).
