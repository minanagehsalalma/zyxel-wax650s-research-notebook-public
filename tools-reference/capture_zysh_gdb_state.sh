#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"

RUNROOT="$ROOT_DIR/runroot"
ART_DIR="$ROOT_DIR/live_artifacts"
STATE_DIR="$ROOT_DIR/.lab-state"
MODE="${1:-direct_x_admin}"
LABEL="${2:-manual}"
PORT="${3:-2345}"

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

cleanup() {
  kill "${cmd_pid:-}" 2>/dev/null || true
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$ART_DIR" "$STATE_DIR"

python3 "$ROOT_DIR/tools/prepare_zyxel_runroot.py" \
  --src "$ROOT_DIR/710ABRM4C0_extracted/rootfs" \
  --dst "$RUNROOT" >/dev/null

"$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
"$ROOT_DIR/tools/run_zyxel_lab.sh" start >/dev/null
rebuild_dev_binds

GDB_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}.txt"
SUMMARY_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}_summary.txt"
STDOUT_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}.stdout.txt"
STDERR_LOG="$ART_DIR/zysh_gdb_${MODE}_${LABEL}.stderr.txt"
CMD_FILE="$STATE_DIR/zysh_gdb_${MODE}_${LABEL}.gdb"
EXECUTER_PRIV_ADDR="0x0d052a8"
EXECUTER_RETVAL_ADDR="0x0d052b0"
ZYSH_CLI_PRIV_ADDR="0x0dc5f00"
ZYSH_CLI_MODE_ADDR="0x0dc5f94"

rm -f "$GDB_LOG" "$SUMMARY_LOG" "$STDOUT_LOG" "$STDERR_LOG" "$CMD_FILE"

case "$MODE" in
  direct_x_admin)
    stdin_payload=$'enable\nconfigure terminal\nshow running-config\t|js 0\nwrite\n'
    env_args=(
      --setenv SERVICE http/https
      --setenv USER admin
      --setenv ADDR 127.0.0.1
      --setenv UNIQUE admin0
    )
    zysh_args=(-x)
    ;;
  direct_x_p110_guest)
    stdin_payload=$'show running-config\n'
    env_args=(
      --setenv SERVICE http/https
      --setenv USER guest
      --setenv ADDR 127.0.0.1
      --setenv UNIQUE testtoken
    )
    zysh_args=(-p 110 -x)
    ;;
  local_p110)
    stdin_payload=""
    env_args=()
    zysh_args=(-p 110 -e "show running-config")
    ;;
  *)
    echo "Usage: $0 [direct_x_admin|direct_x_p110_guest|local_p110] [label] [port]" >&2
    exit 1
    ;;
esac

cat >"$CMD_FILE" <<EOF
set pagination off
set confirm off
set architecture aarch64
file $RUNROOT/usr/bin/zysh
target remote :$PORT
handle SIGPIPE nostop noprint pass
handle SIGUSR1 nostop noprint pass
set breakpoint pending on
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

if [[ "$MODE" == "local_p110" ]]; then
  timeout 20s \
    bwrap \
      --bind "$RUNROOT" / \
      --chdir / \
      --dev /dev \
      "${proc_binds[@]}" \
      "${sys_binds[@]}" \
      "${dev_binds[@]}" \
      --setenv PATH /usr/bin:/bin \
      /usr/bin/qemu-aarch64-static -g "$PORT" /usr/bin/zysh "${zysh_args[@]}" \
      >"$STDOUT_LOG" 2>"$STDERR_LOG" &
  cmd_pid=$!
else
  printf '%s' "$stdin_payload" | \
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
        "${env_args[@]}" \
        /usr/bin/qemu-aarch64-static -g "$PORT" /usr/bin/zysh "${zysh_args[@]}" \
        >"$STDOUT_LOG" 2>"$STDERR_LOG" &
  cmd_pid=$!
fi

wait_for_port "$PORT"
gdb-multiarch --batch -x "$CMD_FILE" >"$GDB_LOG" 2>&1 || true
wait "$cmd_pid" || true

{
  printf 'Mode: %s\n' "$MODE"
  printf 'Label: %s\n' "$LABEL"
  printf 'Port: %s\n' "$PORT"
  printf '\n=== GDB events ===\n'
  grep -E '^(===|executer_privilege_addr=|executer_retval_addr=|zysh_cli_privilege_addr=|zysh_cli_mode_addr=|pc=|message_ptr=|0x0d052a8:|0x0d052b0:|0x0dc5f00:|0x0dc5f94:|0x[0-9a-f]+: \"% )' "$GDB_LOG" || true
  printf '\n=== stdout ===\n'
  sed -n '1,80p' "$STDOUT_LOG" || true
  printf '\n=== stderr ===\n'
  sed -n '1,80p' "$STDERR_LOG" || true
} >"$SUMMARY_LOG"

printf 'GDB log: %s\n' "$GDB_LOG"
printf 'Summary: %s\n' "$SUMMARY_LOG"
