#!/usr/bin/env python3
import json
import os
import socket
import tempfile
import time
from pathlib import Path


DEFAULT_STATE_NAME = "uam_state.json"


def default_state_path(socket_path: Path) -> Path:
    return socket_path.resolve().parent / DEFAULT_STATE_NAME


def read_c_string(blob: bytes, offset: int, size: int) -> str:
    chunk = blob[offset:offset + size]
    return chunk.split(b"\x00", 1)[0].decode("utf-8", errors="ignore")


def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {"sessions": []}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def infer_user_type(username: str, fallback: int) -> int:
    if username == "admin":
        return 0
    return fallback


def extract_query_ipv4(packet: bytes, fallback: str) -> str:
    if len(packet) >= 8:
        try:
            return socket.inet_ntoa(packet[4:8])
        except OSError:
            return fallback
    return fallback


def upsert_session(path: Path, session: dict) -> dict:
    state = load_state(path)
    sessions = [
        item for item in state.get("sessions", [])
        if not (
            item.get("token") == session.get("token")
            and item.get("ipv4") == session.get("ipv4")
        )
    ]
    session["updated_at"] = int(time.time())
    sessions.append(session)
    state["sessions"] = sessions[-16:]
    save_state(path, state)
    return session


def find_session(path: Path, ipv4: str | None = None, token: str | None = None) -> dict | None:
    sessions = list(load_state(path).get("sessions", []))
    if token:
        for session in reversed(sessions):
            if session.get("token") == token:
                return session
    if ipv4:
        for session in reversed(sessions):
            if session.get("ipv4") == ipv4:
                return session
    if sessions:
        return sessions[-1]
    return None
