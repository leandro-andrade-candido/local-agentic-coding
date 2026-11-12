> 🇬🇧 English summary: [README.md](README.md)

# Ambiente agentic local

Ambiente de desenvolvimento com agentes de IA rodando localmente, com modelos e ferramentas open source, sem custo recorrente de API.

- **Runtime:** llama.cpp (`llama-server`).
- **Modelo principal:** Qwen3.6-35B-A3B, em modo híbrido: experts na RAM, atenção na GPU RTX 5050. Padrão em Q4 (UD-Q4_K_XL, medido na E4); variante Q6 (UD-Q6_K) disponível para teste com `scripts/llm model`.
- **Agente:** escolhido por teste entre Qwen Code, Codex CLI, Pi e OpenCode, todos com o modelo local. O Claude Code com o modelo local fica como alternativa.

**Para usar e testar manualmente, comece pelo [USAGE-GUIDE.pt-BR.md](USAGE-GUIDE.pt-BR.md).**

O diagnóstico, as alternativas avaliadas, as decisões e o plano completo estão em [DIAGNOSIS-AND-PLAN.md](DIAGNOSIS-AND-PLAN.md).

## Etapas

| Etapa | Descrição | Estado |
|---|---|---|
| E0 | Ajustes de hardware e WSL (iGPU, PCIe Gen4, 52 GB) | concluída em 29/10 |
| E1 | Repositório, manifesto de versões | concluída e verificada em 29/10 |
| E2 | llama.cpp pré-compilado | concluída e verificada em 29/10 |
| E3 | Teste de fumaça com Qwen3.5-4B | concluída e verificada em 29/10 |
| E4 | Qwen3.6-35B-A3B e benchmarks | concluída e verificada em 29/10 |
| E5 | llama-server como serviço | em andamento: serviço instalado e saudável; bateria de tool calling parcial (ver `docs/stages/E5.md`) |
| E7 | Container, permissões, hooks (roda antes da E6) | concluída; furo do host corrigido (150/150); reverificação adversária pendente |
| E6 | Teste comparativo dos agentes (configs prontas em `agents/`) | pendente |
| E8 | Validação (T1–T7 e piloto em projeto real privado) | suíte pronta e validada sem modelo; primeiro uso manual em 02/11 (relato do usuário, sem métricas); execução formal pendente; Q6 baixado em 03/11 para teste manual |
| E9 | Documentação de operação | pendente |

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `versions.env` | Versões fixadas do runtime, porta e diretórios. É a fonte única para os scripts. |
| `models.tsv` | Modelos com repositório, arquivo, tamanho e SHA-256. O modelo carregado é escolhido com `scripts/llm model`. |
| `scripts/` | Instalação e atualização (runtime, modelos, skills) e o comando `llm` do servidor. |
| `runtime/` | Configuração do `llama-server` e unidade systemd (E5). |
| `bench/` | Benchmarks e resultados resumidos (E4). |
| `agents/` | Configuração de cada agente (E6). |
| `sandbox/` | Container de execução isolada dos agentes (E7). |
| `eval/` | Suíte de validação e resultados (E8). |
| `docs/stages/` | Registro de cada etapa: comandos, resultados, problemas e soluções. |
| `docs/verifications/` | Relatórios do verificador independente, um por etapa. |

Pesos de modelos ficam em `~/models` e o runtime em `~/.local/opt/llama.cpp`, ambos fora do repositório.
