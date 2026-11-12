#!/usr/bin/env python3
"""Tool-calling regression battery for llama-server (OpenAI and Anthropic).

Based on the independent verifier's battery from E1-E3. Covers integer
arguments, arrays and multiline strings, cases where no tool should be
called, streaming and non-streaming, round trip with the tool result and
parallel calls.

The test prompts are in Portuguese on purpose: they are test data, and the
argument checks (e.g. "senha" in the issue title) depend on them.

Each response is classified as:
  OK         expected call (or expected absence of a call), with correct arguments
  MODEL      well-formed response, but the model chose another action or arguments
  RUNTIME    runtime/parser failure: HTTP error, invalid JSON, tool-call markup
             leaking into the text, type outside the schema, nonexistent tool,
             inconsistent stop_reason
  TRUNCATED  response cut off by max_tokens (configuration, not parser)

Exits with code 1 if there is any RUNTIME or TRUNCATED. MODEL is recorded but does
not fail the run: it measures the model, not the runtime.

Usage: python3 -I scripts/tool_calls.py [--base URL] [--model alias] [--reps N]
                                        [--api-key-file FILE | --api-key K] [--json-out FILE]
     (with no key in the arguments, uses $LLM_API_KEY; scripts/llm test already passes the file)
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

SAMPLING = {"temperature": 0.6, "top_p": 0.95, "top_k": 20}
MAXTOK = 4096
SYSTEM = ("You are a software engineering assistant with access to tools. "
          "Call a tool only when it is needed to fulfil the request; otherwise answer directly.")

TOOLS = [
    {"name": "create_issue",
     "description": "Create an issue in the bug tracker.",
     "schema": {"type": "object", "properties": {
         "title": {"type": "string"},
         "priority": {"type": "integer", "description": "1 (highest) to 5 (lowest)"},
         "labels": {"type": "array", "items": {"type": "string"}}},
         "required": ["title", "priority", "labels"]}},
    {"name": "write_file",
     "description": "Create or overwrite a file with the given full content.",
     "schema": {"type": "object", "properties": {
         "path": {"type": "string"},
         "content": {"type": "string", "description": "Full file content"}},
         "required": ["path", "content"]}},
    {"name": "search_code",
     "description": "Search the repository for a regex pattern.",
     "schema": {"type": "object", "properties": {
         "pattern": {"type": "string"},
         "max_results": {"type": "integer"}},
         "required": ["pattern", "max_results"]}},
    {"name": "count_tests",
     "description": "Count test functions in a directory.",
     "schema": {"type": "object", "properties": {
         "directory": {"type": "string"},
         "recursive": {"type": "boolean"}},
         "required": ["directory", "recursive"]}},
    {"name": "read_file",
     "description": "Read a file.",
     "schema": {"type": "object", "properties": {"path": {"type": "string"}},
                "required": ["path"]}},
]
TOOL_NAMES = {t["name"] for t in TOOLS}

PY = 'import sys\n\n\ndef main():\n    print("olá, \\"mundo\\"")\n    return 0\n'


def chk_issue(a):
    return (isinstance(a.get("priority"), int) and a["priority"] == 2
            and isinstance(a.get("labels"), list)
            and sorted(x.lower() for x in a["labels"]) == ["auth", "bug"]
            and "senha" in a.get("title", "").lower())


def types_issue(a):
    # A type outside the schema indicates a conversion problem in the parser.
    errs = []
    if "priority" in a and not isinstance(a["priority"], int):
        errs.append(f"priority={a['priority']!r} ({type(a['priority']).__name__})")
    if "labels" in a and not isinstance(a["labels"], list):
        errs.append(f"labels={a['labels']!r} ({type(a['labels']).__name__})")
    return errs


def chk_write(a):
    # The trailing newline is ignored: the model sometimes omits it (observed in E1-E3).
    return a.get("path", "").endswith("hello.py") and a.get("content", "").rstrip("\n") == PY.rstrip("\n")


def chk_search(a):
    return isinstance(a.get("max_results"), int) and a["max_results"] == 5 and "TODO" in a.get("pattern", "")


def types_search(a):
    if "max_results" in a and not isinstance(a["max_results"], int):
        return [f"max_results={a['max_results']!r} ({type(a['max_results']).__name__})"]
    return []


CASES = [
    # id, prompt, expected tool (None = none), args check, types check, text check
    ("int+array",
     "Abra uma issue com o título 'Login falha com senha vazia', prioridade 2 e os rótulos bug e auth.",
     "create_issue", chk_issue, types_issue, None),
    ("multiline",
     "Crie o arquivo hello.py com exatamente o conteúdo entre as marcas <<< e >>> "
     "(preserve linhas em branco, indentação de 4 espaços e as aspas):\n<<<\n" + PY + ">>>",
     "write_file", chk_write, lambda a: [], None),
    ("int",
     "Procure no repositório o padrão TODO e traga no máximo 5 resultados.",
     "search_code", chk_search, types_search, None),
    ("no-tool-calc",
     "Quanto é 17 vezes 23? Responda só com o número.",
     None, None, None, lambda t: "391" in t),
    ("no-tool-concept",
     "Em uma frase: qual a diferença entre um mutex e um semáforo?",
     None, None, None, lambda t: len(t.strip()) > 20),
]

LEAK = re.compile(r"<tool_call>|</tool_call>|<function=|</function>|<parameter=|\"arguments\"\s*:", re.I)


class Client:
    def __init__(self, base, model, api_key):
        self.base, self.model = base.rstrip("/"), model
        self.headers = {"Content-Type": "application/json", "anthropic-version": "2023-06-01"}
        if api_key:
            self.headers["Authorization"] = f"Bearer {api_key}"
            self.headers["x-api-key"] = api_key

    def post(self, path, payload, stream=False, timeout=600):
        req = urllib.request.Request(self.base + path, data=json.dumps(payload).encode(), headers=self.headers)
        t = time.time()
        r = urllib.request.urlopen(req, timeout=timeout)
        if not stream:
            with r:
                return json.load(r), time.time() - t
        events = []
        with r:
            for raw in r:
                line = raw.decode("utf-8").rstrip("\n")
                if line.startswith("data: "):
                    d = line[6:]
                    if d.strip() == "[DONE]":
                        break
                    events.append(json.loads(d))
        return events, time.time() - t

    def openai(self, messages, stream=False):
        payload = {"model": self.model, "max_tokens": MAXTOK, "tools": oa_tools(), "stream": stream,
                   "messages": [{"role": "system", "content": SYSTEM}] + messages, **SAMPLING}
        body, dt = self.post("/v1/chat/completions", payload, stream)
        if not stream:
            ch = body["choices"][0]
            msg = ch["message"]
            calls = [(c["function"]["name"], c["function"]["arguments"]) for c in (msg.get("tool_calls") or [])]
            return calls, msg.get("content") or "", ch.get("finish_reason"), dt, msg
        acc, text, fin = {}, "", None
        for ev in body:
            if not ev.get("choices"):
                continue
            ch = ev["choices"][0]
            d = ch.get("delta", {})
            text += d.get("content") or ""
            for tc in d.get("tool_calls") or []:
                slot = acc.setdefault(tc.get("index", 0), {"name": "", "args": ""})
                f = tc.get("function", {})
                slot["name"] += f.get("name") or ""
                slot["args"] += f.get("arguments") or ""
            fin = ch.get("finish_reason") or fin
        calls = [(v["name"], v["args"]) for _, v in sorted(acc.items())]
        return calls, text, fin, dt, None

    def anthropic(self, messages, stream=False):
        payload = {"model": self.model, "max_tokens": MAXTOK, "system": SYSTEM, "tools": an_tools(),
                   "stream": stream, "messages": messages, **SAMPLING}
        body, dt = self.post("/v1/messages", payload, stream)
        if not stream:
            content = body.get("content", [])
            calls = [(b["name"], json.dumps(b.get("input"))) for b in content if b.get("type") == "tool_use"]
            text = "".join(b.get("text", "") for b in content if b.get("type") == "text")
            return calls, text, body.get("stop_reason"), dt, content
        blocks, text, stop = {}, "", None
        for ev in body:
            t = ev.get("type")
            if t == "content_block_start" and ev["content_block"].get("type") == "tool_use":
                blocks[ev["index"]] = {"name": ev["content_block"]["name"], "args": ""}
            elif t == "content_block_delta":
                d = ev["delta"]
                if d.get("type") == "input_json_delta":
                    blocks[ev["index"]]["args"] += d.get("partial_json", "")
                elif d.get("type") == "text_delta":
                    text += d.get("text", "")
            elif t == "message_delta":
                stop = ev.get("delta", {}).get("stop_reason") or stop
        calls = [(v["name"], v["args"] or "{}") for _, v in sorted(blocks.items())]
        return calls, text, stop, dt, None


def oa_tools():
    return [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                              "parameters": t["schema"]}} for t in TOOLS]


def an_tools():
    return [{"name": t["name"], "description": t["description"], "input_schema": t["schema"]} for t in TOOLS]


def user_msg(text):
    return [{"role": "user", "content": text}]


def parse_calls(api, calls, text, fin):
    """Common runtime checks. Returns (verdict, detail, parsed_calls)."""
    if fin == ("length" if api == "openai" else "max_tokens"):
        return "TRUNCATED", f"finish={fin}", []
    if LEAK.search(text or ""):
        return "RUNTIME", f"tool-call markup leaked into the text: {text[:160]!r}", []
    parsed = []
    for name, args in calls:
        if name not in TOOL_NAMES:
            return "RUNTIME", f"nonexistent tool: {name!r}", []
        try:
            a = json.loads(args) if isinstance(args, str) else args
        except Exception as e:  # noqa: BLE001
            return "RUNTIME", f"arguments is not valid JSON ({e}): {args[:160]!r}", []
        if not isinstance(a, dict):
            return "RUNTIME", f"arguments is not an object: {a!r}", []
        parsed.append((name, a))
    if calls and fin != ("tool_calls" if api == "openai" else "tool_use"):
        return "RUNTIME", f"there is a tool call but finish/stop_reason={fin}", []
    if not calls and fin not in ("stop", "end_turn"):
        return "RUNTIME", f"no tool call and finish/stop_reason={fin}", []
    return None, "", parsed


def classify(api, case, calls, text, fin):
    _, _, want, chk, types, txtchk = case
    verdict, detail, parsed = parse_calls(api, calls, text, fin)
    if verdict:
        return verdict, detail
    if want is None:
        if parsed:
            return "MODEL", f"called {parsed[0][0]} {json.dumps(parsed[0][1], ensure_ascii=False)[:120]} unnecessarily"
        return ("OK" if txtchk(text) else "MODEL"), f"text={text.strip()[:80]!r}"
    if not parsed:
        return "MODEL", f"did not call a tool; text={text.strip()[:120]!r}"
    name, a = parsed[0]
    if name != want:
        return "MODEL", f"called {name} {json.dumps(a, ensure_ascii=False)[:120]}"
    terr = types(a)
    if terr:
        return "RUNTIME", "type outside the schema: " + "; ".join(terr)
    extra = f" (+{len(parsed) - 1} extra calls)" if len(parsed) > 1 else ""
    if chk(a):
        return "OK", json.dumps(a, ensure_ascii=False)[:140] + extra
    return "MODEL", "different args: " + json.dumps(a, ensure_ascii=False)[:220] + extra


ROUNDTRIP_PROMPT = "Quantos testes existem em tests/, contando subdiretórios? Use a ferramenta."
PARALLEL_PROMPT = "Leia os arquivos a.txt e b.txt (os dois)."


def roundtrip(client, api):
    """tool call -> tool result -> final answer quoting the result."""
    msgs = user_msg(ROUNDTRIP_PROMPT)
    if api == "openai":
        calls, text, fin, _, msg = client.openai(msgs)
    else:
        calls, text, fin, _, content = client.anthropic(msgs)
    verdict, detail, parsed = parse_calls(api, calls, text, fin)
    if verdict:
        return verdict, "1st turn: " + detail
    if not parsed or parsed[0][0] != "count_tests":
        return "MODEL", f"1st turn did not call count_tests: {parsed[:1]}"
    if not isinstance(parsed[0][1].get("recursive"), bool):
        return "RUNTIME", f"recursive outside the schema: {parsed[0][1].get('recursive')!r}"
    if api == "openai":
        msgs = msgs + [msg, {"role": "tool", "tool_call_id": msg["tool_calls"][0]["id"],
                             "content": "137 test functions found"}]
        calls, text, fin, _, _ = client.openai(msgs)
    else:
        tool_id = next(b["id"] for b in content if b.get("type") == "tool_use")
        msgs = msgs + [{"role": "assistant", "content": content},
                       {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id,
                                                     "content": "137 test functions found"}]}]
        calls, text, fin, _, _ = client.anthropic(msgs)
    verdict, detail, parsed = parse_calls(api, calls, text, fin)
    if verdict:
        return verdict, "2nd turn: " + detail
    if parsed:
        return "MODEL", f"2nd turn called {parsed[0][0]} instead of answering"
    return ("OK" if "137" in text else "MODEL"), f"final={text.strip()[:90]!r}"


def parallel(client, api):
    """Two independent reads in the same turn."""
    fn = client.openai if api == "openai" else client.anthropic
    calls, text, fin, _, _ = fn(user_msg(PARALLEL_PROMPT))
    verdict, detail, parsed = parse_calls(api, calls, text, fin)
    if verdict:
        return verdict, detail
    paths = sorted(a.get("path", "") for n, a in parsed if n == "read_file")
    return ("OK" if paths == ["a.txt", "b.txt"] else "MODEL"), f"paths={paths}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:9931")
    ap.add_argument("--model", default="local")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--api-key", default=None,
                    help="key on the command line (visible in ps); prefer --api-key-file")
    ap.add_argument("--api-key-file", default=None,
                    help="file with the key (first line not starting with #); "
                         "with neither --api-key nor --api-key-file, uses $LLM_API_KEY")
    ap.add_argument("--json-out", default=None, help="writes the detailed result as JSON")
    args = ap.parse_args()
    api_key = args.api_key
    if api_key is None and args.api_key_file:
        with open(args.api_key_file, encoding="utf-8") as f:
            api_key = next((ln for ln in f.read().splitlines() if ln and not ln.startswith("#")), None)
    if api_key is None:
        api_key = os.environ.get("LLM_API_KEY") or None
    client = Client(args.base, args.model, api_key)

    results = []

    def record(api, mode, cid, rep, fn):
        t = time.time()
        try:
            verdict, detail = fn()
        except urllib.error.HTTPError as e:
            verdict, detail = "RUNTIME", f"HTTP {e.code}: {e.read()[:200]!r}"
        except Exception as e:  # noqa: BLE001
            verdict, detail = "RUNTIME", f"exception: {e!r}"
        dt = time.time() - t
        results.append({"api": api, "mode": mode, "case": cid, "rep": rep + 1,
                        "verdict": verdict, "seconds": round(dt, 2), "detail": detail})
        print(f"{verdict:9} {api:9} {mode:6} {cid:17} #{rep + 1} {dt:5.1f}s  {detail}", flush=True)

    for stream in (False, True):
        mode = "stream" if stream else "sync"
        for api in ("openai", "anthropic"):
            fn = client.openai if api == "openai" else client.anthropic
            for case in CASES:
                for rep in range(args.reps):
                    def run(case=case, fn=fn, api=api, stream=stream):
                        calls, text, fin, _, _ = fn(user_msg(case[1]), stream)
                        return classify(api, case, calls, text, fin)
                    record(api, mode, case[0], rep, run)
    for api in ("openai", "anthropic"):
        for rep in range(args.reps):
            record(api, "sync", "round-trip", rep, lambda api=api: roundtrip(client, api))
            record(api, "sync", "parallel", rep, lambda api=api: parallel(client, api))

    print("\nSUMMARY (OK/total per case)")
    groups = {}
    for r in results:
        groups.setdefault((r["api"], r["mode"], r["case"]), []).append(r["verdict"])
    for (api, mode, cid), vs in groups.items():
        print(f"  {api:9} {mode:6} {cid:17} OK={vs.count('OK')}/{len(vs)}  MODEL={vs.count('MODEL')}"
              f"  RUNTIME={vs.count('RUNTIME')}  TRUNCATED={vs.count('TRUNCATED')}")
    allv = [r["verdict"] for r in results]
    totals = {k: allv.count(k) for k in ("OK", "MODEL", "RUNTIME", "TRUNCATED")}
    print(f"TOTAL: OK={totals['OK']} MODEL={totals['MODEL']} RUNTIME={totals['RUNTIME']}"
          f" TRUNCATED={totals['TRUNCATED']} of {len(allv)}")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump({"base": args.base, "model": args.model, "reps": args.reps, "sampling": SAMPLING,
                       "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "totals": totals, "results": results},
                      f, ensure_ascii=False, indent=1)
    sys.exit(1 if totals["RUNTIME"] or totals["TRUNCATED"] else 0)


if __name__ == "__main__":
    main()
