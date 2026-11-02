# Container agent-box (E7)

Barreira real para os agentes em modo autônomo (yolo, `bypassPermissions`,
`danger-full-access`, sem aprovações). As regras de cada agente e a guarda
comum (`agents/lib/guard.py`) são a segunda camada. Esta pasta é a primeira.

**Estado (29/10/2026): construída e verificada (fase 2).**

| Verificação | Resultado |
|---|---|
| `sandbox/build.sh` | imagem `agent-box:latest` com 2,89 GB (camada dos agentes: 1,63 GB); os 5 tarballs conferem com o `versions.env`, e o `--version` de cada um sai com 0 |
| `sandbox/escape-tests.sh` | 150 de 150: 127 dentro do container, 2 com o llama-server real (`/health` e `/v1/models` com a chave) e 21 no host (13 de regressão do item 7: host não segue symlinks do agente; box_post e box_check não deixam o agente forjar o placar) |
| Eval com `fake-oracle` pelo wrapper | S1 (pytest, 1360 + 3 testes) passa; S2 (jest, 753 + 3 testes) passa; S3 com `sleep:60` e `EVAL_TIMEOUT_S=5` sai com 124, `timed_out: true`, sem container, encaminhador ou pasta temporária sobrando |
| Sandbox do Codex no container | `codex sandbox -- true` falha: `bwrap: No permissions to create a new namespace` (esperado; ver abaixo) |
| Trava do perfil autonomous (`agents/lib/common.sh`) | liberada no container (`AGENT_BOX=1` e `/.dockerenv`), recusada no host |

Também verificado: o tmpfs da HOME aceita `uid=`/`gid=`; o `/.dockerenv` existe mesmo com
`--read-only`; o seccomp padrão do Docker 29 bloqueia `AF_VSOCK`; o binário do Windows
(interop do WSL) não executa; o encaminhador entrega SSE evento a evento
(0,0/0,3/0,6/0,9/1,2 s), 4 conexões de 1,5 s em 1,51 s e 4 MiB de ida e volta.

Ainda falta ver, com os agentes de verdade na E6, o que está em "Pendências".

## Arquivos

| Arquivo | Função |
|---|---|
| `Dockerfile` | Imagem `agent-box`: Ubuntu 24.04 fixado por digest, Node 24.22.2, Python 3.12, uv 0.12.13, git, ripgrep, fd, jq, Playwright 1.64.1 com Chromium headless e os 5 agentes |
| `install-agents.sh` | Instala os agentes no build; confere o sha512 de cada tarball contra `agents/versions.env` |
| `build.sh` | Constrói a imagem com o UID/GID de quem roda e o rótulo das versões |
| `run-in-box.sh` | Roda um comando num container novo, com as montagens pedidas e nada mais |
| `llm-forward.py` | Encaminhador TCP ↔ socket unix (só biblioteca padrão): o único caminho do container para fora |
| `entrypoint.sh` | Sobe o encaminhador interno e executa o comando |
| `agent-shell.sh` | Sessão interativa de um agente (ou bash) com só um projeto montado |
| `escape-tests.sh` | Testes de fuga (rodam dentro do container, com conferência no host) |
| `lib.sh` | Funções comuns |

## Uso

```bash
sandbox/build.sh                    # constrói agent-box:latest (2,89 GB; ~2 min com cache do apt frio)
sandbox/escape-tests.sh             # testes de fuga; saída 0 = tudo passou

# eval: agente, captura do diff e verificações em containers (ver eval/README.md)
EVAL_WRAPPER=sandbox/run-in-box.sh eval/run.sh qwen-code S1 lote1

# sessão interativa num projeto (só ele é montado)
sandbox/agent-shell.sh claude-local ~/projetos/copia-do-piloto
sandbox/agent-shell.sh shell ~/projetos/copia-do-piloto     # bash no mesmo isolamento
sandbox/agent-shell.sh --skills-dir ~/minhas-skills pi ~/projetos/x   # + skills pessoais
AGENT_PROFILE=autonomous sandbox/agent-shell.sh qwen-code ~/projetos/x

# qualquer comando; por exemplo, medir o preâmbulo de um agente (E6) dentro do container
sandbox/run-in-box.sh --rw ~/projetos/x -- bash -lc 'cd ~/projetos/x && npm test'
mkdir -p ~/.cache/local-agentic/preamble/pi
sandbox/run-in-box.sh --rw ~/.cache/local-agentic/preamble/pi -- \
    "$PWD/agents/measure-preamble.sh" pi ~/.cache/local-agentic/preamble/pi
```

`run-in-box.sh` recusa uma imagem construída com outras versões dos agentes
(rótulo `local-agentic.agents-versions`). Depois de mudar `agents/versions.env`,
rode `sandbox/build.sh` de novo.

## Desenho

### Container

| Opção do `docker run` | Por quê |
|---|---|
| `--network none` | Sem interface além de `lo`: sem internet, sem a rede do WSL, sem a ponte `docker0`, sem o Windows. Os sockets unix abstratos do host também ficam de fora, porque pertencem ao namespace de rede. |
| Encaminhador por socket unix | O único caminho para fora. O destino é fixo (`127.0.0.1:<porta do LLM_BASE_URL>`). Ver "Rede". |
| `--read-only` + tmpfs em `/tmp`, `/var/tmp` e `HOME` (`/home/agent`) | Nada fora das montagens persiste nem muda a imagem. A HOME é vazia a cada execução. |
| Montagens no mesmo caminho absoluto | Os `.venv` do eval têm caminhos absolutos (shebangs, `pyvenv.cfg`), e os `run.sh` usam `pwd -P`. Os logs ficam iguais aos do host. |
| `agents/` só leitura | Lançadores, configuração, guarda. O agente não consegue alterar a própria guarda. |
| `--user <UID>:<GID>` do host, sem `sudo` e sem setuid | Não roda como root (o Claude Code recusa `bypassPermissions` como root), e os arquivos criados ficam com o dono certo. |
| `--cap-drop ALL`, `--security-opt no-new-privileges` | Sem capabilities, sem ganho de privilégio por setuid. O seccomp padrão do Docker continua ligado. |
| `--memory`/`--memory-swap` 8g, `--cpus 8`, `--pids-limit 2048`, `--oom-score-adj 500` | Um agente em loop não derruba a máquina. Sob falta de memória, o kernel mata o agente antes do llama-server. |
| `--init`, `--rm`, nome e rótulo `local-agentic.agent-box` | Reaproveita processos órfãos e apaga o container no fim. SIGTERM, SIGINT e o timeout do eval fazem o wrapper rodar `docker rm -f`. |
| `--runtime runc`, sem `--gpus` | Os agentes não precisam de GPU, e o `/dev/dxg` do WSL fica de fora. |
| Ambiente por lista | O wrapper define `AGENT_BOX=1` (os `run.sh` no perfil autonomous recusam rodar sem ela), `AGENT_SKILLS_DIRS`, `LLM_BASE_URL`, `HOME` e `TZ`; valores do host para elas são ignorados. Do host passam só `LLM_*` (inclui a chave `LLM_API_KEY`), os ajustes `AGENT_*`/`*_LOCAL_*`, `GIT_AUTHOR_*`/`GIT_COMMITTER_*` e poucas outras. Nada de `SSH_AUTH_SOCK`, `GITHUB_TOKEN`, `DOCKER_HOST`, `WSL_INTEROP` ou chaves de nuvem. |
| Skills só leitura em `/opt/skills` | O agente usa as skills, mas não altera as que outras sessões vão carregar. Ver "Skills". |

Montagens recusadas pelo `run-in-box.sh`:

- `/` e a HOME inteira, ou um ancestral dela;
- `/tmp`, `/etc`, `/usr`, `/run`, `/var/run` (onde ficam os sockets do Docker e da sessão), `/proc`, `/sys`, `/dev`;
- os discos do Windows (`/mnt/c`...) e `/mnt/wsl*`;
- `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.docker`, `~/.config/gh`, `~/.claude*`, `~/.codex`, `~/.git-credentials` e afins.

### Rede: o encaminhador

```
agente ──HTTP──► 127.0.0.1:9931 dentro do container   (llm-forward.py box)
                     │ socket unix /run/agent-box/llm.sock  (pasta montada só leitura)
                     ▼
                 llm-forward.py host  (processo do run-in-box.sh, dura o container)
                     │ TCP
                     ▼
                 llama-server 127.0.0.1:9931 do host
```

- O encaminhador não interpreta HTTP: copia bytes, com uma thread por sentido. Por isso streaming (SSE), keep-alive, corpos grandes e várias conexões ao mesmo tempo funcionam.
- O fim de envio de um lado vira `shutdown` do outro. Assim, um agente que desiste de uma requisição fecha a conexão com o llama-server, e o servidor cancela a geração.
- Dentro do container, `LLM_BASE_URL` continua `http://127.0.0.1:<porta>`, então as configurações dos agentes não mudam. O mesmo vale para o `/metrics` que os `run.sh` leem.
- O socket é `0600`, numa pasta `0700` em `$XDG_RUNTIME_DIR`, e some no fim. O container tem o mesmo UID, então conecta. Outro usuário do host não conecta.
- Com o llama-server parado, o encaminhador aceita a conexão e a fecha em seguida. O cliente vê "conexão encerrada", e não "conexão recusada".

Alternativas descartadas:

| Opção | Problema |
|---|---|
| Rede bridge + `host-gateway` | O llama-server escuta só em 127.0.0.1. Seria preciso abri-lo na `docker0` e filtrar com iptables (sem `sudo`), e o container ainda veria o resto do host e a internet. |
| `--network host` | O container teria toda a rede do host: o outro serviço local na 8080, a internet e o Windows. |
| Rede `--internal` + container de proxy | Mais peças, e o proxy ainda precisaria de um caminho até o 127.0.0.1 do host. |
| `socat` | Não instalado, e instalar exige `sudo`. |

O que passa pelo encaminhador é **qualquer** rota do llama-server, não só
`/v1/*`. Por isso, na E5, manter desligados `--slot-save-path` e o `POST /props`
(o padrão já é desligado). A chave da E5 (`LLM_API_KEY`) entra no container
porque os agentes precisam enviá-la. Se ela não estiver no ambiente, o `run-in-box.sh`
lê de `LLM_API_KEY_FILE` (padrão `~/.config/local-agentic/llm-api-key`) e a passa
por nome (`-e LLM_API_KEY`), nunca na linha de comando. O arquivo em si não entra. Ela só vale para o llama-server, que o
container já alcança. Ver "Pendências" para a alternativa de injetar a chave no
lado do host.

### Skills

| Camada | Origem no host | No container |
|---|---|---|
| Base | `$SKILLS_PREFIX/profiles/base` (`SKILLS_PREFIX` do `versions.env` da raiz; a variável de ambiente sobrepõe), materializado por `scripts/fetch-skills.sh` | `/opt/skills/base`, só leitura |
| Pessoais | `--skills-dir <dir>` (repetível) ou `BOX_SKILLS_DIRS=dir1:dir2` | `/opt/skills/extra-1`, `extra-2`..., só leitura |
| Projeto | `.agents/skills`, `.claude/skills` do repositório | vêm com o workdir/projeto (leitura e escrita, como o resto dele) |

- `AGENT_SKILLS_DIRS` lista as pastas montadas em `/opt/skills`, separadas por `:` (vazia se nenhuma). Os lançadores e `run.sh` dos agentes decidem como cada agente as carrega (ver `skills/README.md`).
- Sem o perfil base no host, o wrapper avisa e segue sem ele.
- `--no-skills` não monta nenhuma. O eval usa isso nos containers da captura do diff e das verificações.
- Skills do projeto não são protegidas: o agente pode reescrevê-las, como qualquer arquivo do projeto, e o que ele escrever vale na próxima sessão naquele projeto.

### Git

- **Sem credenciais.** Não entram chaves SSH, agente SSH, `gh`, `~/.git-credentials`, `~/.gitconfig` nem `credential.helper` (o `/etc/gitconfig` da imagem zera os ajudantes). Sem rede, o `git push` falha de qualquer forma.
- **Identidade.** No eval, a fixa do runner (`GIT_AUTHOR_*`). No `agent-shell.sh`, o nome e o e-mail globais do host.
- **`.git` no `agent-shell.sh` (`--protect-git`).** O usuário vai rodar `git status` no host depois da sessão, e o `git` executa comandos de configuração: `core.fsmonitor`, filtros, hooks. Por isso:
  - `.git` vira ponto de montagem, então não pode ser renomeado nem trocado;
  - `.git/config`, `.git/hooks` e os `config` de `.git/modules` ficam só leitura;
  - no fim, um `.git/commondir` ou `.git/config.worktree` criado na sessão é renomeado para `*.agent-box-quarentena-<data>`, porque faria o git ler a configuração de outro lugar;
  - repositórios `.git` aninhados novos geram aviso, porque o `git status` entra em submódulos e roda a configuração deles.
- Efeitos colaterais: dentro do container, `git config` local, `git remote add` e hooks novos falham. Projeto que é worktree (`.git` arquivo) não tem o git funcionando lá dentro, porque o gitdir real fica fora.
- Para revisar no host sem executar nada do repositório:

  ```bash
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null status --ignore-submodules=all
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null diff --ignore-submodules=all
  ```

- **No eval** não há `--protect-git`, para não mudar o comportamento medido. Em vez disso, o host não roda git no workdir depois do agente: a captura do diff roda num container, com o workdir só leitura, sem a pasta do resultado montada e com a config do agente neutralizada; o diff sai pela stdout. E todo o processamento de saída no host (`eval/lib/boxio.py`) não segue symlinks plantados pelo agente — ver `docs/verificacoes/E7.md`, item 7.

### Codex e os sandboxes próprios dos agentes

- **O sandbox do Codex (bubblewrap + seccomp, ou o auxiliar embutido) não funciona dentro deste container.** Ele precisa criar user namespaces sem privilégio.
  - O seccomp padrão do Docker bloqueia `unshare`/`clone` com `CLONE_NEWUSER` para quem não tem `CAP_SYS_ADMIN`.
  - O `no-new-privileges` anula um `bwrap` setuid.
- Para funcionar, seria preciso `seccomp=unconfined` (ou um perfil próprio) e talvez `CAP_SYS_ADMIN`. Isso abre a superfície do kernel que o container fecha, o que é pior que a camada extra do Codex.
- Verificado: `unshare -Ur` falha nos testes de fuga, e `codex sandbox -- true` (0.165; não há subcomando `linux`) termina com `bwrap: No permissions to create a new namespace`.
- **Decisão (igual à do `agents/codex-local/`):**
  - no eval, o perfil `autonomous` já usa `sandbox_mode = "danger-full-access"` e `approval_policy = "never"`, e `CODEX_LOCAL_SANDBOX` fica vazio;
  - no `agent-shell.sh`, o perfil `interactive` (que pede `workspace-write`) recebe `--sandbox danger-full-access`, e as aprovações `on-request` continuam;
  - as regras `forbidden` e o hook `guard.py` continuam valendo nos dois casos.
- O sandbox bubblewrap do Claude Code fica desligado (não está nas settings), pelo mesmo motivo. Qwen Code, Pi e OpenCode não têm sandbox próprio em uso aqui.

## Modelo de ameaça

**Protege contra**, enquanto o agente roda:

- **Escrever fora** do workdir, do log-dir, de `/tmp`/`/var/tmp` e da HOME temporária. Isso cobre o repositório, a HOME do host, a imagem, `agents/` e a guarda.
- **Ler** a HOME do host, chaves, tokens e configurações de outros agentes (`~/.claude`, `~/.codex`). No eval, também os testes ocultos, as soluções e as outras execuções em `eval/`.
- **Alterar as skills** base e pessoais (montadas só leitura).
- **Usar a rede:** internet, DNS, o outro serviço local na 8080, outras portas do host, a ponte do Docker, o Windows (vsock e interop do WSL) e sockets abstratos do host.
- **Ganhar privilégio:** root, `sudo`, setuid, capabilities, user namespaces, o socket do Docker e a GPU.
- **Fazer `git push`** ou qualquer acesso remoto com as credenciais do usuário.
- **Esgotar recursos** com fork bomb, memória ou CPU.
- **Deixar processos para trás:** o container é removido no fim e no timeout.
- **Plantar código que o host execute depois**, nos casos tratados:
  - no eval, nada do workdir roda no host depois do agente;
  - no `agent-shell.sh`, `.git/config` e hooks só leitura, mais a auditoria do `.git`.

**Não protege contra**:

- **Estragos dentro do que foi montado.** O agente pode apagar ou reescrever o projeto inteiro, inclusive o histórico local em `.git`. Trabalhe numa cópia ou worktree, como o plano já prevê para o piloto, ou com o trabalho importante já enviado ao remoto.
- **Código que o agente escreveu e que você executa depois, no host.** Exemplos:
  - scripts do `package.json` (`npm install` roda `postinstall`);
  - `Makefile` e testes;
  - `.envrc` (direnv);
  - `.venv/bin/activate`;
  - tarefas do VS Code;
  - hooks que moram na árvore de trabalho (`.husky/`, `.pre-commit-config.yaml` com hooks `local`).

  Revise o diff antes, ou rode no container (`agent-shell.sh shell`).
- **Dados sensíveis dentro do projeto montado.** `.env` ou credenciais no remoto do `.git/config` (`https://token@...`) ficam visíveis ao agente. Sem rede, ele não as envia para fora, mas pode copiá-las para logs ou para o código.
- **Abuso do llama-server.** O agente pode chamar qualquer rota, gerar texto à vontade e ocupar o slot único.
- **Integridade do placar do eval:** as verificações rodam **sem a pasta do resultado montada**. O `check.sh` grava num tmpfs do container e devolve o resultado por um tar na stdout; o host grava o `checks.json` a partir do veredito do grader, não de um arquivo que o código do agente pudesse plantar. O grader (`eval/lib`), a tarefa (com `hidden/` e a solução) e o transcrito entram só leitura; o código do agente só roda nos subprocessos de teste, separados do grader. O processamento de saída no host não segue symlinks do agente (`eval/lib/boxio.py`). Resíduo conhecido: nos testes que o próprio agente escreve (T4/S3), o código dele roda no mesmo processo do pytest/jest e poderia forjar o relatório daquele processo; fechar isso exige isolar mais o runner. Correções do item 7 de `docs/verificacoes/E7.md`.
- **Falhas do kernel, do runc ou do Docker** (escape de container). O container é rootful e sem `userns-remap`, mas o processo roda com o mesmo UID sem privilégios do usuário, sem capabilities e com seccomp. Uma falha dessas daria acesso ao usuário do host, não a root, salvo uma segunda falha de escalada.
- **O wrapper morto com SIGKILL** antes da limpeza (por exemplo, o `-k 30` do timeout, se o SIGTERM não bastar). O container pode sobrar. Confira com `docker ps --filter label=local-agentic.agent-box` e remova com `docker rm -f`.

## Limites e ajustes

| Variável | Padrão | Efeito |
|---|---|---|
| `BOX_IMAGE` | `agent-box:latest` | Imagem usada e construída |
| `BOX_MEMORY` | `8g` | Memória (sem swap) |
| `BOX_CPUS` | `8` | CPUs (cota). O llama-server usa o resto quando os dois disputam. |
| `BOX_PIDS` | `2048` | Processos e threads |
| `BOX_TMP_SIZE` / `BOX_HOME_SIZE` | `4g` / `1g` | Tamanho do `/tmp` e da HOME. É memória e conta no limite acima. |
| `BOX_ALLOW_STALE` | `0` | `1` aceita uma imagem construída com outras versões dos agentes |
| `BOX_SKILLS_DIRS` | vazio | Pastas de skills pessoais, separadas por `:` (o mesmo que `--skills-dir`) |
| `SKILLS_PREFIX` | do `versions.env` da raiz | Onde está `profiles/base` |
| `BOX_DRY_RUN` | `0` | `1` só mostra o `docker run` montado, sem conferir a imagem nem subir nada |
| `BOX_CODEX_SANDBOX` | `danger-full-access` | Valor de `--sandbox` do Codex no `agent-shell.sh` |
| `AGENT_BOX_STATE` | `~/.local/state/local-agentic/agent-box` | Estado das sessões interativas no container |

O estado das sessões interativas fica separado do estado dos lançadores usados
direto no host (`~/.local/state/local-agentic/agents`). O que um agente grava no
container (config, sessões, MCP) nunca é lido por um agente rodando fora dele.
Não aponte um para o outro.

## Imagem

- **Base:** `ubuntu:24.04@sha256:24737cef…3573c`, publicada em 25/10/2026. É Ubuntu, e não Debian slim, porque o Python 3.12 do sistema fica em `/usr/bin/python3.12`, o mesmo caminho do host. Assim, os `.venv` que o eval cria no host com `uv venv --python 3.12` funcionam dentro do container sem recriar nada.
- **Node 24.22.2 (LTS):** tarball oficial conferido pelo sha256 do `SHASUMS256.txt`. O host está na 24.21.0, anterior à versão de segurança 24.22.1.
- **uv 0.12.13:** tarball do GitHub conferido pelo sha256 publicado.
- **Playwright 1.64.1 (Python):** venv em `/opt/playwright`, instalado de `playwright-requirements.txt` com `--require-hashes`; só o Chromium headless shell em `/opt/ms-playwright`, com as libs e fontes do sistema (`--with-deps`), cerca de +1,1 GB na imagem. O download do Chromium é conferido pelo próprio Playwright, não por um hash nosso. `python` chama esse venv; `python3` segue sendo o do sistema. Serve à skill `webapp-testing` (perfil `frontend`). Para regenerar: `echo playwright==<versão> | uv pip compile - --generate-hashes --python-version 3.12 --python-platform x86_64-unknown-linux-gnu --no-header -o sandbox/playwright-requirements.txt`.
- **Agentes:** `npm pack` de cada pacote, com o sha512 do arquivo comparado ao `*_INTEGRITY` de `agents/versions.env` antes do `npm install`.
  - As dependências, inclusive os binários nativos das dependências opcionais (Codex, OpenCode, Claude Code), vêm do registro, e o npm confere cada uma contra o integrity publicado.
  - Elas não estão fixadas por lockfile.
  - Layout: `/opt/agents/<agente>/<versão>` com o link `current`, como em `agents/install.sh`. `AGENTS_PREFIX=/opt/agents`.
- **apt:** os pacotes vêm do arquivo do Ubuntu no momento do build, sem versão fixada. Para reprodutibilidade total, dá para usar `snapshot.ubuntu.com` (ver "Pendências").
- **`EXTRA_APT_PACKAGES`:** `sandbox/build.sh --build-arg EXTRA_APT_PACKAGES=build-essential` instala compiladores, se um projeto precisar. As tarefas do eval não precisam: pypika é Python puro, e o chrono usa jest e ts-jest.

## Pendências

Comandos da verificação (repetir depois de mudar a imagem ou o wrapper):

```bash
sandbox/build.sh
sandbox/escape-tests.sh
EVAL_WRAPPER=sandbox/run-in-box.sh EVAL_FORCE=1 eval/run.sh fake-oracle S1 e7-sandbox
EVAL_WRAPPER=sandbox/run-in-box.sh EVAL_FORCE=1 eval/run.sh fake-oracle S2 e7-sandbox
EVAL_WRAPPER=sandbox/run-in-box.sh FAKE_ORACLE_MODE=sleep:60 EVAL_TIMEOUT_S=5 \
    EVAL_FORCE=1 eval/run.sh fake-oracle S3 e7-sandbox-timeout
```

Para ver com os agentes de verdade, na E6:

- se o OpenCode tenta instalar dependências de plugin pela rede ao iniciar e quanto isso atrasa;
- se o Qwen Code (YOLO) tenta usar o próprio sandbox Docker/Podman;
- se o Pi carrega `extensions/guard.ts` com `agents/` só leitura (o cache do jiti precisa ir para `/tmp`);
- se algum agente tenta gravar fora da HOME temporária e do log-dir (a raiz é só leitura);
- o Codex avisa que não cria os "PATH aliases" quando o `CODEX_HOME` fica em `/tmp`; no eval ele fica no log-dir, e o efeito no `apply_patch` deve ser conferido.

Abertas:

- **Injetar a chave no host:** o encaminhador do host trocaria o `Authorization` de cada requisição pela chave da E5, e os agentes no container usariam uma chave falsa. Exige interpretar HTTP/1.1 (keep-alive, corpo chunked); hoje a cópia é de bytes.
- **apt por snapshot** (`snapshot.ubuntu.com`) para a imagem ser reproduzível bit a bit.
- **Lockfile npm** por agente, para fixar também as dependências transitivas.
- **Imagem menor:** o OpenCode instala as variantes comum e `baseline` (205 MB cada; a `baseline` é para CPUs sem AVX2), e o Qwen Code traz o Bun (103 MB) como dependência opcional. Dá para remover no build, ao custo de diferir da instalação no host.
- **Isolar mais o runner de testes** (T4/S3): hoje o código que o agente escreve roda no mesmo processo do pytest/jest e poderia forjar o relatório daquele processo. Rodar cada arquivo de teste num sub-sandbox sem `/tmp` compartilhado, ou validar o relatório contra IDs de teste esperados, fecharia o resíduo.
