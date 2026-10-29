# Agentes (harnesses) para o modelo local

Configuração dos cinco agentes que a etapa E6 compara, todos apontados para o
llama-server local (Qwen3.6-35B-A3B, alias `qwen3.6-35b`, porta 9931). Desde
29/10 é uma disputa única na Meta 1 (ver seção 11 do `DIAGNOSTICO-E-PLANO.md`):
Qwen Code, Codex CLI, Pi e OpenCode (abertos) e Claude Code (fechado, gratuito).
Na E6, Claude Code local e Codex local rodam primeiro.

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
| Problemas com Qwen3.6 | #14203 catálogo de memória força reprocessar tudo (mitigado: memória off); #13415 janela de 1M (mitigado) | feito para modelos OpenAI: sem ferramenta `apply_patch` para ID desconhecido (edita pelo shell no formato de patch da OpenAI); llama.cpp recusa item `reasoning` sem `content` | nenhum específico; #10741 papel `developer` (mitigado) | #24316 `<tool_call>` no raciocínio trava (1.x sem manutenção; parser do llama.cpp b11982 já corta o raciocínio no `<tool_call>`) | sem suporte oficial; thinking adaptativo ignorado pelo llama.cpp |

## Instalação (E6)

Um padrão para os cinco, igual ao do llama.cpp: cada versão num prefixo
próprio, com link `current`.

```bash
agents/install.sh qwen-code     # ou codex-local | pi | opencode | claude-local | all
# npm install --global --prefix ~/.local/opt/agents/<agente>/<versão> <pacote>@<versão>
# ln -sfn <versão> ~/.local/opt/agents/<agente>/current
```

- Não mexe no prefixo global do npm (nvm), em `~/.npmrc` nem nas configs dos
  agentes. Usa o cache do npm (`~/.npm`), que é só cache.
- Confere o `dist.integrity` publicado contra o valor fixado em `versions.env`.
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
- Continuam valendo, nos cinco: `AGENTS.md` (e `CLAUDE.md`/`QWEN.md`) do projeto
  e dos diretórios acima dele. O workdir do eval não deve ficar abaixo de uma pasta
  com `AGENTS.md`/`CLAUDE.md` alheio.

## Contrato com o eval

```bash
agents/<agente>/run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
```

| Item | Comportamento |
|---|---|
| Ambiente | `LLM_BASE_URL` (padrão `http://127.0.0.1:9931`; `/v1` final é removido), `LLM_MODEL` (padrão `qwen3.6-35b`), `LLM_CONTEXT` (131072), `LLM_MAX_OUTPUT` (32768) |
| Perfil | `AGENT_PROFILE=autonomous` (padrão no `run.sh`) |
| Execução | `cd <workdir>`, stdin em `/dev/null`, modo não interativo, aprovação automática dentro do workdir |
| Saída | código de saída do agente (0 = terminou normalmente) |
| `<log-dir>` | `events.jsonl` (stdout: JSON/stream), `stderr.log`, `run-meta.json` (versão, perfil, modelo, início/fim, segundos, código), `agent-metrics.json` (abaixo), `command.txt`, config efetiva, `guard.log` (bloqueios), `home/` (estado e sessão), `metrics-before.prom`/`metrics-after.prom` (se o servidor tiver `--metrics`) |
| Opcionais | `AGENT_TIMEOUT=30m` (usa `timeout`), `AGENT_LOG_REQUESTS=1` (corpo das requisições, Qwen Code e Pi), `AGENT_BIN=<executável>`, `AGENT_DRY_RUN=1` (gera a config e mostra o comando) |
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

Duas camadas em cada agente, mais o container da E7 como barreira real.

1. **Regras nativas** de cada agente (ver README de cada um).
2. **`lib/guard.py`**, a mesma guarda nos cinco, chamada antes de todo comando
   de shell (inclusive o script de `bash -c`/`bash -lc`). Bloqueia (código 2, motivo devolvido ao modelo, registro em `guard.log`):

| Regra | interactive | autonomous |
|---|---|---|
| `git push` em qualquer forma (`git -C x push`, `git -c k=v push`) | bloqueia | bloqueia |
| `sudo`, `su`, `doas`, `pkexec`, `runuser` | bloqueia | bloqueia |
| Download executado: `curl … \| sh`, `wget -O- \| python3`, `sh -c "$(curl …)"`, `bash <(curl …)` | bloqueia | bloqueia |
| `rm -r`/`-f` fora do projeto, na raiz do projeto, em `.git` ou com alvo não resolvível (`$VAR`); `/tmp` liberado, menos a pasta que contém o projeto | bloqueia | bloqueia |
| Instalação pela rede: `npm/pnpm/yarn/bun install/add/ci`, `pip install`, `python -m pip install`, `uv add`, `uv pip install`, `poetry`, `cargo install`, `go install/get`, `gem`, `apt`, `brew`… | permite (shell já pergunta) | bloqueia |

Além disso, por perfil:

| | interactive | autonomous |
|---|---|---|
| Leitura | livre | livre |
| Edição | livre dentro do projeto; fora pergunta (ou é recusada) | livre dentro do projeto (Codex: sem limite de caminho no `danger-full-access`; fora do container use `CODEX_LOCAL_SANDBOX=workspace-write`) |
| Shell | pergunta (Pi: só não pergunta leitura simples) | aprovado |
| Web | busca negada; fetch pergunta | negados |

Limites conhecidos da guarda: não vê comandos ofuscados (`eval`, base64, scripts
gerados e depois executados), `find -delete`/`-exec rm`, nem `npx` que baixa
pacotes. O bloqueio de rede de verdade fica para o container (E7). Testes:
`lib/test-guard.sh` (113 casos, permitidos e bloqueados; todos passaram em 29/10).
A guarda também foi exercitada pelo plugin do OpenCode e pela extensão do Pi
(chamados direto pelo Node, sem os agentes instalados).

## Como medir o tamanho do primeiro prompt

```bash
agents/measure-preamble.sh <agente>     # tarefa trivial num repositório git vazio
```

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

Em ordem, para cada agente instalado:

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
| `lib/guard.py` | guarda de comandos de shell comum |
| `lib/test-guard.sh` | casos de teste da guarda |
| `<agente>/` | config base e perfis, `env.sh`, `run.sh`, lançador interativo, README |
