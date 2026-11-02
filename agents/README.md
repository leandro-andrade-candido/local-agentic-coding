# Agentes (harnesses) para o modelo local

Configuração dos cinco agentes que a etapa E6 compara, todos apontados para o
llama-server local (Qwen3.6-35B-A3B, alias `qwen3.6-35b`, porta 9931). Desde
29/10 é uma disputa única na Meta 1 (ver seção 11 do `DIAGNOSTICO-E-PLANO.md`):
Qwen Code, Codex CLI, Pi e OpenCode (abertos) e Claude Code (fechado, gratuito).
Na E6, Claude Code local e Codex local rodam primeiro. A E7 (agent-box) vem antes
da E6: o perfil autonomous só roda dentro do container.

Nada foi instalado nesta etapa. Versões, docs e código conferidos em 29/10/2026
no npm, no GitHub (tags das versões fixadas), em code.claude.com/docs e em
developers.openai.com/codex.
Selos como no `DIAGNOSTICO-E-PLANO.md`: **[verificado]** = conferido na fonte
primária; **não verificado** = depende de teste na E6.

## Comparação

| | Qwen Code | Codex CLI (local) | Pi | OpenCode | Claude Code (local) |
|---|---|---|---|---|---|
| Pasta | [`qwen-code/`](qwen-code/README.md) | [`codex-local/`](codex-local/README.md) | [`pi/`](pi/README.md) | [`opencode/`](opencode/README.md) | [`claude-local/`](claude-local/README.md) |
| Versão fixada | 0.26.3 (28/10) | 0.165.0 (27/10) | 1.4.0 (21/10) | 1.19.5 (28/10); 2.x = `@opencode/cli` 2.2.1, não usado | 2.1.308, canal stable (22/10) |
| Pacote npm | `@qwen-code/qwen-code` | `@openai/codex` | `@earendil-works/pi-coding-agent` | `opencode-ai` | `@anthropic-ai/claude-code` |
| Licença | Apache-2.0 | Apache-2.0 | MIT | MIT | Proprietária |
| Config global padrão | `~/.qwen` | `~/.codex` | `~/.pi/agent` | `~/.config/opencode` + `~/.local/share/opencode` (XDG) | `~/.claude` + `~/.claude.json` |
| Isolamento | `QWEN_HOME` | `CODEX_HOME` | `PI_CODING_AGENT_DIR` | `XDG_CONFIG/DATA/CACHE/STATE_HOME` | `CLAUDE_CONFIG_DIR` |
| API usada | OpenAI Chat Completions `/v1` | OpenAI Responses `/v1/responses` | OpenAI Chat Completions `/v1` | OpenAI Chat Completions `/v1` (`@ai-sdk/openai-compatible`) | Anthropic `/v1/messages` |
| Amostragem do cartão | tudo (`samplingParams`) | **nenhuma**: o Codex não envia temperature/top_p/top_k nem limite de saída; vale o padrão do servidor | tudo (`samplingParams`) | tudo (temperature/top_p por agente; resto em `options`) | por `CLAUDE_CODE_EXTRA_BODY` (**não verificado** se vence a temperatura do cliente) |
| `preserve_thinking` | `extra_body` + reenvio do `reasoning_content` | itens `reasoning` reenviados com `reasoning_text`; padrão do servidor | `thinkingFormat: qwen-chat-template` | `interleaved.field: reasoning_content` + `options` | blocos `thinking` no histórico; padrão do servidor |
| Saída máx. / janela | 32768 / 131072 | sem limite do cliente / 131072 (usa 95%) | 32768 / 131072 | 32000 (teto interno) / 131072 | 32000 / 131072 |
| Compacta em | 75% (~98k) | 98304 (`model_auto_compact_token_limit`) | < 32k livres (~98k) | contexto − saída (~99k) | ~janela − saída (**medir**) |
| Permissões nativas | allow/ask/deny + modos; deny vale no YOLO | aprovação + sandbox (bwrap/seccomp) + regras `forbidden` | nenhuma (extensão nossa) | allow/ask/deny por padrão; deny vale no `--auto` | allow/ask/deny + modos; deny vale no bypass |
| Guarda comum (`lib/guard.py`) | hook `PreToolUse` | hook `PreToolUse` (`matcher = "Bash"`) | extensão `tool_call` | plugin `tool.execute.before` | hook `PreToolUse` |
| Comando não interativo | `qwen --prompt=… --output-format stream-json --approval-mode yolo` | `codex exec --json --cd … --skip-git-repo-check --profile autonomous --model … --dangerously-bypass-hook-trust …` | `pi --mode json --provider local --model … --no-approve -e guard.ts …` | `opencode run --format json --auto --title … --model llamacpp/…` | `claude -p --output-format stream-json --verbose --tools Bash,Read,Edit,Write --permission-mode bypassPermissions …` |
| Transcrição | `events.jsonl` + sessão em `home/qwen` | `events.jsonl` + sessão em `home/codex/sessions` | `events.jsonl` + sessão em `home/pi/sessions` | `events.jsonl` + SQLite em `home/opencode/data` | `events.jsonl` + JSONL em `home/claude/projects` |
| Corpo das requisições | `--openai-logging` | não grava (usar `llama-server --verbose`) | extensão `request-log.ts` | não grava (idem) | não grava (idem) |
| Preâmbulo (plano) | a medir | a medir (instruções base ~21 KB + ferramentas) | ~1,4 mil | ~7,5 mil | ~25–31 mil completo; enxuto a medir |
| Skills: descoberta | `skills.directories` | cópia em `$CODEX_HOME/skills` | extensão `skills.ts` (`resources_discover`) | `skills.paths` | cópia em `$CLAUDE_CONFIG_DIR/skills` (+ ferramenta `Skill`) |
| Skills: chamada explícita | `/<nome>` | `$<nome>` | `/skill:<nome>` | pedir a ferramenta `skill` | `/<nome>` |
| Bootstrap do Superpowers | hook `SessionStart` | `developer_instructions` | evento `context` (como a extensão oficial) | plugin `experimental.chat.messages.transform` (como o oficial 1.x) | hook `SessionStart` (como o plugin oficial) |
| Problemas com Qwen3.6 | #14203 catálogo de memória força reprocessar tudo (mitigado: memória off); #13415 janela de 1M (mitigado) | feito para modelos OpenAI: sem ferramenta `apply_patch` para ID desconhecido (edita pelo shell no formato de patch da OpenAI); llama.cpp recusa item `reasoning` sem `content` | nenhum específico; #10741 papel `developer` (mitigado) | #24316 `<tool_call>` no raciocínio trava (1.x sem manutenção; parser do llama.cpp b11982 já corta o raciocínio no `<tool_call>`) | sem suporte oficial; thinking adaptativo ignorado pelo llama.cpp |

## Instalação (E6)

Um padrão para os cinco, igual ao do llama.cpp: cada versão num prefixo
próprio, com link `current`.

```bash
agents/install.sh qwen-code     # ou codex-local | pi | opencode | claude-local | all
# npm install --global --prefix ~/.local/opt/agents/<agente>/<versão> <pacote>@<versão>
# ln -sfn <versão> ~/.local/opt/agents/<agente>/current
```

- **Nada roda com a HOME real.** O npm (cache, `~/.npmrc`, scripts de instalação) e o
  `<agente> --version` rodam com `env -i`, HOME temporária e as variáveis de
  isolamento de cada agente apontando para ela, como em `sandbox/install-agents.sh`
  (alguns agentes criam arquivos na HOME já no `--version`). Não mexe no prefixo
  global do npm (nvm) nem nas configs dos agentes.
- Integridade: `npm pack` do pacote do agente e sha512 do arquivo conferido contra
  `versions.env` antes de instalar; as dependências o npm confere pelo registro.
- Claude Code e OpenCode precisam do `postinstall` (copia o binário nativo da
  plataforma); os scripts foram lidos nos tarballs e só mexem em `node_modules`.
  O Codex não tem `postinstall`: o binário vem numa dependência opcional por plataforma.
- Espaço: ~1,2 GB no total (Codex ~446 MB, Claude Code ~292 MB, OpenCode ~214 MB,
  Qwen Code ~155 MB + opcionais, Pi ~30 MB). O plano estimava 0,3 GB.
- Desinstalar: `rm -rf ~/.local/opt/agents/<agente>`. Estado interativo:
  `rm -rf ~/.local/state/local-agentic/agents/<agente>`.

`versions.env` deste diretório é a fonte das versões. Proposta: mesclar ao
`versions.env` da raiz quando a E6 for aprovada.

## Isolamento

Nenhum agente lê ou grava `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.gemini`,
`~/.qwen`, `~/.pi` ou `~/.config/opencode`.

- **Configuração gerada, não editada à mão:** cada início monta o arquivo do
  agente a partir de `<agente>/*.base.json` + `<agente>/*.<perfil>.json`
  (`lib/render.py`: mescla e troca `@@LLM_BASE_URL@@`, `@@LLM_MODEL@@`,
  `@@INT:LLM_CONTEXT@@`... pelo ambiente; chaves `//` são comentários removidos).
  No Codex, `config.toml` e `.rules` são texto (troca com escape de string) e os
  perfis são arquivos nativos `<perfil>.config.toml` escolhidos com `--profile`.
- **Eval:** estado novo a cada execução em `<log-dir>/home/`. Nenhuma memória,
  sessão ou confiança passa de uma tarefa para outra.
- **Interativo:** `~/.local/state/local-agentic/agents/<agente>/`.
- **Ambiente limpo.** O `run.sh` e os lançadores executam o agente com o ambiente
  zerado (`unset` de tudo, num subshell, menos uma lista: `PATH`, `HOME`, `LANG`/`LC_*`,
  `TERM`, `TZ`, `TMPDIR`, `LLM_*`, `LOCAL_LLM_API_KEY`, `AGENT_*`, `GIT_AUTHOR_*`/
  `GIT_COMMITTER_*` e as variáveis que o `env.sh` do agente define com `keep`).
  `CLAUDECODE`, `CLAUDE_CODE_*`, `ANTHROPIC_*`, `OPENAI_*` e tokens da sessão que
  chamou não passam; os de `claude-local` e `codex-local` são os definidos de propósito.
  Os valores não vão para a linha de comando (`ps`). O `command.txt` lista os nomes.
- Continuam valendo, nos cinco: `AGENTS.md` (e `CLAUDE.md`/`QWEN.md`) do projeto
  e dos diretórios acima dele. O workdir do eval não deve ficar abaixo de uma pasta
  com `AGENTS.md`/`CLAUDE.md` alheio. No host, Qwen Code, Codex, Pi e OpenCode também
  leem `~/.agents/skills` da HOME real (hoje sem skills); no agent-box a HOME é vazia.

## Chave do llama-server

Desde a E5 o servidor exige chave em todas as rotas, inclusive `/metrics`.
`lib/common.sh` usa `LLM_API_KEY` (no agent-box vem do ambiente) ou, sem ela, a primeira
linha não comentada de `LLM_API_KEY_FILE` (padrão `~/.config/local-agentic/llm-api-key`,
criado por `scripts/llm key`). A chave nunca é impressa nem posta na linha de comando:
os agentes a recebem em `LOCAL_LLM_API_KEY` (Qwen `envKey`, Codex `env_key`, Pi `apiKey`,
OpenCode `{env:...}`, Claude `ANTHROPIC_AUTH_TOKEN`) e o `/metrics` a recebe pela
entrada padrão do `curl` (`-H @-`). Sem chave, um aviso e o servidor responde 401.

## Contrato com o eval

```bash
agents/<agente>/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
```

| Item | Comportamento |
|---|---|
| Ambiente | `LLM_BASE_URL` (padrão `http://127.0.0.1:9931`; `/v1` final é removido), `LLM_MODEL` (padrão `qwen3.6-35b`), `LLM_CONTEXT` (131072), `LLM_MAX_OUTPUT` (32768) |
| Perfil | `AGENT_PROFILE=autonomous` (padrão no `run.sh`). **Só dentro do agent-box**: sem `AGENT_BOX=1` (marcado pelo entrypoint da E7, conferido junto com `/.dockerenv`) o `run.sh` sai com erro 2. `AGENT_ALLOW_HOST_AUTONOMOUS=1` força no host e é **inseguro** (YOLO, `bypassPermissions`, `danger-full-access` e Pi sem permissões, sem container). `AGENT_PROFILE=interactive` roda no host |
| Execução | `cd <workdir>`, stdin em `/dev/null`, modo não interativo, aprovação automática dentro do workdir |
| Saída | código de saída do agente (0 = terminou normalmente) |
| `<log-dir>` | `events.jsonl` (stdout: JSON/stream), `stderr.log`, `run-meta.json` (versão, perfil, modelo, início/fim, segundos, código), `agent-metrics.json` (abaixo), `command.txt`, config efetiva, `guard.log` (bloqueios), `home/` (estado e sessão), `metrics-before.prom`/`metrics-after.prom` (se o servidor tiver `--metrics`) |
| Skills | `AGENT_SKILLS_DIRS` (ver Skills); `AGENT_SKILLS_BOOTSTRAP=0` tira o bootstrap do Superpowers |
| Opcionais | `AGENT_TIMEOUT=30m` (usa `timeout`), `AGENT_LOG_REQUESTS=1` (corpo das requisições, Qwen Code e Pi), `AGENT_BIN=<executável>`, `AGENT_DRY_RUN=1` (gera a config e mostra o comando; não exige o agent-box) |
| Prompt | vai como argumento; limite ~120 KB. Prompt que começa com `-` ganha uma quebra de linha no início |
| Concorrência | uma execução por vez: o servidor tem um slot só (`-np 1`) |

Lançadores interativos (perfil `interactive`): `qwen-code/qwen-local`,
`codex-local/codex-local`, `pi/pi-local`, `opencode/opencode-local`,
`claude-local/claude-local`. Rodar de dentro do projeto; aceitam as opções do próprio agente.

### `agent-metrics.json`

Depois que o agente sai, `lib/agent_metrics.py` lê o `events.jsonl` e grava
`<log-dir>/agent-metrics.json`, que o eval copia para `result.json` em
`agent.metrics`. Nunca muda o código de saída; se a leitura falhar, grava `error`.

| Campo | Significado |
|---|---|
| `turns` | respostas do modelo no laço principal |
| `requests` | requisições ao modelo vistas pelo cliente |
| `tool_calls` | chamadas de ferramenta |
| `tool_call_errors` (= `tool_errors`) | resultados marcados como erro pelo agente |
| `loops_detected` (= `loops_suspected`) | sequências de 3+ chamadas seguidas com a mesma ferramenta e os mesmos argumentos |
| `tokens_in`, `tokens_out` (= `client_tokens.input/output`) | tokens do ponto de vista do cliente, cache incluído |
| `raw_tool_call_text` | textos ou raciocínios com `<tool_call>`/`<function=` cru (chamada que o servidor não reconheceu) |
| `guard_blocks` | linhas do `guard.log` |

Os dois nomes de cada campo atendem ao `eval/README.md` (`tool_call_errors`,
`loops_detected`, `tokens_in`, `tokens_out`) e ao pedido do orquestrador
(`tool_errors`, `loops_suspected`, `client_tokens`).

| Agente | Fonte | O que fica `null` ou muda de sentido |
|---|---|---|
| Qwen Code | eventos `assistant`/`user`/`result` (formato do SDK do Claude) | `usage.input_tokens` já inclui o cache; `turns` = `num_turns` do resultado |
| Codex | `item.completed` (`command_execution`, `file_change`...) e `turn.completed.usage` | **`turns` e `requests` = `null`**: o `exec --json` não tem evento por resposta do modelo (`user_turns` traz os turnos do usuário). Erro = comando com status `failed`/`declined` ou patch `failed` (saída ≠ 0 conta como erro) |
| Pi | `message_end` do assistente, `tool_execution_end.isError`, `turn_end` | — |
| OpenCode | `tool_use` (estado `error`), `step_finish.tokens` | só a sessão principal (subagentes ficam de fora); `turns` = `requests` = passos |
| Claude Code | igual ao Qwen Code | `input_tokens` do llama.cpp exclui o cache: soma com `cache_read`/`cache_creation` |

Os formatos foram tirados da documentação e do código de cada versão e testados
com eventos sintéticos; com os agentes instalados, conferir na E6 (em especial se o
Claude Code repete blocos de conteúdo entre eventos `assistant` da mesma mensagem).

## Permissões

Três camadas, em ordem de força: o **container da E7** (a barreira), as **regras
nativas** de cada agente (ver README de cada um) e a **guarda comum** `lib/guard.py`.

### Guarda comum (melhor esforço)

A mesma guarda nos cinco, chamada antes de todo comando de shell (hook `PreToolUse`
no Qwen Code, Codex e Claude Code; plugin no OpenCode; extensão no Pi). É uma segunda
camada **conservadora**: procura padrões perigosos no texto inteiro do comando, sem
depender da estrutura, e aceita falsos positivos. Bloqueia com código 2, devolve o
motivo ao modelo e registra em `guard.log`.

| Padrão | interactive | autonomous |
|---|---|---|
| `git` e `push`/`send-pack`/`receive-pack` no mesmo comando (falso positivo aceito: `git commit -m "push"`) | bloqueia | bloqueia |
| `sudo`, `su`, `doas`, `pkexec`, `runuser` em qualquer posição | bloqueia | bloqueia |
| Download executado: pipe de `curl`/`wget` para shell, `source`, `eval`, `xargs`, `env`, `if` ou interpretador lendo o stdin; `<(curl`, `$(curl`; arquivo baixado e executado no mesmo comando | bloqueia | bloqueia |
| `rm` fora do projeto, na raiz, em `.git` ou com alvo não resolvível; `rm -r/-f` vindo de `xargs`, depois de `cd`/`pushd` não resolvível ou de `ln`; `find -delete`/`-exec rm` fora do projeto. `/tmp` liberado, menos a pasta que contém o projeto | bloqueia | bloqueia |
| Instalação: `npm/pnpm/yarn/bun install/add/ci`, `yarn` sozinho, `pip install` (inclusive `pip3.12`, `python -m pip`), `uv add/sync/pip/tool`, `uv run --with`, `npx`/`npm exec` de programa fora de `node_modules/.bin`, `poetry`, `cargo`, `go install`, `gem`, `apt`, `brew`… | permite (shell pergunta) | bloqueia |

Estrutura também é analisada: palavras-chave (`if`/`then`/`for`/`do`…) separam
comandos, opções de wrappers (`nice -n`, `time -p`, `env -S`) são puladas, e o script
de `bash -c`, heredocs e here-strings é avaliado como comando (o corpo de `apply_patch`
não, por ser conteúdo de arquivo).

**O que escapa** (o container cobre): código gerado e executado depois (`echo … > x.sh`,
depois `sh x.sh`), strings montadas em tempo de execução (`git $(printf 'p%sh' us)`),
interpretadores executando ações (`perl -e "system q(rm -rf ~)"`), e escrita fora do
projeto sem `rm` (`mv`, `truncate`, `> ~/.bashrc`). Testes: `lib/test-guard.sh`
(223 casos, incluindo os exemplos de contorno listados na verificação estática; todos passam).

### Por perfil

| | interactive (host ou box) | autonomous (só no agent-box) |
|---|---|---|
| Leitura | livre | livre |
| Ferramentas de edição | livres dentro do projeto; fora pergunta (ou é recusada) | livres dentro do projeto (Codex `danger-full-access`: sem limite de caminho) |
| Shell | pergunta (Pi: só não pergunta leitura simples) | aprovado. **O shell escreve em qualquer lugar que o usuário do processo alcance**; a guarda só pega os padrões acima |
| Web | busca negada; fetch pergunta | negados |

## Skills

Contrato: `AGENT_SKILLS_DIRS` = diretórios separados por `:`; cada um contém pastas de
skill (`<nome>/SKILL.md`). Sem a variável vale o perfil base: `/opt/skills/base` (no
agent-box) ou `$SKILLS_PREFIX/profiles/base` (no host), o primeiro que existir.
`AGENT_SKILLS_DIRS=` (vazia) desliga as skills. `lib/skills.py` resolve os diretórios,
copia ou lista as skills para cada agente e gera o bootstrap.

- **Perfil base:** `scripts/fetch-skills.sh` baixa o Superpowers fixado em
  `versions.env` (commit conferido), guarda a árvore em
  `$SKILLS_PREFIX/superpowers/<versão>/` e copia só as skills de
  `skills/profiles/base.txt` para `$SKILLS_PREFIX/profiles/base/`, com `LICENSE.superpowers`
  e `SOURCE`. Tudo só leitura. As referências cruzadas das skills do perfil
  (`subagent-driven-development/scripts`, `requesting-code-review/code-reviewer.md`,
  `using-superpowers/references`) ficam dentro do próprio perfil.
- **Perfis extras:** `scripts/fetch-skills.sh frontend` monta `profiles/frontend/`
  (`anthropic:frontend-design`, de `anthropics/skills` no commit fixado, só a pasta da
  skill, com seu `LICENSE.txt`). Entra no agente com `--skills-dir`.
- **Sob demanda nos cinco:** no prompt entram só nome e descrição de cada skill; o
  corpo é carregado quando o modelo decide ou quando a skill é chamada pelo nome
  (sintaxe por agente na tabela de comparação).
- **Bootstrap do Superpowers:** quando há `using-superpowers`, o texto da skill e o mapa
  de ferramentas do agente entram no início de cada sessão (~1 mil tokens; até ~2 mil no
  Codex). Mapas: `claude-code-tools.md` e `codex-tools.md` do próprio Superpowers; Pi,
  o texto da extensão oficial; OpenCode, o do plugin oficial com `edit`/`write` no lugar
  de `apply_patch`; Qwen Code, um mapa nosso (os nomes do Gemini CLI não valem lá).
- **Não verificado (E6):** em cada agente, se o bootstrap chega ao modelo, se o modelo
  aciona a skill certa sozinho e se a chamada explícita funciona (ver a seção Skills de
  cada README).

## Como medir o tamanho do primeiro prompt

```bash
agents/measure-preamble.sh <agente>     # tarefa trivial num repositório git vazio
```

Usa o perfil interactive (o autonomous só roda no agent-box; para medi-lo, rode o
script pelo container com `AGENT_PROFILE=autonomous`). O `/metrics` exige a chave do
servidor. Com skills, o preâmbulo inclui a lista de skills e o bootstrap; para medir
sem eles, `AGENT_SKILLS_DIRS=`.

| Fonte | O que dá | Requisito |
|---|---|---|
| `/metrics` do llama-server, antes e depois | `llamacpp:prompt_tokens_total` (processados) + `llamacpp:prompt_tokens_cached_total` (do cache); soma de todas as requisições da execução | `--metrics` no llama-server **[verificado: tools/server/README.md e server-task.cpp b11982]**. **Pedido para a E5:** incluir `--metrics` |
| `usage` da primeira resposta no `events.jsonl` | OpenAI: `prompt_tokens` e `prompt_tokens_details.cached_tokens`; Anthropic: `input_tokens` (não cacheado) + `cache_read_input_tokens` **[verificado: server-task.cpp]** | nenhum |
| Corpo da requisição | system prompt, ferramentas e mensagens exatos | Qwen Code (`requests/`), Pi (`requests.jsonl`) com `AGENT_LOG_REQUESTS=1` |
| Log do servidor | tokens do prompt por tarefa no slot e reaproveitamento de checkpoints | `llama-server --verbose` / `-lv 4` (texto exato das linhas **não verificado**) |

Para o custo de cache por turno: na tarefa real, `cached_tokens` de cada resposta
deve ficar perto do tamanho do prompt anterior; queda grande = prefixo mudou.

## Recomendações para a configuração do servidor (E4/E5)

- `--metrics` (medição acima).
- Amostragem padrão no servidor igual à do cartão (`--temp 0.6 --top-p 0.95
  --top-k 20 --min-p 0 --presence-penalty 0`): vale para qualquer cliente que não
  mande os parâmetros. O `min_p` padrão do llama.cpp é 0.05, diferente do cartão.
  **Obrigatório para o Codex**, que não envia nenhum parâmetro de amostragem.
- `-n 32768` (limite de saída padrão por requisição): o Codex não manda
  `max_output_tokens`; os outros agentes mandam o próprio limite e não são afetados.
- `--reasoning-preserve` é redundante: o b11982 já liga `preserve_reasoning` por
  padrão quando o template suporta (`common/arg.cpp`) **[verificado]**. Manter não faz mal.
- O parser do Qwen3 no b11982 encerra o raciocínio quando aparece `<tool_call>`
  (`common/parsers/qwen3-coder.cpp`), o que ataca a causa do problema #24316 do
  OpenCode **[verificado: código]**.

## Testar primeiro na E6 (não verificado)

A E7 vem antes: o perfil autonomous roda pelo agent-box. Em ordem, para cada agente instalado:

1. `AGENT_DRY_RUN=1 agents/<agente>/run.sh …`: config gerada e comando.
2. Config aceita pelo agente sem aviso (Qwen: início limpo; Pi: `pi --list-models local`;
   OpenCode: `opencode debug config`; Claude: `/status` no interativo).
3. `measure-preamble.sh`: preâmbulo, número de requisições por turno (procurar
   chamadas extras de título, memória, sugestões) e se a amostragem chegou ao
   servidor (`--verbose`).
4. Guarda: pedir ao agente `git push` e `rm -rf ../x`; deve aparecer em `guard.log`.
5. Cache entre turnos numa tarefa de 5+ passos (`cached_tokens`).
6. Itens específicos na seção "Testar primeiro" de cada README, em especial:
   Claude Code com `/v1/messages` (thinking, temperatura, `--bare`), Codex com
   `/v1/responses` (itens `reasoning` reenviados, `apply_patch` pelo shell, hook com
   `--dangerously-bypass-hook-trust`), hook do Qwen Code no YOLO, extensão do Pi
   carregada com `-e`, plugin do OpenCode e sintoma da #24316.
7. `agent-metrics.json` de cada agente bate com o que se vê no `events.jsonl`.
8. Skills: bootstrap presente na primeira requisição, chamada explícita, e se o modelo
   aciona a skill sozinho no teste de aceitação do Superpowers ("Let's make a react todo
   list" deve acionar `brainstorming` antes de escrever código).
9. Isolamento real: depois de instalar e rodar, `find -newer <marcador>` em `~/.claude`,
   `~/.claude.json`, `~/.codex`, `~/.qwen`, `~/.pi`, `~/.config/opencode`,
   `~/.local/share/opencode`, `~/.cache/opencode` e `~/.agents` não mostra nada.

## Riscos encontrados

- **OpenCode 1.x sem manutenção:** a 2.0 saiu e as issues da 1.x foram fechadas
  em massa em 11/10/2026. O que falhar na 1.19.5 fica sem correção; migrar para a
  2.x exige refazer o plugin (API de plugins mudou).
- **Qwen Code muda rápido** (0.25.0 → 0.26.3 em 23 dias, nightly diária) e liga por
  padrão recursos que chamam o modelo em segundo plano. Cada atualização pode trazer
  outra chamada extra; conferir o número de requisições por turno a cada troca de versão.
- **Slot único:** qualquer chamada paralela (título, memória, classificador,
  subagente) tira o prompt principal do cache. Tudo isso está desligado onde há
  opção; o `--cache-ram` do servidor atenua o resto.
- **Claude Code com modelo não-Claude:** sem suporte oficial. Recursos que dependem
  da Anthropic (WebSearch, fast mode, artifacts, classificador do modo `auto`) não
  funcionam; o formato de thinking adaptativo é ignorado pelo llama.cpp; a
  temperatura efetiva depende da mescla com `CLAUDE_CODE_EXTRA_BODY`.
- **Codex com modelo não-OpenAI:** prompt, catálogo e `apply_patch` assumem GPT; o
  caminho `/v1/responses` do llama.cpp é o menos testado; sem amostragem nem limite
  de saída do cliente. O sandbox do Codex (bwrap) não deve funcionar dentro do container
  da E7 sem afrouxar o seccomp do Docker: lá o perfil autonomous roda sem ele
  (`danger-full-access`), e o container é a barreira.
- **Guarda é melhor esforço:** conservadora e com falsos positivos (bloqueia texto que
  só menciona `git push` ou `sudo`, inclusive em heredoc de documentação). No modo
  autonomous o shell escreve em qualquer lugar; quem segura é o container.
- **Skills custam prompt:** ~50–150 tokens por skill mais o bootstrap, em todo prompt;
  o perfil base tem 13 skills.
- **Pi sem permissões:** a extensão é a única camada além do container; ela só vê
  as ferramentas `bash`, `write` e `edit`.
- **Prefill longo** (~100k tokens a 500–1000 tok/s = 2 a 3 min sem bytes): os
  timeouts de todos os agentes foram ampliados; se algum ainda cortar, o sintoma é
  repetição da mesma requisição (e mais 2 a 3 min de prefill).
- **Espaço** maior que o estimado (~1,2 GB contra 0,3 GB).

## Arquivos

| Caminho | Conteúdo |
|---|---|
| `versions.env` | versões, integridade npm, prefixos, padrões do servidor |
| `install.sh` | instalação isolada de um agente |
| `measure-preamble.sh` | medição do primeiro prompt |
| `lib/common.sh` | contrato do `run.sh`, geração de config, métricas, metadados |
| `lib/render.py` | mescla de JSON e troca de `@@VAR@@` (JSON, TOML, rules) |
| `lib/agent_metrics.py` | `agent-metrics.json` a partir do `events.jsonl` |
| `lib/skills.py` | `AGENT_SKILLS_DIRS`: diretórios, cópia, overlays de config e bootstrap |
| `<agente>/superpowers-tools.md` | mapa de ferramentas do bootstrap (Qwen Code, Pi, OpenCode) |
| `../scripts/fetch-skills.sh` | baixa o Superpowers fixado e monta o perfil base |
| `lib/guard.py` | guarda de comandos de shell comum |
| `lib/test-guard.sh` | casos de teste da guarda |
| `<agente>/` | config base e perfis, `env.sh`, `run.sh`, lançador interativo, README |
