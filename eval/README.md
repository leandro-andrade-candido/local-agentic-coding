# Suíte de validação (`eval/`)

Mede, sem intervenção humana, se um agente (Qwen Code, Pi, OpenCode, Claude Code apontado para o modelo local...) resolve tarefas reais de programação. Cobre as tarefas T1–T7 da seção 9 do [plano](../DIAGNOSTICO-E-PLANO.md) (etapa E8). Para o teste comparativo de agentes (etapa E6), traz também 3 tarefas curtas (S1–S3) e 3 verificações de skills (K1–K3).

A suíte não depende de nenhum harness específico. Cada execução segue os mesmos passos:

1. cria um workdir novo a partir de um commit fixado de um repositório público;
2. entrega o prompt ao harness e espera ele terminar, com limite de tempo;
3. roda verificações ocultas, que o agente nunca vê;
4. grava `result.json` com sucesso, tempos, tokens e pico de RAM/VRAM.

Tudo é bash + Python stdlib. As dependências dos repositórios ficam só dentro dos workdirs (`.venv` com uv, `node_modules` local). Nada é instalado globalmente.

## Repositórios usados

| | Python | TypeScript |
|---|---|---|
| Projeto | [pypika](https://github.com/kayak/pypika): construtor de SQL | [chrono](https://github.com/wanasit/chrono) (`chrono-node`): datas em linguagem natural |
| Commit fixado | `443e10f3c7b4c40afbed98216be63146c4fc4a1b` (27/10/2026, 0.51.1+) | `d4fe7e39015c818b271d74789fb96f74777421d0` (tag v2.10.3, 12/10/2026) |
| Licença | Apache-2.0 | MIT |
| Tamanho | ~6,5 mil linhas de código + ~10 mil de testes | ~18 mil linhas de código + ~25 mil de testes, 267 arquivos em `src/` |
| Suíte | 1361 testes em **~1 s** (pytest) | 753 testes em **~8 s** (jest + ts-jest, 16 núcleos) |
| Dependências | nenhuma em runtime; testes: pytest, parameterized | nenhuma em runtime; 133 MB de devDependencies |

Por que esses dois:

- **Tamanho médio e arquitetura com camadas reais.** O pypika tem builders imutáveis (`@builder`), uma árvore de `Term` e dialetos. O chrono tem um pipeline de parsers e refiners e 16 idiomas. Os dois são bons para bugs plantados, recursos novos e explicação de arquitetura.
- **Suítes rápidas e offline.** As suítes rodam em segundos. Isso permite rodar a suíte completa em toda verificação e testar mutantes (T4) em menos de 30 s. Depois do primeiro download (~40 MB de cache), tudo funciona sem rede.
- **Menos contaminação.** São projetos conhecidos, mas longe dos mais famosos (cerca de 2,6 mil e 5 mil estrelas). Os commits fixados são de outubro de 2026. T3 e T6 pedem recursos que **não existem no upstream** (expressões relativas em português e `CREATE VIEW`), então não há solução para o modelo lembrar.
- **Licenças permissivas** e poucas dependências.

O setup apaga dos workdirs os `AGENTS.md`/`CLAUDE.md`/`QWEN.md`/`GEMINI.md` do upstream. O chrono traz um `AGENTS.md` com um resumo da arquitetura, que tornaria o T1 trivial e daria informação diferente a harnesses que leem arquivos diferentes.

## Tarefas

| Id | Repo | Tarefa | Verificação oculta | Tempo máx. |
|---|---|---|---|---|
| T1 | chrono | Explicar a arquitetura em `ARQUITETURA.md`. | Documento existe (≥ 300 palavras), código intacto e **nota ≥ 7/10** no `rubric.md`, dada depois. | 30 min |
| T2 | pypika | Relato de usuário: joins vazam entre queries derivadas da mesma base. Bug plantado: `__copy__` deixou de copiar `_joins`. | 6 testes ocultos e a suíte original inteira. | 30 min |
| T3 | chrono | Recurso novo: "há 3 dias", "daqui a 2 semanas" etc. no locale `pt` (constants + 2 parsers + registro). | 4 testes de aceitação (25 expressões comparadas com o equivalente em inglês, modo strict, frases, casos negativos) e a suíte original. | 30 min |
| T4 | chrono | Escrever testes para `src/calculation/duration.ts`, cujo teste foi removido. | Testes do agente passam e matam **≥ 60%** de 12 mutantes; módulo intacto; suíte original. | 30 min |
| T5 | chrono | Dois testes falham sem ninguém ter mexido neles, e um passa quando roda sozinho. Causa plantada: cache em `parseDuration` devolve o mesmo objeto, que `addDuration` muta. | Suíte original inteira com os testes restaurados, 3 testes ocultos de repetibilidade, `INVESTIGACAO.md` citando `parseDuration` e `addDuration`, e **nota 2/2** da causa raiz no `rubric.md`, dada depois. | 30 min |
| T6 | pypika | Planejar em `PLANO.md` e depois implementar `CREATE VIEW` (OR REPLACE, TEMPORARY, IF NOT EXISTS, colunas, schema, MySQL, materializada no PostgreSQL). | 21 testes ocultos, suíte original e **nota ≥ 7/10** do plano no `rubric.md`. | 45 min |
| T7 | pypika | Revisar o diff não commitado do usuário (`paginate()` + "simplificação" que fez `LIMIT 0` sumir) e corrigir. | 10 testes ocultos (regressão corrigida e recurso mantido) e suíte original. | 30 min |
| S1 | pypika | Smoke: `a - (b + c)` perde os parênteses. | 3 testes ocultos e suíte original. | 15 min |
| S2 | chrono | Smoke: centralizar `YEAR_PATTERN`/`parseYear` duplicados de `pt` e `es` em `src/calculation/years.ts` (3 arquivos). | 3 testes ocultos (comportamento, cópias removidas, parsers) e suíte original. | 15 min |
| S3 | pypika | Smoke: escrever testes para 3 funções de `pypika/utils.py`. | Testes passam e matam ≥ 60% de 6 mutantes; módulo intacto. | 15 min |
| K1 | pypika | Skills, chamada explícita: "use a skill `brainstorming`" para uma ideia vaga, sem interação; perguntas e opções em `BRAINSTORM.md`, sem código. | Transcript mostra a skill carregada; ≥ 3 perguntas e ≥ 2 opções; nenhum arquivo de `pypika/` alterado. | 15 min |
| K2 | pypika | Skills, acionamento automático: testes de BETWEEN falhando (bug plantado no slice `Field[a:b]`); o prompt não cita skills. | Correção: testes ocultos e suíte. **Medição** (não reprova): `systematic-debugging` foi carregada? | 15 min |
| K3 | pypika | Skills, efeito no formato: "use a skill `writing-plans`" para planejar `TRUNCATE TABLE`, sem implementar. | Transcript mostra a skill carregada; plano no formato da skill (marcadores); nenhum arquivo de `pypika/` alterado. | 15 min |

Quando um teste visível do upstream pegaria o bug plantado (T2, T7, S1), ele é **removido da suíte visível** e passa a fazer parte dos testes ocultos. O agente precisa achar o problema pelo relato ou pela revisão, não por um teste vermelho. A exceção é o T5, em que os testes vermelhos são o próprio enunciado (e o K2, em que eles disparam a depuração).

No T6, `.columns()` pode acumular ou substituir: a especificação não define, e o teste oculto de imutabilidade parte de uma base sem colunas, o que vale para as duas leituras e ainda pega lista compartilhada entre cópias do `@builder`.

Os prompts (`task.md`) estão em português, no tom de um pedido real, e não mencionam os testes ocultos. Os de Python dizem como rodar os testes (`.venv/bin/python -m pytest`); os de TypeScript, `npx jest`.

## Como rodar

Pré-requisitos já presentes na máquina: `git`, `uv`, `node`/`npm`, `python3` (3.12), `timeout` e `flock` (coreutils/util-linux). O primeiro setup de cada repositório baixa o commit e as dependências para `eval/.cache/`; depois disso não usa a rede (`EVAL_OFFLINE=1` força isso).

```bash
# uma tarefa com um harness (harness = agents/<nome>/run.sh ou eval/harnesses/<nome>/run.sh)
eval/run.sh qwen-code T2 lote1

# matriz em série: 3 repetições, dois harnesses, T1-T7 (ou: smoke, skills, all, ou lista T2,T5,S1)
eval/matrix.sh -r 3 e8-qwen36 qwen-code,pi full

# tabela agregada (padrão: todas as execuções em eval/runs)
python3 -I eval/summarize.py eval/runs/e8-qwen36

# nota do gabarito (T1, T5, T6)
python3 -I eval/grade.py eval/runs/e8-qwen36/r1/qwen-code/T1/result.json --score 8 --by NOME --notes "..."

# validação da própria suíte, sem LLM (falha antes / passa com a solução de referência)
eval/validate.sh            # todas; ou: eval/validate.sh T2 S1

# ponta a ponta sem LLM, com o harness falso que aplica a solução de referência
eval/matrix.sh -r 1 teste-runner fake-oracle all
```

Uso manual de uma tarefa: `eval/tasks/T2-*/setup.sh /tmp/wd` cria o workdir; o prompt é o `task.md`; `eval/tasks/T2-*/check.sh /tmp/wd` roda as verificações. O `check.sh` sai com 0 (passou), 1 (falhou), 3 (aguarda nota) ou 2 (erro).

**Nunca rode duas execuções em paralelo.** Há uma GPU e um modelo. O `run.sh` usa um lock (`eval/.cache/run.lock`): uma segunda chamada espera a primeira terminar. A matriz já roda em série, na ordem repetição -> tarefa -> harness, para que os harnesses se alternem.

### Variáveis de ambiente

| Variável | Padrão | Efeito |
|---|---|---|
| `LLM_BASE_URL` | `http://127.0.0.1:9931` | Repassada ao harness; também usada para ler `/metrics`. |
| `LLM_MODEL` | `qwen3.6-35b` | Repassada ao harness. |
| `LLM_API_KEY` | lida do arquivo abaixo | Chave do llama-server (E5: exigida em todas as rotas, inclusive `/metrics`). Exportada para o harness (o `run-in-box.sh` repassa `LLM_*`) e usada no `/metrics`. Nunca é impressa; o `result.json` só registra a origem (`env`, `file` ou `none`). |
| `LLM_API_KEY_FILE` | `~/.config/local-agentic/llm-api-key` | Arquivo de `scripts/llm key`, lido quando `LLM_API_KEY` está vazia. Sem chave, o `run.sh` avisa e o `result.json` traz `llm.available: false` com o motivo. |
| `EVAL_TIMEOUT_MIN` | `timeout_min` do `task.json` | Tempo máximo do agente (o padrão das tarefas é 30; T6 45; smoke 15). |
| `EVAL_SAMPLE_INTERVAL` | `3` | Segundos entre amostras de RAM/VRAM. |
| `EVAL_WORK_ROOT` | `~/.cache/local-agentic/eval-work` | Onde ficam os workdirs (fora do repositório). |
| `EVAL_CLEANUP` | `deps` | `deps` apaga `.venv`/`node_modules` no fim e mantém as fontes; `all` apaga o workdir; `none` mantém tudo. |
| `EVAL_FORCE` | `0` | `1` sobrescreve um `result.json` existente. |
| `EVAL_OFFLINE` | `0` | `1` falha em vez de usar a rede quando o cache está frio. |
| `EVAL_WRAPPER` | vazio | `sandbox/run-in-box.sh` roda o agente, a captura do diff e as verificações em containers (seção abaixo). |

### No container (E7)

Com os agentes em modo autônomo, rode sempre pelo container da E7 ([`sandbox/`](../sandbox/README.md)):

```bash
sandbox/build.sh                                   # uma vez, e de novo quando agents/versions.env mudar
EVAL_WRAPPER=sandbox/run-in-box.sh eval/run.sh qwen-code S1 lote1
EVAL_WRAPPER=sandbox/run-in-box.sh eval/matrix.sh -r 3 e6 qwen-code,pi smoke
```

Com `EVAL_WRAPPER`, o `run.sh` usa três containers novos por execução. O setup continua no host, porque ainda não houve agente.

| Passo | Montado (fora isso, nada do host) | Rede |
|---|---|---|
| Agente (`agents/<h>/run.sh`) | workdir e log-dir (leitura e escrita); `prompt.md`, `agents/` e o perfil base de skills (só leitura) | só o llama-server, pelo encaminhador |
| Captura do diff (`git add -A`/`diff`/`rev-list`) | workdir e pasta do resultado | nenhuma |
| Verificações (`check.sh`) | workdir e pasta do resultado; `eval/lib`, `eval/repos`, a pasta da tarefa e o ambiente limpo de dependências (só leitura) | nenhuma |

- **O agente nunca vê `eval/`** (testes ocultos, soluções, gabaritos e outras execuções). A exceção são os harnesses de teste de `eval/harnesses/` (como o `fake-oracle`), que não usam LLM e leem as soluções por definição; para eles, `eval/` entra só leitura.
- **Depois do agente, o host não executa nada do workdir.** Os testes ocultos importam o código que o agente escreveu, e o `git` do host executaria um `core.fsmonitor` ou filtro plantado no `.git/config` do workdir. Por isso a captura do diff e as verificações também rodam em containers, criados depois que o container do agente já foi removido.
- O timeout continua valendo: o `timeout` do `run.sh` encerra o wrapper, que remove o container.
- O fuso do host (`TZ`) é repassado ao container, porque os testes do chrono dependem dele.
- `meta.json` registra o wrapper em `sandbox`.
- Para inspecionar um workdir depois da execução, prefira o `agent.patch`. Para rodar `git` ou testes nele, use `sandbox/agent-shell.sh shell <workdir>`.

## Contrato com os harnesses

Cada harness fornece um executável `agents/<harness>/run.sh`:

```
run.sh --workdir <dir> --prompt-file <arquivo> --log-dir <dir>
```

- Roda o agente sem interação, aprovando automaticamente as ações dentro do workdir, e retorna quando o agente para.
- Grava transcript e logs em `--log-dir`.
- Sai com 0 se o processo do agente terminou normalmente.
- Recebe `LLM_BASE_URL`, `LLM_MODEL` e `LLM_API_KEY` no ambiente.
- Grava o transcript em `<log-dir>/events.jsonl` (formato JSON do próprio agente). As verificações de skills (K1–K3) leem esse arquivo.

O runner executa o harness com `cwd` = workdir, `stdin` = `/dev/null` e `timeout -k 30`. O timeout mata o grupo de processos inteiro: exit 124 ou 137 é registrado como `timed_out`.

Opcional: se o harness gravar `<log-dir>/agent-metrics.json`, o conteúdo vai para `result.json` em `agent.metrics`. As chaves sugeridas são `turns`, `tool_calls`, `tool_call_errors`, `loops_detected`, `tokens_in` e `tokens_out` (do ponto de vista do cliente, incluindo cache). O `summarize.py` soma `tool_call_errors`.

O workdir, o prompt (`<work>/prompt.md`) e o log-dir ficam fora do repositório, em `EVAL_WORK_ROOT`. Os logs são copiados para `eval/runs/...` no fim.

## Estrutura de uma tarefa

```
eval/tasks/T2-pypika-join-leak/
  task.md          prompt entregue ao agente
  task.json        id, repo, categoria, timeout e lista de verificações
  setup.sh         setup.sh <workdir>: idempotente, recria o workdir do zero
  check.sh         check.sh <workdir> [--out checks.json] [--log check.log] [--baseline SHA]
                   [--deps-env DIR] [--agent-logs DIR] [--skills-dirs D1:D2]
  setup.patch      aplicado antes do commit-base: bug plantado e/ou testes visíveis removidos
  pending.patch    (T7) aplicado depois do commit-base, sem commit: o "diff do usuário"
  hidden/          testes ocultos; copiados para o workdir só durante a verificação
  mutants/*.patch  (T4, S3) mutações do módulo testado
  solution.patch   solução de referência (relativa ao estado após o setup)
  solution/        (T1, K1, K3) arquivos de referência copiados para o workdir
  oracle/          (K1-K3) transcript simulado (events.jsonl) usado pelo fake-oracle e pelo validate.sh
  rubric.md        (T1, T6: 10 itens; T5: 2 itens) gabarito
```

As tarefas ficam em `eval/tasks/` (T1–T7), `eval/smoke/` (S1–S3) e `eval/skills/` (K1–K3).

Para criar uma tarefa nova, copie `lib/task-setup.sh` e `lib/task-check.sh` como `setup.sh`/`check.sh`, escreva `task.md` e `task.json`, gere os patches com `git diff` num workdir e confira com `eval/validate.sh <tarefa>`.

O workdir é um repositório git com **um único commit** ("Initial import", autor e data fixos, sempre com o mesmo hash). Não carrega o histórico do upstream, para que o bug plantado não apareça em `git log -p`. `.venv/`, `node_modules/` e afins ficam em `.git/info/exclude`, e o `git status` começa limpo (no T7, só com o diff do usuário).

As verificações (`lib/check.py`) são declarativas no `task.json`:

| Tipo | O que faz |
|---|---|
| `hidden_tests` | Copia `hidden/*` para o workdir, roda com pytest (`--junitxml`) ou jest (`--json`) e remove. |
| `baseline_tests` | Restaura os arquivos versionados sob as pastas de teste que o agente alterou e roda a suíte original inteira ("nada mais quebra"). |
| `unchanged` | Caminhos que não deveriam mudar. |
| `report` | Relatório na raiz: existe, tamanho mínimo, grupos de palavras-chave (pelo menos uma de cada grupo) e, opcionalmente, mínimo de linhas com pergunta e de opções ("Opção A", "Abordagem"...). |
| `mutation` | Acha os arquivos de teste **novos** do agente (inexistentes no commit-base), confirma que passam no código original e aplica cada mutante. O mutante está "morto" se os testes falham. Testes já existentes que o agente editou não contam, e tudo que é versionado sob as pastas de teste volta ao commit-base antes. |
| `rubric` | Não decide sozinho: registra o gabarito e uma pista automática por palavras-chave. O status fica `pending_grading` até a nota. |
| `skill_usage` | Lê o transcript do agente (`events.jsonl`) e diz se a skill foi carregada (seção "Skills"). |
| `plan_format` | Entre os `.md` novos ou alterados, acha o que melhor casa com os marcadores do formato (K3) e registra se o caminho segue a convenção da skill. |

### Os testes não rodam com nada que o agente possa ter alterado

- **Dependências limpas.** O `setup.sh` cria uma vez, antes de qualquer agente, um ambiente por repositório em `eval/.cache/envs/<repo>-<commit>-<lock>/`, instalado do cache. As verificações usam o `.venv` de lá (Python) ou trocam o `node_modules` do workdir por uma cópia nova de lá (Node). O `.venv`/`node_modules` que o agente usou nunca roda nos testes.
- **Configuração na linha de comando.**
  - pytest: `python -I -B -m pytest -c <ini vazio> --rootdir <workdir> --noconftest -p no:cacheprovider`, com `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`. Assim `pytest.toml`, `.pytest.toml`, `pytest.ini`, `.pytest.ini`, `pyproject.toml`, `setup.cfg`, `tox.ini` e qualquer `conftest.py` do repositório são ignorados (o upstream fixado não tem nenhum deles com configuração de pytest).
  - jest: `--config '<json do repo.json + rootDir>'`, que ignora o `"jest"` do `package.json` e qualquer `jest.config.*`, com `--cacheDirectory` novo. Os scripts do `package.json` nunca são chamados.
  - O processo de teste recebe só `PATH`, `HOME` temporária, `TZ`, `LANG` e `CI`: nada de `PYTEST_*`, `PYTHON*` ou `NODE_OPTIONS`.
- **Arquivos versionados de volta ao commit-base.**
  - Configuração: padrões de `protected_config` em `repos/<repo>/repo.json`, como `**/conftest.py`, `tsconfig*.json` e `jest.config.*`. Os novos são apagados.
  - Pastas de teste: testes, `__init__.py` e helpers como `test/test_util.ts`.
  - O que foi restaurado fica em `checks.json`.
- **Limite.** O código sob teste é do agente por definição (os testes ocultos importam o `src/` dele). Um agente que sabote o próprio placar pelo código da biblioteca, por exemplo alterando o `unittest`, só é pego lendo o `agent.patch`.

## `result.json`

Gravado em `eval/runs/<run-id>/<harness>/<task-id>/`, junto com:

| Arquivo | Conteúdo |
|---|---|
| `agent.patch` | Diff do agente, com arquivos novos, capturado antes das verificações. |
| `agent-logs/` | Logs do harness. |
| `agent.stdout`/`agent.stderr` | Saída do harness. |
| `setup.log` | Saída do setup. |
| `checks.json` e `check.log` | Resultado e saída completa dos testes. |
| `metrics.before.prom`/`metrics.after.prom` | Snapshots de `/metrics`. |
| `resources.tsv` | Série de RAM/VRAM. |

`eval/runs/` e `eval/.cache/` estão no `.gitignore`.

```jsonc
{
  "schema_version": 1,
  "run_id": "e8-qwen36/r1", "harness": "qwen-code", "task_id": "T2",
  "task_dir": "eval/tasks/T2-pypika-join-leak", "task_title": "...", "task_category": "bugfix",
  "repo": "pypika", "repo_commit": "443e10f...",
  "status": "pass",            // pass | fail | pending_grading (T1/T5/T6 até a nota) | error (setup ou ambiente falhou)
  "success": true,             // true / false / null
  "auto_checks_pass": true,    // verificações automáticas obrigatórias
  "interventions": 0,          // sempre 0 no runner; ajuste com grade.py --interventions se houve ajuda
  "started_at": "...", "finished_at": "...",
  "timing": {"setup_s": 0.3, "agent_wall_s": 412.7, "check_s": 1.4, "timeout_s": 1800},
  "agent": {"exit_code": 0, "timed_out": false, "commits_made": 0,
            "diff": {"files_changed": 2, "insertions": 11, "deletions": 0},
            "metrics": {/* agent-metrics.json do harness, se existir */}},
  "llm": {"base_url": "...", "model": "...", "api_key_source": "file",   // env | file | none (nunca a chave)
          "available": true, "counter_reset": false,     // sem métricas: "available": false, "reason": "HTTP 401: ..."
          "tokens_in": 182345, "tokens_out": 9120, "prefill_seconds": 520.3, "gen_seconds": 260.1,
          "prefill_tps": 350.5, "gen_tps": 35.1, "decode_calls": 9800, "counters_delta": {/* ... */}},
  "resources": {"interval_s": 3, "samples": 140, "ram_total_mib": 52206,
                "ram_used_mib_first": 30100, "ram_used_mib_peak": 33900, "swap_used_mib_peak": 0,
                "vram_available": true, "vram_total_mib": 8151,
                "vram_used_mib_first": 7300, "vram_used_mib_peak": 7700,
                "process": "llama-server", "process_rss_mib_peak": 23000},
  "checks": [{"name": "testes_ocultos", "type": "hidden_tests", "required": true, "pass": true,
              "detail": "6/6 testes ocultos passaram", "tests": {/* total, failed, failing[] ... */}}],
  "rubric": null,              // T1/T5/T6: {"score": null, "threshold": 7, "max": 10, "auto_hint": 8, ...}
  "paths": {"workdir": "...", "baseline_commit": "...", "agent_patch": "agent.patch", ...},
  "env": {"eval_commit": "abc1234", "eval_dirty": false, "hostname": "...", "kernel": "..."}
}
```

### Métricas

- **Tokens e velocidade:** diferença entre `GET $LLM_BASE_URL/metrics` antes e depois do agente, com `Authorization: Bearer $LLM_API_KEY` (o servidor da E5 exige a chave também no `/metrics`). O `llama-server` precisa rodar com `--metrics`. Os contadores usados são `llamacpp:prompt_tokens_total`, `prompt_seconds_total`, `tokens_predicted_total`, `tokens_predicted_seconds_total` e `n_decode_total`.
  - `tokens_in` conta só o prefill efetivamente processado: tokens reaproveitados do cache de prompt não entram. Assim, `tokens_in` mostra o custo real e `prefill_tps` a velocidade real.
  - O total enviado pelo cliente vem do `agent-metrics.json`, se o harness fornecer.
  - Sem métricas, os campos ficam `null`, `available: false` e `reason` diz o motivo: servidor fora, 401 sem chave ou com chave inválida, 404 sem `--metrics`. O motivo fica também em `metrics.*.prom.err`, e o `summarize.py` mostra um aviso com a contagem por motivo. Se o servidor reiniciar no meio, `counter_reset: true` e os deltas são descartados.
- **RAM e VRAM:** `lib/sampler.py` amostra a cada 3 s:
  - RAM usada = `MemTotal - MemAvailable` (sistema todo) e swap;
  - VRAM via `nvidia-smi --query-gpu=memory.used` (só leitura);
  - RSS do processo `llama-server`.

  Registra a primeira amostra (linha de base) e o pico. Os números são do sistema todo, então **a máquina deve ficar dedicada durante as medições** (decisão 2 do plano).

## T1, T5 e T6: gabarito e nota

- **T1:** o `rubric.md` lista 10 fatos verificáveis sobre a arquitetura do chrono, escritos antes das execuções. Um fato vale 1 ponto se o `ARQUITETURA.md` o afirma corretamente e com os nomes reais. Afirmações inventadas tiram pontos. A resposta de referência fica em `solution/ARQUITETURA.md`.
- **T5:** a parte automática só confere que o `INVESTIGACAO.md` existe e cita `parseDuration` (ou `parsedDurationCache`) **e** `addDuration`. Palavras soltas ("cache", "imutável", "estado compartilhado") não bastam. A causa raiz é conferida por pessoa no `rubric.md` (2 itens, sucesso = 2/2).
- **T6:** o `rubric.md` avalia o `PLANO.md` em 10 itens. O corretor também confere no transcript se o plano foi escrito **antes** das edições em `pypika/`; se não foi, tira 2 pontos. A implementação é avaliada pelos testes ocultos.
- **Fluxo:** o runner grava `status: "pending_grading"`, `rubric.score: null` e `rubric.auto_hint` (0–10). A pista automática conta itens com a palavra-chave esperada e serve só para triagem. O orquestrador e o usuário leem o relatório, dão a nota e registram com `eval/grade.py ... --score N --by NOME`.
- **Sucesso** = verificações automáticas obrigatórias passaram **e** nota ≥ limiar (7/10 no T1 e T6; 2/2 no T5).
- O `summarize.py` lista as execuções que aguardam nota e não as conta na taxa até lá.

## T4 e S3: mutantes

Os mutantes são patches pequenos e corretos em tipo, cada um mudando um comportamento observável:

- **T4:** unidade errada numa abreviação, fator do trimestre, frações, sinal da hora, `reverseDuration` sem inverter etc.;
- **S3:** `all`/`any`, aspas não escapadas, precedência de `alias_quote_char` etc.

Os testes de referência (o arquivo removido do upstream, no T4) matam 12/12 e 6/6. Um mutante que não aplica (o agente mexeu no módulo) é restaurado e registrado. A meta é ≥ 60%, como no plano.

Só contam arquivos de teste **novos**. No T4, os testes de `test/en/*_time_units_*` já passam por `addDuration`. Se um teste já existente contasse quando o agente o editasse, até uma edição de passagem inflaria a nota. Por isso eles ficam fora, aparecem em `ignored_existing_test_files` e voltam ao commit-base antes da mutação.

## Skills (K1–K3)

Medem, por harness, se as skills montadas em `AGENT_SKILLS_DIRS` (perfil base `skills/profiles/base.txt`; `/opt/skills/...` no container) funcionam com o modelo local:

- **K1, chamada explícita:** o prompt pede a skill `brainstorming`. A tarefa passa se a skill foi carregada, se o `BRAINSTORM.md` tem perguntas e opções, e se nenhum código mudou.
- **K2, acionamento automático:** um bug comum, sem citar skills. Registra se `systematic-debugging` foi carregada; isso é medição e não reprova. O sucesso da tarefa é a correção.
- **K3, efeito no formato:** o prompt pede a skill `writing-plans`. A tarefa passa se a skill foi carregada e o plano tem os marcadores do formato. O caminho da convenção (`docs/superpowers/plans/AAAA-MM-DD-*.md` ou `docs/plans/`) é só medição.

**"Skill carregada"** é decidido pelo `events.jsonl` do log do agente, olhando só os **argumentos** das chamadas de ferramenta, nunca os resultados (um `find -name SKILL.md` listaria todas):

1. qualquer ferramenta cujo argumento contenha `.../<skill>/SKILL.md` (read, `cat`, `sed -n`...). Registra-se também se o caminho está sob as pastas de skills que o agente viu (`--skills-dirs`: `/opt/skills` com `EVAL_WRAPPER`, senão `$AGENT_SKILLS_DIRS`);
2. ou uma ferramenta cujo nome contém "skill" com o nome da skill no argumento (aceita `superpowers:<nome>` e `/<nome>`).

Definições de ferramenta (JSON schema) não contam.

| Harness | Formato do `events.jsonl` (de `agents/lib/agent_metrics.py`) | Como a skill deve aparecer | Estado |
|---|---|---|---|
| claude-local | stream-json: `assistant` → `tool_use` (`name`, `input`) | ferramenta `Skill` (`{"skill": ...}`) ou `Read` do `SKILL.md` | não verificado |
| qwen-code | stream-json, igual ao Claude | ferramenta de skill do Qwen (nome com "skill") ou `read_file` do `SKILL.md` | não verificado |
| pi | `message_end` → `toolCall` (`name`, `arguments`) | `read` do `SKILL.md` (o Pi lista as skills com o caminho no prompt) | não verificado |
| opencode | `tool_use` → `part.tool` + `part.state.input` | ferramenta nativa `skill` (`{"name": ...}`) ou `read` | não verificado |
| codex-local | `item.*` → `command_execution.command` | comando de shell que lê o `SKILL.md` | não verificado |

Os `oracle/events.jsonl` do K1 (formato Claude), K2 (Pi) e K3 (OpenCode, ferramenta `skill`) exercitam a detecção sem LLM. Quando os agentes rodarem de verdade, conferir num transcript real de cada um. Se um agente carregar skills de outro jeito (por exemplo, injetando o texto sem chamada de ferramenta), a detecção dele precisa de outra regra.

Os marcadores de formato do K3 (título "Implementation Plan", Goal, `### Task N`, `**Files:**`, passos `- [ ]`, blocos de código, comando de teste) seguem o `writing-plans` do Superpowers conhecido até a v6. **Não foram conferidos com o `SKILL.md` da v6.4.1 fixada**, que ainda não foi baixada. Depois do `scripts/fetch-skills.sh`, comparar e ajustar `markers`, `optional_markers` e `path_regex` no `task.json` do K3.

## Validação feita (29/10/2026, sem LLM)

> **Precisa ser refeita.** Esta validação é anterior ao lote que trouxe I1, I5, I6, I7, as tarefas K1–K3 e a chave da API. O lote foi conferido só estaticamente (`bash -n`, `py_compile`, JSON e um teste de unidade da detecção de skills), porque a máquina estava ocupada pela E4. Com o T5 agora pedindo nota, (b) dele passa a ser "aguarda nota".

`eval/validate.sh`: para cada tarefa, (a) logo após o setup as verificações **falham**, e (b) com a solução de referência elas **passam** (T1 e T6 ficam em "aguarda nota", com pista automática 10/10).

```
TAREFA                           (a) após setup        (b) após solução    RESULTADO
T1-chrono-architecture           falha (ok)             aguarda nota (ok)      OK
T2-pypika-join-leak              falha (ok)             passa (ok)             OK
T3-chrono-pt-relative            falha (ok)             passa (ok)             OK
T4-chrono-duration-tests         falha (ok)             passa (ok)             OK
T5-chrono-flaky-duration         falha (ok)             passa (ok)             OK
T6-pypika-create-view            falha (ok)             aguarda nota (ok)      OK
T7-pypika-review-pagination      falha (ok)             passa (ok)             OK
S1-pypika-arith-parens           falha (ok)             passa (ok)             OK
S2-chrono-shared-year            falha (ok)             passa (ok)             OK
S3-pypika-utils-tests            falha (ok)             passa (ok)             OK
```

Ponta a ponta com o harness `fake-oracle`:

- `eval/matrix.sh -r 1 e2e-oracle fake-oracle all`: 8 pass, 2 aguardando nota (T1, T6), 0 erros, ~1,5 min no total. Depois de `grade.py`, T1 e T6 viraram pass.
- Caminhos negativos: `FAKE_ORACLE_MODE=noop` em S1 e T5 deu fail. `FAKE_ORACLE_MODE=sleep:60 EVAL_TIMEOUT_S=5` em S3 deu exit 124, `timed_out: true` e fail, sem processo remanescente.
- Sem `llama-server` rodando, `/metrics` indisponível resultou em `llm.available: false`, sem erro.

## Limitações conhecidas

- **Isolamento.** Sem `EVAL_WRAPPER`, o agente roda no host. O workdir fica fora do repositório e o agente não recebe nenhum caminho para `eval/`, mas um agente que vasculhe o disco pode achar `hidden/` e `solution.patch`. Com `EVAL_WRAPPER=sandbox/run-in-box.sh` (E7), o container do agente monta só o workdir, o log-dir, o prompt e `agents/`. Os resultados não são à prova de um agente que ataque o próprio placar: o código dele roda nas verificações, com a pasta do resultado montada.
- **Contaminação.** Os dois projetos são públicos e os modelos podem tê-los visto. T2, T5 e T7 usam bugs plantados que não existem no upstream. T3 e T6 pedem recursos inexistentes. T4 tem o risco maior: o arquivo de teste removido existe no GitHub.
- **T5:** um relatório correto que não cite `parseDuration` nem `addDuration` pelo nome reprova na parte automática. A causa raiz em si é sempre conferida por pessoa.
- **Skills:** a detecção depende do formato de transcript de cada agente, ainda não conferido com execuções reais, e os marcadores do K3 não foram conferidos com a v6.4.1 (seção "Skills").
- **RAM/VRAM** são do sistema todo, não só do agente e do servidor.
- **Fuso horário.** Os testes do chrono e os testes ocultos usam datas locais e passam em `America/Sao_Paulo`. As datas foram escolhidas longe de transições de horário de verão, mas outra máquina ou fuso deve rodar `eval/validate.sh` antes.
- **Tokens do cliente** (incluindo cache) e erros de chamada de ferramenta dependem do harness gravar `agent-metrics.json`. Sem isso, só há os números do servidor.
