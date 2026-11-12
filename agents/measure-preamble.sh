#!/usr/bin/env bash
# Measures the size of the first prompt (preamble: system prompt + tools +
# instructions) that an agent sends to the llama-server, with a trivial task in
# an empty git repository. Uses the agent's run.sh in the interactive profile:
# autonomous only runs inside the agent-box. To measure the autonomous profile
# (the tool lists change slightly), run this script through the agent-box, where
# AGENT_BOX=1, with AGENT_PROFILE=autonomous.
#
# Usage: agents/measure-preamble.sh <qwen-code|pi|opencode|claude-local|codex-local> [<output-dir>]
#
# Sources, from the most direct to the most indirect:
#   1. llama-server /metrics (needs --metrics): difference of
#      llamacpp:prompt_tokens_total + llamacpp:prompt_tokens_cached_total before and
#      after. It is the sum of ALL requests of the run; with the trivial task
#      it is usually just one. Counts tokens actually processed (prompt_tokens_total)
#      and reused from the cache (prompt_tokens_cached_total).
#   2. The usage field of the first response, in the agent's events.jsonl.
#   3. Recorded requests (AGENT_LOG_REQUESTS=1): Qwen Code (requests/) and Pi
#      (requests.jsonl) keep the exact body; you can count messages/tools.
# To see each request on the server: llama-server -lv 4 (or --verbose) and look for
# the slot lines with the prompt token count.
set -euo pipefail
AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
harness="${1:?usage: $0 <qwen-code|pi|opencode|claude-local|codex-local> [output-dir]}"
[ -x "$AGENTS_DIR/$harness/run.sh" ] || { echo "unknown agent: $harness" >&2; exit 2; }
out="${2:-$(mktemp -d "${TMPDIR:-/tmp}/preamble-$harness.XXXX")}"
mkdir -p "$out"

work="$out/repo"
mkdir -p "$work"
git -C "$work" init -q
printf '# Test project\n\nEmpty repository to measure the preamble.\n' > "$work/README.md"
git -C "$work" add README.md
git -C "$work" -c user.name=measure -c user.email=measure@localhost commit -qm init
printf 'Reply with only the word OK. Do not use any tool.\n' > "$out/prompt.txt"

AGENT_PROFILE="${AGENT_PROFILE:-interactive}" AGENT_LOG_REQUESTS=1 "$AGENTS_DIR/$harness/run.sh" \
  --workdir "$work" --prompt-file "$out/prompt.txt" --log-dir "$out/log" || true

log="$out/log"
echo "== $harness ($(jq -r '.version + ", profile " + .profile' "$log/run-meta.json" 2>/dev/null)), output in $log"
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
print(f"/metrics: prompt processed={proc}  reused from cache={cached}  total={proc + cached}  "
      f"generated={delta('llamacpp:tokens_predicted_total')}")
EOF
else
  echo "/metrics unavailable (llama-server without --metrics?)"
fi
case "$harness" in
  qwen-code)
    echo "recorded requests: $(find "$log/requests" -type f 2>/dev/null | wc -l)"
    jq -r 'select(.type=="assistant") | .message.usage | "usage of the 1st response: \(.)"' "$log/events.jsonl" 2>/dev/null | head -1 ;;
  pi)
    echo "recorded requests: $(wc -l < "$log/requests.jsonl" 2>/dev/null || echo 0)"
    jq -c 'select(.type=="message_end" and .message.role=="assistant") | .message.usage' "$log/events.jsonl" 2>/dev/null | head -1 | sed 's/^/usage of the 1st response: /' ;;
  opencode)
    jq -c 'select(.type=="step_finish") | (.part.tokens // .tokens)' "$log/events.jsonl" 2>/dev/null | head -1 | sed 's/^/tokens of the 1st step: /' ;;
  claude-local)
    jq -r 'select(.type=="assistant") | .message.usage | "usage of the 1st response: input=\(.input_tokens) cache_read=\(.cache_read_input_tokens // 0) cache_creation=\(.cache_creation_input_tokens // 0)"' "$log/events.jsonl" 2>/dev/null | head -1 ;;
  codex-local)
    # exec --json only gives the summed usage of the turn; with the trivial task it is usually one request.
    jq -c 'select(.type=="turn.completed") | .usage' "$log/events.jsonl" 2>/dev/null | head -1 | sed 's/^/usage of the turn: /' ;;
esac
[ -f "$log/agent-metrics.json" ] && echo "agent-metrics: $(jq -c '{requests, tool_calls, tokens_in, tokens_out}' "$log/agent-metrics.json")"
