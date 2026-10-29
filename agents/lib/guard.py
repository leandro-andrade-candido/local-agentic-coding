#!/usr/bin/env python3
"""Guarda de comandos de shell, comum aos quatro agentes.

Chamada como hook PreToolUse (Claude Code, Qwen Code), pelo plugin do OpenCode
e pela extensão do Pi. É a segunda camada de proteção: a barreira real é o
container da etapa E7. Comandos ofuscados (eval, base64, variáveis, scripts
gerados) podem escapar; as regras nativas de cada agente continuam valendo.

Entrada (stdin, JSON), formato de hook do Claude Code / Qwen Code:
  {"tool_name": "Bash", "tool_input": {"command": "..."}, "cwd": "..."}
ou o formato simples {"command": "...", "cwd": "..."}.
Saída: código 0 libera; código 2 bloqueia, com o motivo em stderr (o agente
repassa o motivo ao modelo, por isso as mensagens são em inglês).

Política (ambiente):
  AGENT_PROFILE  interactive | autonomous (padrão: autonomous)
  AGENT_WORKDIR  raiz do projeto; senão CLAUDE_PROJECT_DIR/QWEN_PROJECT_DIR; senão cwd
  AGENT_LOG_DIR  se definido, cada bloqueio é registrado em guard.log (JSONL)

Bloqueado nos dois perfis:
  - git push (em qualquer forma: git -C x push, git -c k=v push ...)
  - sudo, su, doas, pkexec, runuser
  - download executado por shell: curl|sh, wget -O- | bash, sh -c "$(curl ...)", bash <(curl ...)
  - rm recursivo ou forçado fora do projeto (e da raiz do projeto ou de .git);
    /tmp é permitido. Alvos que não dá para resolver ($VAR, $(...)) são bloqueados.
Bloqueado só no perfil autonomous:
  - instalação de pacotes pela rede (npm/pnpm/yarn/bun install|add|ci, pip install,
    uv add|pip install, poetry, cargo install, go install|get, gem, apt, brew ...)
"""
import fnmatch
import json
import os
import re
import shlex
import sys
import time

SHELL_TOOLS = {"bash", "run_shell_command", "shell"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "ash"}
INTERPRETERS = SHELLS | {"python", "python3", "perl", "ruby", "node", "bun", "deno"}
DOWNLOADERS = {"curl", "wget", "fetch", "aria2c", "http", "https", "xh"}
PRIV = {"sudo", "su", "doas", "pkexec", "runuser"}
SEPARATORS = {";", "&&", "||", "|", "|&", "&", "(", ")", "{", "}", "!", "\n"}
WRAPPERS = {"time", "nice", "nohup", "command", "builtin", "noglob", "exec", "stdbuf", "ionice"}
GIT_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}

INSTALL_SUBCMDS = {
    "npm": {"install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta", "isntal",
            "add", "ci", "update", "up", "upgrade", "install-test", "it", "install-ci-test", "cit"},
    "pnpm": {"install", "i", "add", "update", "up", "upgrade", "dlx", "install-test", "it"},
    "yarn": {"install", "add", "upgrade", "dlx", "up"},
    "bun": {"install", "i", "add", "update", "x"},
    "pip": {"install", "download"},
    "pip3": {"install", "download"},
    "poetry": {"add", "install", "update", "self"},
    "pipx": {"install", "run", "inject"},
    "cargo": {"install", "add", "update", "fetch"},
    "go": {"install", "get"},
    "gem": {"install", "update"},
    "bundle": {"install", "update", "add"},
    "conda": {"install", "create", "update"},
    "mamba": {"install", "create", "update"},
    "composer": {"install", "require", "update"},
}
ALWAYS_INSTALLERS = {"apt", "apt-get", "aptitude", "dnf", "yum", "pacman", "brew", "snap",
                     "flatpak", "zypper", "apk", "port", "bunx", "pnpx"}


class Deny(Exception):
    pass


def load_input():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {"command": raw}
    tool = str(data.get("tool_name") or "").lower()
    ti = data.get("tool_input") or {}
    command = ti.get("command") if isinstance(ti, dict) else None
    if command is None:
        command = data.get("command", "")
    cwd = (ti.get("directory") or ti.get("workdir") or ti.get("cwd")) if isinstance(ti, dict) else None
    cwd = cwd or data.get("cwd") or os.getcwd()
    return tool, str(command or ""), str(cwd)


def project_root(cwd):
    for var in ("AGENT_WORKDIR", "CLAUDE_PROJECT_DIR", "QWEN_PROJECT_DIR"):
        if os.environ.get(var):
            return os.path.realpath(os.environ[var])
    return os.path.realpath(cwd)


def strip_heredocs(cmd):
    """Remove o corpo de heredocs (texto de arquivo, não comandos)."""
    out, lines, i = [], cmd.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        tags = re.findall(r"(?<!<)<<(?!<)-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        i += 1
        for tag in tags:
            while i < len(lines) and lines[i].strip() != tag:
                i += 1
            i += 1  # pula a linha do delimitador
    return "\n".join(out)


def tokenize(cmd):
    lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def segments(tokens):
    """Divide em comandos simples; devolve (tokens, separador_anterior).
    Redirecionamentos (> arquivo, 2>&1, < entrada) são retirados dos argumentos."""
    segs, cur, prev, skip = [], [], None, False
    for tok in tokens:
        if skip:
            skip = False
            continue
        if tok in SEPARATORS or (tok and set(tok) <= set(";&|()")):
            if cur:
                segs.append((cur, prev))
            cur, prev = [], tok
        elif tok and set(tok) <= set("<>&|") and ("<" in tok or ">" in tok):
            if cur and cur[-1].isdigit():
                cur.pop()  # descritor: 2>arquivo
            skip = not tok.endswith("&") or tok in ("&>", "&>>")
            if tok.endswith(">&") or tok.endswith("<&"):
                skip = True  # 2>&1: o próximo token é o descritor
        else:
            cur.append(tok)
    if cur:
        segs.append((cur, prev))
    return segs


def program(tokens):
    """Pula atribuições VAR=x e wrappers; devolve (programa, argumentos)."""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
            continue
        base = os.path.basename(t)
        if base in WRAPPERS:
            i += 1
            continue
        if base == "env":
            i += 1
            while i < len(tokens) and (tokens[i].startswith("-") or "=" in tokens[i]):
                i += 1
            continue
        if base == "timeout":
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1
            i += 1  # duração
            continue
        if base == "xargs":
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1
            continue
        return base, tokens[i + 1:]
    return "", []


def resolve(path, cwd):
    """Resolve o alvo de um rm. Devolve (diretório, padrão):
    sem curinga, (caminho absoluto, None); com curinga, (diretório fixo acima
    do curinga, primeiro componente com curinga), pois os alvos reais ficam
    abaixo desse diretório. (None, None) quando não dá para resolver
    ($VAR, $(...), ~usuario)."""
    home = os.path.expanduser("~")
    p = re.sub(r"^\$\{?HOME\}?(?=/|$)", home, path)
    p = re.sub(r"^\$\{?PWD\}?(?=/|$)", cwd, p)
    if p == "~" or p.startswith("~/"):
        p = home + p[1:]
    if "$" in p or "`" in p or p.startswith("~"):
        return None, None
    glob_at = min([i for i, c in enumerate(p) if c in "*?["] or [len(p)])
    if glob_at == len(p):
        return os.path.realpath(os.path.join(cwd, p)), None
    head = p[:glob_at]
    base = head.rsplit("/", 1)[0] + "/" if "/" in head else ""
    pattern = p[len(base):].split("/", 1)[0]
    return os.path.realpath(os.path.join(cwd, base or ".")), pattern


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def may_hit(directory, pattern, protected):
    """O alvo (directory[/pattern]) apaga `protected` ou algo acima dele?"""
    if pattern is None:
        return inside(protected, directory)
    if not inside(protected, directory) or protected == directory:
        return False
    first = os.path.relpath(protected, directory).split("/", 1)[0]
    if first.startswith(".") and not pattern.startswith("."):
        return False  # o shell não expande * para arquivos ocultos
    return fnmatch.fnmatchcase(first, pattern)


def check_rm(args, cwd, root):
    flags = [a for a in args if a.startswith("-") and a != "-"]
    targets = [a for a in args if not (a.startswith("-") and a != "-")]
    recursive = any(f in ("--recursive", "-R") or (not f.startswith("--") and ("r" in f or "R" in f)) for f in flags)
    force = any(f == "--force" or (not f.startswith("--") and "f" in f) for f in flags)
    if not (recursive or force):
        return
    # /tmp é liberado, exceto a pasta que contém o projeto (outros workdirs do eval).
    parent = os.path.dirname(root)
    for t in targets:
        d, pattern = resolve(t, cwd)
        if d is None:
            raise Deny(f"rm with an unresolvable target '{t}': use a literal path inside the project")
        if may_hit(d, pattern, root):
            raise Deny(f"rm -r/-f on '{t}' would delete the project root or a parent of it")
        if may_hit(d, pattern, os.path.join(root, ".git")):
            raise Deny("rm -r/-f on .git is not allowed")
        if inside(d, root):
            continue
        if inside(d, "/tmp") and not may_hit(d, pattern, "/tmp") and not inside(d, parent):
            continue
        if pattern is not None and d == "/tmp" and not may_hit(d, pattern, parent):
            continue
        raise Deny(f"rm -r/-f outside the project is not allowed: '{t}'")


def check_git(args):
    i = 0
    while i < len(args):
        a = args[i]
        if a in GIT_OPTS_WITH_ARG:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        if a == "push":
            raise Deny("git push is not allowed: pushing is always done manually by the user")
        return
    return


def check_install(prog, args):
    if prog in ALWAYS_INSTALLERS:
        raise Deny(f"'{prog}' (package installation) is not allowed in autonomous mode")
    sub = [a for a in args if not a.startswith("-")]
    if prog in ("python", "python3") and len(args) >= 3 and args[0] == "-m" and args[1] in ("pip", "pip3"):
        prog, sub = "pip", [a for a in args[2:] if not a.startswith("-")]
    if prog == "uv" and sub[:2] in (["pip", "install"], ["tool", "install"]) or (prog == "uv" and sub[:1] == ["add"]):
        raise Deny("uv install/add (network install) is not allowed in autonomous mode; dependencies are preinstalled")
    if prog == "uvx":
        raise Deny("uvx downloads packages; not allowed in autonomous mode")
    if prog in INSTALL_SUBCMDS and sub and sub[0] in INSTALL_SUBCMDS[prog]:
        raise Deny(f"'{prog} {sub[0]}' (network install) is not allowed in autonomous mode; dependencies are preinstalled")


def check_raw(cmd):
    dl = r"(?:curl|wget|fetch|aria2c)\b"
    if re.search(r"(?:\b(?:ba|z|da|k|fi)?sh|\bsource|(?:^|[;&|(]\s*)\.)\s+[^;&|]*?(?:<\(|\$\(|`)\s*" + dl, cmd):
        raise Deny("executing downloaded code (sh -c \"$(curl ...)\", bash <(curl ...)) is not allowed")


def reads_stdin(prog, args):
    """O interpretador vai executar o que chega pelo stdin (sh, bash -s, python -)?"""
    if "-" in args or (prog in SHELLS and "-s" in args):
        return True
    if any(a in ("-c", "-m", "-e", "-E", "-p", "--eval", "--print") for a in args):
        return False
    return not [a for a in args if not a.startswith("-")]


def shell_script(prog, args):
    """Script de `bash -c '...'`, `sh -lc '...'`, `zsh -c ...`; None se não houver."""
    if prog not in SHELLS:
        return None
    for i, a in enumerate(args):
        if a.startswith("-") and not a.startswith("--") and "c" in a[1:] and i + 1 < len(args):
            return args[i + 1]
    return None


def evaluate(command, cwd, profile):
    root = project_root(cwd)
    cwd = os.path.realpath(cwd)
    cmd = strip_heredocs(command)
    check_raw(cmd)
    try:
        tokens = tokenize(cmd)
    except ValueError:
        # Aspas desbalanceadas: só as verificações por expressão regular.
        for pat, why in ((r"\bgit\b[^;&|]*\bpush\b", "git push is not allowed"),
                         (r"(?:^|[;&|]\s*)(?:sudo|su|doas|pkexec)\b", "privilege escalation is not allowed")):
            if re.search(pat, cmd):
                raise Deny(why)
        return
    pipeline_has_download = False
    for toks, sep in segments(tokens):
        if sep != "|" and sep != "|&":
            pipeline_has_download = False
        prog, args = program(toks)
        if not prog:
            continue
        if prog in PRIV:
            raise Deny(f"'{prog}' (privilege escalation) is not allowed")
        if prog in INTERPRETERS and sep in ("|", "|&") and pipeline_has_download and reads_stdin(prog, args):
            raise Deny("piping a download into a shell/interpreter (curl | sh) is not allowed")
        if prog in DOWNLOADERS:
            pipeline_has_download = True
        script = shell_script(prog, args)
        if script is not None:
            evaluate(script, cwd, profile)  # bash -lc "<script>": avalia o script interno
        if prog == "git":
            check_git(args)
        elif prog == "rm":
            check_rm(args, cwd, root)
        elif prog == "cd":
            target = args[0] if args else "~"
            new = resolve(target, cwd)[0] if target != "-" else None
            if new:
                cwd = new
        if profile == "autonomous":
            check_install(prog, args)


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
