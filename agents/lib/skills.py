#!/usr/bin/env python3
"""Skills (padrão SKILL.md) para os agentes locais.

Contrato: AGENT_SKILLS_DIRS = lista de diretórios separados por ":"; cada um
contém pastas de skill (<nome>/SKILL.md). Sem a variável, usa o perfil base:
/opt/skills/base (container) ou $SKILLS_PREFIX/profiles/base (host), o que
existir. AGENT_SKILLS_DIRS="" (vazia) desliga as skills.

Comandos:
  dirs                          imprime os diretórios existentes, separados por ":"
  copy <destino>                copia cada pasta de skill para <destino>/<nome>
                                (primeira ocorrência de cada nome vence; <destino> é recriado)
  bootstrap <agente> <arquivo>  grava o bootstrap do Superpowers para o agente
                                (using-superpowers + mapa de ferramentas); não grava
                                nada se não houver using-superpowers
  hook-json <arquivo> [evento]  imprime o JSON de hook SessionStart (Claude Code,
                                Qwen Code) com o conteúdo do arquivo em additionalContext
  overlay <arquivo> <chave>     grava um JSON {"skills": {<chave>: [dirs...]}} para
                                mesclar na config (Qwen: directories; OpenCode: paths)
"""
import json
import os
import re
import shutil
import sys

AGENTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOTSTRAP_MARKER = "superpowers:using-superpowers bootstrap"

# Mapa de ferramentas por agente. Os arquivos references/*-tools.md vêm do próprio
# Superpowers (pasta da skill using-superpowers); os de agents/<agente>/ são nossos,
# para agentes que o Superpowers não cobre ou cobre com outros nomes de ferramenta.
MAPPINGS = {
    "claude-local": ("skill", "references/claude-code-tools.md"),
    "codex-local": ("skill", "references/codex-tools.md"),
    "pi": ("agents", "pi/superpowers-tools.md"),
    "opencode": ("agents", "opencode/superpowers-tools.md"),
    "qwen-code": ("agents", "qwen-code/superpowers-tools.md"),
}


def skill_dirs():
    raw = os.environ.get("AGENT_SKILLS_DIRS")
    if raw is None:
        prefix = os.environ.get("SKILLS_PREFIX") or os.path.expanduser("~/.local/opt/skills")
        candidates = ["/opt/skills/base", os.path.join(prefix, "profiles", "base")]
        found = [c for c in candidates if os.path.isdir(c)]
        return found[:1]
    out = []
    for d in raw.split(":"):
        d = d.strip()
        if not d:
            continue
        if os.path.isdir(d):
            out.append(os.path.abspath(d))
        else:
            print(f"skills.py: aviso: diretório de skills inexistente: {d}", file=sys.stderr)
    return out


def skills():
    """[(nome, caminho)] na ordem de AGENT_SKILLS_DIRS; o primeiro nome vence."""
    seen, out = set(), []
    for d in skill_dirs():
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name)
            if name in seen or not os.path.isfile(os.path.join(path, "SKILL.md")):
                continue
            seen.add(name)
            out.append((name, path))
    return out


def strip_frontmatter(text):
    m = re.match(r"^---\n.*?\n---\n(.*)$", text, re.S)
    return (m.group(1) if m else text).strip()


def cmd_copy(dest):
    if os.path.islink(dest) or os.path.isfile(dest):
        os.unlink(dest)
    elif os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    for name, path in skills():
        shutil.copytree(path, os.path.join(dest, name), symlinks=False)


def cmd_bootstrap(harness, out):
    if os.path.exists(out):
        os.unlink(out)
    using = dict(skills()).get("using-superpowers")
    if not using or harness not in MAPPINGS:
        return
    with open(os.path.join(using, "SKILL.md"), encoding="utf-8") as fh:
        body = strip_frontmatter(fh.read())
    kind, rel = MAPPINGS[harness]
    base = using if kind == "skill" else AGENTS_DIR
    try:
        with open(os.path.join(base, rel), encoding="utf-8") as fh:
            mapping = fh.read().strip()
    except OSError:
        mapping = ""
    text = (
        "<EXTREMELY_IMPORTANT>\n"
        f"{BOOTSTRAP_MARKER} ({harness})\n\n"
        "You have superpowers.\n\n"
        "The using-superpowers skill content is included below and is ALREADY LOADED for this "
        "session: you are following it now. Do not load using-superpowers again. Load every "
        "other skill on demand with this harness's skill mechanism (see the tool mapping).\n\n"
        f"{body}\n\n{mapping}\n"
        "</EXTREMELY_IMPORTANT>\n"
    )
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)


def cmd_hook_json(path, event="SessionStart"):
    try:
        with open(path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return
    json.dump({"hookSpecificOutput": {"hookEventName": event, "additionalContext": content}}, sys.stdout)
    sys.stdout.write("\n")


def cmd_overlay(out, key):
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"skills": {key: skill_dirs()}}, fh, indent=2)
        fh.write("\n")


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd = args[0]
    if cmd == "dirs":
        print(":".join(skill_dirs()))
    elif cmd == "copy" and len(args) == 2:
        cmd_copy(args[1])
    elif cmd == "bootstrap" and len(args) == 3:
        cmd_bootstrap(args[1], args[2])
    elif cmd == "hook-json" and len(args) in (2, 3):
        cmd_hook_json(*args[1:])
    elif cmd == "overlay" and len(args) == 3:
        cmd_overlay(args[1], args[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
