# E6: comparação dos agentes (protocolo)

Escolhe o agente de custo zero que usa o modelo local. Concorrem Claude Code local, Codex local, Qwen Code, Pi e OpenCode. A regra de decisão está no plano (seção 11, item 7): vence o melhor resultado medido e, em empate técnico, vence o open source.

## Por que rodadas eliminatórias

5 agentes × 6 testes × 2 repetições = 60 execuções. A ~5–15 min cada no modelo local (estimativa), seriam de 5 a 15 horas. As rodadas descartam cedo os agentes que nem funcionam e guardam as repetições para os finalistas.

| Rodada | Agentes | Testes | Repetições | Execuções | Tempo estimado |
|---|---|---|---|---|---|
| R1. Funciona? | os 5; Claude Code local e Codex local primeiro | S1 (bug curto) e K1 (chamada explícita de skill) | 1 | 10 | ~1–2 h |
| R2. Qualidade | os que passaram na R1 | S2, S3, K2 e K3 | 1 | até 16 | ~2–3 h |
| R3. Variação | os 2 ou 3 melhores | S1–S3 | +2 | até 18 | ~2–4 h |

Antes da R1, `agents/measure-preamble.sh` mede o tamanho do primeiro pedido de cada agente: é o custo de cada perda de cache.

## Critérios de eliminação na R1

Um agente sai se acontecer qualquer um destes:
- não inicia no container, ou a configuração gerada é recusada;
- mais de 2 erros de formato de ferramenta (`RUNTIME`) numa execução;
- loop detectado (`loops_suspected` ≥ 1 com mais de 5 repetições) ou estouro do tempo máximo em S1;
- não carrega a skill em K1 quando ela é chamada pelo nome.

## Medidas por execução

Gravadas pelo `eval/run.sh` em `result.json` e `agent-metrics.json`:
- **resultado:** sucesso nos testes ocultos;
- **tempo de relógio;**
- **tokens:** de prompt e gerados, a partir do `/metrics`;
- **cache:** reaproveitado (`cache_n`) contra reprocessado (`prompt_n`);
- **ferramentas:** chamadas, erros e loops;
- **memória:** pico de RAM e VRAM.

O aquecimento antes do retrato de métricas já é automático.

## Condições de execução

- **Isolamento:** sempre no container (`EVAL_WRAPPER=sandbox/run-in-box.sh`), uma execução por vez.
- **GPU dedicada:** sem jogos e sem NVIDIA Broadcast. `scripts/llm preflight` roda antes de cada rodada.
- **Execuções longas:** manter um terminal do WSL aberto, porque com o lingering desligado o serviço pode parar quando o último terminal fecha.
- **Identificadores:** `e6-r1`, `e6-r2`, `e6-r3`.

## Saída

`docs/stages/E6.md`: tabela por agente e rodada, com o tamanho do primeiro pedido, a taxa de sucesso, os tempos, o uso de cache e os erros; os eliminados e o motivo; a decisão; e os 1 ou 2 agentes que seguem para a E8. A verificação independente da E6 refaz uma amostra das execuções.
