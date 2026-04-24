#!/usr/bin/env python3
import argparse
import os
import signal
import socket
import struct
import sys
from pathlib import Path

from uam_state import default_state_path, extract_query_ipv4, find_session


EVENT_SIZE = 0x478
DATA_SIZE = 0x3C8
QUERY_SIZE = 0x48
TYPE_OFFSET = 0x159
TOKEN_OFFSET = 0xA0
SERVICE_OFFSET = 0x00
USERNAME_OFFSET = 0x20
ADDR_STR_OFFSET = 0x60


def pack_ipv4(addr: str) -> int:
    return int.from_bytes(socket.inet_aton(addr), "little")


def build_event() -> bytes:
    buf = bytearray(EVENT_SIZE)
    struct.pack_into("<I", buf, 0x0, 0x0B)
    struct.pack_into("<I", buf, 0x4, 0x1)
    return bytes(buf)


def build_data(service: str, token: str, user_type: int, ipv4: str, username: str) -> bytes:
    buf = bytearray(DATA_SIZE)
    buf[SERVICE_OFFSET:SERVICE_OFFSET + len(service)] = service.encode()
    buf[USERNAME_OFFSET:USERNAME_OFFSET + len(username)] = username.encode()
    buf[ADDR_STR_OFFSET:ADDR_STR_OFFSET + len(ipv4)] = ipv4.encode()
    buf[TOKEN_OFFSET:TOKEN_OFFSET + len(token)] = token.encode()
    # libuam's first-match path compares the query IPv4 against these fields.
    struct.pack_into("<I", buf, 0x114, pack_ipv4(ipv4))
    struct.pack_into("<I", buf, 0x11C, pack_ipv4(ipv4))
    buf[TYPE_OFFSET] = user_type & 0xFF
    return bytes(buf)


def extract_strings(packet: bytes) -> list[str]:
    out = []
    for chunk in packet.split(b"\x00"):
        if not chunk:
            continue
        try:
            text = chunk.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if all(31 < ord(ch) < 127 for ch in text):
            out.append(text)
    return out


def token_from_query(packet: bytes, default_token: str) -> str:
    for text in extract_strings(packet):
        if text == "http/https":
            continue
        if text.count(".") == 3 and all(part.isdigit() for part in text.split(".")):
            continue
        if ":" in text:
            continue
        return text
    return default_token


def select_session(
    state_path: Path,
    packet: bytes,
    default_token: str,
    default_ipv4: str,
    default_username: str,
    default_user_type: int,
) -> tuple[dict, str, str]:
    query_ipv4 = extract_query_ipv4(packet, default_ipv4)
    session = find_session(state_path, ipv4=query_ipv4)
    if session is None:
        session = {
            "service": "http/https",
            "token": token_from_query(packet, default_token),
            "user_type": default_user_type,
            "ipv4": query_ipv4,
            "username": default_username,
        }
        match_kind = "fallback"
    else:
        match_kind = "state"
    return session, match_kind, query_ipv4


def serve(
    path: Path,
    user_type: int,
    default_token: str,
    ipv4: str,
    username: str,
    log_path: Path | None,
    state_path: Path,
) -> int:
    if path.exists():
        path.unlink()
    path.parent.mkdir(parents=True, exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
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
            packet = conn.recv(QUERY_SIZE)
            strings = extract_strings(packet)
            session, match_kind, query_ipv4 = select_session(
                state_path,
                packet,
                default_token,
                ipv4,
                username,
                user_type,
            )
            if log_path:
                with log_path.open("a", encoding="utf-8") as fh:
                    fh.write(
                        "query_len="
                        f"{len(packet)} query_ipv4={query_ipv4} match={match_kind} "
                        f"session_username={session['username']} session_token={session['token']} "
                        f"session_type={session['user_type']} state={state_path} "
                        f"strings={strings} hex={packet.hex()}\n"
                    )
            event = build_event()
            data = build_data(
                session.get("service", "http/https"),
                session["token"],
                int(session["user_type"]),
                session["ipv4"],
                session["username"],
            )
            conn.sendall(event)
            conn.sendall(data)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fake Zyxel UAM daemon over AF_UNIX")
    parser.add_argument("--socket", required=True, help="Socket path, e.g. runroot/dev/user-request")
    parser.add_argument("--user-type", type=int, default=1, help="Session type byte to inject")
    parser.add_argument("--token", default="GUEST_SESSION_DEMO", help="Default token if not found in query")
    parser.add_argument("--ipv4", default="127.0.0.1", help="IPv4 address to place in record")
    parser.add_argument(
        "--username",
        help="Session username to place in the UAM record; defaults to admin for type 0 and guest for type 1",
    )
    parser.add_argument("--log", help="Optional append-only log path")
    parser.add_argument("--state", help="Shared UAM state path; defaults beside the socket")
    args = parser.parse_args()

    log_path = Path(args.log).resolve() if args.log else None
    socket_path = Path(args.socket).resolve()
    state_path = Path(args.state).resolve() if args.state else default_state_path(socket_path)
    username = args.username
    if username is None:
        username = "admin" if args.user_type == 0 else "guest"
    return serve(socket_path, args.user_type, args.token, args.ipv4, username, log_path, state_path)


if __name__ == "__main__":
    raise SystemExit(main())
