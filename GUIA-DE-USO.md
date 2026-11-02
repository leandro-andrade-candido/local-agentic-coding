# Guia de uso manual

Como ligar, usar e testar o ambiente sozinho. Os comandos rodam a partir de `~/me/local`. Estado em 30/10/2026: veja a tabela de etapas no [README](README.md).

## 1. Ligar e desligar o modelo

```bash
scripts/llm preflight   # confere a GPU (outros processos, VRAM, temperatura), a RAM e a porta
scripts/llm start       # sobe o serviço (~35 s); não sobe sozinho no boot
scripts/llm health      # 13 checagens; todas devem dar "ok"
scripts/llm status      # estado do serviço
scripts/llm logs -f     # log ao vivo
scripts/llm stop        # libera GPU e ~22 GB de RAM
```

- **Antes de usar:** feche jogos e o NVIDIA Broadcast. O pré-voo avisa quando há outro processo na GPU.
- **Execuções longas:** mantenha um terminal do WSL aberto, porque o serviço pode parar quando o último terminal fecha.
- **Para os agentes:** `eval "$(scripts/llm env)"` exporta `LLM_BASE_URL` e `LLM_API_KEY`. A chave fica em `~/.config/local-agentic/llm-api-key`; não a coloque em arquivos do projeto.

**Desempenho medido** (E4, verificado): ler um prompt de 20 mil tokens do zero leva ~16 s, e um turno seguinte, ~1 s. A geração fica em 33–37 tok/s com contexto curto e cai para ~21 tok/s com 120 mil tokens.

## 2. Usar um agente num projeto (interativo, isolado)

```bash
sandbox/agent-shell.sh codex-local  ~/caminho/do/projeto
sandbox/agent-shell.sh claude-local ~/caminho/do/projeto
sandbox/agent-shell.sh qwen-code    ~/caminho/do/projeto   # também: pi, opencode
sandbox/agent-shell.sh shell        ~/caminho/do/projeto   # bash no mesmo container
```

- **O que o container enxerga:** só a pasta do projeto, montada com escrita; sem internet, sem suas credenciais e sem push. A rede alcança apenas o servidor do modelo.
- **Skills do Superpowers:** já vêm montadas. Chame uma pelo nome, por exemplo pedindo para usar a skill `brainstorming`. Para skills suas, use `--skills-dir <pasta>` antes do nome do agente.
- **Projeto com UI (skill `frontend-design` da Anthropic):** rode uma vez `scripts/fetch-skills.sh frontend` e depois `sandbox/agent-shell.sh --skills-dir ~/.local/opt/skills/profiles/frontend claude-local ~/projeto`. Peça pelo nome ("use a skill frontend-design para…") ou cite-a no `AGENTS.md`. Sem `--net`, fontes e pacotes externos não baixam; o agente precisa usar o que estiver no projeto.
- **Rede externa (internet, DNS, APIs):** desligada por padrão. Para liberar numa sessão, coloque `--net` antes do nome do agente, por exemplo `sandbox/agent-shell.sh --net codex-local ~/projeto`. O modelo local continua acessível. Com rede, o agente pode baixar pacotes e acessar APIs, mas também pode enviar para fora o que estiver montado: use só em projetos sem dados sensíveis e acompanhe a sessão. Na suíte de validação e no modo autônomo, mantenha sem rede.
- **Primeiro uso:** se a imagem não existir, rode `sandbox/build.sh` (~2,9 GB).
- **Push:** faça você mesmo, fora do container, depois de revisar o diff.

## 2.1 Começar um projeto novo com brainstorm

```bash
mkdir -p ~/me/projeto-novo && cd ~/me/projeto-novo && git init -q
cat > AGENTS.md <<'EOF'
# Como trabalhar neste projeto
- Fluxo: brainstorming → writing-plans → executing-plans (ou subagent-driven-development)
  → requesting-code-review → finishing-a-development-branch.
- Sempre escreva testes e rode-os antes de declarar uma tarefa pronta.
- Documentos de desenho e planos ficam em docs/.
EOF
cd ~/me/local
scripts/llm start                                   # se o servidor não estiver no ar
sandbox/agent-shell.sh codex-local ~/me/projeto-novo     # ou claude-local, qwen-code, pi, opencode
```

Dentro do agente, peça o brainstorm pelo nome e descreva a dor, não a solução:

> Use a skill brainstorming. Quero criar um sistema para <problema>. Hoje a dor é <o que acontece>, para <quem>. Uma boa entrega seria <resultado esperado>.

O agente faz perguntas uma a uma, propõe 2 ou 3 abordagens e grava um documento de desenho em `docs/`. Depois de você aprovar:
- `Use a skill writing-plans` gera o plano de tarefas.
- `Use a skill executing-plans` implementa tarefa a tarefa, com testes.
- `Use a skill requesting-code-review` revisa o resultado.
- `Use a skill finishing-a-development-branch` fecha a branch.

O push você faz fora do container.

**Dicas para o modelo local**
- **Chame as skills pelo nome.** O acionamento automático é menos confiável que no Claude.
- **Comece novas sessões a cada fase.** Contexto curto deixa o modelo mais rápido e mais preciso; o documento de desenho e o plano em `docs/` levam o estado de uma fase para a outra.
- **Planejamento aberto é o ponto mais fraco do modelo local.** Se o desenho sair raso, uma opção é fazer o brainstorm com um modelo mais forte e executar o plano localmente.
- **Não testado:** esse fluxo ainda não rodou com o modelo de verdade, porque a E6 não foi executada. O primeiro uso é também o teste.

## 3. Testar o ambiente

| O quê | Comando | Esperado |
|---|---|---|
| Isolamento do container | `sandbox/escape-tests.sh` | 150/150 |
| Tool calling do modelo | `scripts/llm test` | `RUNTIME=0`; grava `logs/tool_calls-*.json`; leva 20–40 min |
| Suíte de validação, sem modelo | `eval/validate.sh` | toda tarefa falha após o setup e passa com a solução |
| Um agente numa tarefa | `EVAL_WRAPPER=sandbox/run-in-box.sh eval/run.sh codex-local S1 meu-teste` | `eval/runs/meu-teste/codex-local/S1/result.json` |
| Comparação de agentes (E6, R1) | `EVAL_WRAPPER=sandbox/run-in-box.sh eval/matrix.sh -r 1 e6-r1 claude-local,codex-local,qwen-code,pi,opencode S1,K1` | ~1–2 h; uma execução por vez |
| Resumo | `python3 -I eval/summarize.py eval/runs/e6-r1` | tabela por agente e tarefa |
| Nota de T1, T5, T6 | `python3 -I eval/grade.py <result.json> --score N --by NOME` | tarefas avaliadas por rubrica |

O protocolo da comparação está em [docs/etapas/E6-protocolo.md](docs/etapas/E6-protocolo.md), com as rodadas R1–R3 e os critérios de eliminação. O do piloto está em [docs/piloto/PROTOCOLO.md](docs/piloto/PROTOCOLO.md).

## 4. Problema conhecido: raciocínio em espiral

Com a configuração atual (temperatura 0,6, sem penalidade), o modelo entra em espiral em ~11% dos pedidos (4 de 35 no experimento). Ele raciocina até o limite de tokens e não responde: pode levar minutos, ou mais de 15 com o limite real.

| Configuração (35 chamadas cada) | Espirais | Corretas |
|---|---|---|
| Atual | 4 | 30 |
| `presence_penalty` 1,5 | 0 | 35 |
| Amostragem "geral" do cartão (temperatura 1,0, presença 1,5) | 0 | 35 |
| Atual + orçamento de raciocínio de 2.048 tokens por pedido | 0 | 34 |

Os dados brutos estão em `logs/e5-raciocinio/` (fora do git). A decisão está pendente, porque falta medir o efeito em código: a penalidade de presença pune repetir nomes, e código repete nomes o tempo todo. Para testar você mesmo:
- **Pelo servidor, para todos os agentes:** acrescente em `runtime/llama-server.policy.args` uma linha `--presence-penalty 1.5` (substituindo a de `0`) ou `--reasoning-budget 4096`, depois `scripts/llm restart && scripts/llm health`. A checagem de saúde espera os valores da política, então ajuste e confira.
- **Por pedido:** envie `presence_penalty` ou `reasoning_budget_tokens` no corpo do pedido à API.
- **Para medir:** rode S1–S3 com um agente antes e depois da mudança e compare.

## 5. O que está verificado e o que não está

| Parte | Estado |
|---|---|
| Hardware, llama.cpp, modelo, perfil de desempenho (E0–E4) | verificado de forma independente |
| Servidor como serviço, chave, CORS, rotas desligadas (E5) | saúde 13/13; bateria completa de tool calling e verificação independente pendentes; 26 de 27 chamadas OK na bateria parcial |
| Container (E7) | 150/150 testes de fuga; furo do host corrigido; reverificação adversária da correção pendente |
| Configuração dos 5 agentes, skills | revisão estática feita; nunca rodaram com o modelo de verdade |
| Suíte de validação | validada sem modelo (13/13) |
| Comparação de agentes (E6), validação completa e pilotos (E8) | não executados |

## 6. Atualizar

- **llama.cpp:** troque `LLAMA_CPP_BUILD` e os hashes em `versions.env`, rode `scripts/install-llama-cpp.sh` e depois `scripts/llm restart`. Para voltar atrás, restaure o valor anterior; o build antigo continua no disco.
- **Modelos:** adicione a linha em `models.tsv` (com revisão do HF e SHA-256) e rode `scripts/fetch-model.sh <alias>`.
- **Agentes:** atualize as versões em `agents/versions.env` e rode `sandbox/build.sh`.
- **Skills:** atualize `SUPERPOWERS_*` ou `ANTHROPIC_SKILLS_COMMIT` em `versions.env` e rode `scripts/fetch-skills.sh base frontend`.
