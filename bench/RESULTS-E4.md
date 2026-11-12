# E4: benchmark do Qwen3.6-35B-A3B e perfil do llama-server

> **Verificação independente (29/10, 12:11–12:31):** as 7 afirmações passaram ([`docs/verifications/E4.md`](../docs/verifications/E4.md)). Algumas magnitudes aqui ficaram maiores que as remedidas, sem mudar nenhuma conclusão:
> - `MIN_BATCH=1024`: ~2,2× em pp128.
> - `-t 16` contra `-t 8`: −18 a 19% na geração.
> - `--moe-cache-mib 1024`: −22% na geração.
> - Ao medir, descarte os 1–2 primeiros pedidos depois da carga, que são ~10% mais lentos.

Executada em 29/10/2026, das 10h36 às 12h05. Build `b11982` do llama.cpp (CUDA 12.8). Modelo `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (22,35 GB). Método e comandos em [`README.md`](README.md); saídas brutas em `bench/raw/` (fora do git).

## Resumo

**Perfil escolhido** ([`runtime/llama-server.args`](../runtime/llama-server.args) + [`runtime/llama-server.env`](../runtime/llama-server.env)):

```
-np 1 -c 131072 -fa on -ctk q8_0 -ctv q8_0 -ngl 99 -ncmoe 38 --fit on --fit-target 384
-b 4096 -ub 4096 -t 8 -tb 12 -lm dio --jinja --reasoning-preserve
-ctxcp 48 -cms 2048 --cache-ram 12288 --metrics --temp 0.6 --top-p 0.95 --top-k 20
ambiente: GGML_OP_OFFLOAD_MIN_BATCH=1024
```

**O que um agente vai sentir** (servidor real, pedidos com ferramentas e template de chat):

| Situação | 20k tokens de contexto | 64k | ~120k |
|---|---|---|---|
| Prompt frio (perda de cache): tempo de prefill | **16,2 s** (1.242 tok/s) | **58,2 s** (1.100 tok/s) | **128,6 s** (934 tok/s) |
| Turno quente (+350 a 450 tokens anexados) | **1,0 a 1,2 s** | 1,2 a 1,3 s | 1,3 a 1,5 s |
| Volta a uma conversa depois de outra (cache de prompts na RAM) | 0,41 s | — | 0,48 s |
| Geração | **30 a 32 tok/s** | 25 a 26 tok/s | 21 a 23 tok/s |
| Geração com contexto curto | 34 a 37 tok/s | | |

**Veredictos**
- **PCIe Gen4 ×8 estável:** contador de replays em 0 antes, durante e depois de ~1,5 h de carga, incluindo o período com um jogo usando a GPU. **[medido]**
- **`--moe-cache-mib`: não usar.** Com 1024 MiB a geração caiu 36%; com 2048 MiB, 21%. O CPU calcula os experts mais rápido do que a PCIe consegue trazê-los para a GPU. **[medido]**
- **Reuso de cache entre turnos funciona:** o turno seguinte reprocessa só o que foi anexado (444 tokens de 20.618), e a conversa principal volta do cache na RAM depois de um desvio (39 tokens reprocessados). **[medido]**

**Surpresas**
1. **Para turnos curtos, calcular os experts na CPU é mais rápido que copiá-los para a GPU.** Lote de 128 tokens: 384 tok/s na CPU contra 141 tok/s copiando pela PCIe. O cruzamento fica em ~1.000 tokens, e daí vem `GGML_OP_OFFLOAD_MIN_BATCH=1024`.
2. **O prefill paga um custo fixo de ~0,9 a 1,2 s por micro-lote,** quase independente do tamanho. Micro-lote de 4096 rende +45% em prompts longos em relação a 2048.
3. **Memória fixada (`-lm dio`/`none`) acelera o prefill em 10 a 27%** em relação ao `mmap` padrão. Mas `-lm none` leva ~2,5 min para carregar, contra ~30 s com `dio`.
4. **16 threads é o pior valor para geração** (−20 a 30%). 6 a 8 threads é o melhor.
5. **Mais camadas de experts na GPU rendem pouco:** ~1 a 1,5% por camada. A geração é limitada pela troca CPU↔GPU a cada camada, não pela banda da RAM.

## Premissa de uso e condições das medições

**Premissa decidida pelo usuário:** quando a IA está em uso, a GPU é dedicada a ela (sem jogos, NVIDIA Broadcast fechado). Por isso o perfil usa a GPU inteira e deixa só ~470 MiB de folga para variações do driver/WDDM, não para outros apps. Se outro app usar a NVIDIA ao mesmo tempo, o desempenho cai pela metade (seção 11).

**Interferências durante a E4 e o que foi feito**

| Quando | O quê | Execuções afetadas | Tratamento |
|---|---|---|---|
| ~10h39–10h40 (horário informado pelo orquestrador: "10h5x–11h0x") | Checagem SHA-256 do GGUF pelo orquestrador (1 núcleo + banda de RAM) | Pela minha marcação de tempo, só as cargas do `--fit` (que medem memória, não velocidade). Pela janela informada, também `E-threads`, `D-smallturn`, `D3`, `F-depth` (10h54–11h07) | `E` e `D` refeitos às 11h42 (`E2`, `D2`), `F` refeito às 11h12 (`F2`); conclusões iguais. `D3` não foi refeito: o servidor confirmou o efeito depois |
| 11h08–11h09 | Carga externa não identificada: fila de 37 a 55 threads e −6 GB de RAM livre por ~4 s, duas vezes (`raw/02-G-tgnoise.vmstat`) | `G-tgnoise` (2 de 10 amostras a 12 e 16 tok/s) | Refeito (`G2`, sem picos) e monitor `burstmon.sh` ligado no resto da sessão |
| **11h26–~11h37** | **Jogo (Dota 2) na NVIDIA** (C+G, 100% da GPU, 126 W, ~2 GB de VRAM), visto no `nvidia-smi` do Windows | `03-CONTAMINADO-jogo-M2048-ub2048`, `03-CONTAMINADO-jogo-FINAL-64k-ncmoe40` | Refeitos com a GPU livre; os contaminados ficaram como dado à parte (seção 11) |
| 11h26–~11h47 | NVIDIA Broadcast como processo de computação na NVIDIA: 144 MiB, 1 a 3% de uso com a GPU ociosa (até ~14% em picos) | `M2048-rerun`, `FINAL-64k-ncmoe40`, `E2-threads`, `D2-smallturn` | Mantidos com a ressalva: geração possivelmente 2 a 5% mais baixa e mais ruidosa. Fechado pelo usuário; as execuções das 11h47 em diante estão limpas |
| A sessão inteira | Outros serviços locais em containers (healthchecks periódicos) | Picos de 15 a 26 threads de poucos ms no `burstmon` | Desprezível |

Antes das 11h26 a VRAM partia de 0 MiB com 0% de uso em todas as execuções. Depois partia de 144 MiB (Broadcast). A partir das 11h47, de 0 MiB outra vez (`raw/03-*.csv`, primeira linha).

## 1. PCIe e estado da máquina

| Momento | Link | Replays | GPU | VRAM usada | RAM disponível |
|---|---|---|---|---|---|
| 10h38 (antes) | Gen4 ×8 | 0 | 31 °C, P8 | 0 MiB | 48,8 GiB |
| 11h37 (logo após o jogo) | Gen4 ×8 | 0 | 53 °C | 144 MiB (Broadcast) | 48,5 GiB |
| 11h41 | Gen4 ×8 | 0 | 54 °C | 144 MiB | — |
| 12h05 (final, depois da carga de 128k) | Gen4 ×8 | 0 | 40 °C, P8 | 0 MiB | — |

- Contadores de lentidão térmica (`SW/HW Thermal Slowdown`) em 0 µs na sessão inteira. Só o teto de potência de 130 W atuou (`SW Power Capping`), o que é normal sob carga.
- **Veredicto: Gen4 ×8 estável.** Não houve erro de CUDA, texto corrompido nem queda de link.

## 2. Onde ficam os experts

**O que o `--fit` escolhe** (`01-fit.sh`, contexto 131072, KV q8_0, folga padrão de 1024 MiB; o CUDA vê 7.062 MiB livres de 8.150):

| Micro-lote | Escolha do `--fit` | VRAM própria | Modelo | Contexto (KV + estado recorrente) | Buffer de cálculo |
|---|---|---|---|---|---|
| 512 | 37 camadas de experts na RAM + 1 parcial | 5.854 MiB | 3.987 | 1.422 | 444 |
| 1024 | 38 + 1 parcial | 5.870 | 3.815 | 1.422 | 632 |
| 2048 | 38 + 1 parcial | 5.954 | 3.523 | 1.422 | 1.008 |
| 4096 | **ruim:** 2 camadas inteiras (com atenção) na CPU | 5.949 | 2.562 | 1.418 | 1.968 |

- Com todos os experts na RAM, os pesos densos ocupam 2.038 MiB na GPU. Cada camada de experts custa 464 a 560 MiB (o UD varia a quantização por camada).
- KV de 131072 tokens em q8_0: 1.360 MiB, ou 10,6 KiB por token (só 10 camadas de atenção completa; o plano estimava 20 KiB). Estado recorrente (DeltaNet): 63 MiB.
- Com micro-lote de 4096, ficar só com pesos densos deixaria 1.023 MiB livres, 1 MiB abaixo da folga padrão. Por isso o `--fit` tirou camadas inteiras da GPU, o pior resultado possível. Com `-ngl 99 -ncmoe` explícitos isso não acontece.

**Ganho por camada na GPU** (`llama-bench`, `mmap`, micro-lote 2048, 12 threads):

| `-ncmoe` | pp2048 (tok/s) | tg (tok/s) |
|---|---|---|
| 40 | 968 | 32,2 (1 amostra válida; a outra, 12,1, foi um pico externo) |
| 38 | 1.013 | 35,0 |
| 36 | 1.055 | 36,5 |
| 34 | 1.088 | 37,2 |

Com micro-lote 4096, 8 threads e `dio`: tg de 36,1 (`-ncmoe 40`) contra 36,7 (`-ncmoe 38`). **Cada camada rende ~1 a 1,5%.** A geração não é limitada pela banda da RAM (o teto teórico seria ~100 tok/s). O limite é o custo fixo de ~76 trocas CPU↔GPU por token. **[medido / interpretação]**

**Escolha:** `-ncmoe 38` com micro-lote 4096. Ocupa 6.571 MiB e deixa **472 MiB livres** na visão do CUDA (`raw/03-K2-ncmoe38.log`), dentro da folga de 300 a 500 MiB decidida para GPU dedicada. Alternativa testada: o `--fit` com folga de 384 MiB e camadas livres escolheu 1 camada + 1 parcial (6.450 MiB, 594 livres). O desempenho é equivalente, mas preferi o valor explícito porque não depende da heurística do `--fit` mudar entre versões.

## 3. Micro-lote: custo fixo por micro-lote

`llama-bench`, `-ncmoe 38`, `mmap`, tok/s:

| Micro-lote | pp512 | pp2048 | pp4096 |
|---|---|---|---|
| 512 | 378 | 301 ± 99 | 357 |
| 1024 | 388 | 638 | 590 |
| 2048 | 389 | 1.013 | 1.009 |
| 4096 | 366 | 1.020 | **1.477** |

- O tempo por micro-lote segue `t ≈ custo fixo + n / ~2.450 tok/s`. O custo fixo é **~1,2 s com `mmap`** e **~0,86 s com memória fixada** (`dio`). **[medido]**
- O custo fixo é atribuído à transferência dos experts da RAM para a GPU. Pela taxa implícita, nem todos os 18 GB são copiados a cada micro-lote, ou a cópia se sobrepõe ao cálculo. O mecanismo não foi verificado.
- No servidor, com o prompt frio de 20k tokens: **16,5 s com micro-lote 4096 contra 22,0 s com 2048** (−25%). A geração não muda.
- Custo do micro-lote 4096: +1,1 GB de buffer de cálculo na GPU (2.114 contra 1.008 MiB) e +576 MiB fixados na RAM (1.152 contra 576 MiB).

## 4. Modo de carga: mmap contra memória fixada

`llama-bench`, `-ncmoe 38`, tok/s:

| Modo | Micro-lote | pp512 | pp4096 | tg64 | Tempo de carga |
|---|---|---|---|---|---|
| `mmap` (padrão) | 2048 | 406 | 1.015 | 35,0 | ~6 s (arquivo no cache de página) |
| `mmap` | 4096 | 378 | 1.240 (1.402 / 1.079) | 33,7 | |
| `none` (memória fixada) | 2048 | 460 | 1.114 | 35,6 | **~2,5 min** (GPU parada, RAM estável) |
| `none` | 4096 | 461 | 1.573 | 33,8 | |
| `dio` (DirectIO + memória fixada) | 2048 | 465 | 1.128 | 27,9 * | **~30 a 34 s** no servidor |
| `dio` | 4096 | **480** | **1.620** | 19,4 * | |

\* A geração com `dio` teve amostras isoladas lentas (22,7 e 6,4 tok/s) num momento de pressão de memória externa. Nas execuções seguintes com `dio`, a geração ficou em 33 a 37 tok/s.

- Com memória fixada, os pesos dos experts vão para um buffer `CUDA_Host` (19.275 MiB com `-ncmoe 40`), que aparece como `Shmem` no `/proc/meminfo`. O próprio llama.cpp avisa: *"tensor overrides to CPU are used with mmap enabled - consider using --load-mode none for better performance"*.
- `mlock` não foi testado: o limite `memlock` é de 64 MiB e só sobe com `sudo`. A memória fixada já impede a troca para o swap.
- `--no-host` (reempacotamento dos pesos para a CPU) e `GGML_CUDA_REGISTER_HOST` não foram testados (questões em aberto).

## 5. Turnos curtos: CPU contra cópia para a GPU

Um agente anexa de 100 a 2.000 tokens por turno. Por padrão, qualquer lote com 32 tokens ou mais copia os experts para a GPU (`GGML_OP_OFFLOAD_MIN_BATCH=32`). `llama-bench`, `-ncmoe 40`, micro-lote 4096, `dio`, tok/s (`D2`, 11h42, com a ressalva do Broadcast):

| Lote | Copiando para a GPU (padrão) | Na CPU, 8 threads (`-nopo 1`) | Na CPU, 12 threads | `MIN_BATCH=1024`, 12 threads (`D3`) |
|---|---|---|---|---|
| 128 | 141 | 371 | 372 | **384** |
| 512 | 451 | 504 ± 172 | 568 | **580** |
| 1024 | 744 | 761 | 694 | 730 (já vai para a GPU) |
| 2048 | 1.135 | 786 | 675 ± 117 | **1.116** |
| 4096 | — | — | — | **1.510** |

- Na CPU, o tempo cresce ~1,2 ms por token. Pela GPU, há o custo fixo de ~0,9 s. **O cruzamento fica em ~1.000 tokens.** **[medido]**
- `GGML_OP_OFFLOAD_MIN_BATCH=1024` junta o melhor dos dois caminhos: **2,7× mais rápido em lotes de 128** e +29% em lotes de 512, sem perder nada nos lotes grandes.
- Para o caminho da CPU, 12 threads (`-tb 12`) rendem um pouco mais que 8. Com 16 threads foi pior e instável (`D`: pp128 de 131 ± 52).
- No servidor, os turnos quentes de 346 a 444 tokens levam 1,0 a 1,2 s (20k) e 1,3 a 1,5 s (120k). Esse tempo inclui criar 2 a 3 checkpoints (63 MiB cada) e o template.

## 6. Threads na geração

`llama-bench` tg128, micro-lote 4096, `dio`, tok/s:

| Threads | `E` (10h54, `-ncmoe 40`) | `E` (`-ncmoe 38`) | `E2` (11h42, Broadcast ativo) | `G2` (11h09, limpo, 10 repetições) |
|---|---|---|---|---|
| 6 | 32,7 ± 5,3 | 37,0 | 35,7 | |
| 8 | 36,1 | 36,7 | 32,1 ± 3,8 | **34,9 ± 2,4** |
| 12 | 33,8 | 35,1 | 33,1 | |
| 16 | 26,9 ± 4,0 | 29,1 ± 4,9 | 24,8 | |

- 6 a 8 threads dão o melhor resultado, 12 fica ~3 a 5% abaixo e 16 perde 20 a 30%.
- O WSL vê 16 vCPUs (8 núcleos × 2 SMT, 1 L3 de 96 MB) e o Hyper-V não fixa vCPU em núcleo. Por isso não dá para escolher o CCD com cache 3D por afinidade.
- Escolha: **`-t 8`** para a geração e **`-tb 12`** para os lotes na CPU.

## 7. Curva de profundidade

`llama-bench` `F2` (11h12–11h17, limpo), `-ncmoe 40`, micro-lote 4096, `dio`, `MIN_BATCH=1024`, tok/s:

| Profundidade | pp512 (caminho CPU, 12 threads) | pp4096 (caminho GPU) | tg128 (8 threads) |
|---|---|---|---|
| 0 | 580 | 1.622 | 34,9 |
| 16.384 | 600 | 1.209 (1.388 / 1.030) | 33,6 |
| 65.536 | 518 | 843 (751 / 935) | 24,4 (27,0 / 20,5 / 25,6) |

- O pp4096 em profundidade alterna entre repetições num padrão que se repete (rápida/lenta em 16k, lenta/rápida em 64k). A tabela mostra as duas amostras.
- No servidor, com prompts reais, a geração ficou em 30 a 32 tok/s com 20k de contexto, 25 a 26 com 64k e 21 a 23 com ~120k.

## 8. Cache de experts na GPU (`--moe-cache-mib`)

Servidor, `-ncmoe 40`, micro-lote 2048 (para a cache de 2 GiB caber), 4 pedidos de 256 tokens:

| Cache | Geração (tok/s) | Média | Taxa de acerto (lote ≤ 8) | Enviado à GPU durante o teste | VRAM no pico |
|---|---|---|---|---|---|
| 0 | 33,4 / 36,8 / 35,9 / 36,3 | **35,6** | — | — | 4.728 MiB |
| 1024 MiB | 23,4 / 22,6 / 23,1 / 22,7 | 22,9 (**−36%**) | 43,5% | 343 GB | 5.862 MiB |
| 2048 MiB (refeito, Broadcast ativo) | 29,6 / 28,7 / 25,7 / 28,6 | 28,1 (**−21%**) | 60,7% | 239 GB | 6.887 MiB |

- **Veredicto: não usar.** Mesmo com 60% de acerto, cada falha envia o expert pela PCIe, e isso é mais lento que calcular na CPU (Zen 5 com AVX-512).
- A promessa de "até 2,2×" vale para máquinas em que o cálculo na CPU é o gargalo, o que não é o caso aqui.
- A execução contaminada pelo jogo (2048 MiB) foi pior ainda: 4,5 a 28 tok/s, carga de 123 s e 7.857 MiB de VRAM (seção 11).

## 9. Simulação de turnos de agente

`agent_turns.py` pelo `/v1/chat/completions`, com template de chat e 8 ferramentas (como num agente de programação). Sequência:
1. Prompt frio: system + ferramentas + um arquivo-fonte grande colado (`argparse.py`; mais arquivos para 64k e 120k).
2. Dois turnos quentes: a resposta do modelo (raciocínio + chamada de ferramenta) é devolvida, e anexa-se o resultado da ferramenta e uma mensagem do usuário.
3. Uma conversa paralela diferente (como um subagente ou um pedido de título).
4. A volta à conversa principal.

| Execução (perfil) | Frio: tokens | Frio: prefill | Turno 2: reprocessados / em cache | Turno 2: tempo | Turno 3 | Desvio (1.427 tokens) | Volta: reprocessados | Volta: tempo | Geração |
|---|---|---|---|---|---|---|---|---|---|
| `S1` (`-ncmoe 40`, micro-lote 4096) | 20.065 | 16,5 s | 444 / 20.174 | 1,24 s | 346: 1,02 s | 2,45 s | 39 | 0,43 s | 32,0 a 32,9 |
| `M0` (`-ncmoe 40`, micro-lote **2048**) | 20.065 | 22,0 s | 444 / 20.174 | 1,19 s | 346: 1,04 s | 2,44 s | 39 | 0,41 s | 30,8 a 31,7 |
| **`FINAL-20k-ncmoe38`** | 20.065 | **16,2 s** | 444 / 20.174 | **1,19 s** | 346: **1,03 s** | 2,47 s | 39 | **0,41 s** | 30,4 a 31,8 |
| `FINAL-64k-ncmoe40` (Broadcast ativo) | 64.065 | **58,2 s** | 444 / 64.146 | 1,29 s | 346: 1,24 s | — | — | — | 24,8 a 26,3 |
| `FINAL-128k-ncmoe40` | 120.065 | 127,5 s | 444 / 120.191 | 1,48 s | 349: 1,39 s | 2,75 s | 39 | 0,50 s | 20,6 a 21,4 |
| **`FINAL-128k-ncmoe38`** | 120.065 | **128,6 s** | 444 / 120.191 | **1,45 s** | 349: **1,30 s** | 2,47 s | 42 | **0,48 s** | 21,4 a 22,6 |

**O que o log mostra** (`-lv 4`, `raw/03-S1-agent.log`):
- **Prompt frio:** checkpoints criados nas posições 1.585, 15.969 (fim − 4.096) e 20.061 (fim − 4), de 62,8 MiB cada. Ou seja, não a cada 2.048 tokens: o `-cms` é só o espaço mínimo. Nos turnos quentes, 2 ou 3 checkpoints por turno.
- **Turno 2:** `selected slot by LCP similarity, f_sim_best = 0.978, f_keep = 1.000`. O histórico reenviado bateu token a token com o cache, inclusive o raciocínio e a chamada de ferramenta gerados pelo próprio modelo (efeito do `--reasoning-preserve`). Não foi preciso restaurar checkpoint.
- **Desvio:** a outra conversa só compartilha ~1.011 tokens (o bloco de ferramentas), menos que o primeiro checkpoint (1.585). Por isso o log registra `forcing full prompt re-processing due to lack of cache data`, o esperado para uma conversa diferente. Antes, a conversa principal foi salva no cache de prompts: 21.212 tokens, 283 MiB de estado + 9 checkpoints = 849 MiB, em 0,6 s.
- **Volta:** a conversa principal foi restaurada do cache na RAM; só 39 tokens foram reprocessados.
- **Sem `-lv 4`:** o log só mostra a linha `selected slot by LCP similarity ... f_keep`. Os checkpoints e o aviso de reprocessamento completo não aparecem. Para conferir o reuso de cache sem `-lv 4`, use `timings.cache_n`/`prompt_n` das respostas ou `llamacpp:prompt_tokens_total` em `/metrics`.

**Custo real de uma perda de cache** (prompt frio, perfil final): **~16 s para 20k tokens, ~58 s para 64k e ~2 min 9 s para 120k.** Com o preâmbulo dos agentes (seção 2 do plano), isso dá ~25 s no Claude Code (~30k), ~6 s no OpenCode (~7,5k) e ~1,5 s no Pi (~1,4k). **[estimado a partir do medido]**

As chamadas de ferramenta vieram com formato válido em todos os turnos frios e quentes até ~123k de contexto; não houve texto corrompido. Alguns turnos com 120k bateram o limite de 1.200 tokens de saída durante o raciocínio.

## 10. Memória e temperatura sob carga

Perfil final (`-ncmoe 38`, micro-lote 4096, `dio`), execuções `FINAL-20k-ncmoe38` e `FINAL-128k-ncmoe38`:

| Recurso | Valor |
|---|---|
| VRAM (`nvidia-smi`) | **6.794 a 6.796 MiB**, plana da carga até 123k tokens de contexto (289 amostras em ~5 min) |
| VRAM (visão do CUDA) | modelo 3.035 + contexto 1.422 + cálculo 2.114 = 6.571 MiB; **472 MiB livres**; o WDDM reserva ~1.090 MiB que o CUDA não usa |
| Transbordo para memória compartilhada | Não houve: VRAM abaixo do total, geração estável (21 a 22 tok/s sustentados com 120k) |
| RAM do processo (RSS) | 19,6 GiB após a carga; pico de 22,5 GiB |
| Memória fixada (`CUDA_Host`) | ~17,9 GiB de experts + 1,1 GiB de buffer de cálculo |
| `MemAvailable` mínimo | 26,0 GiB (de 51 GiB visíveis no WSL), com o cache de prompts ainda pequeno |
| Swap | ~200 MB foram usados uma vez durante os `llama-bench` com `none`/`dio` (outros processos); sem crescimento nos testes do servidor |
| Temperatura da GPU | máxima de **82 °C** em ~6 min de carga contínua; 0 µs de lentidão térmica; só o teto de 130 W atuou |
| Carga do servidor até responder | 32 a 34 s |

**Orçamento de RAM no pior caso** **[estimado]**: ~20 GiB do processo + até 3 GiB de checkpoints (48 × 63 MiB) + até 12 GiB de cache de prompts = ~35 GiB. Sobram ~16 GiB dos 51 GiB do WSL para o container do agente, builds e testes.

**Folga de VRAM com 128k:** o servidor reserva o KV de 131072 tokens e os buffers de cálculo na carga. A VRAM não cresceu com a profundidade (medido até 123k). A folga de 472 MiB vale para o contexto cheio.

O `llama-bench` mostrou até 7,6 GB nas profundidades altas porque dimensiona contexto e buffers a cada teste. Esse número não representa o servidor.

Alternativa caso a folga se mostre curta na E5: `-ncmoe 40` (1.348 MiB livres, ~2% mais lento) ou micro-lote 2048 (+1,1 GB livres, prompt frio 33% mais lento).

## 11. Dado à parte: a GPU dividida com um jogo

O usuário abriu um jogo (Dota 2) na NVIDIA entre ~11h26 e ~11h37, de propósito, para ver o efeito. Duas execuções coincidiram com ele e ficaram guardadas como `raw/03-CONTAMINADO-jogo-*`. A comparação é com as mesmas medições refeitas com a GPU livre:

| Medida | GPU livre | Com o jogo | Variação |
|---|---|---|---|
| Carga até responder (`-ncmoe 40`, micro-lote 4096) | 34 s | 89 s | 2,6× mais lenta |
| Prompt frio de 64k | 58,2 s (1.100 tok/s) | 109,3 s (586 tok/s) | **−47%** |
| Turnos quentes com 64k | 1,29 / 1,24 s | 1,91 / 1,77 s | +45% |
| Geração com 64k | 24,8 a 26,3 tok/s | 11,8 a 12,1 tok/s | **−53%** |
| VRAM total (`nvidia-smi`) | 5.941 MiB | 7.815 MiB (jogo ~2 GB + servidor) | a 336 MiB do total |
| Temperatura máxima | 78 °C | 83 °C | |
| Cache de experts 2048 MiB: geração | 25,7 a 29,6 tok/s | 4,5 a 28,3 tok/s | um pedido a 4,5 tok/s |
| Cache de experts 2048 MiB: carga | 31 s | 123 s | |

- **Não houve falha:** nenhum erro de CUDA, nenhuma falta de memória, nenhuma queda. As chamadas de ferramenta continuaram válidas e o reuso de cache funcionou igual (444 tokens reprocessados de 64k).
- **O desempenho cai à metade** porque a GPU é dividida no tempo com o jogo (100% de uso dele).
- **Pegadinha:** com o jogo aberto, o CUDA continuou informando 7.062 MiB livres ao `--fit`. No WSL/WDDM o `--fit` não enxerga a VRAM de outros processos e não protege contra eles.
- **Com o perfil final** (`-ncmoe 38`, ~1 GB a mais de VRAM), servidor + jogo passariam do total da placa. O driver do Windows tende a jogar parte da memória para a RAM do sistema, o que deve piorar ainda mais. **[estimado, não medido]**
- **Recomendação:** não jogar nem usar apps na NVIDIA durante a inferência (a premissa adotada). Se for inevitável, parar o servidor ou reiniciá-lo com `-ncmoe 40`.

**NVIDIA Broadcast** como processo de computação: 144 MiB de VRAM e 1 a 3% de uso com a GPU ociosa (picos de ~14%). É uma fonte provável de ruído na geração nas execuções das 11h26–11h47 (`E2`, `D2`, `M2048-rerun`, `FINAL-64k-ncmoe40`). Deve ficar fechado durante o uso da IA.

## 12. Perfil escolhido, flag por flag

| Flag | Valor | Por quê |
|---|---|---|
| `-np` | 1 | Um agente por vez. Mais slots dividiriam contexto e cache e invalidariam o reuso entre turnos |
| `-c` | 131072 | Contexto pedido. O KV custa só 1.360 MiB em q8_0 (10 camadas de atenção completa) |
| `-fa` | on | Exigido pelo cache V quantizado |
| `-ctk` / `-ctv` | q8_0 | q4_0 degrada chamadas de ferramenta (pesquisa do plano). q8_0 cabe com folga |
| `-ngl` | 99 | Atenção, DeltaNet, expert compartilhado e saída na GPU |
| `-ncmoe` | 38 | Experts das camadas 0 a 37 na RAM e das 2 últimas na GPU. Usa a VRAM até ~470 MiB de folga (premissa de GPU dedicada). Ganho de ~2 a 3% (seção 2) |
| `--fit` / `--fit-target` | on / 384 | Só confere a folga na carga. Com `-ngl`/`-ncmoe` explícitos ele não muda nada: se a folga faltar, registra `failed to fit params ... abort` e carrega mesmo assim. O script de saúde da E5 deve procurar esse aviso |
| `-b` / `-ub` | 4096 / 4096 | O custo fixo de ~0,9 s por micro-lote faz o micro-lote de 4096 render +45% de prefill. Prompt frio de 20k: 16,2 s contra 22,0 s com 2048 |
| `-t` | 8 | Melhor geração (6 a 8). 12 fica ~3 a 5% abaixo e 16 perde 20 a 30% |
| `-tb` | 12 | Lotes abaixo de 1.024 tokens rodam na CPU (por `MIN_BATCH`), e 12 threads rendem um pouco mais que 8 nesse caminho |
| `-lm` | dio | Memória fixada: +10 a 27% de prefill contra `mmap`. Carrega em ~30 s (`none` leva ~2,5 min) e não ocupa 22 GB de cache de página |
| `--jinja` | (padrão) | Template do modelo com o parser de tool calls do Qwen3 |
| `--reasoning-preserve` | (padrão) | O histórico reenviado bate token a token com o cache (`f_keep = 1.000`), sem restaurar checkpoint |
| `-ctxcp` | 48 | Até 48 checkpoints de 63 MiB (~3 GB de RAM). Cada turno cria 2 ou 3 |
| `-cms` | 2048 | Mantido do plano: permite checkpoints mais próximos que o padrão de 8192. Nos testes, os checkpoints ficaram no fim de cada prompt (e no início do último micro-lote), e o efeito do `-cms` não foi isolado (questão em aberto 9) |
| `--cache-ram` | 12288 | Guarda conversas inteiras na RAM (849 MiB para 21k tokens com 9 checkpoints; ~2 a 2,5 GiB estimados para 120k) e as devolve em ~0,4 s depois de um desvio |
| `--metrics` | | `/metrics` para o runner da validação |
| `--temp` / `--top-p` / `--top-k` | 0,6 / 0,95 / 20 | Padrão do plano (cartão do modelo). Não foi medido na E4 e o agente pode sobrescrever por pedido |
| `-lv 4` | comentado | Só para depuração: mostra checkpoints e reprocessamento completo (~10 KB por pedido, sem o conteúdo) |
| `GGML_OP_OFFLOAD_MIN_BATCH` | 1024 | Lotes com menos de 1.024 tokens calculam os experts na CPU: turnos curtos até 2,7× mais rápidos |

## 13. Velocidades esperadas (perfil final, GPU dedicada)

| Operação | Velocidade |
|---|---|
| Prefill de prompt longo (frio) | ~1.240 tok/s com 20k, ~1.100 com 64k, ~930 com 120k (média do prompt inteiro) |
| Turno quente de 300 a 500 tokens | 1,0 a 1,5 s, de 20k a 120k de contexto |
| Turno quente de ~100 tokens | ~0,3 a 0,5 s **[estimado]** |
| Geração | 34 a 37 tok/s com contexto curto, 30 a 32 com 20k, 25 a 26 com 64k, 21 a 23 com 120k |
| Carga do servidor | ~33 s até o `/health` |

## 14. Questões em aberto

1. **Mecanismo do custo fixo por micro-lote** (~0,9 s com memória fixada). A taxa implícita passa da banda do Gen4 ×8 se todos os experts fossem copiados. Entender isso pode levar a um ajuste melhor, por exemplo um `GGML_OP_OFFLOAD_MIN_BATCH` diferente por camada.
2. **`--no-host` (reempacotamento para a CPU) e `GGML_CUDA_REGISTER_HOST`** não foram testados. O reempacotamento poderia acelerar o caminho da CPU nos turnos curtos e na geração, mas tiraria a memória fixada do prefill.
3. **Alternância rápida/lenta do pp4096 em profundidade** no `llama-bench` (1.388 / 1.030 com 16k). O servidor não mostrou isso nos prompts frios, mas não foi investigado.
4. **A carga externa das 11h08** (fila de ~40 threads e −6 GB por ~4 s) não foi identificada. Se for periódica, vai aparecer como engasgo na geração; o `burstmon.sh` pode ficar ligado na E6.
5. **Amostragem:** a `min_p` padrão do llama.cpp (0,05) foi mantida. Conferir no cartão do Qwen3.6 se o recomendado é `min_p = 0` e se `presence_penalty` muda algo em sessões longas.
6. **Cache de prompts com vários agentes ou subagentes:** 12 GiB comportam ~5 conversas de 120k ou ~14 de 20k **[estimado]**. Medir a taxa de acerto real na E6, com `-lv 4` ligado temporariamente.
7. **WSL contra llama-server nativo no Windows** (incerteza do plano): não foi necessário. O WSL entregou o esperado (prefill ~1.200 a 1.600 tok/s, geração ~35 tok/s).
8. **Comportamento do `--fit` com folga insuficiente e flags explícitas:** só registra o aviso, sem impedir a carga. O script de saúde da E5 deve verificar a linha `failed to fit params` e o uso de VRAM.
9. **Efeito do `-cms 2048`:** os checkpoints apareceram no fim de cada prompt, não a cada 2.048 tokens. Falta testar um agente que edita ou compacta o histórico no meio (E6) para saber se `-cms` menor ajuda e se 48 checkpoints bastam.
