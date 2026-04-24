#!/usr/bin/env python3
import argparse
import os
import signal
import socket
import struct
import sys
from pathlib import Path

from uam_state import default_state_path, infer_user_type, read_c_string, upsert_session


PAYLOAD_SIZE = 1144
SERVICE_OFFSET = 0x0C
USERNAME_OFFSET = 0x2C
TOKEN_OFFSET = 0xEC
FIELD_SIZE = 0x20
TOKEN_FIELD_SIZE = 0x200


def parse_notify_payload(payload: bytes, default_ipv4: str, default_user_type: int) -> dict:
    username = read_c_string(payload, USERNAME_OFFSET, FIELD_SIZE)
    return {
        "service": read_c_string(payload, SERVICE_OFFSET, FIELD_SIZE) or "http/https",
        "username": username or ("admin" if default_user_type == 0 else "guest"),
        "token": read_c_string(payload, TOKEN_OFFSET, TOKEN_FIELD_SIZE),
        "ipv4": default_ipv4,
        "user_type": infer_user_type(username, default_user_type),
        "notify_type": struct.unpack_from("<I", payload[:4], 0)[0] if len(payload) >= 4 else None,
    }


def serve(
    path: Path,
    log_path: Path | None,
    state_path: Path,
    default_ipv4: str,
    default_user_type: int,
) -> int:
    if path.exists():
        path.unlink()
    path.parent.mkdir(parents=True, exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    os.chmod(path, 0o777)
    server.listen(8)

    def cleanup(*_args):
        try:
            server.close()
        finally:
            if path.exists():
                path.unlink()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    while True:
        conn, _ = server.accept()
        with conn:
            payload = conn.recv(4096)
            session = None
            if len(payload) >= PAYLOAD_SIZE:
                session = upsert_session(
                    state_path,
                    parse_notify_payload(payload, default_ipv4, default_user_type),
                )
            if log_path:
                with log_path.open("a", encoding="utf-8") as fh:
                    if session:
                        fh.write(
                            f"notify_len={len(payload)} service={session['service']} "
                            f"username={session['username']} token={session['token']} "
                            f"ipv4={session['ipv4']} user_type={session['user_type']} "
                            f"state={state_path} hex={payload.hex()}\n"
                        )
                    else:
                        fh.write(f"notify_len={len(payload)} state={state_path} hex={payload.hex()}\n")
            conn.sendall(struct.pack("<i", 0))


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal Zyxel UAM notify ACK server")
    parser.add_argument("--socket", required=True, help="Socket path, e.g. runroot/dev/user-notify")
    parser.add_argument("--log", help="Optional append-only log path")
    parser.add_argument("--state", help="Shared UAM state path; defaults beside the socket")
    parser.add_argument("--ipv4", default="127.0.0.1", help="IPv4 to attach to stored sessions")
    parser.add_argument("--default-user-type", type=int, default=1, help="Fallback type if payload does not imply one")
    args = parser.parse_args()

    log_path = Path(args.log).resolve() if args.log else None
    socket_path = Path(args.socket).resolve()
    state_path = Path(args.state).resolve() if args.state else default_state_path(socket_path)
    return serve(socket_path, log_path, state_path, args.ipv4, args.default_user_type)


if __name__ == "__main__":
    raise SystemExit(main())
