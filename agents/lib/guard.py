#!/usr/bin/env python3
"""Shell command guard, shared by the five agents. BEST EFFORT.

Called as a PreToolUse hook (Claude Code, Qwen Code, Codex), by the OpenCode
plugin and by the Pi extension. It is a conservative second layer: it blocks
dangerous patterns in the command text and accepts false positives (for example,
`git commit -m "push"` is blocked). It is not a barrier: code generated and run
later, `eval` of built strings, interpreters (`python -c`) and redirections
(`> ~/.bashrc`, `mv`, `truncate`) get through. The barrier is the E7 container
(agent-box).

Input (stdin, JSON), hook format of Claude Code / Qwen Code / Codex:
  {"tool_name": "Bash", "tool_input": {"command": "..."}, "cwd": "..."}
or the plain format {"command": "...", "cwd": "..."}. `command` may be a list.
Output: exit code 0 allows; exit code 2 blocks, with the reason on stderr (the
agent passes the reason to the model, which is why the messages are in English).

Policy (environment):
  AGENT_PROFILE  interactive | autonomous (default: autonomous)
  AGENT_WORKDIR  project root; else CLAUDE_PROJECT_DIR/QWEN_PROJECT_DIR; else cwd
  AGENT_LOG_DIR  if set, each block is recorded in guard.log (JSONL)

Two passes; either one blocks.
1. Whole text (without quotes or backslashes, heredocs included), ignoring
   structure:
   - `git` and `push`/`send-pack`/`receive-pack` in the same command
   - `sudo`, `su`, `doas`, `pkexec`, `runuser` as a word
   - a downloader (`curl`, `wget`...) together with: a pipe to shell/`source`/
     `eval`/`xargs`/`env`/`if`, a pipe to an interpreter reading stdin,
     `<(curl`/`$(curl`, or a downloaded file (`-o`) followed by a shell/interpreter
   - autonomous: package installs (npm/pnpm/yarn/bun/pip/uv/poetry/cargo/
     go/gem/apt/brew..., versioned names such as pip3.12), bare `yarn`, and
     `npx`/`npm exec`/`pnpm dlx` of a program that is not in node_modules/.bin
2. Structure (separate commands, shell keywords as separators, wrapper
   options, `bash -c`, `env -S`, heredoc and here-string evaluated as a script,
   except the body of `apply_patch`):
   - `rm` outside the project, on the project root, on `.git` or with an
     unresolvable target; `rm -r/-f` coming from `xargs`, after an unresolvable
     `cd`/`pushd` or after `ln` in the same command; `/tmp` is allowed, except
     the folder that contains the project
   - `find ... -delete` / `-exec rm` with a starting point outside the project
"""
import fnmatch
import json
import os
import re
import shlex
import sys
import time

SHELL_TOOLS = {"bash", "run_shell_command", "shell", "exec_command"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "ash"}
INTERPRETERS = {"python", "perl", "ruby", "node", "bun", "deno"}
DOWNLOADERS = {"curl", "wget", "fetch", "aria2c", "http", "https", "xh"}
PRIV = {"sudo", "su", "doas", "pkexec", "runuser"}
KEYWORDS = {"if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
            "case", "esac", "select", "function", "{", "}", "!", "in", "coproc"}
SEPARATORS = {";", "&&", "||", "|", "|&", "&", "(", ")", ";;", "\n"}
# Wrappers and the options that take an argument.
WRAPPER_OPTS = {
    "nice": {"-n", "--adjustment"}, "time": {"-f", "--format", "-o", "--output"},
    "command": set(), "builtin": set(), "noglob": set(), "exec": {"-a"}, "nohup": set(),
    "stdbuf": {"-i", "-o", "-e"}, "ionice": {"-c", "-n", "-p", "-P", "-u"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"}, "chrt": set(), "setsid": set(),
    "env": {"-u", "--unset", "-C", "--chdir"},
    "xargs": {"-I", "-i", "-n", "-P", "-L", "-l", "-d", "-a", "-E", "-e", "-s", "--arg-file",
              "--delimiter", "--max-args", "--max-procs", "--max-lines", "--replace"},
}

INSTALL_SUBCMDS = {
    "npm": {"install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta", "isntal",
            "add", "ci", "update", "up", "upgrade", "install-test", "it", "install-ci-test", "cit"},
    "pnpm": {"install", "i", "add", "update", "up", "upgrade", "dlx", "install-test", "it"},
    "yarn": {"install", "add", "upgrade", "dlx", "up"},
    "bun": {"install", "i", "add", "update", "x"},
    "pip": {"install", "download"},
    "poetry": {"add", "install", "update", "self", "sync"},
    "pipx": {"install", "run", "inject"},
    "cargo": {"install", "add", "update", "fetch"},
    "go": {"install", "get"},
    "gem": {"install", "update"},
    "bundle": {"install", "update", "add"},
    "conda": {"install", "create", "update"},
    "mamba": {"install", "create", "update"},
    "composer": {"install", "require", "update"},
    "uv": {"add", "sync", "pip", "tool"},
}
ALWAYS_INSTALLERS = {"apt", "apt-get", "aptitude", "dnf", "yum", "pacman", "brew", "snap",
                     "flatpak", "zypper", "apk", "port", "bunx", "pnpx", "uvx"}


class Deny(Exception):
    pass


def load_input():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {"command": raw}
    tool = str(data.get("tool_name") or "").lower()
    ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    command = ti.get("command", ti.get("cmd"))
    if command is None:
        command = data.get("command", "")
    if isinstance(command, list):
        command = shlex.join(str(c) for c in command)
    cwd = ti.get("directory") or ti.get("workdir") or ti.get("cwd") or data.get("cwd") or os.getcwd()
    return tool, str(command or ""), str(cwd)


def project_root(cwd):
    for var in ("AGENT_WORKDIR", "CLAUDE_PROJECT_DIR", "QWEN_PROJECT_DIR"):
        if os.environ.get(var):
            return os.path.realpath(os.environ[var])
    return os.path.realpath(cwd)


def norm_prog(word):
    """Program name without path or version: /usr/bin/pip3.12 -> pip."""
    base = word.rsplit("/", 1)[-1]
    m = re.fullmatch(r"(pip|python|node|ruby|perl)[0-9.]*", base)
    return m.group(1) if m else base


# ---------------------------------------------------------------- whole text

def scan_text(command, cwd, root, profile, heredoc_skip):
    text = command
    for body in heredoc_skip:  # apply_patch body: file content, never executed
        text = text.replace(body, " ")
    # apply_patch '<patch>' (Codex argument form): same.
    text = re.sub(r"\bapply_patch\s+(['\"])\*\*\* Begin Patch.*?\*\*\* End Patch\s*\1", "apply_patch ", text, flags=re.S)
    flat = re.sub(r"\\\n", " ", text)
    flat = re.sub(r"[\\'\"]", "", flat)
    words = [norm_prog(w) for w in re.findall(r"[A-Za-z0-9_.+/~-]+", flat)]
    wset = set(words)

    if "git" in wset and wset & {"push", "send-pack", "receive-pack"}:
        raise Deny("git push is not allowed: pushing is always done manually by the user "
                   "(the guard is conservative: any command mentioning both git and push is refused)")
    hit = wset & PRIV
    if hit:
        raise Deny(f"'{sorted(hit)[0]}' (privilege escalation) is not allowed")

    if wset & DOWNLOADERS:
        dl = r"(?:\S*/)?(?:curl|wget|fetch|aria2c|xh)\b"
        sh = r"(?:\S*/)?(?:sh|bash|zsh|dash|ksh|fish|ash|source|eval|xargs|env|if|\.)\b"
        interp = r"(?:\S*/)?(?:python[0-9.]*|perl|ruby|node|bun|deno)"
        if (re.search(r"\|&?\s*" + sh, flat)
                or re.search(r"\|&?\s*" + interp + r"\s*(?:-\s*)?(?:$|[|;&)])", flat, re.M)
                or re.search(r"(?:<\(|\$\(|`)\s*" + dl, flat)
                or re.search(r"/dev/stdin|/proc/self/fd/0", flat)):
            raise Deny("executing downloaded code (curl | sh, bash <(curl ...), source /dev/stdin) is not allowed")
        if re.search(dl + r".*\s(?:-o|-O|--output|--remote-name|-P)\b", flat) and \
                re.search(r"(?:^|[;&|\s])(?:\S*/)?(?:sh|bash|zsh|dash|python[0-9.]*|perl|ruby|node|source|\.)\s+\S", flat):
            raise Deny("downloading a file and running it with a shell/interpreter in the same command is not allowed")

    if profile == "autonomous":
        scan_installs(flat, cwd, root)


def scan_installs(flat, cwd, root):
    for chunk in re.split(r"[;&|\n(){}`]|\$\(|\b(?:then|do|else|elif)\b", flat):
        w = [norm_prog(x) for x in re.findall(r"[A-Za-z0-9_.+/~=-]+", chunk)]
        for i, prog in enumerate(w):
            if prog in ALWAYS_INSTALLERS:
                raise Deny(f"'{prog}' (package installation) is not allowed in autonomous mode")
            rest = [a for a in w[i + 1:] if not a.startswith("-")]
            flags = [a for a in w[i + 1:] if a.startswith("-")]
            if prog == "python" and w[i + 1:i + 3] == ["-m", "pip"]:
                prog, rest = "pip", [a for a in w[i + 3:] if not a.startswith("-")]
            if prog == "uv" and ("--with" in flags or any(a.startswith("--with=") for a in flags)):
                raise Deny("uv run --with installs packages; not allowed in autonomous mode")
            if prog in INSTALL_SUBCMDS and rest and rest[0] in INSTALL_SUBCMDS[prog]:
                raise Deny(f"'{prog} {rest[0]}' (network install) is not allowed in autonomous mode; "
                           "dependencies are preinstalled")
            if prog == "yarn" and not rest:
                raise Deny("bare `yarn` installs dependencies; not allowed in autonomous mode")
            target = None
            if prog == "npx" or (prog in ("npm", "pnpm") and rest[:1] in (["exec"], ["x"], ["dlx"])):
                cand = rest[1:] if prog != "npx" else rest
                target = cand[0] if cand else None
                if target is None or not local_bin(target, cwd, root):
                    raise Deny(f"'{prog}' would download '{target}': only binaries already in "
                               "node_modules/.bin are allowed in autonomous mode")


def local_bin(name, cwd, root):
    name = name.split("@")[0] if not name.startswith("@") else name
    for base in {cwd or root, root}:
        if os.path.exists(os.path.join(base, "node_modules", ".bin", os.path.basename(name))):
            return True
    return False


# ---------------------------------------------------------------- structure

HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def split_heredocs(cmd):
    """Return (command without the bodies, [(reader, body)]). Reader "apply_patch"
    marks a patch body (file content, never executed)."""
    out, bodies, lines, i = [], [], cmd.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            tag = m.group(2)
            prefix = line[:m.start()]
            is_patch = re.search(r"(?:^|[\s;&|(\"'])apply_patch\s*$", prefix) is not None
            words = prefix.split()
            reader = "apply_patch" if is_patch else (norm_prog(words[0]) if words else "")
            body = []
            while i < len(lines) and lines[i].strip() != tag:
                body.append(lines[i])
                i += 1
            i += 1
            bodies.append((reader, "\n".join(body)))
    return "\n".join(out), bodies


def tokenize(cmd):
    lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def segments(tokens):
    """Simple commands: [(tokens, previous_separator, here_strings)].
    Shell keywords (if/then/for/do...) separate; redirections are dropped."""
    segs, cur, prev, skip, herestr = [], [], None, None, []
    for tok in tokens:
        if skip:
            if skip == "<<<":
                herestr.append(tok)
            skip = None
            continue
        if tok in SEPARATORS or (tok and set(tok) <= set(";&|()")) or (not cur and tok in KEYWORDS):
            if cur:
                segs.append((cur, prev, herestr))
            cur, prev, herestr = [], tok, []
        elif tok and set(tok) <= set("<>&|") and ("<" in tok or ">" in tok):
            if cur and cur[-1].isdigit():
                cur.pop()
            skip = tok if (not tok.endswith("&") or tok in ("&>", "&>>") or tok.endswith((">&", "<&"))) else None
        else:
            cur.append(tok)
    if cur:
        segs.append((cur, prev, herestr))
    return segs


def program(tokens):
    """Skip VAR=x and wrappers with their options. Return (prog, args, via_xargs, env_s)."""
    i, via_xargs, env_s = 0, False, None
    while i < len(tokens):
        t = tokens[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
            continue
        base = norm_prog(t)
        if base in WRAPPER_OPTS:
            via_xargs = via_xargs or base == "xargs"
            opts = WRAPPER_OPTS[base]
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                o = tokens[i]
                if base == "env" and o in ("-S", "--split-string") and i + 1 < len(tokens):
                    env_s = tokens[i + 1]
                    i += 2
                    continue
                i += 2 if o in opts else 1
            if base == "timeout" and i < len(tokens):
                i += 1  # duration
            if base == "env":
                while i < len(tokens) and "=" in tokens[i]:
                    i += 1
            continue
        return base, tokens[i + 1:], via_xargs, env_s
    return "", [], via_xargs, env_s


def resolve(path, cwd):
    """(directory, pattern) of the target; (None, None) if it cannot be resolved."""
    if cwd is None and not (path.startswith("/") or path.startswith("~") or path.startswith("$HOME")):
        return None, None
    home = os.path.expanduser("~")
    p = re.sub(r"^\$\{?HOME\}?(?=/|$)", home, path)
    if cwd is not None:
        p = re.sub(r"^\$\{?PWD\}?(?=/|$)", cwd, p)
    if p == "~" or p.startswith("~/"):
        p = home + p[1:]
    if "$" in p or "`" in p or p.startswith("~"):
        return None, None
    glob_at = min([i for i, c in enumerate(p) if c in "*?["] or [len(p)])
    if glob_at == len(p):
        return os.path.realpath(os.path.join(cwd or "/", p)), None
    head = p[:glob_at]
    base = head.rsplit("/", 1)[0] + "/" if "/" in head else ""
    pattern = p[len(base):].split("/", 1)[0]
    return os.path.realpath(os.path.join(cwd or "/", base or ".")), pattern


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def may_hit(directory, pattern, protected):
    if pattern is None:
        return inside(protected, directory)
    if not inside(protected, directory) or protected == directory:
        return False
    first = os.path.relpath(protected, directory).split("/", 1)[0]
    if first.startswith(".") and not pattern.startswith("."):
        return False
    return fnmatch.fnmatchcase(first, pattern)


def check_target(t, cwd, root, what):
    parent = os.path.dirname(root)
    d, pattern = resolve(t, cwd)
    if d is None:
        raise Deny(f"{what} with a target the guard cannot resolve ('{t}'); use a literal path inside the project")
    if may_hit(d, pattern, root):
        raise Deny(f"{what} on '{t}' would delete the project root or a parent of it")
    if may_hit(d, pattern, os.path.join(root, ".git")):
        raise Deny(f"{what} on .git is not allowed")
    if inside(d, root):
        return
    if inside(d, "/tmp") and not may_hit(d, pattern, "/tmp") and not inside(d, parent):
        return
    if pattern is not None and d == "/tmp" and not may_hit(d, pattern, parent):
        return
    raise Deny(f"{what} outside the project is not allowed: '{t}'")


def check_rm(args, cwd, root, via_xargs, link_made):
    flags = [a for a in args if a.startswith("-") and a not in ("-", "--")]
    targets = [a for a in args if not (a.startswith("-") and a not in ("-",))]
    recursive = any(f in ("--recursive", "-R") or (not f.startswith("--") and ("r" in f or "R" in f)) for f in flags)
    force = any(f == "--force" or (not f.startswith("--") and "f" in f) for f in flags)
    if (recursive or force) and via_xargs:
        raise Deny("rm -r/-f with targets from xargs is not allowed (the guard cannot see the targets)")
    if (recursive or force) and link_made:
        raise Deny("rm -r/-f after creating a link in the same command is not allowed")
    if (recursive or force) and not targets:
        raise Deny("rm -r/-f without explicit targets is not allowed")
    for t in targets:
        check_target(t, cwd, root, "rm -r/-f" if (recursive or force) else "rm")


def check_find(args, cwd, root):
    deleting = "-delete" in args or any(
        a in ("-exec", "-execdir", "-ok", "-okdir") and i + 1 < len(args) and norm_prog(args[i + 1]) in ("rm", "rmdir", "unlink", "shred")
        for i, a in enumerate(args))
    if not deleting:
        return
    starts = []
    for a in args:
        if a.startswith("-") or a in ("(", "!", ")"):
            break
        starts.append(a)
    for t in starts or ["."]:
        d, _ = resolve(t, cwd)
        if d is None or not (inside(d, root) or (inside(d, "/tmp") and not inside(root, d))):
            raise Deny(f"find with -delete/-exec rm starting at '{t}' (outside the project or unresolvable) is not allowed")


def shell_script(prog, args):
    if prog not in SHELLS:
        return None
    for i, a in enumerate(args):
        if a.startswith("-") and not a.startswith("--") and "c" in a[1:] and i + 1 < len(args):
            return args[i + 1]
    return None


def structural(command, cwd, root, profile, depth):
    try:
        tokens = tokenize(command)
    except ValueError:
        return  # unbalanced quotes: only the text pass applies
    link_made = False
    for toks, _sep, herestr in segments(tokens):
        prog, args, via_xargs, env_s = program(toks)
        for s in herestr:
            evaluate(s, cwd, profile, depth + 1)
        if env_s:
            evaluate(env_s, cwd, profile, depth + 1)
        if not prog:
            continue
        script = shell_script(prog, args)
        if script is not None:
            evaluate(script, cwd, profile, depth + 1)
        if prog in ("ln", "link"):
            link_made = True
        elif prog in ("rm", "unlink", "rmdir", "shred"):
            check_rm(args, cwd, root, via_xargs, link_made)
        elif prog == "find":
            check_find(args, cwd, root)
        elif prog in ("cd", "pushd"):
            target = next((a for a in args if not a.startswith("-")), "~")
            cwd = resolve(target, cwd)[0] if target != "-" else None
        elif prog == "popd":
            cwd = None


def evaluate(command, cwd, profile, depth=0):
    if depth > 4:
        raise Deny("command nesting too deep for the guard")
    root = project_root(cwd if cwd else ".")
    cwd = os.path.realpath(cwd) if cwd else None
    stripped, bodies = split_heredocs(command)
    scan_text(command, cwd, root, profile, [b for prog, b in bodies if prog == "apply_patch" and b])
    for prog, body in bodies:
        if prog != "apply_patch":
            evaluate(body, cwd, profile, depth + 1)
    structural(stripped, cwd, root, profile, depth)


def main():
    tool, command, cwd = load_input()
    if tool and tool not in SHELL_TOOLS:
        return 0
    profile = os.environ.get("AGENT_PROFILE", "autonomous")
    try:
        evaluate(command, cwd, profile)
    except Deny as e:
        msg = f"Blocked by local policy: {e}."
        log_dir = os.environ.get("AGENT_LOG_DIR")
        if log_dir:
            try:
                with open(os.path.join(log_dir, "guard.log"), "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "profile": profile,
                                         "cwd": cwd, "command": command, "reason": str(e)}) + "\n")
            except OSError:
                pass
        print(msg, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
