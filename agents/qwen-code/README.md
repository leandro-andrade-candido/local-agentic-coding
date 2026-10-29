# Qwen Code (local)

Concorrente da Meta 1 (disputa única desde 29/10). Fork do Gemini CLI mantido pela equipe do Qwen, com
provedores OpenAI-compatíveis, hooks no formato do Claude Code, regras de
permissão e modo headless.

| Item | Valor |
|---|---|
| Versão fixada | **0.26.3** (`@qwen-code/qwen-code`, tag `latest` no npm, publicada em 28/10/2026) **[verificado: npm]** |
| Outras linhas | `preview` 0.26.3-preview.0 e `nightly` diária; não usar |
| Licença | Apache-2.0 (arquivo `LICENSE` do repositório; o `package.json` publicado não traz o campo) **[verificado]** |
| Requisito | Node ≥ 22 (aqui: 24.21) |
| Tamanho | ~155 MB descompactado, mais dependências opcionais (bun, node-pty, sharp) |
| Executável | `qwen` |

## Instalação

```bash
agents/install.sh qwen-code
# = npm install --global --prefix ~/.local/opt/agents/qwen-code/0.26.3 @qwen-code/qwen-code@0.26.3
#   e link ~/.local/opt/agents/qwen-code/current -> 0.26.3
```

Nada vai para o prefixo global do npm (nvm). A atualização automática fica
desligada na config (`general.enableAutoUpdate: false`), senão o Qwen Code
tentaria `npm install -g` no prefixo global.

## Isolamento da configuração

- `QWEN_HOME` muda o diretório global (padrão `~/.qwen`): settings, credenciais,
  memória, skills, sessões e logs **[verificado: docs/users/configuration/settings.md, tabela de variáveis]**.
  `QWEN_RUNTIME_DIR` (sessões, logs) segue o `QWEN_HOME` quando não definido.
- Interativo: `QWEN_HOME=~/.local/state/local-agentic/agents/qwen-code/qwen`.
  Eval: `QWEN_HOME=<log-dir>/home/qwen`, novo a cada execução.
- O `settings.json` é **regerado a cada início** a partir de `settings.base.json` +
  `settings.<perfil>.json` (`agents/lib/render.py`). Mudanças feitas por `/settings`
  ou `/model` duram só até a próxima vez; edite os modelos no repositório.
- Continuam valendo, por desenho do Qwen Code: `.qwen/settings.json`, `QWEN.md` e
  `AGENTS.md` do projeto, e `~/.env` (lido depois de `$QWEN_HOME/.env`, sem sobrepor
  variáveis já definidas). Hoje não existe `~/.env` nem `~/.qwen` nesta máquina.

## Arquivos

| Arquivo | Função |
|---|---|
| `settings.base.json` | Provedor local, amostragem, janela, compactação, telemetria, ferramentas e hook |
| `settings.interactive.json` | Permissões do uso diário |
| `settings.autonomous.json` | Permissões do eval (YOLO + lista de bloqueio) |
| `env.sh` | Variáveis de ambiente e geração do `settings.json` |
| `run.sh` | Contrato do eval |
| `qwen-local` | Lançador interativo (`cd projeto && .../qwen-local`) |

## Modelo e servidor

| Ajuste | Valor | Onde |
|---|---|---|
| Endpoint | `$LLM_BASE_URL/v1`, provedor `openai` (Chat Completions) | `modelProviders.openai[0]` |
| Chave | a do llama-server, por `envKey: LOCAL_LLM_API_KEY` (ver chave em `agents/README.md`) | idem |
| Amostragem | temperature 0.6, top_p 0.95, top_k 20, min_p 0, presence_penalty 0 | `generationConfig.samplingParams` |
| Saída máxima | 32768 (`max_tokens` explícito; desliga a escalada automática para 64k) | idem |
| Thinking | `chat_template_kwargs.preserve_thinking: true` | `generationConfig.extra_body` |
| Janela | 131072 | `generationConfig.contextWindowSize` |
| Compactação | a 75% da janela (~98k) | `context.autoCompactThreshold: 0.75` |
| Timeouts | sem limite por requisição; 15 min sem bytes no stream; sem limite de vida do stream | `timeout: 0`, `streamIdleTimeoutMs`, `QWEN_STREAM_MAX_LIFETIME_MS=0` |

Todas as chaves acima constam de `docs/users/configuration/settings.md` e
`model-providers.md` da tag v0.26.3 **[verificado]**. Detalhes conferidos no código:

- Com `samplingParams` definido, as chaves vão como estão para o servidor e o
  Qwen Code não injeta o próprio campo de raciocínio **[verificado: doc model-providers]**.
- Para IDs que começam com `qwen` fora da DashScope, o perfil de raciocínio é
  `qwen-chat-template` e o histórico reenvia o `reasoning_content` de cada turno
  (copiado também para o campo `reasoning`) **[verificado: provider/default.ts]**.
  Isso é o que o `preserve_thinking` precisa.
- Sem `contextWindowSize`, um ID `qwen3.6-*` cai na regra de 1M tokens e a
  compactação nunca acontece (issue #13415, aberta) **[verificado]**.

## Telemetria, rede e chamadas extras

| O quê | Como |
|---|---|
| Estatísticas de uso e telemetria | `privacy.usageStatisticsEnabled: false`, `telemetry.enabled: false`, `QWEN_USAGE_STATISTICS_ENABLED=0`, `QWEN_TELEMETRY_ENABLED=0` |
| Catálogo models.dev (download diário) | `QWEN_CODE_MODELS_DEV=off`, `QWEN_CODE_MODELS_DEV_REFRESH=off` |
| Atualização automática | `general.enableAutoUpdate: false` |
| Busca na web, geração de imagem, artifacts, cron, autofix de PR | `tools.disabled` (o perfil autonomous também desliga `web_fetch`, `ask_user_question` e o modo plano) |
| Memória automática, "dream", auto-skill | `memory.*: false` (ver problema 1 abaixo) |
| Sugestões de continuação, feedback, resumo de ferramentas, recap | `ui.enableFollowupSuggestions`, `ui.enableUserFeedback`, `experimental.emitToolUseSummaries`, `general.showSessionRecap`: `false` |
| Título automático | só roda com `fastModel` (não configurado); também `QWEN_DISABLE_AUTO_TITLE=1` **[não verificado: citado só no doc de design]** |
| Mensagens entre sessões | `agents.crossSessionMessaging: false` |
| Co-autoria em commits e notas git | `general.gitCoAuthor.commit/pr: false` |

Com um slot só no servidor, cada chamada em segundo plano tira o prompt
principal do cache. Por isso todas as chamadas extras ficam desligadas.

## Permissões

O Qwen Code decide nesta ordem: `deny` > `ask` > `allow` > modo de aprovação.
Regras `Bash(...)` sem `*` casam por prefixo de palavra (`Bash(git push)` pega
`git push origin main`). Comandos compostos são separados antes da checagem.

| | interactive (`qwen-local`) | autonomous (`run.sh`) |
|---|---|---|
| Modo | `default`: edição e shell perguntam | `yolo` (`--approval-mode yolo`) |
| Leitura | `allow: Read` (leitura, grep, glob, ls) | livre |
| Edição | `allow: Edit(/**)`, só dentro do projeto (`/` = raiz do projeto). As ferramentas de edição recusam caminhos fora do workspace | livre dentro do workspace |
| Shell | pergunta | livre |
| Bloqueado (regra) | `git push`, `sudo`, `su`, `doas`, `pkexec` | os mesmos + `npm/pnpm/yarn/bun install/add/ci`, `pip install`, `uv add`, `apt`, `brew` |
| Bloqueado (hook, melhor esforço) | `lib/guard.py`: padrões de `git push`, `sudo`, `curl \| sh`, `rm` fora do projeto | o mesmo + instalações pela rede |

No YOLO, `deny` continua bloqueando (`permissionFlow.ts`: `deny` é checado antes
do modo) **[verificado: código]**; `ask` e `allow` não fazem efeito. O hook roda em
`PreToolUse` com `matcher: ^run_shell_command$`; código de saída 2 bloqueia e o
motivo vai para o modelo **[verificado: docs/users/features/hooks.md]**.
Não usamos o modo `auto`: ele chama um classificador LLM a cada ação, o que
custa uma requisição extra no slot único.

## Skills (AGENT_SKILLS_DIRS)

- **Descoberta:** os diretórios de `AGENT_SKILLS_DIRS` entram em `skills.directories`
  (nível "user"; cada diretório é varrido um nível abaixo, `<nome>/SKILL.md`)
  **[verificado: docs settings.md]**. O Qwen Code também lê `$QWEN_HOME/skills`,
  `.qwen/skills` e `.agents/skills` do projeto e `~/.agents/skills` da HOME real
  (no host; no agent-box a HOME é vazia).
- **Sob demanda:** só nome e descrição entram na lista da ferramenta `skill`; o corpo
  é carregado quando o modelo chama a skill **[verificado: docs features/skills.md]**.
- **Chamada explícita:** `/<nome-da-skill>` (ou o painel `/skills`).
- **Bootstrap do Superpowers:** hook `SessionStart` (`startup|resume|clear|compact`)
  que devolve `hookSpecificOutput.additionalContext` com o `using-superpowers` e o mapa
  `qwen-code/superpowers-tools.md` (`settings.skills-bootstrap.json`).
- **Mapa de ferramentas:** o Qwen Code é um fork do Gemini CLI, mas os nomes das
  ferramentas mudaram (`edit` e não `replace`, `skill` e não `activate_skill`, `agent`
  e não `invoke_agent`, `todo_write` desligado por padrão; conferido em
  `packages/core/src/tools/tool-names.ts`). Por isso o mapa é nosso, não o
  `gemini-tools.md` do Superpowers.
- **Não verificado (E6):** o `additionalContext` do `SessionStart` chega ao modelo no
  modo `-p`; o modelo aciona a skill certa sozinho; custo de tokens da lista.

> **Perfil autonomous só no agent-box.** O `run.sh` recusa `AGENT_PROFILE=autonomous`
> fora do container da E7 (que marca `AGENT_BOX=1`); `AGENT_ALLOW_HOST_AUTONOMOUS=1`
> força no host e é inseguro. O ambiente do agente é limpo (`env -i` + lista de
> permitidas) e a chave do llama-server vem de `LLM_API_KEY` ou do arquivo da E5
> (ver `agents/README.md`).

## Uso não interativo

```bash
agents/qwen-code/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
# executa: qwen --prompt=<conteúdo> --output-format stream-json --approval-mode yolo
```

- `events.jsonl`: mensagens `system`, `assistant` (com `usage`), resultados de
  ferramenta e `result` final.
- Códigos de saída do Qwen Code: 0 sucesso, 53 limite de turnos, 55 orçamento
  (`--max-wall-time`/`--max-tool-calls`), 130 SIGINT **[verificado: docs/users/features/headless.md]**.
- `AGENT_LOG_REQUESTS=1` acrescenta `--openai-logging --openai-logging-dir <log>/requests`
  (corpo de cada requisição e resposta).
- O prompt vai como argumento (`--prompt=`); prompts acima de ~120 KB são recusados.

## Medir o preâmbulo

`agents/measure-preamble.sh qwen-code`. A primeira requisição gravada em
`requests/` mostra system prompt, ferramentas e mensagens; o `usage` da primeira
resposta no `events.jsonl` dá `prompt_tokens`; o `/metrics` do servidor dá o total
processado. O Qwen Code adia ferramentas pouco usadas (`tools.toolSearch.enabled`,
padrão ligado), o que reduz o preâmbulo.

## Problemas conhecidos com Qwen3.6 + llama.cpp

1. **Catálogo de memória no fim da requisição** (#14203, aberta desde 0.25.1): com
   memória automática ligada, o catálogo é anexado no fim de cada requisição e
   some na seguinte. Em modelos híbridos como o Qwen3.6, o llama.cpp só volta a
   checkpoints perto do fim do prompt, então cada passo reprocessa a conversa
   inteira. **Mitigação:** `memory.enableManagedAutoMemory: false` (conferido no
   código: sem memória gerenciada o catálogo fica vazio).
2. **Janela de 1M presumida para `qwen3.x`** (#13415, aberta). **Mitigação:**
   `contextWindowSize: 131072`.
3. **Recursos que mudam o contexto** (#14215, aberta): sugestões, atualizações de
   memória e retomada de sessão alteram o prompt e derrubam o cache em servidores
   locais. **Mitigação:** os recursos estão desligados.
4. Hooks `PreToolUse` que falham (erro ≠ 2) deixam o comando passar (#12457,
   aberta, citada para `qwen serve`). A guarda só usa saída 0 ou 2; as regras
   `deny` nativas são a primeira camada.

## Testar primeiro na E6 (não verificado)

- O `settings.json` gerado é aceito pela 0.26.3 sem aviso (`goals.modelProposed`,
  nomes em `tools.disabled`, `hooks`).
- O hook de guarda dispara em `-p` com `--approval-mode yolo` e bloqueia `git push`.
- Nenhuma requisição extra por turno: contar `requests/` contra os turnos do `events.jsonl`.
- O reaproveitamento de cache entre turnos: `prompt_tokens_details.cached_tokens`
  perto do tamanho do prompt anterior.
- O campo extra `reasoning` (cópia do `reasoning_content`) não atrapalha o template do Qwen3.6.
- `QWEN_DISABLE_AUTO_TITLE` (só no doc de design).
- `--bare` (só `read_file`, `edit`, `run_shell_command`) como variante de preâmbulo mínimo:
  ignora boa parte da config; testar se o provedor local continua valendo.
