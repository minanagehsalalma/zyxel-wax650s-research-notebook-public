#!/usr/bin/env python3
import argparse
import os
import signal
import socket
import struct
import sys
from pathlib import Path


REQUEST_SIZE = 0x228
REPLY_SIZE = 0x228
SEARCH_STAIP_EVENT = 0x2E
REPLY_TYPE_SEARCH_RESULT = 0x07
PID_OFFSET = 0x00
EVENT_OFFSET = 0x04
SLOT_OFFSET = 0x08
IPV4_OFFSET = 0x38
PAYLOAD_OFFSET = 0x08
PAYLOAD_RADIO_OFFSET = 0x00
PAYLOAD_VAP_OFFSET = 0x2C


def decode_ipv4(raw: bytes) -> str:
    return socket.inet_ntoa(raw)


def build_reply(pid: int, radio: int, vap: int) -> bytes:
    buf = bytearray(REPLY_SIZE)
    struct.pack_into("<I", buf, PID_OFFSET, pid)
    struct.pack_into("<I", buf, EVENT_OFFSET, REPLY_TYPE_SEARCH_RESULT)
    struct.pack_into("<I", buf, PAYLOAD_OFFSET + PAYLOAD_RADIO_OFFSET, radio)
    struct.pack_into("<I", buf, PAYLOAD_OFFSET + PAYLOAD_VAP_OFFSET, vap)
    return bytes(buf)


def serve(path: Path, radio: int, vap: int, log_path: Path | None) -> int:
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
            packet = conn.recv(REQUEST_SIZE)
            if len(packet) < REQUEST_SIZE:
                if log_path:
                    with log_path.open("a", encoding="utf-8") as fh:
                        fh.write(f"short_request len={len(packet)} hex={packet.hex()}\n")
                continue
            pid = struct.unpack_from("<I", packet, PID_OFFSET)[0]
            event = struct.unpack_from("<I", packet, EVENT_OFFSET)[0]
            slot = struct.unpack_from("<I", packet, SLOT_OFFSET)[0]
            ipv4 = decode_ipv4(packet[IPV4_OFFSET:IPV4_OFFSET + 4])
            if log_path:
                with log_path.open("a", encoding="utf-8") as fh:
                    fh.write(
                        "pid="
                        f"{pid} event=0x{event:02x} slot={slot} ipv4={ipv4} "
                        f"reply_radio={radio} reply_vap={vap}\n"
                    )
            if event != SEARCH_STAIP_EVENT:
                conn.sendall(bytes(REPLY_SIZE))
                continue
            conn.sendall(build_reply(pid, radio, vap))


def main() -> int:
    parser = argparse.ArgumentParser(description="Deterministic AF_UNIX shim for Zyxel wireless_hal debug lookups")
    parser.add_argument("--socket", required=True, help="Socket path, e.g. runroot/tmp/wirelesshaldebug")
    parser.add_argument("--radio", type=int, default=0, help="Radio index returned to the CGI")
    parser.add_argument("--vap", type=int, default=1, help="VAP index returned to the CGI")
    parser.add_argument("--log", help="Optional append-only log path")
    args = parser.parse_args()

    log_path = Path(args.log).resolve() if args.log else None
    return serve(Path(args.socket).resolve(), args.radio, args.vap, log_path)


if __name__ == "__main__":
    raise SystemExit(main())
