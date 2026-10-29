# Ambiente agentic local: diagnóstico e plano

Fase 1: auditoria do hardware, pesquisa de modelos, runtimes e agentes, arquitetura recomendada e plano de execução.

- Auditoria e pesquisa: 27/10/2026. Hardware reverificado em 29/10/2026, depois dos ajustes A e B.
- Nada instalado até aqui. Único download: imagem `ubuntu:24.04` (119 MB), usada para testar a GPU no Docker.

**Nível de evidência** usado em todo o documento:

| Selo | Significado |
|---|---|
| **[medido]** | medido nesta máquina |
| **[verificado]** | conferido na fonte primária |
| **[fonte]** | relatado por fonte externa citada |
| **[estimado]** | cálculo ou extrapolação, falta medir |
| **[não verificado]** | relato isolado |

---

## 1. Resumo

| Item | Recomendação |
|---|---|
| Runtime | **llama.cpp (llama-server)**, binário pré-compilado CUDA 12.8 para Linux, rodando no WSL como serviço do usuário. Os experts do MoE ficam na RAM; atenção e cache de contexto, na GPU. **[verificado]** |
| Modelo principal | **Qwen3.6-35B-A3B** (Apache-2.0), GGUF Unsloth UD-Q4_K_XL, 22,4 GB. É o melhor resultado independente entre os modelos que cabem aqui. **[verificado]** |
| Agente | Escolhido por teste entre **Qwen Code**, **OpenCode** e **Pi**, com o Claude Code apontado para o modelo local como referência. Ordem provável: Qwen Code, Pi, OpenCode. As evidências são fracas e se contradizem, por isso a escolha será medida. |
| Arquitetura | Agente único, isolado em container Docker com o repositório montado. Subagentes e modelo revisor entram só se a validação mostrar ganho. |
| Expectativa | Bom para tarefas delimitadas: corrigir bug, feature em poucos arquivos, escrever testes. Claramente abaixo do Claude Code com modelos Claude em tarefas longas e ambíguas. A diferença será medida com as mesmas tarefas, não presumida. |

| Indicador | Valor | Nível |
|---|---|---|
| Banda de leitura da RAM | 65 GB/s (teórico 89,6) | **[medido]** |
| VRAM livre | 7,9 GB de 8 (era 4,9 antes do ajuste A) | **[medido]** |
| Link da GPU | PCIe 4.0 ×8, ~15,8 GB/s teóricos (era 3.0 ×8) | **[medido]** |
| Downloads do núcleo | ≈ 26 GB | **[verificado]** |

---

## 2. Diagnóstico do hardware

| Componente | Estado real | Consequência para inferência |
|---|---|---|
| CPU | AMD Ryzen 9 9900X3D, Zen 5, 12 núcleos / 24 threads, 96 MB L3. AVX-512 completo (VNNI, BF16, VBMI2). O WSL vê 16 threads. **[medido]** | Ótima para calcular os experts do MoE. A geração é limitada pela RAM, não pela CPU. |
| RAM | 61,6 GB DDR5-5600 (2 × 32 GB, dual-channel). WSL limitado a 40 GB + 8 GB de swap. Leitura de 65 GB/s, triad de 47 GB/s, igual com 8 ou 16 threads. **[medido]** | Cabe o modelo de 35B em Q4 a Q6 com folga. Modelos de ~80B exigem subir o limite do WSL (ajuste C). |
| GPU | RTX 5050 desktop, 8 GB, Blackwell (compute 12.0), 130 W, driver 610.88, CUDA 13.3. Sem monitor ligado, 0 MiB em uso, 7,9 GB livres. **[medido]** | Cabem atenção, cache de contexto, buffers e ainda ~3 GB para experts ou para o cache de experts. |
| Vídeo | Os dois monitores (PHL 276E8V e ASM-16QCC) estão na iGPU AMD Radeon. **[medido]** | A NVIDIA fica dedicada à inferência. |
| PCIe | Gen4 ×8. O limite do host é 4, a GPU aceita até 5; em repouso o link cai para Gen1 (economia de energia normal). Placa-mãe JGINYUE B650I Night Devil (mini-ITX), BIOS de jul/2025. Contador de erros (replays) em 0. **[medido]** | É o gargalo do prefill quando os experts ficam na RAM. A banda dobrou em relação ao Gen3. |
| Disco | NVMe ADATA Legend 860, 1 TB. 827 GB livres no ext4 do WSL. **[medido]** | Sem restrição. Os modelos ficam no ext4, nunca em `/mnt/c`. |
| Sistema | Windows 11 Pro (build 26300), WSL 2.7.14, kernel 6.18, Ubuntu 24.04.4, systemd ativo. **[medido]** | Serviço do usuário via `systemctl --user` funciona. |
| Containers | Docker 29.8 + nvidia-container-toolkit 1.20. A GPU aparece dentro do container (testado). **[medido]** | Base pronta para isolar o agente. |
| Ferramentas | Node 24, npm, pnpm, uv, Python 3.12, git, gh, rg, fd, jq, gcc. Já instalados: Claude Code 2.1.311, Codex CLI 0.154, Gemini CLI 0.65. Ausentes: llama.cpp, Ollama, bubblewrap, toolkit CUDA (não é necessário). **[medido]** | Nada precisa de `sudo` no caminho principal. |

### Como o hardware limita a velocidade

- **Geração (tokens de saída).** A cada token o modelo lê os experts ativos na RAM; no Qwen3.6-35B-A3B em Q4 são ~0,6 GB por token.
  - Com 65 GB/s, o teto teórico é ~100 tok/s.
  - Expectativa realista: **35 a 50 tok/s** com contexto curto. **[estimado]**
- **Prefill (ler o prompt).** Em lotes grandes, o llama.cpp copia para a GPU, a cada micro-lote, os experts que estão na RAM.
  - Com 7,9 GB de VRAM devem sobrar ~14 GB de experts na RAM. Isso dá ~1,2 s por cópia a ~12 GB/s (Gen4 ×8 real).
  - Com micro-lote de 2048 tokens, o teto passa de 1.500 tok/s.
  - Expectativa: **500 a 1.000 tok/s**. Pode cair se o WSL não usar memória fixada (pinned). **[estimado]**
- **Por isso o tamanho do prompt do agente importa.** Sempre que o cache se perde, o agente reprocessa o preâmbulo inteiro. A 700 tok/s **[estimado]**:

  | Agente | Preâmbulo | Custo por perda de cache |
  |---|---|---|
  | Claude Code | ~30 mil tokens | ~45 s |
  | OpenCode | ~7,5 mil tokens | ~11 s |
  | Pi | ~1,4 mil tokens | ~2 s |

- **Contexto.** O Qwen3.6 só tem atenção completa em 10 das 40 camadas: 20 KiB por token, ~1,3 GB para 128k tokens com cache em q8_0. **[fonte]** Contexto longo não é o problema; o custo está em reprocessá-lo.

### Ajustes de hardware

| Ajuste | Estado | Ganho e risco |
|---|---|---|
| **A.** Monitores na iGPU | **Feito em 29/10**, verificado | +3 GB de VRAM. Se algum app passar a usar a NVIDIA para desenhar (Configurações › Sistema › Tela › Gráficos), a VRAM volta a ser ocupada. Isso será monitorado nos testes. |
| **B.** PCIe Gen4 na BIOS | **Feito em 29/10**, verificado | 2× banda no prefill. Estabilidade sob carga a confirmar na E4: o contador de replays deve continuar em 0. |
| **C.** Limite do WSL de 40 para 52 GB | **Aplicado em 29/10** no `.wslconfig` (backup em `.wslconfig.bak-20261029`); vale após `wsl --shutdown` | Permite o teste completo, incluindo o Qwen3-Coder-Next (80B). O Windows fica com ~9,6 GB garantidos e usava ~17,4 GB (7,7 só no Chrome): durante a inferência, feche apps pesados no Windows. Para voltar, restaure o backup. |

---

## 3. Onde está cada limite

Um modelo que escreve bom código pode falhar como agente, e um bom agente não compensa um runtime que perde o cache. As três camadas são avaliadas separadamente.

| Camada | O que ela decide | Situação aqui |
|---|---|---|
| **Modelo** | Qualidade do raciocínio e do código, aderência ao formato de chamada de ferramentas, tendência a entrar em loop. | O melhor modelo que cabe (Qwen3.6-35B-A3B) fica bem abaixo dos modelos de fronteira. É a maior fonte de diferença em relação ao Claude Code. |
| **Agente** | Tamanho do prompt fixo, desenho das ferramentas de edição, controle do loop, compactação de contexto, permissões. | Com os mesmos modelos locais, agentes diferentes variaram de 62% a 77% num teste independente de 16 tarefas. **[fonte]** |
| **Runtime** | Velocidade, reuso do cache entre turnos, conversão das chamadas de ferramenta, estabilidade. | O llama.cpp é o único com controle fino do offload MoE e com checkpoints para modelos de atenção híbrida como o Qwen3.6. |

---

## 4. Runtimes de inferência

| Runtime | Versão | Veredito | Motivo |
|---|---|---|---|
| **llama.cpp / llama-server** | v0.7.0 (15/10); build b11935 (27/10) **[verificado]** | **Usar** | Ver os pontos logo abaixo da tabela. |
| ik_llama.cpp | sem releases | Só comparação | Fork focado em CPU e híbrido, mas tem um bug aberto (#1762): o Qwen3.6 não restaura checkpoints e reprocessa o prompt inteiro a cada turno, o que inviabiliza o uso como agente. Num benchmark citado, o prefill foi mais lento que o do mainline. **[fonte]** |
| Ollama | 0.40.11 | Não | Sem controle de offload de experts (pedido aberto desde 2025). Contexto padrão de 4k em GPUs com menos de 24 GB. Issue aberta de Qwen3.5 ~5× mais lento que o llama.cpp. A API Anthropic não tem cache de prompt nem `count_tokens`. **[fonte]** |
| LM Studio | 0.4.x | Possível | Usa o mesmo motor llama.cpp com menos controle. Gratuito, mas de código fechado. Não acrescenta nada aqui. |
| vLLM / SGLang | — | Não | Feitos para modelos inteiros em VRAM. O cache de experts dinâmico do vLLM não foi integrado. Com 8 GB não há espaço útil. |
| KTransformers | 0.7 | Não | Não suporta Qwen3.5/3.6, Coder-Next, GLM-4.7-Flash, gpt-oss nem Gemma 4. |
| llama-swap | v267 | Depois | Troca de modelos sob demanda. Só faz sentido se o modelo revisor provar valor; o llama-server também tem roteador próprio. |

Por que o llama.cpp:
- Controle do offload MoE: `--fit`, `-ncmoe`, `-ot`.
- Na v0.7.0, cache LRU de experts na GPU (`--moe-cache-mib`), com até 2,2× na geração segundo o projeto.
- Endpoint Anthropic `/v1/messages` nativo e parser dedicado para o Qwen3.
- Checkpoints de contexto para modelos híbridos.
- Binário CUDA 12.8 com código nativo para Blackwell. Licença MIT.

**Cuidados encontrados na pesquisa:**
- Usar o build CUDA 12.8. O de 13.4 pode falhar com o driver atual (CUDA 13.3), e o CUDA 13.2 gerou texto corrompido com o Qwen3.6. **[não verificado]**
- Cache de contexto em q4_0 degrada as chamadas de ferramenta; usar q8_0. **[fonte]**
- Quando nenhum checkpoint serve, o servidor reprocessa o prompt inteiro sem avisar; isso só aparece com `-lv 4`. Será monitorado nos testes. **[fonte]**

---

## 5. Seleção de modelos

Priorizei benchmarks independentes e descontaminados (SWE-rebench, Artificial Analysis) aos números dos fabricantes, que usam ambientes de teste próprios e não são comparáveis entre si.

### Principal: `Qwen/Qwen3.6-35B-A3B`

- **Lançamento:** abr/2026. 35B parâmetros no total, 3B ativos, contexto nativo de 262k.
- **Licença:** Apache-2.0 **[verificado]**.
- **Tamanhos:** UD-Q4_K_XL 22,4 GB · UD-Q6_K 29,3 GB · Q8_0 36,9 GB **[verificado]**.
- **Evidência [fonte]:**
  - SWE-rebench (mai–jul/2026): **24,7%**, contra 17,1% do Qwen3.5-35B e 31,2% do Qwen3.6-27B denso.
  - Maior índice de código entre os modelos pequenos no Artificial Analysis.
  - Modelo local mais citado com OpenCode e Pi.
- **Limitações:**
  - As chamadas de ferramenta pioram com contexto longo.
  - No OpenCode, às vezes escreve a chamada como texto e a sessão trava.
  - Há relatos de mais estabilidade em Q6/Q8 do que em Q4.

### Principal alternativo: `Qwen/Qwen3-Coder-Next`

- **Lançamento:** jan/2026. 80B no total, 3B ativos, sem modo de raciocínio.
- **Licença:** Apache-2.0 **[verificado]**.
- **Tamanhos:** UD-IQ4_XS 38,4 GB · UD-Q4_K_XL 49,6 GB **[verificado]**.
- **Evidência:** SWE-rebench (snapshot de 6/5): 54,4%, contra 53,7% do Qwen3.5-35B no mesmo snapshot. Nunca foi medido no mesmo período que o Qwen3.6. **[fonte]**
- **Limitações:** exige o ajuste C. O prefill fica ~2,4× mais lento aqui, porque passam 2,4× mais experts pelo PCIe. **[estimado]**

### Revisor / planejador: `Qwen/Qwen3.8-27B`

- **Lançamento:** ago/2026. Denso, com atenção híbrida.
- **Licença:** Apache-2.0 **[verificado]**.
- **Tamanho:** UD-Q4_K_XL 17,6 GB **[verificado]**.
- **Evidência:** Artificial Analysis Intelligence 28–34, contra 18 do Qwen3.6-35B. Ainda sem resultado no SWE-rebench. **[fonte]**
- **Limitações:**
  - Por ser denso, roda a ~4–8 tok/s aqui **[estimado]**.
  - Raciocina muito: até 67 mil tokens por tarefa no nível máximo.
  - Serve só para revisar ou planejar, em passes curtos.

### Auxiliar

- **Opção padrão:** o próprio modelo principal com raciocínio desligado (0 GB extra).
- **Alternativa:** `Qwen/Qwen3.5-4B` (2,9 GB, Apache-2.0 **[verificado]**). Lidera os modelos pequenos em chamadas de ferramenta (BFCL-v3 70,6) **[fonte]**.
- **Limitação:** a VRAM não comporta dois modelos ao mesmo tempo. O 4B será usado no teste de fumaça da etapa E3.

### Descartados, com o motivo

- **GLM-4.7-Flash** (MIT): SWE-rebench e índice de código abaixo do Qwen3.6, mais problemas de template.
- **gpt-oss-20b / 120b**: o 120b (~63 GB) não cabe; o 20b fica atrás nas avaliações independentes.
- **Gemma 4 26B-A4B / 31B**: resultados muito sensíveis ao ambiente de teste; o 31B denso é lento aqui.
- **Devstral Small 2 (24B)**: denso e lento aqui, sem vantagem demonstrada.
- **Nemotron 3.5 Lightning 30B-A3B**: rápido, porém mais fraco (índice 13 contra 18).
- **Laguna XS 2.1**: há relato de crash no CUDA com offload parcial de experts numa RTX 5060 Ti.
- **Observar:** Nemotron 3.5 Bolt 74B-A9B (sem avaliação independente ainda) e K2-Horizon MoVA 36B-A4B (suporte entrou no llama.cpp v0.7.0; faltam quantizações).
- **Grandes demais** para ~54 GB em Q4: Qwen3.5-122B, Mistral Small 4, Nemotron Super, DeepSeek V4-Flash, MiniMax M3, GLM-5.3-Flash.

---

## 6. Agentes (interfaces agentic)

| Agente | Licença | Prompt fixo | Subagentes · MCP · Skills · Hooks | Isolamento |
|---|---|---|---|---|
| **Qwen Code** 0.26.x | Apache-2.0 | a medir | Sim · Sim · Sim · Sim | Modos de aprovação, sandbox, worktrees |
| **Pi** 1.4 | MIT **[verificado]** | ~1,4 mil | Por add-on · Sim · Sim · extensões TS | **Nenhum**: exige container |
| **OpenCode** 1.19.4 | MIT | ~7,5 mil | Sim · Sim · Sim (lê `.claude/skills`) · plugins | allow/ask/deny, padrão quase tudo liberado |
| Claude Code 2.1.311 (local) | Proprietário | ~25–31 mil | Sim · Sim · Sim · Sim (o mais completo) | Regras de permissão, sandbox bubblewrap |
| Codex CLI · Crush · Mistral Vibe · Goose · OpenHands | vários | — | Variam | O Codex tem o melhor sandbox |
| Aider · Roo Code · Continue | — | — | — | — |

Como cada um se sai com modelos locais:

- **Qwen Code:** 75% no harness-bench (2º lugar). É da mesma família do modelo e busca paridade com o Claude Code. **[fonte]**
- **Pi:** 77% no harness-bench (1º lugar). Tem integração nativa com o llama.cpp. Não tem modo de plano nem permissões. **[fonte]**
- **OpenCode:**
  - 64% no harness-bench. Sem os casos em que o agente leu o avaliador, cai para ~55%.
  - Tem um bug com o Qwen3.6 que trava a sessão, fechado como "não planejado" **[verificado]**.
  - A linha 2.x mudou o formato de configuração há seis semanas.
- **Claude Code (local):**
  - 66% no harness-bench.
  - Funciona via `/v1/messages`, mas a Anthropic não dá suporte a modelos não-Claude.
  - As chamadas em segundo plano descartam o cache. **[fonte]**
- **Codex CLI, Crush, Mistral Vibe, Goose, OpenHands:** situacionais. O Codex só fala a Responses API, que tem problemas no llama.cpp; o Crush tem licença FSL.
- **Evitar:** Aider (em manutenção), Roo Code (arquivado) e Continue (sem manutenção).

**As evidências se contradizem, por isso o agente será escolhido por teste.**
- O OpenCode é a alternativa aberta mais parecida com o Claude Code em recursos.
- Mesmo assim, tem um bug registrado justamente com o Qwen3.6 e foi o pior do único teste independente com modelos locais (16 tarefas privadas, num Mac M3 Max).
- O Pi e o Qwen Code foram melhores nesse teste, mas a amostra é pequena e o hardware é outro.

Na etapa E6, os quatro passam pelo mesmo teste curto e só os dois melhores seguem para a validação completa. Os demais são desinstalados.

---

## 7. Arquitetura recomendada

```
Você (terminal do WSL ou VS Code)
  │  tarefa em linguagem natural
  ▼
┌─ Container agent-box (Docker) ───────────────────────────────────────┐
│  Agente: vencedor do teste E6, AGENTS.md por projeto,                │
│          permissões restritas                                        │
│  Ferramentas: shell, git (sem push), leitura/edição, testes, linters │
│  Repositório montado em /work, sem chaves SSH nem token do GitHub    │
└──────────────────────────────────────────────────────────────────────┘
  │  HTTP 127.0.0.1 · OpenAI /v1/chat/completions ou Anthropic /v1/messages
  ▼
llama-server (systemd --user)
  parser de tool calls do Qwen3, checkpoints de contexto,
  cache de prompt na RAM, métricas em /metrics, só escuta em localhost
  │
  ├─► GPU · RTX 5050 (7,9 GB)
  │     atenção e camadas DeltaNet, expert compartilhado, embeddings,
  │     cache de contexto q8_0, experts extras ou cache LRU de experts
  │
  └─► CPU + RAM
        experts roteados (~14–17 GB em Q4), 12–16 threads AVX-512,
        checkpoints de contexto

~/models (ext4)    arquivos GGUF, com manifesto de versões e hashes
~/me/local (git)   configurações, scripts, suíte de avaliação, resultados, docs
```

### Configuração inicial do servidor

Ponto de partida a ser calibrado com medições na etapa E4. **[fonte]** **[estimado]**

```bash
llama-server -m ~/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf -a qwen3.6-35b \
  --host 127.0.0.1 --port 9931 -np 1 -c 131072 \
  -fa on -ctk q8_0 -ctv q8_0 \
  --fit on -b 4096 -ub 2048 -t 12 -tb 16 \
  --jinja --reasoning-preserve \
  -ctxcp 48 -cms 2048 --cache-ram 12288
# a testar: --moe-cache-mib 1024–2048, -ncmoe manual, GGML_OP_OFFLOAD_MIN_BATCH, --no-mmap
# amostragem (cartão do modelo): temp 0.6, top_p 0.95, top_k 20, presence_penalty 0, preserve_thinking
```

### Agentes, permissões e extensões

- **Permissões.**
  - Leitura liberada; edição liberada só dentro de `/work`.
  - Shell com lista de bloqueio: `git push`, `rm -rf` fora do projeto, `curl | sh`, `sudo`.
  - O container é a barreira real; as regras do agente são a segunda camada.
- **Git.** Uma branch por tarefa, commits locais feitos pelo agente e push sempre manual. O diff é revisado antes do merge.
- **Hooks.** Dois para começar: formatador após cada edição e testes do projeto antes de o agente declarar a tarefa concluída.
- **Skills e AGENTS.md.** Um modelo de AGENTS.md com os comandos de build, teste e lint de cada projeto, e uma skill de "ciclo de depuração" (reproduzir, isolar, corrigir, validar).
- **MCP.** Nenhum no início, porque cada ferramenta MCP aumenta o prompt fixo, que é caro aqui. Entra só se a validação mostrar falta de algo específico.
- **Subagentes e revisor.** Desligados no início: com um único slot no servidor, cada subagente apaga o cache do agente principal. Serão testados na etapa E8.
- **Claude Code local.** Usado com diretório de configuração separado (`CLAUDE_CONFIG_DIR`), sem tocar no seu Claude Code atual.

---

## 8. Plano de execução

**Ordem de execução alterada em 29/10: a E7 (container) roda antes da E6 (teste dos agentes).** O teste da E6 executa os agentes em modo autônomo (yolo / `bypassPermissions`), em que qualquer comando roda sem confirmação. Sem o container, a única barreira seria o guarda de cada agente, que é só a segunda camada. A numeração foi mantida porque já é referenciada em documentos e scripts.

Cada etapa termina com uma verificação objetiva e pode ser desfeita isoladamente. Nenhuma etapa usa `sudo`, a não ser que o Claude Code local seja o escolhido e precise do bubblewrap; nesse caso pergunto antes. Cada download acima de 5 GB será confirmado antes, mesmo depois da aprovação geral.

| Etapa | O que faz | Verificação | Como desfazer | Download · tempo |
|---|---|---|---|---|
| ~~E0~~ | Ajustes A, B e C. **Feito em 29/10** (C vale após `wsl --shutdown`). | VRAM livre de 7,9 GB e host em Gen4 verificados; `free -h` deve mostrar ~50 GB. | Cabo, BIOS e backup do `.wslconfig`. | — |
| E1 | Repositório git nesta pasta: estrutura, README, manifesto de versões. | `git log` com a estrutura inicial. | Apagar `.git` e os arquivos criados. | — · minutos |
| E2 | llama.cpp pré-compilado (CUDA 12.8) em `~/.local/opt/llama.cpp/<build>`, com link `current`. | A GPU aparece como compute 12.0, o CPU mostra AVX512 = 1 e `--version` confere. | Trocar o link ou apagar a pasta. | ~0,5 GB · minutos |
| E3 | Teste de fumaça com o Qwen3.5-4B: chat e chamada de ferramenta via OpenAI e via Anthropic. | 3 chamadas de ferramenta corretas em cada endpoint. | Apagar o GGUF. | 2,9 GB · 15 min |
| E4 | Qwen3.6-35B-A3B Q4 e varredura com `llama-bench`: tamanho de micro-lote, offload, threads, cache de experts, contexto de 0, 16k e 64k. Inclui a checagem de estabilidade do PCIe Gen4. | Tabela de prefill e geração; perfil escolhido e justificado; replays do PCIe em 0. | Apagar o GGUF. | 22,4 GB · 1–2 h |
| E5 | llama-server como serviço do usuário com o perfil escolhido, mais um script de saúde. | Reinicia sozinho, responde em localhost, reuso de checkpoint confirmado no log. | `systemctl --user disable`. | — · 30 min |
| E6 | Teste curto dos agentes: Qwen Code, OpenCode e Pi (npm, versões fixadas) e Claude Code local. Mede prompt fixo, erros de ferramenta e 3 tarefas pequenas. | Tabela comparativa; 1 ou 2 agentes seguem para a E8. | `npm uninstall` dos descartados. | ~0,3 GB · 2–3 h |
| E7 | Container agent-box, regras de permissão, hooks, modelo de AGENTS.md, fluxo git. | Testes de fuga: o agente não consegue fazer push nem escrever fora de `/work`. | `docker rmi` e apagar as configs. | ~1 GB · 1 h |
| E8 | Validação completa (seção 9). Variações opcionais: Q6_K, Coder-Next, revisor 27B, subagentes. | Relatório com taxa de sucesso por configuração. | Apagar os GGUFs extras. | 0–85 GB · 4–8 h de máquina |
| E9 | Documentação: iniciar, parar, atualizar, reverter, problemas encontrados e soluções. | Você sobe o ambiente do zero seguindo só o README. | — | — |

---

## 9. Validação prática

Um script executa cada tarefa sem intervenção a partir de um commit fixo, roda testes ocultos que o agente não vê e grava os resultados em JSON. Cada combinação de agente e modelo roda cada tarefa 2 a 3 vezes, porque os resultados variam entre execuções.

Repositórios usados:
- dois projetos públicos com commit fixado, um em Python e um em TypeScript;
- se você autorizar, uma **cópia** de um projeto seu.

| Tarefa | O que testa | Critério de sucesso |
|---|---|---|
| T1 | Explicar a arquitetura de um repositório desconhecido. | Cobre pelo menos 7 de 10 fatos de um gabarito escrito antes. |
| T2 | Corrigir um bug plantado, a partir de um relato de usuário. | Testes ocultos passam e nada mais quebra. |
| T3 | Implementar uma funcionalidade que toca de 3 a 5 arquivos. | Testes de aceitação ocultos passam. |
| T4 | Escrever testes para um módulo sem testes. | Testes passam e detectam pelo menos 60% de mutações plantadas. |
| T5 | Investigar um teste que falha por causa não óbvia. | Causa raiz correta no relatório e correção validada. |
| T6 | Planejar uma mudança complexa antes de implementar, depois implementar. | O plano cobre os pontos do gabarito e a implementação passa nos testes. |
| T7 | Revisar o próprio diff, que contém uma regressão plantada. | Encontra e corrige a regressão. |

- **Métricas por execução:** sucesso, intervenções humanas, tempo total, tokens de entrada e saída, velocidade de prefill e geração, erros de chamada de ferramenta, loops, pico de RAM e VRAM.
- **Piloto ponta a ponta: um projeto real e privado,** fora deste repositório. Os detalhes estão em `PILOTO.local.md`, que não é versionado. É o primeiro teste real para saber se a arquitetura entrega software do começo ao fim:
  - montar requisitos e especificação;
  - quebrar em tarefas;
  - implementar e testar;
  - entregar e2e.

  Regras do piloto:
  - **O original nunca é alterado.** O trabalho acontece numa cópia ou num git worktree, dentro do container do agente.
  - **Só o código do projeto é montado no container.** Documentos pessoais e contratuais que ficam ao lado dele não são acessíveis aos agentes.
  - **Nada do piloto entra neste repositório:** nem código, nem resultados brutos. Só métricas agregadas.
- **Referência com o Claude, guiada e condicional.** É a mesma atividade do piloto, executada com o Claude Code e os modelos Claude da conta do autor.
  - Só roda se for necessária: se o resultado local for avaliado como satisfatório, ela não roda.
  - Antes de rodar, o orquestrador informa o que será executado, quando, em qual cópia e qual o consumo estimado, e espera aprovação.
  - Nunca envia documentos pessoais ou contratuais.
- **Meta proposta para considerar o ambiente pronto (ajustável):**
  - pelo menos 5 das 7 tarefas resolvidas sem intervenção, em 2 de 3 execuções;
  - nenhuma ação destrutiva;
  - mediana de no máximo 1 intervenção nas tarefas restantes.

---

## 10. Incertezas e como serão resolvidas

| Incerteza | Por que importa | Teste · etapa |
|---|---|---|
| Velocidade real de cópia RAM→GPU no WSL, que limita a memória fixada | Pode dividir o prefill por dois. | Varredura do `llama-bench` com e sem `--no-mmap` · E4 |
| Estabilidade do PCIe Gen4 sob carga | Erros de link causam lentidão ou travamento. | Contador de replays antes e depois dos benchmarks · E4 |
| WSL contra llama-server nativo no Windows | Fontes divergem sobre qual é mais rápido no modo híbrido. | Mesmo GGUF nos dois lados, se o WSL decepcionar · E4 |
| Apps do Windows voltando a usar a NVIDIA | Reocupam VRAM e o driver pode jogar memória para a RAM em silêncio. | Monitorar a VRAM durante os testes · E4–E5 |
| Ganho do cache de experts na GPU | Promete até 2,2× na geração. | `--moe-cache-mib` de 0 a 2048 · E4 |
| Taxa de acerto do cache entre turnos com cada agente | Cada falha custa de 2 s a 45 s. | Log `-lv 4` durante a E6 |
| Bug de chamadas de ferramenta do Qwen3.6 no OpenCode | Pode eliminar o OpenCode. | Reproduzir com o build atual e as correções relatadas · E6 |
| Q4 contra Q6: estabilidade nas chamadas de ferramenta | Relatos indicam Q6 mais estável e ~30% mais lento. | Mesmas tarefas nas duas quantizações · E8 |
| Coder-Next 80B contra Qwen3.6-35B | Nunca comparados no mesmo período de benchmark. | Mesmas tarefas, com o ajuste C · E8 (opcional) |

---

## 11. Decisões

### Tomadas em 29/10/2026

1. **Arquitetura e plano E1–E9 aprovados.** A execução é etapa por etapa.
   - Os downloads do núcleo (~26 GB: llama.cpp, Qwen3.5-4B, Qwen3.6-35B) estão aprovados.
   - Os opcionais da E8 (até ~85 GB) serão confirmados um a um.
   - Usarei a variante padrão do Qwen3.6, sem MTP. No modo híbrido, a decodificação especulativa lê mais experts da RAM por passo e rendeu só ~2% em teste publicado.
   - A porta do servidor é a 9931, porque a 8080 já é usada por outro serviço local.
2. **WSL com 52 GB de RAM** (ajuste C), para permitir o teste completo. Quando estiver processando IA, a máquina fica dedicada a isso.
3. **Orquestração só na construção.**
   - O Claude Code (esta sessão) é o orquestrador.
   - Agentes paralelos especializados fazem só o trabalho independente: suíte de validação, container, configurações dos agentes, documentação.
   - Ao fim de cada etapa, um verificador novo confere a entrega. Ele recebe só os critérios da etapa e onde olhar, não as conclusões do orquestrador, e registra o resultado em `.md`.
   - Benchmarks e testes de agentes rodam em série: são uma GPU e um modelo, e medições em paralelo seriam inválidas.
   - O ambiente local final começa com agente único e revisão sequencial (um executa, outro verifica).
4. **Cascata de metas, com critério objetivo.**

   | Nível | Agente | Modelo | Custo recorrente | Passa se |
   |---|---|---|---|---|
   | Meta 1 (custo zero) | Disputa única na E6 entre Qwen Code, Codex CLI, Pi e OpenCode (open source) e Claude Code (fechado, gratuito), todos com o modelo local | local | zero | ≥ 5 de 7 tarefas sem intervenção em 2 de 3 execuções, nenhuma ação destrutiva, e o piloto aprovado pelo autor e pelo orquestrador |
   | Meta 2 | Incorporada à Meta 1 em 29/10: o Claude Code local disputa junto com os open source | — | — | — |
   | Meta 3 | qualquer um | local na maior parte, nuvem para planejar e revisar. Opções: Codex com o plano ChatGPT Go (custo baixo) ou Claude | assinatura do autor | A parcela de tarefas resolvida localmente, a definir. Contraria a restrição original e só vale como decisão sua, explícita. |

   Se o limite for do modelo (chamadas de ferramenta corretas, mas soluções erradas), trocar de agente não resolve. O próximo passo, nesse caso, é um modelo local maior (Coder-Next 80B ou Qwen3.8-27B como revisor) e, depois, a Meta 3.
5. **O piloto de validação é um projeto real e privado**, fora deste repositório (ver seção 9).
6. **Codex adicionado ao plano (29/10)**, de duas formas que não se misturam:
   - **Codex CLI com o modelo local:** entra na Meta 1 e no teste da E6 (`agents/codex-local/`).
     - É open source (Apache-2.0), não usa conta nem plano, e o llama-server tem o endpoint `/v1/responses` que ele exige.
     - Riscos a medir: ele é ajustado para modelos da OpenAI, usa o formato de edição `apply_patch` e passa pelo caminho Responses do llama.cpp, o menos testado.
     - Configuração isolada em `CODEX_HOME` próprio; o `~/.codex` do autor não é tocado.
   - **Codex com os modelos da OpenAI pelo plano ChatGPT Go:** é nuvem, então fica como régua de comparação na validação e como opção da Meta 3.
     - Antes de cada uso, o orquestrador informa o que vai rodar e o consumo estimado, e espera aprovação.
     - Os limites do plano Go ainda precisam ser confirmados.
     - No piloto, conferir a confidencialidade contratual antes de enviar código à nuvem. Documentos pessoais nunca são enviados.
7. **Regra de escolha do agente (29/10).** O critério principal é custo zero, não código aberto, então as antigas Metas 1 e 2 viraram uma disputa só.
   - **Vence o melhor resultado medido** na E6 e na E8.
   - **Em empate técnico, vence o open source.** Empate técnico é diferença de até 1 tarefa em 7, dentro da variação entre execuções.
   - **Riscos do Claude Code local que pesam no desempate:** não tem suporte oficial para modelos não-Claude (uma atualização pode quebrar o uso local), o prompt fixo é de ~25–31 mil tokens (mais caro a cada perda de cache) e as chamadas em segundo plano podem descartar o cache.
   - **A favor dele:** o autor já domina o fluxo (skills, hooks, subagentes, plugins).
   - **Ordem na E6:** o Claude Code local e o Codex local rodam primeiro, para dar logo o sinal com as ferramentas já conhecidas.

8. **Condição de uso (29/10): GPU dedicada à IA enquanto ela é usada.** Sem jogos e com o NVIDIA Broadcast fechado. O perfil do servidor usa a VRAM inteira, guardando só uma margem pequena para variações do driver.
   - Num teste deliberado, o autor abriu um jogo durante a E4: o servidor continuou funcionando. A degradação medida fica registrada nos resultados da E4.
   - A E5 inclui uma checagem antes de iniciar que avisa quando há outro processo usando a GPU.

### Pendentes

- Confirmar cada download acima de 5 GB quando chegar a etapa correspondente.
- Na hora do piloto: autorizar, ou não, a execução de referência com o Claude.

---

## 12. Histórico

| Data | Evento |
|---|---|
| 27/10/2026 | Auditoria do hardware e pesquisa (modelos, runtimes, agentes). Download da imagem `ubuntu:24.04` (119 MB) para testar a GPU no Docker. |
| 29/10/2026 | Você moveu os dois monitores para a iGPU e configurou o PCIe em Gen4 na BIOS. Verificado: 0 MiB de VRAM em uso, 7,9 GB livres, host em Gen4 ×8, replays em 0. |
| 29/10/2026 | Decisões da seção 11. `.wslconfig` alterado de 40 para 52 GB (backup `.wslconfig.bak-20261029`). Piloto definido (projeto privado). Repositório preparado para ser publicado no futuro, sem referências a projetos privados. |

---

## Fontes principais

- **Hugging Face:** cartões e repositórios GGUF consultados pela API em 27/10/2026: `Qwen/Qwen3.6-35B-A3B`, `Qwen/Qwen3.8-27B`, `Qwen/Qwen3-Coder-Next`, `Qwen/Qwen3.5-4B` e os `unsloth/*-GGUF`.
- **Benchmarks:**
  - SWE-rebench: <https://swe-rebench.com> (janela de 15/05 a 01/07/2026).
  - Artificial Analysis: <https://artificialanalysis.ai> (comparativos de modelos pequenos, jun–out/2026).
- **llama.cpp:**
  - Releases v0.7.0 e b11935: <https://github.com/ggml-org/llama.cpp/releases>
  - PRs #29887 (cache de experts) e #26252 (parser Qwen3).
  - Blog sobre a API Anthropic: <https://huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp> (19/01/2026).
- **Outros runtimes:**
  - ik_llama.cpp: issue #1762.
  - Ollama: <https://docs.ollama.com/api/anthropic-compatibility> e issues #11772 e #14579.
  - vLLM: PR #37190.
  - KTransformers: README do projeto.
- **Claude Code:** <https://code.claude.com/docs/en/llm-gateway> e model-config (27/10/2026).
- **Agentes:**
  - OpenCode: <https://opencode.ai/docs> e issue #24316 em <https://github.com/anomalyco/opencode> (fechada em 11/10/2026 como "not planned").
  - Pi: <https://github.com/earendil-works/pi>
  - Qwen Code: <https://github.com/QwenLM/qwen-code>
- **Testes de agentes:**
  - harness-bench: <https://neuralnoise.com/2026/harness-bench-wip> (28/04/2026).
  - Medições de preâmbulo: mykolaaleksandrov.dev (21/06/2026) e heyuan110.com (06/09/2026).
- **Relatos práticos:**
  - insiderllm.com, guia do Qwen3.6 (atualizado em 16/10/2026).
  - Fórum NVIDIA, tópico 367721.
  - Discussões #31 e #51 do Qwen3.6 no Hugging Face.
