#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"

RUNROOT="$ROOT_DIR/runroot"
ART_DIR="$ROOT_DIR/live_artifacts"
STATE_DIR="$ROOT_DIR/.lab-state"
MODE="${1:-cgi_guest}"
LABEL="${2:-manual}"
PORT="${3:-2360}"

command -v bwrap >/dev/null 2>&1
command -v qemu-aarch64-static >/dev/null 2>&1
command -v gdb-multiarch >/dev/null 2>&1
command -v ss >/dev/null 2>&1
command -v timeout >/dev/null 2>&1
command -v python3 >/dev/null 2>&1

proc_binds=()
sys_binds=()
dev_binds=()
uam_binds=()

rebuild_dev_binds() {
  build_vendor_binds proc_binds sys_binds dev_binds uam_binds "$RUNROOT"
}

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

wait_for_port() {
  local port="$1"
  local attempts="${2:-100}"
  local i
  for ((i=0; i<attempts; i++)); do
    if ss -ltn "( sport = :$port )" | tail -n +2 | grep -q .; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for gdbstub port $port" >&2
  return 1
}

cleanup_bg() {
  kill "${cgi_pid:-}" "${zylogd_pid:-}" "${link_pid:-}" "${uam1_pid:-}" "${uam2_pid:-}" 2>/dev/null || true
  python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true
}

cleanup() {
  cleanup_bg
}
trap cleanup EXIT

mkdir -p "$ART_DIR" "$STATE_DIR"

python3 "$ROOT_DIR/tools/prepare_zyxel_runroot.py" \
  --src "$ROOT_DIR/710ABRM4C0_extracted/rootfs" \
  --dst "$RUNROOT" >/dev/null

case "$MODE" in
  cgi_guest)
    user_type=1
    token=testtoken
    user_label=guest
    ;;
  cgi_admin)
    user_type=0
    token=admin0
    user_label=admin
    ;;
  *)
    echo "Usage: $0 [cgi_guest|cgi_admin] [label] [port]" >&2
    exit 1
    ;;
esac

GDB_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}.txt"
SUMMARY_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}_summary.txt"
BODY_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}.body.txt"
STDERR_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}.stderr.txt"
CMD_FILE="$STATE_DIR/zysh_gdb_${MODE}_${LABEL}.gdb"
UAM1_STDOUT="$STATE_DIR/${MODE}_${LABEL}_uam1.stdout.log"
UAM2_STDOUT="$STATE_DIR/${MODE}_${LABEL}_uam2.stdout.log"
EXECUTER_PRIV_ADDR="0x0d052a8"
EXECUTER_RETVAL_ADDR="0x0d052b0"
ZYSH_CLI_PRIV_ADDR="0x0dc5f00"
ZYSH_CLI_MODE_ADDR="0x0dc5f94"
CMD_PAYLOAD='cmd=show+running-config'
CONTENT_LENGTH="${#CMD_PAYLOAD}"

rm -f "$GDB_LOG" "$SUMMARY_LOG" "$BODY_LOG" "$STDERR_LOG" "$CMD_FILE"

cat >"$CMD_FILE" <<EOF
set pagination off
set confirm off
set architecture aarch64
file $RUNROOT/usr/bin/zysh
target remote :$PORT
handle SIGPIPE nostop noprint pass
handle SIGUSR1 nostop noprint pass
set breakpoint pending on
break *0x4079d4
commands
  silent
  printf "=== zysh_entry_4079d4 ===\n"
  printf "pc=0x%lx lr=0x%lx sp=0x%lx\n", \$pc, \$lr, \$sp
  x/6i \$pc
  continue
end
break *0x405760
commands
  silent
  printf "=== fprintf_plt ===\n"
  printf "pc=0x%lx lr=0x%lx sp=0x%lx\n", \$pc, \$lr, \$sp
  printf "executer_privilege_addr=$EXECUTER_PRIV_ADDR\n"
  x/wx $EXECUTER_PRIV_ADDR
  printf "executer_retval_addr=$EXECUTER_RETVAL_ADDR\n"
  x/wx $EXECUTER_RETVAL_ADDR
  printf "zysh_cli_privilege_addr=$ZYSH_CLI_PRIV_ADDR\n"
  x/wx $ZYSH_CLI_PRIV_ADDR
  printf "zysh_cli_mode_addr=$ZYSH_CLI_MODE_ADDR\n"
  x/wx $ZYSH_CLI_MODE_ADDR
  printf "\nmessage_ptr=0x%lx\n", \$x1
  x/s \$x1
  x/6i \$lr
  continue
end
break null_executer
commands
  silent
  printf "=== null_executer ===\n"
  printf "pc=0x%lx lr=0x%lx sp=0x%lx\n", \$pc, \$lr, \$sp
  printf "executer_privilege_addr=$EXECUTER_PRIV_ADDR\n"
  x/wx $EXECUTER_PRIV_ADDR
  printf "executer_retval_addr=$EXECUTER_RETVAL_ADDR\n"
  x/wx $EXECUTER_RETVAL_ADDR
  printf "zysh_cli_privilege_addr=$ZYSH_CLI_PRIV_ADDR\n"
  x/wx $ZYSH_CLI_PRIV_ADDR
  printf "zysh_cli_mode_addr=$ZYSH_CLI_MODE_ADDR\n"
  x/wx $ZYSH_CLI_MODE_ADDR
  printf "\n"
  x/8i \$pc
  continue
end
break *0x4225c0
commands
  silent
  printf "=== guard_4225c0 ===\n"
  printf "pc=0x%lx lr=0x%lx sp=0x%lx\n", \$pc, \$lr, \$sp
  printf "executer_privilege_addr=$EXECUTER_PRIV_ADDR\n"
  x/wx $EXECUTER_PRIV_ADDR
  printf "zysh_cli_privilege_addr=$ZYSH_CLI_PRIV_ADDR\n"
  x/wx $ZYSH_CLI_PRIV_ADDR
  printf "zysh_cli_mode_addr=$ZYSH_CLI_MODE_ADDR\n"
  x/wx $ZYSH_CLI_MODE_ADDR
  printf "\n"
  info registers x0 x1 x19 x20 x21 x22 x23 x24 x25
  x/10i \$pc
  continue
end
break *0x4226dc
commands
  silent
  printf "=== deny_4226dc ===\n"
  printf "pc=0x%lx lr=0x%lx sp=0x%lx\n", \$pc, \$lr, \$sp
  printf "executer_privilege_addr=$EXECUTER_PRIV_ADDR\n"
  x/wx $EXECUTER_PRIV_ADDR
  printf "zysh_cli_privilege_addr=$ZYSH_CLI_PRIV_ADDR\n"
  x/wx $ZYSH_CLI_PRIV_ADDR
  printf "zysh_cli_mode_addr=$ZYSH_CLI_MODE_ADDR\n"
  x/wx $ZYSH_CLI_MODE_ADDR
  printf "\n"
  x/8i \$pc
  continue
end
continue
EOF

rm -f "$RUNROOT/dev/user-request" "$RUNROOT/dev/user-request2"
python3 "$ROOT_DIR/tools/uam_unix_server.py" \
  --socket "$RUNROOT/dev/user-request" \
  --user-type "$user_type" \
  --token "$token" \
  --ipv4 127.0.0.1 \
  --log "$STATE_DIR/${MODE}_${LABEL}_uam1.log" \
  >"$UAM1_STDOUT" 2>&1 &
uam1_pid=$!
python3 "$ROOT_DIR/tools/uam_unix_server.py" \
  --socket "$RUNROOT/dev/user-request2" \
  --user-type "$user_type" \
  --token "$token" \
  --ipv4 127.0.0.1 \
  --log "$STATE_DIR/${MODE}_${LABEL}_uam2.log" \
  >"$UAM2_STDOUT" 2>&1 &
uam2_pid=$!
wait_for_socket "$RUNROOT/dev/user-request"
wait_for_socket "$RUNROOT/dev/user-request2"
rebuild_dev_binds

python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true
rm -f "$RUNROOT/var/run/zylogd.pid"
rm -f "$RUNROOT/tmp/zylog_fifo1" "$RUNROOT/tmp/zylog_fifo2" "$RUNROOT/tmp/zylog_fifo3" "$RUNROOT/tmp/zylog_fifo4"
bwrap \
  --bind "$RUNROOT" / \
  --chdir / \
  --dev /dev \
  "${proc_binds[@]}" \
  "${sys_binds[@]}" \
  "${dev_binds[@]}" \
  "${uam_binds[@]}" \
  --setenv PATH /usr/bin:/bin \
  /usr/bin/qemu-aarch64-static /usr/sbin/zylogd \
  >"$STATE_DIR/${MODE}_${LABEL}_zylogd.log" 2>&1 &
zylogd_pid=$!
sleep 2

python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" up >"$STATE_DIR/${MODE}_${LABEL}_ipc.log" 2>&1
python3 "$ROOT_DIR/tools/link_updown_socket_server.py" \
  --socket "$RUNROOT/tmp/link-updown-socket" \
  --log "$STATE_DIR/${MODE}_${LABEL}_link-updown.log" \
  >"$STATE_DIR/${MODE}_${LABEL}_link-updown.stdout.log" 2>&1 &
link_pid=$!
wait_for_socket "$RUNROOT/tmp/link-updown-socket"

printf '%s' "$CMD_PAYLOAD" | \
  timeout 20s \
    bwrap \
      --bind "$RUNROOT" / \
      --chdir / \
      --dev /dev \
      "${proc_binds[@]}" \
      "${sys_binds[@]}" \
      "${dev_binds[@]}" \
      "${uam_binds[@]}" \
      --setenv PATH /usr/bin:/bin \
      --setenv REQUEST_METHOD POST \
      --setenv CONTENT_LENGTH "$CONTENT_LENGTH" \
      --setenv HTTP_COOKIE "authtok=$token" \
      --setenv CONTENT_TYPE 'application/x-www-form-urlencoded' \
      --setenv REMOTE_ADDR '127.0.0.1' \
      --setenv SCRIPT_NAME '/cgi-bin/zysh-cgi' \
      /usr/bin/qemu-aarch64-static -g "$PORT" /usr/local/lighttpd/cgi-bin/zysh-cgi \
      >"$BODY_LOG" 2>"$STDERR_LOG" &
cgi_pid=$!

wait_for_port "$PORT"
gdb-multiarch --batch -x "$CMD_FILE" >"$GDB_LOG" 2>&1 || true
wait "$cgi_pid" || true

{
  printf 'Mode: %s\n' "$MODE"
  printf 'Label: %s\n' "$LABEL"
  printf 'Port: %s\n' "$PORT"
  printf 'User label: %s\n' "$user_label"
  printf 'User type: %s\n' "$user_type"
  printf '\n=== GDB events ===\n'
  grep -E '^(===|executer_privilege_addr=|executer_retval_addr=|zysh_cli_privilege_addr=|zysh_cli_mode_addr=|pc=|message_ptr=|0x0d052a8:|0x0d052b0:|0x0dc5f00:|0x0dc5f94:|0x[0-9a-f]+: \"% )' "$GDB_LOG" || true
  printf '\n=== body ===\n'
  sed -n '1,120p' "$BODY_LOG" || true
  printf '\n=== stderr ===\n'
  sed -n '1,120p' "$STDERR_LOG" || true
} >"$SUMMARY_LOG"

printf 'GDB log: %s\n' "$GDB_LOG"
printf 'Summary: %s\n' "$SUMMARY_LOG"
