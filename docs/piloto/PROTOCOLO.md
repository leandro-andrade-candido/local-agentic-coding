# Piloto ponta a ponta: protocolo

O piloto testa se o ambiente local consegue entregar software de verdade num projeto real e privado. O agente parte de uma descrição curta de necessidade e passa por requisitos, especificação, tarefas, implementação com testes, entrega e revisão.

Os detalhes do projeto ficam em `PILOTO.local.md`, fora do git. Este protocolo não cita o projeto.

## Entradas

| Entrada | Quem fornece | Observação |
|---|---|---|
| Descrição da funcionalidade, em 2 a 5 linhas: o problema, para quem e o que muda | autor | Não traz solução técnica; levantar os requisitos é parte do teste |
| Código do projeto | cópia ou git worktree, montado no container | Só o código. Documentos pessoais e contratuais nunca são montados |
| Restrições conhecidas (prazo, tecnologia, o que não pode mudar) | autor, opcional | Entram nos requisitos |

## Fases

Cada fase produz um arquivo numa branch própria da cópia. Os pontos de aprovação são planejados e não contam como intervenção. Intervenção é qualquer correção, dica ou retomada que o autor ou o orquestrador precise fazer fora desses pontos.

| Fase | O agente produz | Ponto de aprovação |
|---|---|---|
| F1. Entendimento | `ARQUITETURA.md`: módulos, fluxo de dados, como rodar, testar e publicar | — |
| F2. Requisitos | `REQUISITOS.md`: histórias com critérios de aceite, fora de escopo, perguntas abertas | O autor responde às perguntas e aprova |
| F3. Especificação | `SPEC.md`: desenho, arquivos afetados, dados e migrações, mudanças de API, plano de testes, riscos | O autor aprova |
| F4. Tarefas | `TAREFAS.md`: tarefas pequenas, em ordem, cada uma com critério de pronto | — |
| F5. Implementação | Código e testes tarefa a tarefa, com um commit por tarefa e testes rodando a cada passo | — |
| F6. Entrega | Build, suíte completa, lint, execução local e verificação ponta a ponta do fluxo novo. `ENTREGA.md` diz o que mudou, como verificar e o que ficou de fora | O autor testa e aceita ou recusa |
| F7. Revisão | Revisão do próprio diff numa sessão nova (ou com o modelo revisor), seguida das correções | — |

## Métricas

Registradas por fase em `metricas.json`, no diretório privado do piloto. Só os agregados vão para o repositório.

- Tempo de relógio, tokens de entrada e saída, velocidade de prefill e geração (`/metrics` do servidor)
- Intervenções não planejadas, com o motivo de cada uma
- Chamadas de ferramenta, erros de ferramenta e loops (`agent-metrics.json`)
- Estado de build, testes e lint ao fim de cada fase
- Defeitos que o autor encontrar depois do aceite

## Avaliação

O autor e o orquestrador dão uma nota de 0 a 2 em cada item. O orquestrador avalia só pelos arquivos produzidos e pelo diff, que já estão nos artefatos do piloto. Ele não lê o restante do projeto, a menos que o autor autorize.

| Item | 0 | 1 | 2 |
|---|---|---|---|
| Requisitos | incompletos ou errados | úteis, com lacunas | claros, testáveis, com bom fora de escopo |
| Especificação | inviável ou genérica | viável, com riscos não vistos | precisa, com riscos e plano de testes |
| Tarefas | sem ordem ou critério | ordenadas, sem critério claro | pequenas, ordenadas, com critério de pronto |
| Código | não segue o projeto | funciona, com retrabalho necessário | segue as convenções, pronto para merge com ajustes menores |
| Testes | ausentes ou triviais | cobrem o caminho feliz | cobrem erros e bordas e rodam no CI local |
| Entrega | não funciona ponta a ponta | funciona com correções do autor | funciona, com instruções corretas |

## Critério de aprovação

O piloto é aprovado se todas estas condições valerem:
1. O autor aceita a funcionalidade entregue.
2. Build, testes e lint terminam verdes.
3. No máximo 3 intervenções não planejadas.
4. Nenhuma ação destrutiva.
5. Nota total de pelo menos 8 em 12, sem nenhum 0.

## Isolamento e confidencialidade

- **Execução:** sempre no container `agent-box` (E7). Só a cópia do código é montada, sem rede além do servidor local.
- **Modelos:** só o modelo local. Uma execução de referência na nuvem (Codex com plano Go, ou Claude) só acontece depois do resultado local e com aprovação prévia: o orquestrador informa o que será enviado, quando e o consumo estimado. Antes disso, é preciso conferir as cláusulas de confidencialidade do contrato do projeto.
- **Artefatos:** os arquivos do piloto (requisitos, especificação, diff, logs) ficam fora deste repositório.
