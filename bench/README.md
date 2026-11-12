# Benchmarks da E4

Calibração do `llama-server` para o Qwen3.6-35B-A3B nesta máquina: onde ficam os experts, micro-lote, modo de carga, threads, turnos curtos, profundidade de contexto, cache de experts e simulação de turnos de agente.

Resultados, perfil escolhido e justificativas: [`RESULTS-E4.md`](RESULTS-E4.md). Perfil final: [`../runtime/llama-server.args`](../runtime/llama-server.args) e [`../runtime/llama-server.env`](../runtime/llama-server.env).

## Pré-requisitos

- llama.cpp instalado pela E2 (`$LLAMA_CPP_PREFIX/current`, lido de `versions.env`).
- Modelo `~/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (`MODELS_DIR` em `versions.env`).
- `jq`, `curl` e `python3` (só biblioteca padrão).
- **GPU dedicada durante as medições.** Antes de começar, confira no Windows (`/mnt/c/Windows/System32/nvidia-smi.exe`) que nenhum outro processo usa a NVIDIA: nem jogo, nem NVIDIA Broadcast. Nesta E4, um jogo e o Broadcast entraram no meio das medições (ver `RESULTS-E4.md`).
- Feche apps pesados no Windows. Medições em série, uma por vez: são uma GPU e um modelo.

## Arquivos

| Arquivo | O que faz |
|---|---|
| `lib.sh` | Caminhos (de `versions.env`), amostrador de VRAM/RAM/temperatura (1 s, CSV), subir e parar o servidor **pelo PID** |
| `00-baseline.sh <rótulo>` | Replays do PCIe, geração e largura do link, clocks, VRAM e RAM |
| `01-fit.sh <rótulo> [flags]` | Sobe o servidor com `--fit on -c 131072 -ctk q8_0 -ctv q8_0` e registra o que o `--fit` escolheu (use `-lv 4`) |
| `02-bench.sh <rótulo> [flags]` | `llama-bench` com flags fixas (`-fa 1 -ctk q8_0 -ctv q8_0 -ngl 99 -o jsonl`) e amostrador em paralelo |
| `summarize.py` | Tabela Markdown a partir dos JSONL do `llama-bench` |
| `03-server.sh <rótulo> <modo> [flags]` | Sobe o `llama-server`, mede com pedidos reais (`tg`, `agent`, `deep` ou `load`) e encerra |
| `04-final.sh <modo> [rótulo]` | Igual ao anterior, mas lê as flags de `runtime/llama-server.args` e o ambiente de `runtime/llama-server.env`, como a E5 fará |
| `agent_turns.py` | Simula turnos de agente por `/v1/chat/completions` com ferramentas: prompt frio grande, 2 turnos quentes, conversa paralela e volta |
| `tg_requests.py` | 4 pedidos gerando exatamente 256 tokens (`ignore_eos`) e lê `timings.predicted_per_second` |
| `burstmon.sh <arquivo>` | Registra os processos mais ativos quando a fila de execução passa de 14 threads (detecta carga externa) |
| `raw/` | Saídas brutas (fora do git): JSONL, logs do servidor, CSV do amostrador, `vmstat` |

Convenção de nomes em `raw/`: `02-*` são `llama-bench`; `03-*` são `llama-server`; `03-CONTAMINADO-jogo-*` são as execuções que coincidiram com o jogo (guardadas como dado à parte).

## Como reproduzir

Todos os comandos rodam a partir da raiz do repositório. Tempo total: ~1,5 h de máquina.

```bash
# 1. Estado inicial (repita no fim: os replays do PCIe devem continuar em 0)
bench/00-baseline.sh antes

# 2. O que o --fit escolhe para 131072 de contexto, por micro-lote
for ub in 512 1024 2048 4096; do bench/01-fit.sh ub$ub -ub $ub -b 4096 -lv 4; done

# 3. Experts na GPU (-ncmoe) e micro-lote
bench/02-bench.sh A-ncmoe -ncmoe 40,38,36 -ub 2048 -b 4096 -p 512,2048 -n 128 -r 2 -t 12
bench/02-bench.sh A2-ncmoe-vram -ncmoe 38,37,36,35,34 -ub 2048 -b 4096 -p 2048 -n 32 -r 3 -t 12
bench/02-bench.sh B-ub -ncmoe 38 -ub 512,1024,2048,4096 -b 4096 -p 512,2048,4096 -n 0 -r 2 -t 12

# 4. Modo de carga (mmap = memória paginável; none/dio = memória fixada, pinned)
bench/02-bench.sh C-loadmode -ncmoe 38 -lm mmap,none,dio -ub 2048,4096 -b 4096 -p 512,4096 -n 64 -r 2 -t 12

# 5. Threads na geração
bench/02-bench.sh E2-threads -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 6,8,12,16 -p 0 -n 128 -r 3
bench/02-bench.sh G2-tgnoise -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 8 -p 0 -n 128 -r 10

# 6. Turnos curtos: experts copiados para a GPU (nopo 0) contra calculados na CPU (nopo 1)
bench/02-bench.sh D2-smallturn -lm dio -ncmoe 40 -ub 4096 -b 4096 -nopo 0,1 -t 8,12 -p 128,512,1024,2048 -r 3
GGML_OP_OFFLOAD_MIN_BATCH=1024 bench/02-bench.sh D3-minbatch1024 -lm dio -ncmoe 40 -ub 4096 -b 4096 \
  -t 8,12 -p 128,512,1024,2048,4096 -n 0 -r 3

# 7. Profundidade de contexto (a de 65536 leva ~1 min por repetição só para encher o contexto)
GGML_OP_OFFLOAD_MIN_BATCH=1024 bench/02-bench.sh F2-depth-tg -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 8 \
  -p 0 -n 128 -d 16384,65536 -r 3
GGML_OP_OFFLOAD_MIN_BATCH=1024 bench/02-bench.sh F2-depth-pp -lm dio -ncmoe 40 -ub 4096 -b 4096 -t 12 \
  -p 512,4096 -n 0 -d 16384,65536 -r 2

# 8. Cache de experts na GPU (só existe no llama-server). Micro-lote 2048 para caber 2 GiB de cache.
P="-np 1 -c 131072 -fa on -ctk q8_0 -ctv q8_0 -ngl 99 -ncmoe 40 -b 4096 -ub 2048 -t 8 -tb 12 -lm dio --jinja -ctxcp 48 -cms 2048 --cache-ram 12288 --metrics -lv 4"
for mc in 0 1024 2048; do
  SERVER_ENV="GGML_OP_OFFLOAD_MIN_BATCH=1024" bench/03-server.sh M$mc-ub2048 tg $P --moe-cache-mib $mc
done   # em zsh, use ${=P} no lugar de $P

# 9. Perfil final, pelos arquivos de runtime/: turnos de agente com 20k, 64k e ~120k tokens
bench/04-final.sh agent FINAL-20k-ncmoe38
bench/04-final.sh deep FINAL-64k
DEEP_TARGET=120000 DEEP_DETOUR=1 \
DEEP_FILES=/usr/lib/python3.12/argparse.py,/usr/lib/python3.12/typing.py,/usr/lib/python3.12/tarfile.py,/usr/lib/python3.12/_pydecimal.py \
  bench/04-final.sh deep FINAL-128k-ncmoe38

# 10. Estado final
bench/00-baseline.sh depois

# Resumo de todas as execuções do llama-bench
python3 -I bench/summarize.py bench/raw/02-*.jsonl
```

Para ver se carga externa contaminou uma medição, deixe o monitor rodando em paralelo e encerre-o pelo PID:

```bash
bench/burstmon.sh bench/raw/burstmon.log & BM=$!
# ... medições ...
kill $BM
```

## Método e cuidados

- **`llama-bench` para varreduras, `llama-server` para o que só existe nele.** O cache de experts, os checkpoints de contexto, o cache de prompts e o template de chat com ferramentas só existem no servidor.
- **VRAM: vale o servidor, não o `llama-bench`.** O `llama-bench` dimensiona o contexto pelo teste (`p + n + d`) e mostrou picos de até 7,6 GB nas profundidades altas. O servidor reserva tudo na carga (KV de 131072 incluído), e a VRAM ficou plana da carga até 123k tokens de contexto.
- **Pedidos com tempo do próprio servidor.** Os números do servidor vêm de `timings` em cada resposta (`prompt_n`, `prompt_ms`, `predicted_per_second`, `cache_n`); o tempo de parede inclui HTTP e template.
- **Repetições.** Usei `-r 2` ou `-r 3` (`-r 10` para medir ruído). Amostras isoladas lentas aparecem sob carga externa; quando elas existem, a tabela de resultados mostra a faixa, não só a média.
- **Servidor encerrado sempre pelo PID salvo** (`stop_server` em `lib.sh`), nunca por padrão de nome.
- **Processos externos.** Outros serviços locais em containers rodam no WSL o tempo todo; o `burstmon.sh` e o `vmstat` mostram quando algo externo disputa CPU ou RAM.
