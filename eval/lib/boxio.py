#!/usr/bin/env python3
"""Safe reading and writing of the agent's outputs (E7, fix for item 7 of the
adversarial verification in docs/verifications/E7.md).

With EVAL_WRAPPER, the agent runs in a container, but eval/run.sh still processes
ON THE HOST what the agent produced: the diff, the agent-logs directory and agent-metrics.json.
A malicious workdir can plant symlinks at those paths (directly in agent-logs,
which it mounts rw, or in $out via code running in the containers that mount $out).
If the host follows those symlinks when reading or writing, that allows reading and
overwriting arbitrary files on the host.

Rules here:
- never follow a symlink when reading (O_NOFOLLOW; regular files only; bounded size);
- never write through a symlink (exclusive temporary file + os.replace, which
  swaps the directory entry without following a symlink in its place);
- copy trees with regular files and real directories only (symlinks ignored);
- extract the diff tar without writing anything to disk from it (reads the expected
  members and writes them with the safe writer);
- scan $out deleting every symlink before the host reads or writes.
"""
from __future__ import annotations

import json
import os
import stat
import sys
import tarfile

MAX_JSON = 1 << 20          # 1 MiB: agent-metrics.json is small
MAX_PATCH = 64 * 1024 * 1024  # 64 MiB of diff is plenty


def read_json_nofollow(path: str, max_bytes: int = MAX_JSON, default=None):
    """Reads JSON without following symlinks. Returns default if it is not a regular file,
    is too large, cannot be opened or is not valid JSON."""
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
    """Writes bytes without following symlinks: creates an exclusive temporary file in the same
    directory and does os.replace (rename does not follow a symlink at the destination)."""
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
    """Deletes every symlink (to a file or directory) under root. Returns how many.
    If root itself is a symlink, deletes it and stops."""
    if os.path.islink(root):
        os.unlink(root)
        return 1
    n = 0
    for dirpath, dirnames, filenames in os.walk(root, topdown=True):  # does not follow directory symlinks
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
    """Copies src -> dst with real directories and regular files only. Ignores
    symlinks (neither follows nor recreates them) and any other type. dst is recreated
    from scratch; never writes through a symlink at the destination."""
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
            if not stat.S_ISREG(st.st_mode):   # symlink, fifo, socket, device: skipped
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
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):  # does not follow symlinks
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
    """Reads the tar emitted by the diff capture in the container (agent.patch,
    numstat.txt, commits.txt), without extracting anything to disk from it: it only reads the
    expected regular members and writes agent.patch with the safe writer.
    Returns (numstat, commits)."""
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
    """Reads the checks tar (checks.json, check.log, check.stdout, check.stderr,
    check.rc), emitted in the container where $out is NOT mounted, and writes each file to
    out_dir with the safe writer, so the host, not the agent's code, writes the
    verdict. Returns the check.sh exit code (as text)."""
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
        sys.stdout.write(commits + "\n")   # line 1 = commits; the rest = numstat
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
            sys.stderr.write(f"boxio: {n} symlink(s) removed from {argv[2]}\n")
        return 0
    sys.stderr.write("usage: boxio.py extract-diff|extract-checks|copy-logs|sanitize ...\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
