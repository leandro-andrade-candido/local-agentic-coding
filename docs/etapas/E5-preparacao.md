# E5: preparação do serviço do llama-server

Preparado em 29/10/2026, enquanto a E4 e a verificação dela usavam a porta 9931 e a GPU. Nada foi instalado nem iniciado: só a chave foi criada e o `--dry-run` e o pré-voo foram executados. Requisitos atendidos: [`E5-requisitos.md`](E5-requisitos.md), mais o pedido da E7 de manter desligadas as rotas perigosas.

## Divisão de responsabilidades

| Arquivo | Dono | Conteúdo |
|---|---|---|
| `runtime/llama-server.args` | E4 | desempenho: contexto, offload, lotes, threads, cache, `--metrics` e amostragem `--temp/--top-p/--top-k` |
| `runtime/llama-server.env` | E4 | `GGML_OP_OFFLOAD_MIN_BATCH=1024` |
| `runtime/llama-server.policy.args` | E5 | segurança e padrões: host, porta, chave, CORS, `--no-agent`, `--offline`, `--min-p 0`, `--presence-penalty 0`, `-n 32768` |
| `runtime/llama-server-args.py` | E5 | monta a linha final e aplica as regras abaixo |
| `runtime/llama-server-start.sh` | E5 | wrapper: ambiente, conferências, pré-voo e `exec` |
| `runtime/llama-server.service.in` | E5 | modelo da unidade `systemd --user` |
| `runtime/common.sh` | E5 | caminhos e funções comuns (versions.env, models.tsv, PID da unidade) |
| `scripts/llm` | E5 | comando único: chave, instalação, início/parada, saúde, teste |
| `scripts/preflight.sh` | E5 | pré-voo (só leitura, ~0,2 s) |

`scripts/tool_calls.py` ganhou `--api-key-file` (e usa `$LLM_API_KEY` se nenhuma chave for passada), para a chave não aparecer na linha de comando (`ps`). O `--api-key` continua aceito.

## Como a linha de comando é montada

`-m <modelo>` + perfil (E4) + política (E5), nesta ordem.

- **Modelo:** o alias vem do `-a` do perfil (`qwen3.6-35b`) ou de `LLM_SERVER_MODEL`. O arquivo e o tamanho vêm do `models.tsv`, e a pasta, do `MODELS_DIR` do `versions.env`. Se o arquivo faltar ou o tamanho não bater, o wrapper recusa iniciar. O SHA-256 não é recalculado (22 GB); quem confere o hash é o `scripts/fetch-model.sh`.
- **Binário:** `$LLAMA_CPP_PREFIX/$LLAMA_CPP_BUILD/llama-server`, com o marcador `.complete`. Usa o build do `versions.env`, não o link `current`.
- **Sobreposição:** no b11982 vale a última ocorrência de cada flag (`common/arg.cpp`), e cada repetição gera o aviso `DEPRECATED: argument specified multiple times`. O montador agrupa os aliases pela ajuda do próprio binário (`-n` = `--predict` = `--n-predict`; `_` vira `-`, como no llama.cpp). Quando uma flag está nos dois arquivos, **vence a política**: a do perfil sai da linha e, se o valor for diferente, fica uma nota no log. Com os arquivos atuais não há nenhuma flag nos dois. A política traz só o que falta no perfil.
- **Recusas** (código 2, o serviço não sobe):
  - flag desconhecida para o build, ou repetida no mesmo arquivo;
  - flag proibida, no perfil ou na política (abaixo);
  - flag de segurança no perfil (host, porta, chave, CORS, `--no-agent`, `--offline`, `--ui`, SSL);
  - `--host` fora do loopback;
  - `--cors-origins *` ou uma lista de origens;
  - chave ausente, legível por outros usuários, guardada dentro do repositório ou com espaço nas pontas;
  - linha final sem `--metrics`, `--temp`, `--top-p`, `--top-k`, `--min-p`, `--presence-penalty` ou `-n`: estas podem vir do perfil ou da política, mas não podem faltar.
- **Ambiente:** o wrapper tira do ambiente `LLAMA_*`, `GGML_*`, `HF_TOKEN` e `MTMD_BACKEND_DEVICE`, porque o llama-server lê `LLAMA_ARG_*` como flags e a política não pode ser contornada por fora. Depois carrega `runtime/llama-server.env`, recusando nele qualquer `LLAMA_*`. Valores `${...}` nos arquivos só aceitam `LLAMA_SERVER_HOST`, `LLAMA_SERVER_PORT` e `LLM_API_KEY_FILE`.

### Linha final (`scripts/llm dry-run`, 29/10, perfil final da E4)

```
GGML_OP_OFFLOAD_MIN_BATCH=1024 /home/leandro/.local/opt/llama.cpp/b11982/llama-server \
  -m /home/leandro/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf -a qwen3.6-35b -np 1 -c 131072 \
  -fa on -ctk q8_0 -ctv q8_0 -ngl 99 -ncmoe 38 --fit on --fit-target 384 -b 4096 -ub 4096 \
  -t 8 -tb 12 -lm dio --jinja --reasoning-preserve -ctxcp 48 -cms 2048 --cache-ram 12288 \
  --metrics --temp 0.6 --top-p 0.95 --top-k 20 \
  --host 127.0.0.1 --port 9931 --api-key-file /home/leandro/.config/local-agentic/llm-api-key \
  --cors-origins http://127.0.0.1:9931 --no-cors-credentials --no-agent --offline \
  --min-p 0 --presence-penalty 0 -n 32768
```

## Segurança (conferido no código do b11982, commit `8a199ad`)

- **Chave.** `--api-key-file` lê uma chave por linha (linhas com `#` são comentário). O servidor aceita `Authorization: Bearer <chave>` (OpenAI) ou `x-api-key` (Anthropic) e compara byte a byte. Só `/health`, `/v1/health` e os arquivos da interface web são públicos. **`/metrics`, `/props`, `/slots` e `/v1/models` exigem a chave** (`server-http.cpp`).
- **Arquivo da chave.** `~/.config/local-agentic/llm-api-key`, modo 0600, pasta 0700, uma linha (`sk-llama-` + 64 hex). É criado por `scripts/llm key`, que nunca imprime a chave. O wrapper e a unidade só conhecem o caminho; na linha de comando aparece `--api-key-file <caminho>`.
- **CORS.** `--cors-origins` vai literal no `Access-Control-Allow-Origin`: a "lista separada por vírgulas" da ajuda não é tratada. Por isso a política usa uma origem só, a do próprio servidor. O valor especial `localhost` aceitaria qualquer porta de localhost. Com `--no-cors-credentials`, o preflight responde `Allow-Credentials: false`. A barreira principal é a chave: um navegador não consegue pôr `Authorization` em requisição simples.
- **Rotas desligadas** (pedido da E7: o encaminhador do container expõe todas as rotas aos agentes). Todas já vêm desligadas no b11982. A política acrescenta `--no-agent`, que no código esvazia `--tools` e desliga o proxy CORS. O montador recusa:

  | Flag | Rota ou efeito |
  |---|---|
  | `--props` | `POST /props` responde 501 sem ela |
  | `--slot-save-path` | `POST /slots/<id>?action=save\|restore` responde 501 sem ela |
  | `-ag/--agent`, `--tools`, `--tools-runtime`, `--mcp-servers-*` | ferramentas embutidas (`exec_shell_command`, `write_file`…) e MCP; `/tools` responde 403 |
  | `--ui-mcp-proxy` | `/cors-proxy` responde 403 |
  | `--media-path`, `--path` | leitura de arquivos locais e servidor de arquivos estáticos |
  | `--connect` | túnel peer-to-peer para fora da máquina |
  | `--log-prompts-dir` | prompts gravados em disco |
  | `--api-key` | chave visível no `ps` e no git |
  | `-hf`, `-mu`, `-dr`, `--models-dir`, `--models-preset`, presets `--fim-*` etc. | downloads e modo roteador |
  | `--cors-credentials`, `--reuse-port` | credenciais em CORS; outro processo na mesma porta |

  `GET /slots` (monitoramento, sem escrita) continua ligado.
- **`-n 32768`** é só o padrão. No b11982, o `max_tokens` do pedido vence e não é limitado pelo `-n` (`server-context.cpp`, "the per-request limit takes priority").
- **Interface web** continua ligada em `http://127.0.0.1:9931`: carrega sem chave e pede a chave para conversar. Para desligar, `--no-ui` na política.

## Pré-voo (`scripts/preflight.sh`)

Só lê, nunca encerra nada, ~0,2 s. Roda em `scripts/llm start` e `restart`, no terminal, e de novo dentro da unidade, antes do `exec`. Código 0 = pode iniciar, com ou sem avisos; código 2 = bloqueio.

| Item | Bloqueia | Avisa |
|---|---|---|
| Binário do build e marcador `.complete` | ausente | — |
| Modelo | ausente ou com tamanho diferente do `models.tsv` | — |
| Argumentos (montador em modo `check`) | recusados (inclui chave ausente e flag proibida) | — |
| Porta 9931 | ocupada por outro processo | — |
| Outra instância do llama.cpp (`llama-server`, `llama-bench`…) | — | sempre |
| Processos na GPU | — | do Windows (jogos, NVIDIA Broadcast) ou do WSL fora do serviço |
| VRAM livre, com o serviço parado | — | < 7.500 MiB (sem nada na GPU: 7.910) |
| Temperatura e redução térmica | — | ≥ 80 °C, ou qualquer `Slowdown` ativo |
| PCIe (`nvidia-smi -q`) | — | máximo abaixo de Gen4, replays > 0, estouros do contador > 0 |
| RAM do WSL, com o serviço parado | — | `MemAvailable` < modelo + 2 GiB (a carga pode falhar) ou < modelo + `--cache-ram` + 4 GiB |
| Swap | — | > 1 GiB em uso |

Limites mudam por `PREFLIGHT_MIN_FREE_VRAM_MIB`, `PREFLIGHT_MAX_TEMP_C` e `PREFLIGHT_MAX_SWAP_USED_MIB`. `LLM_PREFLIGHT=off` no ambiente da unidade pula o pré-voo (`systemctl --user edit llama-server`).

**Como a GPU é lida.** O `nvidia-smi.exe` do Windows mostra os processos do Windows. O trabalho CUDA do WSL aparece lá como **PID 4 (System), tipo C, sem nome**, observado em 29/10 com o llama-server da E4 no ar; com a GPU ociosa, a lista fica vazia. O `nvidia-smi` do WSL (`/usr/lib/wsl/lib`) mostra os processos do Linux com PID e nome. O pré-voo cruza os dois: o PID 4 é atribuído ao WSL quando há processo do WSL na GPU, e o PID principal da unidade é reconhecido como o próprio serviço.

Com a GPU ociosa (29/10): `0 bloqueio(s), 0 aviso(s)`, VRAM livre 7.910 MiB, PCIe Gen4 sem replays, RAM disponível 49.586 MiB. Com o servidor do verificador da E4 no ar, a porta deu bloqueio e houve 3 avisos (outra instância, VRAM livre 4.791 MiB, RAM abaixo do recomendado), e nenhum processo do Windows foi apontado.

## Unidade `systemd --user`

| Item | Valor | Por quê |
|---|---|---|
| `Type` | `exec` | o wrapper faz `exec`, e o llama-server vira o `MainPID`: parar é sinal para o PID (resolve o `pkill` da E3) |
| `ExecStartPost` | `scripts/llm wait-ready --timeout 600` | o início só termina com `GET /health` = 200 (modelo carregado); desiste se o processo morrer |
| `TimeoutStartSec` | 11 min | carga de ~30 s na E4 com `-lm dio`; mmap levou ~2,5 min |
| `Restart` | `on-failure`, 10 s crescendo até 5 min em 5 passos | sinal, saída ≠ 0, falha da espera |
| `RestartPreventExitStatus` | 2 | recusa do wrapper (configuração, pré-voo): reiniciar não resolve |
| `StartLimitBurst` / `IntervalSec` | 5 em 30 min | evita laço; `scripts/llm start` faz `reset-failed` |
| `KillMode` / `KillSignal` | `mixed` / `SIGTERM` | SIGTERM só no llama-server (desligamento limpo); SIGKILL no grupo após 90 s |
| Logs | journald, `SyslogIdentifier=llama-server` | `scripts/llm logs [-f]` |
| Endurecimento | `NoNewPrivileges`, `UMask=0077` | `ProtectSystem`/`PrivateTmp` exigem namespaces e não foram testados com o `/dev/dxg` do WSL |
| `[Install]` | `WantedBy=default.target` | só com `scripts/llm install --enable` |

O `versions.env` e os arquivos de argumentos são lidos a cada início: mudou o perfil, basta `scripts/llm restart`. `scripts/llm install` de novo só é necessário se o repositório mudar de lugar ou se o modelo da unidade mudar. `LimitMEMLOCK` não foi mexido: a E4 carrega com `-lm dio` num shell com `ulimit -l` de 64 MiB, e o padrão do gerenciador do usuário é maior (6,8 GB). `systemd-analyze --user verify` na unidade gerada: sem erros.

## Comandos

```bash
scripts/llm key                  # cria a chave se não existir; imprime o caminho
scripts/llm install --dry-run    # mostra a unidade e roda systemd-analyze verify
scripts/llm install [--enable]   # grava ~/.config/systemd/user/llama-server.service + daemon-reload
scripts/llm start | stop | restart | status
scripts/llm logs [-f] [-n N]
scripts/llm health               # disponibilidade, latência e política no servidor
scripts/llm test [--reps N]      # tool_calls.py; JSON em logs/tool_calls-<data>.json
scripts/llm preflight
scripts/llm dry-run              # linha de comando final, sem iniciar
eval "$(scripts/llm env)"        # LLM_BASE_URL, LLM_MODEL, LLM_API_KEY e LOCAL_LLM_API_KEY
```

`scripts/llm env` imprime `export LLM_API_KEY="$(cat <caminho>)"`: a chave só é lida no `eval`, e a saída do comando não a contém.

`scripts/llm health` confere:

- `/health` sem chave;
- `/v1/models` e `/metrics` com a chave;
- um chat de 1 token, com a latência;
- 401 sem a chave;
- `/props` bate com a linha final (amostragem, `max_tokens`, `n_ctx`, `total_slots`, `endpoint_props=false`, `cors_proxy_enabled=false`, `endpoint_metrics=true`);
- `POST /props` responde 501;
- `POST /slots/0?action=<inválida>` responde 501: sem `--slot-save-path` a resposta vem antes de olhar a ação; com ela ligada, viria 400, e nada é gravado em nenhum dos dois casos;
- `/tools` e `/cors-proxy` respondem 403;
- CORS para outra origem é negado;
- o servidor escuta só no loopback;
- o log da execução atual não tem `failed to fit params`.

O chat de 1 token ocupa o slot único: rode com os agentes parados.

## Instalação (quando a porta e a GPU estiverem livres)

```bash
scripts/llm install --dry-run && scripts/llm install
scripts/llm start          # pré-voo + espera o modelo carregar
scripts/llm health
scripts/llm test           # primeira execução real do tool_calls.py contra o Qwen3.6-35B
```

## Como desfazer

```bash
scripts/llm uninstall
# o mesmo, à mão:
scripts/llm stop; systemctl --user disable llama-server.service
rm ~/.config/systemd/user/llama-server.service; systemctl --user daemon-reload
# opcional: rm ~/.config/local-agentic/llm-api-key
```

Trocar a chave: apague o arquivo, rode `scripts/llm key` e `scripts/llm restart`, e refaça o `eval "$(scripts/llm env)"` nos terminais dos agentes.

## Mudanças pendentes em `agents/` e `eval/` (não aplicadas aqui)

Sem elas, os agentes mandam a chave fictícia (401) e os retratos de `/metrics` somem sem erro, porque `/metrics` agora exige a chave.

1. `agents/lib/common.sh`, no lugar da linha `LOCAL_LLM_API_KEY="${LOCAL_LLM_API_KEY:-sk-local-no-key}"` e do comentário acima dela:
   ```bash
   # Chave do llama-server (E5): LLM_API_KEY (no container vem do ambiente), senão o arquivo
   # de scripts/llm key. Nunca uma chave de nuvem: ela seria enviada ao servidor local.
   LLM_API_KEY_FILE="${LLM_API_KEY_FILE:-$HOME/.config/local-agentic/llm-api-key}"
   if [ -z "${LLM_API_KEY:-}" ] && [ -r "$LLM_API_KEY_FILE" ]; then
     LLM_API_KEY="$(cat "$LLM_API_KEY_FILE")"
   fi
   LOCAL_LLM_API_KEY="${LLM_API_KEY:-${LOCAL_LLM_API_KEY:-sk-local-no-key}}"
   ```
   Os cinco agentes já leem `LOCAL_LLM_API_KEY`: Qwen Code por `envKey`, Codex por `env_key`, Pi por `apiKey`, OpenCode por `{env:...}` e Claude Code por `ANTHROPIC_AUTH_TOKEN`, que vai como Bearer.
2. `agents/lib/common.sh`, `metrics_snapshot`, com a chave pela entrada padrão, fora do `ps`:
   ```bash
   printf 'Authorization: Bearer %s\n' "$LOCAL_LLM_API_KEY" \
     | curl -fsS --max-time 5 -H @- "$LLM_BASE_URL/metrics" -o "$1" 2>/dev/null || rm -f "$1"
   ```
3. `eval/lib/metrics.py`, `snapshot()`: montar um `urllib.request.Request(metrics_url(base))` com `Authorization: Bearer` + `os.environ.get("LLM_API_KEY") or os.environ.get("LOCAL_LLM_API_KEY")` e passá-lo ao `urlopen`.
4. `eval/run.sh`, depois do `export LLM_MODEL=...` (linha 41): o mesmo bloco do item 1, terminando em `export LLM_API_KEY`. O `sandbox/run-in-box.sh` já repassa `LLM_*` ao container.
5. Textos que dizem "chave fictícia, o servidor não confere": `agents/claude-local/env.sh` e `README.md`, `agents/qwen-code/README.md` e `agents/pi/README.md`.

## O que verificar com o servidor no ar

1. `scripts/llm install` real e `scripts/llm start`: tempo até pronto e `wait-ready` vendo o `$MAINPID` dentro do `ExecStartPost`.
2. `scripts/llm health` todo `ok`, em especial `/props` com os padrões da linha final e o log sem `failed to fit params`.
3. `scripts/llm test`: primeira execução real, sem `RUNTIME`/`TRUNCADO`, com o JSON em `logs/`.
4. Reinício automático: `kill -9` no `MainPID` → volta em ~10 s (`systemctl --user show -p NRestarts llama-server`).
5. Parada limpa: `scripts/llm stop` em menos de 90 s, sem SIGKILL no journal, VRAM livre de volta a ~7.910 MiB (`scripts/llm preflight`).
6. Pré-voo dentro da unidade: o `nvidia-smi.exe` (interop do WSL) responde a partir do systemd. No journal, não deve aparecer "nvidia-smi.exe do Windows não respondeu".
7. Vida do serviço: com `Linger=no`, conferir se ele para ao fechar o último terminal do WSL ou no desligamento ocioso do WSL. Não ligar o linger sem decidir, pela regra da GPU dedicada.
8. `ps -o args -p <MainPID>` mostra só o caminho da chave; `--offline` não gera erro na inicialização.
9. Reuso de checkpoint no log numa sessão de agente com vários turnos (verificação da E5 no plano). Pode exigir o `-lv 4`, hoje comentado no perfil.
10. Do navegador do Windows: a interface em `http://127.0.0.1:9931` carrega e pede a chave; um `fetch` de outra origem é bloqueado.
11. Com os itens 1–4 da seção anterior aplicados: `metrics-before.prom`/`metrics.before.prom` não vazios num run do eval, e agentes sem 401.
12. De dentro do container da E7, pelo encaminhador: `POST /props` e `POST /slots/0?action=save` recusados, `/tools` e `/cors-proxy` com 403.
