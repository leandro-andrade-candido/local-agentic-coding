#!/usr/bin/env python3
"""Leitura e escrita seguras das saídas do agente (E7, correção do item 7 da
verificação adversarial em docs/verifications/E7.md).

Com EVAL_WRAPPER, o agente roda num container, mas o eval/run.sh ainda processa
NO HOST o que o agente produziu: o diff, a pasta agent-logs e o agent-metrics.json.
Um workdir malicioso pode plantar symlinks nesses caminhos (direto em agent-logs,
que ele monta rw, ou em $out via código que roda nos containers que montam $out).
Se o host seguir esses symlinks ao ler ou escrever, dá leitura e sobrescrita de
arquivo arbitrário no host.

Regras aqui:
- nunca seguir symlink ao ler (O_NOFOLLOW; só arquivo regular; tamanho limitado);
- nunca escrever através de symlink (arquivo temporário exclusivo + os.replace, que
  troca a entrada do diretório sem seguir um symlink que esteja no lugar);
- copiar árvores só com arquivos regulares e diretórios reais (symlinks ignorados);
- extrair o tar do diff sem escrever nada no disco a partir dele (lê os membros
  esperados e grava com o escritor seguro);
- varrer $out apagando qualquer symlink antes de o host ler ou escrever.
"""
from __future__ import annotations

import json
import os
import stat
import sys
import tarfile

MAX_JSON = 1 << 20          # 1 MiB: agent-metrics.json é pequeno
MAX_PATCH = 64 * 1024 * 1024  # 64 MiB de diff é folgado


def read_json_nofollow(path: str, max_bytes: int = MAX_JSON, default=None):
    """Lê JSON sem seguir symlink. Devolve default se não for arquivo regular,
    se passar do tamanho, se não abrir ou se não for JSON válido."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return default
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > max_bytes:
            return default
        data = os.read(fd, max_bytes + 1)
    except OSError:
        return default
    finally:
        os.close(fd)
    if len(data) > max_bytes:
        return default
    try:
        return json.loads(data)
    except ValueError:
        return default


def write_bytes_atomic(path: str, data: bytes) -> None:
    """Escreve bytes sem seguir symlink: cria um temporário exclusivo no mesmo
    diretório e faz os.replace (rename não segue um symlink no destino)."""
    d = os.path.dirname(path) or "."
    tmp = os.path.join(d, f".{os.path.basename(path)}.tmp.{os.getpid()}")
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def write_json_atomic(path: str, obj) -> None:
    write_bytes_atomic(path, (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode())


def sanitize_tree(root: str) -> int:
    """Apaga todo symlink (de arquivo ou de diretório) sob root. Devolve quantos.
    Se root for ele mesmo um symlink, apaga e para."""
    if os.path.islink(root):
        os.unlink(root)
        return 1
    n = 0
    for dirpath, dirnames, filenames in os.walk(root, topdown=True):  # não segue symlink de dir
        for name in list(dirnames):
            p = os.path.join(dirpath, name)
            if os.path.islink(p):
                os.unlink(p)
                dirnames.remove(name)
                n += 1
        for name in filenames:
            p = os.path.join(dirpath, name)
            if os.path.islink(p):
                os.unlink(p)
                n += 1
    return n


def copy_tree_regular(src: str, dst: str) -> None:
    """Copia src -> dst só com diretórios reais e arquivos regulares. Ignora
    symlinks (não os segue nem os recria) e qualquer outro tipo. dst é recriado
    do zero; nunca escreve através de um symlink no destino."""
    if os.path.lexists(dst):
        if os.path.islink(dst) or not os.path.isdir(dst):
            os.unlink(dst)
        else:
            _rmtree_no_follow(dst)
    os.makedirs(dst, mode=0o755, exist_ok=True)
    if not os.path.isdir(src) or os.path.islink(src):
        return
    for dirpath, dirnames, filenames in os.walk(src, topdown=True):  # followlinks=False
        rel = os.path.relpath(dirpath, src)
        target_dir = dst if rel == "." else os.path.join(dst, rel)
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))]
        os.makedirs(target_dir, mode=0o755, exist_ok=True)
        for name in filenames:
            sp = os.path.join(dirpath, name)
            try:
                st = os.lstat(sp)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):   # symlink, fifo, socket, dispositivo: fora
                continue
            try:
                rfd = os.open(sp, os.O_RDONLY | os.O_NOFOLLOW)
            except OSError:
                continue
            try:
                data = os.read(rfd, MAX_PATCH + 1)
            finally:
                os.close(rfd)
            write_bytes_atomic(os.path.join(target_dir, name), data[:MAX_PATCH])


def _rmtree_no_follow(root: str) -> None:
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):  # não segue symlink
        for name in filenames + dirnames:
            p = os.path.join(dirpath, name)
            try:
                (os.unlink if not (os.path.isdir(p) and not os.path.islink(p)) else os.rmdir)(p)
            except OSError:
                pass
    try:
        os.rmdir(root)
    except OSError:
        pass


def extract_diff(tar_path: str, out_dir: str) -> tuple[str, str]:
    """Lê o tar emitido pela captura do diff no container (agent.patch,
    numstat.txt, commits.txt), sem extrair nada no disco a partir dele: só lê os
    membros regulares esperados e grava agent.patch com o escritor seguro.
    Devolve (numstat, commits)."""
    want = {"agent.patch", "numstat.txt", "commits.txt"}
    patch, numstat, commits = b"", "", "0"
    try:
        with tarfile.open(tar_path, "r:") as tf:
            for m in tf.getmembers():
                if m.name not in want or not m.isreg():
                    continue
                f = tf.extractfile(m)
                data = f.read(MAX_PATCH + 1) if f else b""
                if m.name == "agent.patch":
                    patch = data[:MAX_PATCH]
                elif m.name == "numstat.txt":
                    numstat = data[:MAX_JSON].decode("utf-8", "replace")
                elif m.name == "commits.txt":
                    commits = data[:64].decode("utf-8", "replace").strip() or "0"
    except (OSError, tarfile.TarError):
        pass
    write_bytes_atomic(os.path.join(out_dir, "agent.patch"), patch)
    if not commits.isdigit():
        commits = "0"
    return numstat, commits


def extract_checks(tar_path: str, out_dir: str) -> str:
    """Lê o tar das verificações (checks.json, check.log, check.stdout, check.stderr,
    check.rc), emitido no container onde $out NÃO é montado, e grava cada arquivo em
    out_dir com o escritor seguro — assim o host, e não o código do agente, escreve o
    veredito. Devolve o código de saída do check.sh (texto)."""
    want = {"checks.json", "check.log", "check.stdout", "check.stderr", "check.rc"}
    caps = {"checks.json": MAX_PATCH, "check.log": MAX_PATCH, "check.stdout": MAX_JSON,
            "check.stderr": MAX_JSON, "check.rc": 16}
    got, rc = {}, "2"
    try:
        with tarfile.open(tar_path, "r:") as tf:
            for m in tf.getmembers():
                if m.name not in want or not m.isreg():
                    continue
                f = tf.extractfile(m)
                got[m.name] = (f.read(caps[m.name] + 1)[:caps[m.name]] if f else b"")
    except (OSError, tarfile.TarError):
        pass
    for name in ("checks.json", "check.log", "check.stdout", "check.stderr"):
        if name in got:
            write_bytes_atomic(os.path.join(out_dir, name), got[name])
    if "check.rc" in got:
        v = got["check.rc"].decode("utf-8", "replace").strip()
        if v.lstrip("-").isdigit():
            rc = v
    return rc


def _main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "extract-checks":
        sys.stdout.write(extract_checks(argv[2], argv[3]))
        return 0
    if cmd == "extract-diff":
        numstat, commits = extract_diff(argv[2], argv[3])
        sys.stdout.write(commits + "\n")   # linha 1 = commits; o resto = numstat
        sys.stdout.write(numstat)
        if numstat and not numstat.endswith("\n"):
            sys.stdout.write("\n")
        return 0
    if cmd == "copy-logs":
        copy_tree_regular(argv[2], argv[3])
        return 0
    if cmd == "sanitize":
        n = sanitize_tree(argv[2])
        if n:
            sys.stderr.write(f"boxio: {n} symlink(s) removido(s) de {argv[2]}\n")
        return 0
    sys.stderr.write("uso: boxio.py extract-diff|copy-logs|sanitize ...\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
