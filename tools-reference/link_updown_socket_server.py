#!/usr/bin/env python3
import argparse
import os
import signal
import socket
import sys
from pathlib import Path


running = True


def handle_stop(signum, frame):
    del signum, frame
    global running
    running = False


def main() -> int:
    parser = argparse.ArgumentParser(description="No-op AF_UNIX datagram server for Zyxel lab")
    parser.add_argument("--socket", required=True, help="Socket path to bind")
    parser.add_argument("--log", help="Optional append-only log path")
    args = parser.parse_args()

    sock_path = Path(args.socket)
    sock_path.parent.mkdir(parents=True, exist_ok=True)
    if sock_path.exists() or sock_path.is_symlink():
        sock_path.unlink()

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    log_fp = None
    if args.log:
        log_path = Path(args.log)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_fp = log_path.open("a", encoding="utf-8")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(str(sock_path))
    sock.settimeout(0.5)

    try:
        while running:
            try:
                data = sock.recv(4096)
            except TimeoutError:
                continue
            except socket.timeout:
                continue
            if log_fp:
                log_fp.write(data.decode("utf-8", errors="replace"))
                if not data.endswith(b"\n"):
                    log_fp.write("\n")
                log_fp.flush()
    finally:
        sock.close()
        if log_fp:
            log_fp.close()
        try:
            sock_path.unlink()
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
