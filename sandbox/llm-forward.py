#!/usr/bin/env python3
"""Byte forwarder between TCP and a unix socket, standard library only.

Connects the agent-box container (no network: --network none) to the host's llama-server:

  host  listens on a unix socket (directory mounted read-only in the container) and
        connects each client to llama-server at 127.0.0.1:<port> on the host.
  box   listens on 127.0.0.1:<port> inside the container and connects each client
        to the unix socket.

It does not interpret HTTP: each connection becomes two byte streams (one thread
per direction), so streaming (SSE), keep-alive, large bodies and several
simultaneous connections work. The host-side destination is fixed by whoever starts
the forwarder (sandbox/run-in-box.sh); the container cannot choose another
destination or another port.

Closing: end of sending on one side (EOF) becomes shutdown(SHUT_WR) on the other; an
error in either direction closes both. So a client that gives up on a request
closes the connection to llama-server, which cancels the generation.

Usage:
  llm-forward.py host --socket <file> --target 127.0.0.1:<port> [--quiet]
  llm-forward.py box  --listen 127.0.0.1:<port> --socket <file> [--background] [--quiet]
"""
from __future__ import annotations

import argparse
import os
import socket
import sys
import threading

BUF = 256 * 1024
MAX_CONNS = 64
QUIET = False


def log(msg: str) -> None:
    if not QUIET:
        print(f"llm-forward: {msg}", file=sys.stderr, flush=True)


def hostport(value: str) -> tuple[str, int]:
    host, sep, port = value.rpartition(":")
    if not sep or not port.isdigit():
        raise argparse.ArgumentTypeError(f"expected host:port, got {value!r}")
    return host.strip("[]"), int(port)


def tune(sock: socket.socket) -> None:
    if sock.family in (socket.AF_INET, socket.AF_INET6):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)


def pump(src: socket.socket, dst: socket.socket) -> bool:
    """Copies src -> dst until EOF (True) or error (False)."""
    try:
        while True:
            data = src.recv(BUF)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        return False
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    return True


def kill_both(a: socket.socket, b: socket.socket) -> None:
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def handle(client: socket.socket, connect, slots: threading.BoundedSemaphore) -> None:
    upstream = None
    try:
        try:
            upstream = connect()
        except OSError as e:
            log(f"destination unavailable: {e}")
            return
        tune(client)
        tune(upstream)

        def back() -> None:
            if not pump(upstream, client):
                kill_both(upstream, client)

        t = threading.Thread(target=back, daemon=True)
        t.start()
        if not pump(client, upstream):
            kill_both(client, upstream)
        t.join()
    finally:
        for s in (client, upstream):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
        slots.release()


def serve(listener: socket.socket, connect) -> None:
    slots = threading.BoundedSemaphore(MAX_CONNS)
    while True:
        try:
            client, _ = listener.accept()
        except InterruptedError:
            continue
        except OSError as e:
            log(f"accept failed: {e}")
            threading.Event().wait(0.2)
            continue
        if not slots.acquire(blocking=False):
            log(f"more than {MAX_CONNS} simultaneous connections; refusing")
            client.close()
            continue
        threading.Thread(target=handle, args=(client, connect, slots), daemon=True).start()


def mode_host(a: argparse.Namespace) -> None:
    host, port = a.target
    if host not in ("127.0.0.1", "localhost", "::1"):
        sys.exit(f"llm-forward: destination must be local (127.0.0.1), got {host}")
    tmp = a.socket + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)  # socket 0600: only the owner (the same UID as the container) connects
    try:
        listener.bind(tmp)
    finally:
        os.umask(old)
    listener.listen(128)
    # The file only appears under its final name once it accepts connections.
    os.rename(tmp, a.socket)

    def connect() -> socket.socket:
        return socket.create_connection((host, port))

    serve(listener, connect)


def mode_box(a: argparse.Namespace) -> None:
    host, port = a.listen
    listener = socket.create_server((host, port), backlog=128)

    def connect() -> socket.socket:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(a.socket)
        except OSError:
            s.close()
            raise
        return s

    if a.background:
        # The parent exits after listen(): the caller can already connect.
        if os.fork():
            os._exit(0)
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDWR)
        os.dup2(devnull, 0)
        os.dup2(devnull, 1)
        if QUIET:
            os.dup2(devnull, 2)
    serve(listener, connect)


def main() -> None:
    global QUIET
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    h = sub.add_parser("host")
    h.add_argument("--socket", required=True)
    h.add_argument("--target", required=True, type=hostport)
    h.add_argument("--quiet", action="store_true")
    b = sub.add_parser("box")
    b.add_argument("--listen", required=True, type=hostport)
    b.add_argument("--socket", required=True)
    b.add_argument("--background", action="store_true")
    b.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    QUIET = a.quiet
    try:
        mode_host(a) if a.mode == "host" else mode_box(a)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
