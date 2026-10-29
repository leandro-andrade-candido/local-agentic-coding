#!/usr/bin/env python3
"""Simula turnos de um agente de programação contra o llama-server (E4).

Turno 1 (frio): system + ferramentas + um arquivo-fonte grande (~20k tokens no total).
Turnos 2 e 3 (quentes): devolvem a resposta do modelo, anexam resultado de
ferramenta + mensagem do usuário (~300-600 tokens) e medem quanto do prompt foi
reprocessado (timings.prompt_n). Opcional (--detour): uma conversa paralela
diferente e a volta à conversa principal, para testar o cache de prompt na RAM.

Uso: python3 -I bench/agent_turns.py --out raw/04-agent.jsonl [--base URL] [--target 20000]
Grava uma linha JSON por requisição; imprime um resumo.
"""
import argparse
import json
import time
import urllib.request

SYSTEM = """You are an autonomous coding agent working inside a sandboxed repository mounted at /work.
You solve software engineering tasks end to end: you read code, run commands, edit files and verify
your changes with tests before reporting back.

# Rules
- Always read a file before editing it. Never guess file contents.
- Prefer small, surgical edits with edit_file over rewriting whole files.
- After any change, run the relevant tests with run_command and read the output carefully.
- Never run destructive commands (rm -rf outside /work, git push, curl | sh, sudo).
- Keep the user informed with short status updates, but do not ask for permission for read-only actions.
- When a task is ambiguous, state your assumption explicitly and proceed.
- If a command fails, read the error, form a hypothesis, and test it. Do not retry blindly.
- Use the todo tool to track multi-step work; mark items done as you finish them.

# Output style
- Be concise. Use Markdown only for code blocks and short lists.
- When you finish, summarize what changed, which files, and how it was verified.

# Environment
- OS: Linux (container). Python 3.12, Node 24, git available. No network access.
- The repository uses pytest for tests and ruff for linting.
""" * 2

TOOLS = [
    ("read_file", "Read a file from the repository. Returns the content with line numbers. Use offset/limit for large files.",
     {"path": {"type": "string", "description": "Path relative to /work"},
      "offset": {"type": "integer", "description": "First line to read (1-based)"},
      "limit": {"type": "integer", "description": "Maximum number of lines to return"}}, ["path"]),
    ("write_file", "Create or overwrite a file with the given content. Prefer edit_file for existing files.",
     {"path": {"type": "string"}, "content": {"type": "string", "description": "Full file content"}}, ["path", "content"]),
    ("edit_file", "Replace an exact string in a file. old_string must match exactly once unless replace_all is true.",
     {"path": {"type": "string"}, "old_string": {"type": "string", "description": "Exact text to replace"},
      "new_string": {"type": "string", "description": "Replacement text"},
      "replace_all": {"type": "boolean", "description": "Replace every occurrence"}}, ["path", "old_string", "new_string"]),
    ("run_command", "Run a shell command in /work and return stdout, stderr and the exit code. Timeout 120 s.",
     {"command": {"type": "string", "description": "The full command line"},
      "timeout": {"type": "integer", "description": "Timeout in seconds"}}, ["command"]),
    ("grep", "Search file contents with a regular expression (ripgrep syntax). Returns matching lines with paths.",
     {"pattern": {"type": "string"}, "path": {"type": "string", "description": "Directory or file to search"},
      "glob": {"type": "string", "description": "Optional file glob filter, e.g. *.py"}}, ["pattern"]),
    ("glob", "List files matching a glob pattern, sorted by modification time.",
     {"pattern": {"type": "string", "description": "Glob such as src/**/*.py"}}, ["pattern"]),
    ("list_dir", "List the entries of a directory with sizes.",
     {"path": {"type": "string"}}, ["path"]),
    ("todo_write", "Replace the current todo list. Each item has content and status (pending, in_progress, done).",
     {"todos": {"type": "array", "items": {"type": "object", "properties": {
         "content": {"type": "string"}, "status": {"type": "string", "enum": ["pending", "in_progress", "done"]}},
         "required": ["content", "status"]}}}, ["todos"]),
]

TOOL_RESULT = """============================= test session starts ==============================
platform linux -- Python 3.12.3, pytest-8.3.4, pluggy-1.5.0
rootdir: /work
configfile: pyproject.toml
collected 214 items

tests/test_parser.py ........................................F.......      [ 32%]
tests/test_actions.py ..................................................  [ 55%]
tests/test_help.py ................F.................................     [ 79%]
tests/test_subparsers.py .............................................   [100%]

=================================== FAILURES ===================================
_______________________ test_optional_with_default_none ________________________

    def test_optional_with_default_none():
        parser = ArgumentParser(prog="demo")
        parser.add_argument("--level", type=int, default=None, choices=[1, 2, 3])
>       ns = parser.parse_args([])
E       TypeError: '<' not supported between instances of 'NoneType' and 'int'

tests/test_parser.py:412: TypeError
___________________________ test_help_wraps_metavar ____________________________

    def test_help_wraps_metavar():
        parser = ArgumentParser(prog="demo", formatter_class=HelpFormatter)
        parser.add_argument("--very-long-option-name", metavar="VERY_LONG_METAVAR")
        out = parser.format_help()
>       assert "--very-long-option-name VERY_LONG_METAVAR" in out
E       AssertionError: assert '--very-long-option-name VERY_LONG_METAVAR' in 'usage: demo [-h]\\n'

tests/test_help.py:88: AssertionError
=========================== short test summary info ============================
FAILED tests/test_parser.py::test_optional_with_default_none - TypeError
FAILED tests/test_help.py::test_help_wraps_metavar - AssertionError
======================== 2 failed, 212 passed in 3.41s =========================
"""


def post(base, path, payload, timeout=1800):
    req = urllib.request.Request(base + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r), time.time() - t


def tokens(base, text):
    return post(base, "/tokenize", {"content": text})[0]["tokens"]


def detokenize(base, toks):
    return post(base, "/detokenize", {"tokens": toks})[0]["content"]


def tools_payload():
    return [{"type": "function", "function": {"name": n, "description": d, "parameters": {
        "type": "object", "properties": p, "required": r}}} for n, d, p, r in TOOLS]


def chat(base, messages, max_tokens, label, out, seed=1):
    payload = {"model": "qwen3.6-35b", "messages": messages, "tools": tools_payload(),
               "max_tokens": max_tokens, "temperature": 0.6, "top_p": 0.95, "top_k": 20,
               "seed": seed, "cache_prompt": True}
    resp, wall = post(base, "/v1/chat/completions", payload)
    t = resp.get("timings", {})
    msg = resp["choices"][0]["message"]
    rec = {"label": label, "wall_s": round(wall, 2), "finish": resp["choices"][0].get("finish_reason"),
           "prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"), "prompt_ms": t.get("prompt_ms"),
           "prompt_tps": t.get("prompt_per_second"), "predicted_n": t.get("predicted_n"),
           "predicted_ms": t.get("predicted_ms"), "predicted_tps": t.get("predicted_per_second"),
           "usage": resp.get("usage"), "tool_calls": [c["function"]["name"] for c in (msg.get("tool_calls") or [])]}
    out.write(json.dumps(rec) + "\n")
    out.flush()
    print(json.dumps(rec))
    return msg


def assistant_echo(msg):
    """Mensagem do assistente como um agente a devolveria no próximo turno."""
    m = {"role": "assistant", "content": msg.get("content") or ""}
    if msg.get("reasoning_content"):
        m["reasoning_content"] = msg["reasoning_content"]
    if msg.get("tool_calls"):
        m["tool_calls"] = msg["tool_calls"]
    return m


def followup(msg, result, user_text):
    """Mensagens anexadas após a resposta do modelo: resultado de ferramenta e/ou pedido do usuário."""
    extra = [assistant_echo(msg)]
    calls = msg.get("tool_calls") or []
    for c in calls:
        extra.append({"role": "tool", "tool_call_id": c.get("id", "call_0"), "content": result})
    if not calls:
        user_text = "Tool output from my side:\n" + result + "\n" + user_text
    extra.append({"role": "user", "content": user_text})
    return extra


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:9931")
    ap.add_argument("--target", type=int, default=20000, help="tokens aproximados do prompt frio")
    ap.add_argument("--file", default="/usr/lib/python3.12/argparse.py",
                    help="um ou mais arquivos (separados por vírgula) colados no primeiro pedido")
    ap.add_argument("--max-tokens", type=int, default=1200)
    ap.add_argument("--detour", action="store_true", help="testa conversa paralela e volta")
    ap.add_argument("--salt", default="", help="texto no início do system para forçar cache frio")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    overhead = len(tokens(a.base, SYSTEM + json.dumps(tools_payload()))) + 200
    src = "\n\n".join(open(f, encoding="utf-8").read() for f in a.file.split(","))
    src_tok = tokens(a.base, src)
    keep = max(1000, a.target - overhead)
    if len(src_tok) > keep:
        src = detokenize(a.base, src_tok[:keep])
    user1 = (f"Here is the current content of argparse_vendored.py from this repo:\n\n```python\n{src}\n```\n\n"
             "Two tests fail (test_optional_with_default_none and test_help_wraps_metavar). "
             "Start by running the test suite to see the failures, then plan the fix.")
    messages = [{"role": "system", "content": a.salt + SYSTEM}, {"role": "user", "content": user1}]

    with open(a.out, "a") as out:
        m1 = chat(a.base, messages, a.max_tokens, "t1_frio", out)
        messages += followup(m1, TOOL_RESULT, "Focus on the first failure. Find where choices are validated against "
                                              "the default value and propose a minimal edit.")
        m2 = chat(a.base, messages, a.max_tokens, "t2_quente", out)
        messages += followup(m2, "src/argparse_vendored.py:2510:        if action.choices is not None and value not in action.choices:\n"
                                 "src/argparse_vendored.py:2511:            args = {'value': value,\n" * 6,
                             "Good. Now apply the edit and rerun only the failing test.")
        m3 = chat(a.base, messages, a.max_tokens, "t3_quente", out)
        if a.detour:
            side = [{"role": "system", "content": "You generate short titles."},
                    {"role": "user", "content": "Give a 5-word title for this conversation about fixing argparse "
                                                "choices validation and a help formatter bug." * 20}]
            chat(a.base, side, 30, "desvio_outra_conversa", out)
            messages += followup(m3, "1 passed in 0.12s", "Great. Now look at the second failure.")
            chat(a.base, messages, a.max_tokens, "t4_volta_do_desvio", out)


if __name__ == "__main__":
    main()
