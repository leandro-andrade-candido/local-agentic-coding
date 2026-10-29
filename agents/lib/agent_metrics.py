#!/usr/bin/env python3
"""Lê o events.jsonl de uma execução e grava <log-dir>/agent-metrics.json.

Uso: agent_metrics.py <agente> <log-dir>
Agentes: qwen-code, pi, opencode, claude-local, codex-local.

Campos (null quando o agente não fornece o dado; ver agents/README.md):
  turns              respostas do modelo no laço do agente
  requests           requisições ao modelo vistas pelo cliente (só as do laço principal)
  tool_calls         chamadas de ferramenta
  tool_call_errors   resultados marcados como erro pelo agente (alias: tool_errors)
  loops_detected     sequências de 3+ chamadas iguais seguidas, mesma ferramenta e
                     mesmos argumentos (alias: loops_suspected)
  tokens_in/out      tokens do ponto de vista do cliente, cache incluído
                     (também em client_tokens: {"input", "output"})
  raw_tool_call_text textos/raciocínios com "<tool_call>" ou "<function=" crus
                     (sintoma de chamada de ferramenta não reconhecida)
  guard_blocks       linhas de guard.log (comandos bloqueados pela guarda comum)
Nunca falha: erro de leitura vira campo "error" no JSON.
"""
import json
import os
import re
import sys

RAW_CALL = re.compile(r"<tool_call>|<function=")


def read_events(path):
    events = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except OSError:
        pass
    return events


def canon(name, args):
    try:
        return name + "\x00" + json.dumps(args, sort_keys=True, ensure_ascii=False)
    except (TypeError, ValueError):
        return name + "\x00" + str(args)


def count_loops(calls, min_run=3):
    loops, run, prev = 0, 0, None
    for c in calls:
        run = run + 1 if c == prev else 1
        if run == min_run:
            loops += 1
        prev = c
    return loops


def raw_hits(text):
    return 1 if isinstance(text, str) and RAW_CALL.search(text) else 0


def anthropic_like(events, usage_includes_cache):
    """Claude Code e Qwen Code (stream-json no formato do SDK do Claude)."""
    calls, errors, raw, ids, tin, tout = [], 0, 0, set(), 0, 0
    per_msg = {}
    result = None
    for e in events:
        t = e.get("type")
        if t == "assistant" and not e.get("parent_tool_use_id"):
            msg = e.get("message") or {}
            mid = msg.get("id") or e.get("uuid")
            ids.add(mid)
            if isinstance(msg.get("usage"), dict):
                per_msg[mid] = msg["usage"]
            for b in msg.get("content") or []:
                if b.get("type") == "tool_use":
                    calls.append(canon(str(b.get("name")), b.get("input")))
                elif b.get("type") == "text":
                    raw += raw_hits(b.get("text"))
                elif b.get("type") == "thinking":
                    raw += raw_hits(b.get("thinking"))
        elif t == "user" and not e.get("parent_tool_use_id"):
            content = (e.get("message") or {}).get("content")
            if isinstance(content, list):
                errors += sum(1 for b in content if isinstance(b, dict)
                              and b.get("type") == "tool_result" and b.get("is_error"))
        elif t == "result":
            result = e

    def total_in(u):
        base = int(u.get("input_tokens") or 0)
        if usage_includes_cache:
            return base
        return base + int(u.get("cache_read_input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0)

    usage = (result or {}).get("usage")
    if isinstance(usage, dict) and (usage.get("input_tokens") or usage.get("output_tokens")):
        tin, tout = total_in(usage), int(usage.get("output_tokens") or 0)
    elif per_msg:
        tin = sum(total_in(u) for u in per_msg.values())
        tout = sum(int(u.get("output_tokens") or 0) for u in per_msg.values())
    else:
        tin = tout = None
    turns = (result or {}).get("num_turns")
    return {"turns": turns if isinstance(turns, int) else len(ids) or None,
            "requests": len(ids) or None, "tool_calls": len(calls), "tool_call_errors": errors,
            "loops_detected": count_loops(calls), "tokens_in": tin, "tokens_out": tout,
            "raw_tool_call_text": raw}


def pi(events):
    calls, errors, raw, requests, tin, tout, turns = [], 0, 0, 0, 0, 0, 0
    for e in events:
        t = e.get("type")
        if t == "message_end" and (e.get("message") or {}).get("role") == "assistant":
            msg = e["message"]
            requests += 1
            u = msg.get("usage") or {}
            tin += int(u.get("input") or 0) + int(u.get("cacheRead") or 0) + int(u.get("cacheWrite") or 0)
            tout += int(u.get("output") or 0)
            for b in msg.get("content") or []:
                if b.get("type") == "toolCall":
                    calls.append(canon(str(b.get("name")), b.get("arguments")))
                elif b.get("type") == "text":
                    raw += raw_hits(b.get("text"))
                elif b.get("type") == "thinking":
                    raw += raw_hits(b.get("thinking"))
        elif t == "tool_execution_end" and e.get("isError"):
            errors += 1
        elif t == "turn_end":
            turns += 1
    return {"turns": turns or None, "requests": requests or None, "tool_calls": len(calls),
            "tool_call_errors": errors, "loops_detected": count_loops(calls),
            "tokens_in": tin if requests else None, "tokens_out": tout if requests else None,
            "raw_tool_call_text": raw}


def opencode(events):
    calls, errors, raw, steps, tin, tout = [], 0, 0, 0, 0, 0
    for e in events:
        t, part = e.get("type"), e.get("part") or {}
        if t == "tool_use":
            state = part.get("state") or {}
            calls.append(canon(str(part.get("tool")), state.get("input")))
            if state.get("status") == "error":
                errors += 1
        elif t == "step_finish":
            steps += 1
            tok = part.get("tokens") or {}
            cache = tok.get("cache") or {}
            tin += int(tok.get("input") or 0) + int(cache.get("read") or 0) + int(cache.get("write") or 0)
            tout += int(tok.get("output") or 0) + int(tok.get("reasoning") or 0)
        elif t in ("text", "reasoning"):
            raw += raw_hits(part.get("text"))
    return {"turns": steps or None, "requests": steps or None, "tool_calls": len(calls),
            "tool_call_errors": errors, "loops_detected": count_loops(calls),
            "tokens_in": tin if steps else None, "tokens_out": tout if steps else None,
            "raw_tool_call_text": raw}


def codex(events):
    calls, errors, raw, turns, tin, tout, seen_usage = [], 0, 0, 0, 0, 0, False
    for e in events:
        t = e.get("type")
        if t == "item.completed":
            item = e.get("item") or {}
            it = item.get("type")
            if it == "command_execution":
                calls.append(canon("exec_command", item.get("command")))
                if item.get("status") in ("failed", "declined"):
                    errors += 1
            elif it == "file_change":
                calls.append(canon("apply_patch", item.get("changes")))
                if item.get("status") == "failed":
                    errors += 1
            elif it in ("mcp_tool_call", "collab_tool_call", "web_search", "todo_list"):
                calls.append(canon(it, item.get("arguments") or item.get("query") or item.get("items")))
                if item.get("status") == "failed" or item.get("error"):
                    errors += 1
            elif it in ("agent_message", "reasoning"):
                raw += raw_hits(item.get("text"))
        elif t in ("turn.completed", "turn.failed"):
            turns += 1
            u = e.get("usage")
            if isinstance(u, dict):
                seen_usage = True
                tin += int(u.get("input_tokens") or 0)
                tout += int(u.get("output_tokens") or 0)
    # O exec --json não emite um evento por resposta do modelo: turns e requests
    # ficam null (turn.completed é o turno do usuário, um por prompt).
    return {"turns": None, "requests": None, "user_turns": turns or None, "tool_calls": len(calls),
            "tool_call_errors": errors, "loops_detected": count_loops(calls),
            "tokens_in": tin if seen_usage else None, "tokens_out": tout if seen_usage else None,
            "raw_tool_call_text": raw}


PARSERS = {
    "qwen-code": lambda ev: anthropic_like(ev, usage_includes_cache=True),
    "claude-local": lambda ev: anthropic_like(ev, usage_includes_cache=False),
    "pi": pi,
    "opencode": opencode,
    "codex-local": codex,
}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in PARSERS:
        sys.exit(f"uso: {sys.argv[0]} <{'|'.join(PARSERS)}> <log-dir>")
    harness, log_dir = sys.argv[1], sys.argv[2]
    out = {"harness": harness, "source": "events.jsonl"}
    try:
        m = PARSERS[harness](read_events(os.path.join(log_dir, "events.jsonl")))
        out.update(m)
        out["tool_errors"] = m["tool_call_errors"]
        out["loops_suspected"] = m["loops_detected"]
        out["client_tokens"] = (None if m["tokens_in"] is None and m["tokens_out"] is None
                                else {"input": m["tokens_in"], "output": m["tokens_out"]})
    except Exception as exc:  # noqa: BLE001 - métricas nunca derrubam a execução
        out["error"] = f"{type(exc).__name__}: {exc}"
    try:
        with open(os.path.join(log_dir, "guard.log"), encoding="utf-8") as fh:
            out["guard_blocks"] = sum(1 for _ in fh)
    except OSError:
        out["guard_blocks"] = 0
    with open(os.path.join(log_dir, "agent-metrics.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


if __name__ == "__main__":
    main()
