# E5: requisitos do servidor reunidos antes da etapa

Pedidos que chegaram das outras frentes até 29/10, para entrar no serviço do `llama-server` junto com o perfil escolhido na E4 (`runtime/llama-server.args`).

| Requisito | Origem | Motivo |
|---|---|---|
| `--api-key-file` com a chave fora do git; agentes recebem a chave por `LLM_API_KEY` | verificação E1–E3 | O servidor sem chave é alcançável pelo navegador do Windows |
| `--cors-origins` restrito e `--no-cors-credentials` | verificação E1–E3 | O CORS padrão aceita qualquer origem, com credenciais |
| `--metrics` | suíte de validação e configuração dos agentes | Única medida de tokens e velocidade que vale para os 5 agentes |
| Amostragem do cartão como padrão do servidor: `--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0` | configuração dos agentes | O Codex não envia amostragem, e outros agentes podem não enviar. O padrão do llama.cpp é temperatura 0.8 com `min_p` 0.05. |
| `-n 32768` como limite padrão de saída | configuração do `codex-local` | O Codex não envia `max_output_tokens`, e argumentos longos de ferramenta não podem ser cortados |
| `-np 1`, `-t` e `-tb` calibrados | E3 e E4 | Os padrões são 4 slots e 8 threads; na E4, 6–8 threads foram melhores na geração |
| `--reasoning-preserve` | plano | Redundante no b11982, que já liga o `preserve_reasoning` por padrão; pode ficar explícito |
| Primeira execução real de `scripts/tool_calls.py` contra o Qwen3.6-35B, com saída em JSON | verificação E1–E3 | É o primeiro teste de chamadas de ferramenta do modelo principal |
| Serviço `systemd --user` com reinício automático e encerramento pelo PID | E3 | Evita o problema do `pkill` |
| Checagem antes de iniciar (pré-voo): avisar se há outro processo usando a GPU (jogo, NVIDIA Broadcast etc.), com VRAM livre, temperatura e RAM disponível, consultando o `nvidia-smi.exe` do Windows | E4, teste do autor com jogo e Broadcast | Condição de uso decidida: a GPU fica dedicada à IA enquanto ela é usada. A checagem torna visível quando essa condição não vale |
