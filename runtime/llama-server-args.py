#!/usr/bin/env python3
"""Monta os argumentos do llama-server: perfil da E4 + política da E5.

Uso (chamado por runtime/llama-server-start.sh e scripts/llm):
  python3 -I runtime/llama-server-args.py --bin BIN --profile ARQ --policy ARQ \
      --model GGUF [--format nul|shell|json|check]

Ambiente obrigatório (trocado nos valores ${...}): LLAMA_SERVER_HOST,
LLAMA_SERVER_PORT, LLM_API_KEY_FILE. Opcional: LOCAL_AGENTIC_REPO (para recusar
uma chave guardada dentro do repositório).

Regras:
- Formato dos dois arquivos: uma flag por linha ("flag" ou "flag valor", sem aspas
  e sem espaço no valor); linhas vazias e começadas por # são ignoradas.
- Os aliases vêm da ajuda do próprio binário (--help): -n, --predict e --n-predict
  são a mesma flag; --metrics e uma eventual --no-metrics também.
- Sobreposição: no b11982 vale a última ocorrência (common/arg.cpp), com o aviso
  "DEPRECATED: argument specified multiple times". Aqui a política vence e a flag
  repetida sai do perfil, para não haver repetição nem aviso.
- Recusa (código 2): flag desconhecida para o build, flag repetida no mesmo arquivo,
  flag proibida, flag de segurança no perfil, host fora do loopback, CORS aberto,
  chave ausente/legível por outros/dentro do repositório, política incompleta.
- A chave nunca é impressa; o arquivo só é lido para conferir o formato.
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

# Proibidas em qualquer arquivo (basta um nome; os aliases vêm da ajuda). O
# encaminhador do container da E7 expõe todas as rotas do servidor aos agentes.
FORBIDDEN = {
    "--props": "liga POST /props (muda propriedades globais com o servidor no ar)",
    "--slot-save-path": "liga POST /slots/<id>?action=save|restore (cache gravado e lido em disco)",
    "--agent": "liga as ferramentas embutidas (shell, arquivos) e o proxy CORS",
    "--tools": "liga as ferramentas embutidas em /tools (exec_shell_command, write_file...)",
    "--tools-runtime": "ambiente de execução das ferramentas embutidas",
    "--mcp-servers-config": "servidores MCP dentro do llama-server",
    "--mcp-servers-json": "servidores MCP dentro do llama-server",
    "--ui-mcp-proxy": "liga /cors-proxy (o servidor busca URLs arbitrárias)",
    "--connect": "túnel peer-to-peer para fora da máquina",
    "--connect-code": "túnel peer-to-peer para fora da máquina",
    "--media-path": "a API leria arquivos locais por file://",
    "--path": "serviria arquivos estáticos de um diretório local",
    "--log-prompts-dir": "gravaria os prompts (código dos projetos) em disco",
    "--api-key": "a chave ficaria na linha de comando (ps) e no git; use --api-key-file",
    "--model": "o modelo vem do models.tsv, pelo wrapper",
    "--model-url": "download de modelo",
    "--docker-repo": "download de modelo",
    "--hf-repo": "download de modelo",
    "--hf-file": "download de modelo",
    "--hf-token": "segredo na linha de comando",
    "--spec-draft-hf": "download de modelo",
    "--mmproj-url": "download de modelo",
    "--models-dir": "modo roteador (carrega e descarrega modelos pela API)",
    "--models-preset": "modo roteador (carrega e descarrega modelos pela API)",
    "--reuse-port": "outro processo poderia escutar na mesma porta",
    "--cors-credentials": "credenciais do navegador em requisições CORS",
}
# Presets que baixam pesos da internet.
FORBIDDEN_RE = re.compile(r"^--(fim-|gpt-oss-|vision-gemma-|embd-gemma-)")

# Só a política define (no perfil, recusa).
POLICY_ONLY = ("--host", "--port", "--api-key-file", "--cors-origins", "--cors-methods",
               "--cors-headers", "--cors-credentials", "--agent", "--ui-mcp-proxy", "--offline",
               "--ui", "--ssl-key-file", "--ssl-cert-file", "--api-prefix")

# Obrigatórias na linha final (perfil ou política), com a grafia exigida quando é
# booleana. As de amostragem e -n vêm de docs/stages/E5-requirements.md: sem elas o
# Codex, que não envia nada, cairia nos padrões do llama.cpp (temperatura 0.8, min-p 0.05).
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
    print(f"nota: {msg}", file=sys.stderr)


def norm(flag):
    # Mesma normalização do llama.cpp: em "--nome", "_" vira "-".
    return flag.replace("_", "-") if flag.startswith("--") else flag


def is_negative(name):
    return name.startswith("--no-") or name.startswith("-no-")


def show(e):
    return e["flag"] if e["value"] is None else f"{e['flag']} {e['value']}"


def help_groups(binary):
    """Mapa nome -> grupo (tupla com todos os nomes da mesma opção), lido do --help."""
    try:
        text = subprocess.run([binary, "--help"], capture_output=True, text=True,
                              timeout=20, check=False).stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Refusal(f"não consegui ler a ajuda de {binary}: {e}")
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
        raise Refusal(f"ajuda de {binary} inesperada (sem --port/--api-key-file)")
    return groups


def expand(value, where):
    def repl(m):
        name = m.group(1)
        if name not in PLACEHOLDERS:
            raise Refusal(f"{where}: variável ${{{name}}} não permitida (aceitas: {', '.join(PLACEHOLDERS)})")
        val = os.environ.get(name, "")
        if not val:
            raise Refusal(f"{where}: ${{{name}}} vazia no ambiente")
        return val
    out = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", repl, value)
    if "$" in out or "`" in out:
        raise Refusal(f"{where}: valor com $ ou ` não expandido: {value}")
    return out


def read_args(path, groups):
    entries, seen = [], {}
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        raise Refusal(f"não consegui ler {path}: {e}")
    for no, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        where = f"{os.path.basename(path)}:{no}"
        parts = line.split()
        if len(parts) > 2:
            raise Refusal(f"{where}: mais de um valor na linha (valor sem espaços; o comentário vai na linha de cima)")
        flag = norm(parts[0])
        if not flag.startswith("-"):
            raise Refusal(f"{where}: linha não começa com uma flag: {line}")
        group = groups.get(flag)
        if group is None:
            raise Refusal(f"{where}: flag {flag} não existe neste build do llama-server")
        if group in seen:
            raise Refusal(f"{where}: {flag} repete a linha {seen[group]} do mesmo arquivo")
        seen[group] = no
        value = expand(parts[1], where) if len(parts) == 2 else None
        entries.append({"flag": flag, "value": value, "group": group, "where": where})
    return entries


def check_forbidden(entries, groups):
    for e in entries:
        flag = e["flag"]
        if FORBIDDEN_RE.match(flag):
            raise Refusal(f"{e['where']}: {flag} proibida (preset que baixa pesos da internet)")
        for name, why in FORBIDDEN.items():
            group = groups.get(name)
            if group is None or e["group"] != group:
                continue
            # Em opções booleanas, a forma negativa (--no-...) é permitida.
            if is_negative(flag):
                continue
            raise Refusal(f"{e['where']}: {flag} proibida: {why}")


def check_key_file(path, repo):
    if not os.path.isabs(path):
        raise Refusal(f"--api-key-file precisa de caminho absoluto: {path}")
    real = os.path.realpath(path)
    if repo and (real == repo or real.startswith(repo.rstrip("/") + "/")):
        raise Refusal(f"a chave não pode ficar dentro do repositório: {path}")
    try:
        st = os.stat(path)
    except FileNotFoundError:
        raise Refusal(f"chave não encontrada: {path} (crie com: scripts/llm key)")
    if not stat.S_ISREG(st.st_mode):
        raise Refusal(f"a chave não é um arquivo comum: {path}")
    if st.st_mode & 0o077:
        raise Refusal(f"a chave é legível por outros usuários (modo {stat.S_IMODE(st.st_mode):o}): chmod 600 {path}")
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    keys = [k for k in lines if k and not k.startswith("#")]
    if not keys:
        raise Refusal(f"arquivo de chave sem nenhuma chave: {path}")
    if any(k != k.strip() for k in keys):
        raise Refusal(f"chave com espaço ou \\r nas pontas (o servidor compara byte a byte): {path}")
    if len(keys) > 1 or len(lines) != len(keys):
        note(f"{path} tem mais de uma linha; os clientes leem o arquivo inteiro com cat")
    if min(len(k) for k in keys) < 32:
        note("chave com menos de 32 caracteres")


def build(args):
    groups = help_groups(args.bin)
    profile = read_args(args.profile, groups)
    policy = read_args(args.policy, groups)
    check_forbidden(profile + policy, groups)

    policy_only = {groups[n] for n in POLICY_ONLY if n in groups}
    for e in profile:
        if e["group"] in policy_only:
            raise Refusal(f"{e['where']}: {e['flag']} é da política (runtime/llama-server.policy.args), não do perfil")

    # A política vence: a flag do perfil que ela também define sai da linha.
    policy_groups = {e["group"]: e for e in policy}
    kept, same = [], []
    for e in profile:
        p = policy_groups.get(e["group"])
        if p is None:
            kept.append(e)
        elif p["value"] == e["value"] and is_negative(p["flag"]) == is_negative(e["flag"]):
            same.append(show(p))
        else:
            note(f"perfil '{show(e)}' ({e['where']}) substituído pela política '{show(p)}' ({p['where']})")
    if same:
        note("no perfil e na política com o mesmo valor (fica só a da política): " + ", ".join(same))

    final = [{"flag": "-m", "value": args.model, "group": groups["-m"], "where": "wrapper"}] + kept + policy

    by_group = {e["group"]: e for e in final}
    for name, spelling in REQUIRED.items():
        e = by_group.get(groups[name])
        if e is None:
            raise Refusal(f"a linha final precisa de {spelling or name} (no perfil ou na política)")
        if spelling and is_negative(spelling) != is_negative(e["flag"]):
            raise Refusal(f"{e['where']}: esperado {spelling}, encontrado {e['flag']}")

    hosts = by_group[groups["--host"]]["value"].split(",")
    for h in hosts:
        if h not in LOOPBACK and not h.endswith(".sock"):
            raise Refusal(f"--host {h}: só loopback (127.0.0.1, ::1, localhost) ou socket UNIX")
    port = by_group[groups["--port"]]["value"]
    if not port.isdigit() or not 0 < int(port) < 65536:
        raise Refusal(f"--port inválida: {port}")
    origins = by_group[groups["--cors-origins"]]["value"]
    if origins == "*" or "," in origins:
        raise Refusal(f"--cors-origins {origins}: use uma origem só (o b11982 copia o valor literal "
                      "no Access-Control-Allow-Origin)")
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
        print(f"erro: {e}", file=sys.stderr)
        return 2
    if args.format == "nul":
        sys.stdout.write("".join(a + "\0" for a in argv))
    elif args.format == "shell":
        lines = [shlex.quote(args.bin)]
        for e in final:
            lines.append(shlex.quote(e["flag"]) + ("" if e["value"] is None else " " + shlex.quote(e["value"])))
        print(" \\\n  ".join(lines))
    elif args.format == "json":
        # Valor final por nome (todos os aliases), para scripts/llm health comparar com /props.
        out = {}
        for e in final:
            for name in e["group"]:
                out[name] = {"flag": e["flag"], "value": e["value"]}
        print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
