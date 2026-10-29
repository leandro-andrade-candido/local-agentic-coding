# Codex CLI com o modelo local (codex-local)

O Codex CLI da OpenAI (Apache-2.0), apontado para o endpoint Responses
(`/v1/responses`) do llama-server. O Codex do dia a dia (login ChatGPT em
`~/.codex`) não é usado nem alterado.

| Item | Valor |
|---|---|
| Versão fixada | **0.165.0** (`@openai/codex`, tag `latest`, publicada em 27/10/2026; release `rust-v0.165.0` no GitHub) **[verificado: npm, GitHub]**. Já existe 0.166.0-alpha |
| Licença | Apache-2.0 **[verificado: npm, repositório openai/codex]** |
| Executável | `codex`. O pacote é um lançador de 13 KB; o binário nativo vem na dependência opcional `@openai/codex@0.165.0-linux-x64` (~446 MB descompactado) |
| API | só Responses (`wire_api = "responses"`, único valor aceito) **[verificado: config-reference]** |

## Instalação

```bash
agents/install.sh codex-local
# = npm install --global --prefix ~/.local/opt/agents/codex-local/0.165.0 @openai/codex@0.165.0
```

O pacote não tem `postinstall`; o lançador `bin/codex.js` só escolhe o binário
da plataforma **[verificado: tarball]**. Para reaproveitar o binário já instalado:
`AGENT_BIN="$(command -v codex)" agents/codex-local/codex-local`.

## Isolamento da configuração

- `CODEX_HOME` muda o diretório de estado (padrão `~/.codex`): `config.toml`,
  perfis, `auth.json`, `rules/`, sessões, logs, SQLite **[verificado: docs config-advanced]**.
- Interativo: `~/.local/state/local-agentic/agents/codex-local/codex`.
  Eval: `<log-dir>/home/codex`, novo a cada execução.
- `env.sh` remove `OPENAI_API_KEY`, `CODEX_API_KEY` e `OPENAI_BASE_URL` do ambiente.
  O diretório isolado não tem `auth.json`: o provedor local usa só a chave do
  llama-server, em `LOCAL_LLM_API_KEY` (`env_key`; ver `agents/README.md`).
- Continuam valendo: `AGENTS.md` do projeto (`project_doc_max_bytes` no padrão) e,
  só em projeto confiável, `.codex/` do repositório. No `exec` o projeto não é
  confiável, então `.codex/` do repositório não carrega.
- `config.toml` é regerado a cada início. Na TUI, a confiança na pasta (gravada
  pelo Codex em `config.toml`) não persiste: a pergunta pode voltar a cada início.

## Arquivos

| Arquivo | Função |
|---|---|
| `config.base.toml` | Provedor, modelo, janela, compactação, raciocínio, telemetria, recursos desligados, hook |
| `interactive.config.toml`, `autonomous.config.toml` | Perfis nativos do Codex (`--profile <nome>` sobrepõe `$CODEX_HOME/<nome>.config.toml`) |
| `rules/base.rules`, `rules/autonomous.rules` | Regras de execução (`prefix_rule`, `forbidden`), copiadas para `$CODEX_HOME/rules/local.rules` |
| `env.sh`, `run.sh`, `codex-local` | Ambiente, contrato do eval, lançador interativo |

## Modelo e servidor

| Ajuste | Valor |
|---|---|
| Provedor | `[model_providers.llamacpp]`: `base_url = $LLM_BASE_URL/v1`, `wire_api = "responses"`, `env_key = "LOCAL_LLM_API_KEY"`, WebSocket desligado, `stream_idle_timeout_ms` 30 min |
| Compactação | local (`capabilities.remote_compaction = "unsupported"`) a 98304 tokens (`model_auto_compact_token_limit`, 75%) |
| Janela | `model_context_window = 131072` (o Codex usa 95% dela) |
| Raciocínio | `model_supports_reasoning_summaries = false`, `model_reasoning_summary = "none"`: sem `reasoning.effort/summary`. O thinking fica ligado pelo template |
| Instruções | prompt base do Codex para modelos desconhecidos (~21 KB) sem a seção Personality (`personality = "none"`) |
| **Amostragem** | **O Codex não envia `temperature`, `top_p`, `top_k` nem `max_output_tokens`**: a requisição Responses não tem esses campos **[verificado: codex-api/src/common.rs]**. Valem os padrões do servidor, a definir na E5 |

O ID `qwen3.6-35b` não existe no catálogo do Codex, que então usa metadados
genéricos (`model_info_from_slug`) **[verificado: models-manager/src/model_info.rs]**:

- ferramenta de shell `exec_command`/`write_stdin` (unified exec), do tipo `function`;
- **sem ferramenta `apply_patch`**: na 0.165 ela só existe no formato "freeform"
  (ferramenta `custom`), que vem só para modelos do catálogo. O prompt base manda
  chamar `apply_patch` pelo shell, e o `exec_command` intercepta esse comando
  **[verificado: core/src/tools/spec_plan.rs, handlers/unified_exec/exec_command.rs]**.

Do lado do llama.cpp b11982 (`tools/server/server-chat.cpp`) **[verificado: código]**:

- só ferramentas `type: "function"` são convertidas; as outras são descartadas com aviso;
- itens de entrada aceitos: mensagens, `function_call`, `function_call_output` e
  `reasoning` **com `content` não vazio**. Qualquer outro tipo (`custom_tool_call`,
  `local_shell_call`) gera erro 400;
- `previous_response_id` não é aceito (o Codex manda o histórico inteiro, `store: false`);
- o raciocínio sai como item `reasoning` com `content: [{type: "reasoning_text"}]`, e o
  Codex reenvia o `content` quando ele tem `reasoning_text`
  (`protocol/src/models.rs`, `should_serialize_reasoning_content`). Assim o raciocínio
  volta ao llama.cpp como `reasoning_content` (preserve thinking).

## Telemetria, rede e recursos desligados

| O quê | Como |
|---|---|
| Analytics e métricas (o exportador padrão de métricas é `statsig`) | `[analytics] enabled = false`, `[otel] exporter/trace_exporter/metrics_exporter = "none"` |
| Feedback, checagem de atualização | `[feedback] enabled = false`, `check_for_update_on_startup = false` |
| Busca na web | `web_search = "disabled"`, `capabilities.external_web_access = false` |
| Conectores, catálogo remoto de plugins, fast/ultrafast, instalação de dependências de skills | `[features] apps`, `remote_plugin`, `fast_mode`, `ultrafast_mode`, `skill_mcp_dependency_install` = `false` |
| Chamadas extras ao modelo | `[features] multi_agent`, `goals`, `memories` = `false`; `[tui] auto_recap = false` |

Todas as chaves constam da Configuration Reference atual **[verificado]**.

## Permissões

| | interactive (`codex-local`) | autonomous (`run.sh`) |
|---|---|---|
| Aprovação | `on-request` (o modelo pede para sair do sandbox) | `never` |
| Sandbox | `workspace-write`: escrita no workspace e em `/tmp`, rede desligada | `danger-full-access` (isolamento = container da E7) |
| Regras `forbidden` | `git push`, `sudo`, `su`, `doas`, `pkexec`, `runuser` | as mesmas + `npm/pnpm/yarn/bun install/add/ci`, `pip install`, `python -m pip install`, `uv add/pip/tool`, `apt`, `brew`, `uvx`... |
| Hook `PreToolUse` (`matcher = "Bash"`) | `lib/guard.py` | `lib/guard.py` |

- O hook recebe `tool_name: "Bash"` e `tool_input.command`; código de saída 2
  bloqueia e o `stderr` vai para o modelo. Cobre `exec_command` e o shell; o
  `apply_patch` aparece como `apply_patch` (a guarda só olha shell) **[verificado: docs hooks]**.
- Hooks não gerenciados só rodam depois de "confiados" pelo hash. `run.sh` e
  `codex-local` passam `--dangerously-bypass-hook-trust` (flag da 0.165, conferida
  em `utils/cli/src/shared_options.rs`); o único hook é a guarda gerada daqui.
- As regras usam o formato `prefix_rule` (Starlark) em `$CODEX_HOME/rules/`; vale a
  decisão mais restritiva; scripts `bash -lc` simples são separados em comandos
  **[verificado: docs exec-policy]**. No código, `forbidden` vira bloqueio antes de
  olhar a política de aprovação (`core/src/exec_policy.rs`) **[verificado: código]**.
- O nome `local.rules` deixa o `default.rules` (onde a TUI grava os "sempre permitir") separado.

### Sandbox do Codex dentro do Docker

- No Linux o sandbox é `bwrap` + `seccomp` e precisa criar user namespaces sem
  privilégio. Sem `bwrap` no PATH, o Codex usa um auxiliar embutido com o mesmo
  requisito **[verificado: docs sandboxing]**.
- A documentação da OpenAI diz que, num container Docker, o sandbox pode não funcionar
  quando o host ou o container bloqueia namespaces, o `bwrap` setuid ou o `seccomp`.
  Nesse caso a orientação é isolar com o próprio container e rodar com
  `--sandbox danger-full-access` ou `--dangerously-bypass-approvals-and-sandbox`
  **[verificado: docs agent-approvals-security]**.
- O perfil padrão de seccomp do Docker não deixa um container sem privilégios criar
  user namespaces. Para manter o sandbox interno seria preciso afrouxar o container
  (`--security-opt seccomp=unconfined`, talvez também AppArmor). **Não verificado**
  aqui; testar na E7 com `codex sandbox linux -- true`. O Codex já cai de `--proc`
  para `--tmpfs /proc` quando a montagem de `/proc` falha (`linux-sandbox/src`).
- **Decisão:** no container da E7 o perfil autonomous usa `danger-full-access` com
  aprovação `never`, o que equivale a `--dangerously-bypass-approvals-and-sandbox`.
  A barreira é o container; regras `forbidden` e o hook continuam valendo.
- O perfil autonomous só roda dentro do agent-box (`AGENT_BOX=1`); a E7 vem antes
  da E6, então todos os testes do perfil autonomous passam pelo container. Fora
  dele, só com `AGENT_ALLOW_HOST_AUTONOMOUS=1` (inseguro); nesse caso
  `CODEX_LOCAL_SANDBOX=workspace-write` liga o sandbox do Codex no host (no WSL,
  `unshare -Ur` funciona e o Codex usa o auxiliar embutido, já que não há `bwrap`).

## Skills (AGENT_SKILLS_DIRS)

- **Descoberta:** as pastas de skill são copiadas para `$CODEX_HOME/skills`, local de
  usuário que a 0.165 ainda lê (marcado como obsoleto no código; a doc atual cita
  `~/.agents/skills`, que fica na HOME real) **[verificado: ext/skills/src/host_roots.rs]**.
  Também valem `.agents/skills` do projeto e, no host, `~/.agents/skills`.
- **Sob demanda:** o Codex põe no prompt só nome, descrição e caminho de cada skill e
  lê o `SKILL.md` quando a tarefa pede ("progressive disclosure") **[verificado: docs skills]**.
- **Chamada explícita:** `$nome-da-skill` no prompt, ou `/skills` na TUI.
- **Bootstrap do Superpowers:** em `developer_instructions` (chave de topo inserida no
  início do `config.toml`), com o `using-superpowers` e o `references/codex-tools.md`
  do próprio Superpowers. O Superpowers oficial não usa hook no Codex (confia na
  descrição da skill); aqui o texto vai sempre, porque o modelo local aciona skills com
  menos precisão. O `codex-tools.md` fala sobretudo de multiagente, que está desligado.
- **Não verificado (E6):** `$CODEX_HOME/skills` ainda carregado; `developer_instructions`
  aplicado no `exec`; custo de tokens do mapa (~1,2 mil).

> **Perfil autonomous só no agent-box.** O `run.sh` recusa `AGENT_PROFILE=autonomous`
> fora do container da E7 (que marca `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> força no host e é inseguro. O ambiente do agente é limpo (`env -i` + lista de
> permitidas) e a chave do llama-server vem de `LLM_API_KEY` ou do arquivo da E5
> (ver `agents/README.md`).

## Uso não interativo

```bash
agents/codex-local/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# executa: codex exec --json --color never --cd <dir> --skip-git-repo-check \
#   --output-last-message <log>/last-message.txt --profile autonomous \
#   --model qwen3.6-35b --dangerously-bypass-hook-trust <prompt>
```

`--json` escreve JSONL em stdout: `thread.started`, `turn.started`, `item.*`
(`agent_message`, `reasoning`, `command_execution` com `exit_code`, `file_change`...),
`turn.completed` com `usage` (`input_tokens`, `cached_input_tokens`, `output_tokens`),
`turn.failed`, `error`; o progresso vai para stderr **[verificado: docs noninteractive, exec/src/exec_events.rs]**.
A sessão completa fica em `home/codex/sessions/`.

## Medir o preâmbulo

`agents/measure-preamble.sh codex-local`: `usage` do `turn.completed` e o
`/metrics` do servidor. O Codex não grava o corpo das requisições; para ver
instruções e ferramentas, `llama-server --verbose` durante a medição.

## Testar primeiro na E6 (não verificado)

1. `codex exec` com o provedor local sem login: nenhuma tela de login, nenhum acesso
   a chatgpt.com/openai.com (rodar uma vez com a rede externa cortada).
2. Ida e volta no `/v1/responses` por 5+ turnos: itens `reasoning` reenviados com
   `content` (senão o llama.cpp responde 400 "item['content'] is not an array"),
   `function_call`/`function_call_output`, e campos que o Codex manda e o llama.cpp
   deve ignorar (`include`, `store`, `prompt_cache_key`, `client_metadata`, `tool_choice`).
3. Edição de arquivo: o Qwen3.6 precisa escrever o formato `*** Begin Patch` do
   `apply_patch` pelo shell. Contar `file_change` com falha no `events.jsonl`.
4. Hook com `--dangerously-bypass-hook-trust` dispara no `exec` e bloqueia `git push`;
   regra `forbidden` vale no modo `never` + `danger-full-access`.
5. Perfis lidos de `$CODEX_HOME/<perfil>.config.toml` com `--profile`.
6. Compactação local a ~98k e a 95% da janela.
7. Tráfego de inicialização: descoberta de modelos no `/v1/models` do llama.cpp.
8. Tamanho do preâmbulo (instruções base + ferramentas).
9. Sandbox `workspace-write` no host (WSL) com o auxiliar embutido; no container da E7, `codex sandbox linux -- true`.

## Riscos

- **Feito para modelos OpenAI:** prompt base, formato do `apply_patch` e catálogo de
  modelos assumem GPT. Com metadados genéricos o Qwen edita arquivos pelo shell, num
  formato de patch em que não foi treinado.
- **`/v1/responses` no llama.cpp** é um caminho mais novo e menos usado que
  `/chat/completions`; a conversão dos itens de raciocínio tem as exigências acima.
- **Sem limite de saída:** o Codex não manda `max_output_tokens`; sem `-n` no servidor,
  uma resposta pode ir até encher a janela.
- **Sem amostragem do cliente:** depende dos padrões do servidor (padrão do
  llama.cpp: temp 0.8, top_k 40, min_p 0.05).
- **Ritmo de versões:** 0.163 → 0.165 em 12 dias. Chaves mudam (o `--full-auto` e o
  `approval_policy = "untrusted"` já foram retirados); conferir a config a cada troca.
- **Binário grande:** ~446 MB.
