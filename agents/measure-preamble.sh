#!/usr/bin/env bash
# Mede o tamanho do primeiro prompt (preâmbulo: system prompt + ferramentas +
# instruções) que um agente envia ao llama-server, com uma tarefa trivial num
# repositório git vazio. Usa o run.sh do agente (perfil autonomous).
#
# Uso: agents/measure-preamble.sh <qwen-code|pi|opencode|claude-local> [<dir-de-saída>]
#
# Fontes, da mais direta para a mais indireta:
#   1. /metrics do llama-server (exige --metrics): diferença de
#      llamacpp:prompt_tokens_total + llamacpp:prompt_tokens_cached_total antes e
#      depois. É a soma de TODAS as requisições da execução; com a tarefa trivial
#      costuma ser uma só. Conta tokens processados de fato (prompt_tokens_total)
#      e reaproveitados do cache (prompt_tokens_cached_total).
#   2. O campo usage da primeira resposta, no events.jsonl do agente.
#   3. Requisições gravadas (AGENT_LOG_REQUESTS=1): Qwen Code (requests/) e Pi
#      (requests.jsonl) guardam o corpo exato; dá para contar mensagens/ferramentas.
# Para ver cada requisição no servidor: llama-server -lv 4 (ou --verbose) e procurar
# as linhas do slot com o número de tokens do prompt.
set -euo pipefail
AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
harness="${1:?uso: $0 <qwen-code|pi|opencode|claude-local> [dir-de-saída]}"
[ -x "$AGENTS_DIR/$harness/run.sh" ] || { echo "agente desconhecido: $harness" >&2; exit 2; }
out="${2:-$(mktemp -d "${TMPDIR:-/tmp}/preamble-$harness.XXXX")}"
mkdir -p "$out"

work="$out/repo"
mkdir -p "$work"
git -C "$work" init -q
printf '# Projeto de teste\n\nRepositório vazio para medir o preâmbulo.\n' > "$work/README.md"
git -C "$work" add README.md
git -C "$work" -c user.name=measure -c user.email=measure@localhost commit -qm init
printf 'Responda apenas com a palavra OK. Não use nenhuma ferramenta.\n' > "$out/prompt.txt"

AGENT_LOG_REQUESTS=1 "$AGENTS_DIR/$harness/run.sh" \
  --workdir "$work" --prompt-file "$out/prompt.txt" --log-dir "$out/log" || true

log="$out/log"
echo "== $harness ($(jq -r .version "$log/run-meta.json" 2>/dev/null)), saída em $log"
if [ -f "$log/metrics-before.prom" ] && [ -f "$log/metrics-after.prom" ]; then
  python3 -I - "$log/metrics-before.prom" "$log/metrics-after.prom" <<'EOF'
import sys
def read(p):
    d = {}
    for line in open(p):
        if line.startswith("llamacpp:"):
            k, v = line.split()[:2]
            d[k] = float(v)
    return d
a, b = read(sys.argv[1]), read(sys.argv[2])
delta = lambda k: int(b.get(k, 0) - a.get(k, 0))
proc, cached = delta("llamacpp:prompt_tokens_total"), delta("llamacpp:prompt_tokens_cached_total")
print(f"/metrics: prompt processado={proc}  reaproveitado do cache={cached}  total={proc + cached}  "
      f"gerado={delta('llamacpp:tokens_predicted_total')}")
EOF
else
  echo "/metrics indisponível (llama-server sem --metrics?)"
fi
case "$harness" in
  qwen-code)
    echo "requisições gravadas: $(find "$log/requests" -type f 2>/dev/null | wc -l)"
    jq -r 'select(.type=="assistant") | .message.usage | "usage da 1ª resposta: \(.)"' "$log/events.jsonl" 2>/dev/null | head -1 ;;
  pi)
    echo "requisições gravadas: $(wc -l < "$log/requests.jsonl" 2>/dev/null || echo 0)"
    jq -c 'select(.type=="message_end" and .message.role=="assistant") | .message.usage' "$log/events.jsonl" 2>/dev/null | head -1 | sed 's/^/usage da 1ª resposta: /' ;;
  opencode)
    jq -c 'select(.type=="step_finish") | (.part.tokens // .tokens)' "$log/events.jsonl" 2>/dev/null | head -1 | sed 's/^/tokens do 1º passo: /' ;;
  claude-local)
    jq -r 'select(.type=="assistant") | .message.usage | "usage da 1ª resposta: input=\(.input_tokens) cache_read=\(.cache_read_input_tokens // 0) cache_creation=\(.cache_creation_input_tokens // 0)"' "$log/events.jsonl" 2>/dev/null | head -1 ;;
esac
