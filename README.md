# Ambiente agentic local

Ambiente de desenvolvimento com agentes de IA rodando localmente, com modelos e ferramentas open source, sem custo recorrente de API.

- **Runtime:** llama.cpp (`llama-server`).
- **Modelo principal:** Qwen3.6-35B-A3B, em modo híbrido: experts na RAM, atenção na GPU RTX 5050.
- **Agente:** escolhido por teste. A ordem de prioridade é Qwen Code, depois Pi, depois OpenCode.

O diagnóstico, as alternativas avaliadas, as decisões e o plano completo estão em [DIAGNOSTICO-E-PLANO.md](DIAGNOSTICO-E-PLANO.md).

## Etapas

| Etapa | Descrição | Estado |
|---|---|---|
| E0 | Ajustes de hardware e WSL (iGPU, PCIe Gen4, 52 GB) | concluída em 29/10 |
| E1 | Repositório, manifesto de versões | concluída e verificada em 29/10 |
| E2 | llama.cpp pré-compilado | concluída e verificada em 29/10 |
| E3 | Teste de fumaça com Qwen3.5-4B | concluída e verificada em 29/10 |
| E4 | Qwen3.6-35B-A3B e benchmarks | pendente |
| E5 | llama-server como serviço | pendente |
| E6 | Teste comparativo dos agentes | pendente |
| E7 | Container, permissões, hooks | pendente |
| E8 | Validação (T1–T7 e piloto em projeto real privado) | pendente |
| E9 | Documentação de operação | pendente |

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `versions.env` | Versões fixadas do runtime, porta e diretórios. É a fonte única para os scripts. |
| `models.tsv` | Modelos com repositório, arquivo, tamanho e SHA-256. |
| `scripts/` | Instalação e atualização (runtime, modelos). |
| `runtime/` | Configuração do `llama-server` e unidade systemd (E5). |
| `bench/` | Benchmarks e resultados resumidos (E4). |
| `agents/` | Configuração de cada agente (E6). |
| `sandbox/` | Container de execução isolada dos agentes (E7). |
| `eval/` | Suíte de validação e resultados (E8). |
| `docs/etapas/` | Registro de cada etapa: comandos, resultados, problemas e soluções. |
| `docs/verificacoes/` | Relatórios do verificador independente, um por etapa. |

Pesos de modelos ficam em `~/models` e o runtime em `~/.local/opt/llama.cpp`, ambos fora do repositório.
