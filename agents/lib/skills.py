#!/usr/bin/env python3
"""Skills (SKILL.md standard) for the local agents.

Contract: AGENT_SKILLS_DIRS = list of directories separated by ":"; each one
contains skill folders (<name>/SKILL.md). Without the variable, it uses the base
profile: /opt/skills/base (container) or $SKILLS_PREFIX/profiles/base (host),
whichever exists. AGENT_SKILLS_DIRS="" (empty) turns skills off.

Commands:
  dirs                          print the existing directories, separated by ":"
  copy <dest>                   copy each skill folder to <dest>/<name>
                                (the first occurrence of each name wins; <dest> is recreated)
  bootstrap <agent> <file>      write the Superpowers bootstrap for the agent
                                (using-superpowers + tool map); writes nothing
                                if there is no using-superpowers
  hook-json <file> [event]      print the SessionStart hook JSON (Claude Code,
                                Qwen Code) with the file contents in additionalContext
  overlay <file> <key>          write a JSON {"skills": {<key>: [dirs...]}} to
                                merge into the config (Qwen: directories; OpenCode: paths)
"""
import json
import os
import re
import shutil
import sys

AGENTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOTSTRAP_MARKER = "superpowers:using-superpowers bootstrap"

# Tool map per agent. The references/*-tools.md files come from Superpowers
# itself (the using-superpowers skill folder); the ones in agents/<agent>/ are ours,
# for agents that Superpowers does not cover or covers with other tool names.
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
            print(f"skills.py: warning: skills directory does not exist: {d}", file=sys.stderr)
    return out


def skills():
    """[(name, path)] in AGENT_SKILLS_DIRS order; the first name wins."""
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


def make_writable(root):
    # The source is mounted read-only and copytree preserves permissions; without
    # write access on the folders, the next session cannot delete the copy (PermissionError).
    for d, dirs, files in os.walk(root):
        os.chmod(d, os.stat(d).st_mode | 0o700)
        for f in files:
            p = os.path.join(d, f)
            if not os.path.islink(p):
                os.chmod(p, os.stat(p).st_mode | 0o600)


def cmd_copy(dest):
    if os.path.islink(dest) or os.path.isfile(dest):
        os.unlink(dest)
    elif os.path.isdir(dest):
        make_writable(dest)
        shutil.rmtree(dest)
    os.makedirs(dest)
    for name, path in skills():
        shutil.copytree(path, os.path.join(dest, name), symlinks=False)
    make_writable(dest)


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
