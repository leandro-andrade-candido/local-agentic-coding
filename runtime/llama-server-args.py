#!/usr/bin/env python3
"""Builds the llama-server arguments: E4 profile + E5 policy.

Usage (called by runtime/llama-server-start.sh and scripts/llm):
  python3 -I runtime/llama-server-args.py --bin BIN --profile FILE --policy FILE \
      --model GGUF [--format nul|shell|json|check]

Required environment (substituted in the ${...} values): LLAMA_SERVER_HOST,
LLAMA_SERVER_PORT, LLM_API_KEY_FILE. Optional: LOCAL_AGENTIC_REPO (to refuse
a key stored inside the repository).

Rules:
- Format of both files: one flag per line ("flag" or "flag value", no quotes
  and no space in the value); blank lines and lines starting with # are ignored.
- Aliases come from the binary's own help (--help): -n, --predict and --n-predict
  are the same flag; so are --metrics and a possible --no-metrics.
- Overlap: in b11982 the last occurrence wins (common/arg.cpp), with the warning
  "DEPRECATED: argument specified multiple times". Here the policy wins and the
  repeated flag is dropped from the profile, so there is no repetition and no warning.
- Refusal (exit code 2): flag unknown to the build, flag repeated in the same file,
  forbidden flag, security flag in the profile, non-loopback host, open CORS,
  key missing/readable by others/inside the repository, incomplete policy.
- The key is never printed; the file is only read to check its format.
"""
import argparse
import json
import os
import re
import shlex
import stat
import subprocess
import sys

PLACEHOLDERS = ("LLAMA_SERVER_HOST", "LLAMA_SERVER_PORT", "LLM_API_KEY_FILE")

# Forbidden in any file (one name is enough; aliases come from the help). The
# E7 container's forwarder exposes every server route to the agents.
FORBIDDEN = {
    "--props": "turns on POST /props (changes global properties while the server is running)",
    "--slot-save-path": "turns on POST /slots/<id>?action=save|restore (cache written to and read from disk)",
    "--agent": "turns on the built-in tools (shell, files) and the CORS proxy",
    "--tools": "turns on the built-in tools at /tools (exec_shell_command, write_file...)",
    "--tools-runtime": "execution environment of the built-in tools",
    "--mcp-servers-config": "MCP servers inside llama-server",
    "--mcp-servers-json": "MCP servers inside llama-server",
    "--ui-mcp-proxy": "turns on /cors-proxy (the server fetches arbitrary URLs)",
    "--connect": "peer-to-peer tunnel out of the machine",
    "--connect-code": "peer-to-peer tunnel out of the machine",
    "--media-path": "the API would read local files via file://",
    "--path": "would serve static files from a local directory",
    "--log-prompts-dir": "would write the prompts (project code) to disk",
    "--api-key": "the key would end up on the command line (ps) and in git; use --api-key-file",
    "--model": "the model comes from models.tsv, via the wrapper",
    "--model-url": "model download",
    "--docker-repo": "model download",
    "--hf-repo": "model download",
    "--hf-file": "model download",
    "--hf-token": "secret on the command line",
    "--spec-draft-hf": "model download",
    "--mmproj-url": "model download",
    "--models-dir": "router mode (loads and unloads models through the API)",
    "--models-preset": "router mode (loads and unloads models through the API)",
    "--reuse-port": "another process could listen on the same port",
    "--cors-credentials": "browser credentials in CORS requests",
}
# Presets that download weights from the internet.
FORBIDDEN_RE = re.compile(r"^--(fim-|gpt-oss-|vision-gemma-|embd-gemma-)")

# Only the policy defines these (in the profile, refusal).
POLICY_ONLY = ("--host", "--port", "--api-key-file", "--cors-origins", "--cors-methods",
               "--cors-headers", "--cors-credentials", "--agent", "--ui-mcp-proxy", "--offline",
               "--ui", "--ssl-key-file", "--ssl-cert-file", "--api-prefix")

# Required in the final line (profile or policy), with the required spelling when
# boolean. The sampling ones and -n come from docs/stages/E5-requirements.md: without them
# Codex, which sends nothing, would fall back to llama.cpp defaults (temperature 0.8, min-p 0.05).
REQUIRED = {"--host": None, "--port": None, "--api-key-file": None, "--cors-origins": None,
            "--cors-credentials": "--no-cors-credentials", "--agent": "--no-agent",
            "--metrics": "--metrics", "--temp": None, "--top-p": None, "--top-k": None,
            "--min-p": None, "--presence-penalty": None, "-n": None}

LOOPBACK = {"127.0.0.1", "::1", "localhost"}
NAME_RE = re.compile(r"-{1,2}[A-Za-z0-9][A-Za-z0-9_.-]*")
SEP_RE = re.compile(r",\s*")


class Refusal(Exception):
    pass


def note(msg):
    print(f"note: {msg}", file=sys.stderr)


def norm(flag):
    # Same normalization as llama.cpp: in "--name", "_" becomes "-".
    return flag.replace("_", "-") if flag.startswith("--") else flag


def is_negative(name):
    return name.startswith("--no-") or name.startswith("-no-")


def show(e):
    return e["flag"] if e["value"] is None else f"{e['flag']} {e['value']}"


def help_groups(binary):
    """Map name -> group (tuple with all names of the same option), read from --help."""
    try:
        text = subprocess.run([binary, "--help"], capture_output=True, text=True,
                              timeout=20, check=False).stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Refusal(f"could not read the help of {binary}: {e}")
    groups = {}
    for line in text.splitlines():
        if not line.startswith("-"):
            continue
        names, pos = [], 0
        while True:
            m = NAME_RE.match(line, pos)
            if not m:
                break
            names.append(m.group(0))
            pos = m.end()
            sep = SEP_RE.match(line, pos)
            if not sep:
                break
            pos = sep.end()
        group = tuple(names)
        for n in names:
            groups.setdefault(n, group)
    if "--port" not in groups or "--api-key-file" not in groups:
        raise Refusal(f"unexpected help from {binary} (no --port/--api-key-file)")
    return groups


def expand(value, where):
    def repl(m):
        name = m.group(1)
        if name not in PLACEHOLDERS:
            raise Refusal(f"{where}: variable ${{{name}}} not allowed (accepted: {', '.join(PLACEHOLDERS)})")
        val = os.environ.get(name, "")
        if not val:
            raise Refusal(f"{where}: ${{{name}}} is empty in the environment")
        return val
    out = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", repl, value)
    if "$" in out or "`" in out:
        raise Refusal(f"{where}: value with unexpanded $ or `: {value}")
    return out


def read_args(path, groups):
    entries, seen = [], {}
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        raise Refusal(f"could not read {path}: {e}")
    for no, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        where = f"{os.path.basename(path)}:{no}"
        parts = line.split()
        if len(parts) > 2:
            raise Refusal(f"{where}: more than one value on the line (value without spaces; the comment goes on the line above)")
        flag = norm(parts[0])
        if not flag.startswith("-"):
            raise Refusal(f"{where}: line does not start with a flag: {line}")
        group = groups.get(flag)
        if group is None:
            raise Refusal(f"{where}: flag {flag} does not exist in this llama-server build")
        if group in seen:
            raise Refusal(f"{where}: {flag} repeats line {seen[group]} of the same file")
        seen[group] = no
        value = expand(parts[1], where) if len(parts) == 2 else None
        entries.append({"flag": flag, "value": value, "group": group, "where": where})
    return entries


def check_forbidden(entries, groups):
    for e in entries:
        flag = e["flag"]
        if FORBIDDEN_RE.match(flag):
            raise Refusal(f"{e['where']}: {flag} forbidden (preset that downloads weights from the internet)")
        for name, why in FORBIDDEN.items():
            group = groups.get(name)
            if group is None or e["group"] != group:
                continue
            # For boolean options, the negative form (--no-...) is allowed.
            if is_negative(flag):
                continue
            raise Refusal(f"{e['where']}: {flag} forbidden: {why}")


def check_key_file(path, repo):
    if not os.path.isabs(path):
        raise Refusal(f"--api-key-file needs an absolute path: {path}")
    real = os.path.realpath(path)
    if repo and (real == repo or real.startswith(repo.rstrip("/") + "/")):
        raise Refusal(f"the key must not be inside the repository: {path}")
    try:
        st = os.stat(path)
    except FileNotFoundError:
        raise Refusal(f"key not found: {path} (create it with: scripts/llm key)")
    if not stat.S_ISREG(st.st_mode):
        raise Refusal(f"the key is not a regular file: {path}")
    if st.st_mode & 0o077:
        raise Refusal(f"the key is readable by other users (mode {stat.S_IMODE(st.st_mode):o}): chmod 600 {path}")
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    keys = [k for k in lines if k and not k.startswith("#")]
    if not keys:
        raise Refusal(f"key file with no key: {path}")
    if any(k != k.strip() for k in keys):
        raise Refusal(f"key with a space or \\r at the ends (the server compares byte by byte): {path}")
    if len(keys) > 1 or len(lines) != len(keys):
        note(f"{path} has more than one line; clients read the whole file with cat")
    if min(len(k) for k in keys) < 32:
        note("key shorter than 32 characters")


def build(args):
    groups = help_groups(args.bin)
    profile = read_args(args.profile, groups)
    policy = read_args(args.policy, groups)
    check_forbidden(profile + policy, groups)

    policy_only = {groups[n] for n in POLICY_ONLY if n in groups}
    for e in profile:
        if e["group"] in policy_only:
            raise Refusal(f"{e['where']}: {e['flag']} belongs to the policy (runtime/llama-server.policy.args), not the profile")

    # The policy wins: a profile flag that it also defines is dropped from the line.
    policy_groups = {e["group"]: e for e in policy}
    kept, same = [], []
    for e in profile:
        p = policy_groups.get(e["group"])
        if p is None:
            kept.append(e)
        elif p["value"] == e["value"] and is_negative(p["flag"]) == is_negative(e["flag"]):
            same.append(show(p))
        else:
            note(f"profile '{show(e)}' ({e['where']}) replaced by policy '{show(p)}' ({p['where']})")
    if same:
        note("in both profile and policy with the same value (only the policy's stays): " + ", ".join(same))

    final = [{"flag": "-m", "value": args.model, "group": groups["-m"], "where": "wrapper"}] + kept + policy

    by_group = {e["group"]: e for e in final}
    for name, spelling in REQUIRED.items():
        e = by_group.get(groups[name])
        if e is None:
            raise Refusal(f"the final line needs {spelling or name} (in the profile or the policy)")
        if spelling and is_negative(spelling) != is_negative(e["flag"]):
            raise Refusal(f"{e['where']}: expected {spelling}, found {e['flag']}")

    hosts = by_group[groups["--host"]]["value"].split(",")
    for h in hosts:
        if h not in LOOPBACK and not h.endswith(".sock"):
            raise Refusal(f"--host {h}: loopback only (127.0.0.1, ::1, localhost) or UNIX socket")
    port = by_group[groups["--port"]]["value"]
    if not port.isdigit() or not 0 < int(port) < 65536:
        raise Refusal(f"invalid --port: {port}")
    origins = by_group[groups["--cors-origins"]]["value"]
    if origins == "*" or "," in origins:
        raise Refusal(f"--cors-origins {origins}: use a single origin (b11982 copies the literal value "
                      "into Access-Control-Allow-Origin)")
    check_key_file(by_group[groups["--api-key-file"]]["value"], args.repo)

    argv = []
    for e in final:
        argv.append(e["flag"])
        if e["value"] is not None:
            argv.append(e["value"])
    return final, argv


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bin", required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--policy", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--repo", default=os.environ.get("LOCAL_AGENTIC_REPO", ""))
    ap.add_argument("--format", choices=("nul", "shell", "json", "check"), default="nul")
    args = ap.parse_args()
    try:
        final, argv = build(args)
    except Refusal as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if args.format == "nul":
        sys.stdout.write("".join(a + "\0" for a in argv))
    elif args.format == "shell":
        lines = [shlex.quote(args.bin)]
        for e in final:
            lines.append(shlex.quote(e["flag"]) + ("" if e["value"] is None else " " + shlex.quote(e["value"])))
        print(" \\\n  ".join(lines))
    elif args.format == "json":
        # Final value by name (all aliases), for scripts/llm health to compare with /props.
        out = {}
        for e in final:
            for name in e["group"]:
                out[name] = {"flag": e["flag"], "value": e["value"]}
        print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
