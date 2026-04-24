#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"

RUNROOT="$ROOT_DIR/runroot"
STATE_DIR="$ROOT_DIR/.lab-state"
TRACE_OUT="${1:-$ROOT_DIR/live_artifacts/direct_zysh_trace_guest.log}"
BODY_OUT="${2:-$ROOT_DIR/live_artifacts/direct_zysh_trace_guest_body.txt}"
CMD_PAYLOAD="${CMD_PAYLOAD:-cmd=show+version}"
CONTENT_LENGTH="${#CMD_PAYLOAD}"

command -v bwrap >/dev/null 2>&1
command -v qemu-aarch64-static >/dev/null 2>&1

mkdir -p "$(dirname "$TRACE_OUT")" "$(dirname "$BODY_OUT")" "$STATE_DIR"

proc_bind=()
sys_bind=()
dev_bind=()
uam_bind=()
build_vendor_binds proc_bind sys_bind dev_bind uam_bind "$RUNROOT"

wait_for_socket() {
  local socket_path="$1"
  local attempts="${2:-50}"
  local i
  for ((i=0; i<attempts; i++)); do
    if [[ -S "$socket_path" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for socket: $socket_path" >&2
  return 1
}

if [[ ! -f "$STATE_DIR/uam.pid" ]] || ! kill -0 "$(cat "$STATE_DIR/uam.pid")" 2>/dev/null; then
  python3 "$ROOT_DIR/tools/uam_unix_server.py" \
    --socket "$RUNROOT/dev/user-request" \
    --user-type 1 \
    --token testtoken \
    --ipv4 127.0.0.1 \
    --log "$STATE_DIR/uam-direct.log" \
    >"$STATE_DIR/uam-direct.stdout.log" 2>&1 &
  echo $! >"$STATE_DIR/uam.pid"
fi
wait_for_socket "$RUNROOT/dev/user-request"
build_vendor_binds proc_bind sys_bind dev_bind uam_bind "$RUNROOT"

python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true
rm -f "$RUNROOT/var/run/zylogd.pid"
rm -f "$RUNROOT/tmp/zylog_fifo1" "$RUNROOT/tmp/zylog_fifo2" "$RUNROOT/tmp/zylog_fifo3" "$RUNROOT/tmp/zylog_fifo4"
bwrap \
  --bind "$RUNROOT" / \
  --chdir / \
  --dev /dev \
  "${proc_bind[@]}" \
  "${sys_bind[@]}" \
  "${dev_bind[@]}" \
  "${uam_bind[@]}" \
  --setenv PATH /usr/bin:/bin \
  /usr/bin/qemu-aarch64-static /usr/sbin/zylogd \
  >"$STATE_DIR/direct-zylogd.log" 2>&1 &
zylogd_pid=$!
sleep 2

python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" up >"$STATE_DIR/direct-ipc.log" 2>&1
python3 "$ROOT_DIR/tools/link_updown_socket_server.py" \
  --socket "$RUNROOT/tmp/link-updown-socket" \
  --log "$STATE_DIR/direct-link-updown.log" \
  >"$STATE_DIR/direct-link.stdout.log" 2>&1 &
link_pid=$!
trap 'kill "${zylogd_pid:-}" "${link_pid:-}" 2>/dev/null || true; python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true' EXIT

printf '%s' "$CMD_PAYLOAD" | \
  bwrap \
    --bind "$RUNROOT" / \
    --chdir / \
    --dev /dev \
    "${proc_bind[@]}" \
    "${sys_bind[@]}" \
    "${dev_bind[@]}" \
    "${uam_bind[@]}" \
    --setenv PATH /usr/bin:/bin \
    --setenv REQUEST_METHOD POST \
    --setenv CONTENT_LENGTH "$CONTENT_LENGTH" \
    --setenv HTTP_COOKIE 'authtok=testtoken' \
    --setenv CONTENT_TYPE 'application/x-www-form-urlencoded' \
    --setenv REMOTE_ADDR '127.0.0.1' \
    --setenv SCRIPT_NAME '/cgi-bin/zysh-cgi' \
    /usr/bin/qemu-aarch64-static -strace /usr/local/lighttpd/cgi-bin/zysh-cgi \
    >"$BODY_OUT" 2>"$TRACE_OUT" || true

echo "Trace: $TRACE_OUT"
echo "Body:  $BODY_OUT"
