#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"
source "$ROOT_DIR/tools/zyxel_console_pty.sh"

RUNROOT="$ROOT_DIR/runroot"
SRC_ROOT="$ROOT_DIR/710ABRM4C0_extracted/rootfs"
STATE_DIR="$ROOT_DIR/.lab-state"
WIRELESS_HAL_MODE="${ZYXEL_WIRELESS_HAL_MODE:-real}"
UAM_MODE="${ZYXEL_UAM_MODE:-fake}"
GATEKEEPER_MODE="${ZYXEL_GATEKEEPER_MODE:-off}"
UAM_LOCKOUT_MODE="${ZYXEL_UAM_LOCKOUT_MODE:-off}"
UAM_TRACE_MODE="${ZYXEL_UAM_TRACE_MODE:-off}"
UAM_USER_TYPE="${ZYXEL_UAM_USER_TYPE:-1}"
UAM_TOKEN="${ZYXEL_UAM_TOKEN:-testtoken}"
UAM_USERNAME="${ZYXEL_UAM_USERNAME:-}"
UAM2_USER_TYPE="${ZYXEL_UAM2_USER_TYPE:-$UAM_USER_TYPE}"
UAM2_TOKEN="${ZYXEL_UAM2_TOKEN:-$UAM_TOKEN}"
UAM2_USERNAME="${ZYXEL_UAM2_USERNAME:-$UAM_USERNAME}"
UAM_LOG="$STATE_DIR/uam-user-request.log"
UAM2_LOG="$STATE_DIR/uam-user-request2.log"
UAM_NOTIFY_LOG="$STATE_DIR/uam-user-notify.log"
UAMD_LOG="$STATE_DIR/uamd.log"
UAMD_STRACE_PREFIX="$STATE_DIR/uamd.strace"
GATEKEEPER_LOG="$STATE_DIR/gatekeeper-marker-clearer.log"
LIGHTTPD_LOG="$STATE_DIR/lighttpd.log"
ZYSHD_LOG="$STATE_DIR/zyshd_wd.log"
LINK_LOG="$STATE_DIR/link-updown-socket.log"
ZYLOGD_LOG="$STATE_DIR/zylogd.log"
WIRELESS_HAL_LOG="$STATE_DIR/wireless_hal.log"
WIRELESS_HAL_SHIM_LOG="$STATE_DIR/wireless_hal_shim.log"

usage() {
  cat <<'EOF'
Usage: tools/run_zyxel_lab.sh <prepare|start|promote-full|stop|status|health|rebuild> [--phase core|full]

prepare  Prepare runroot only.
start    Prepare runroot if needed, then start the requested lab phase.
promote-full  Starting from a healthy core lane, run only the web-lane steps with transition artifacts.
stop     Stop lab processes started by this script.
status   Show current lab process and socket state.
health   Verify that the requested lab phase is alive.
rebuild  Rebuild runroot and start the requested lab phase from scratch.
EOF
}

LAB_PHASE="full"

parse_phase_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)
        shift
        if [[ $# -eq 0 ]]; then
          echo "Missing value for --phase" >&2
          exit 1
        fi
        LAB_PHASE="$1"
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  case "$LAB_PHASE" in
    core|full)
      ;;
    *)
      echo "Unsupported phase: $LAB_PHASE" >&2
      exit 1
      ;;
  esac
}

seed_uam_lockout_ipc() {
  if [[ "$UAM_LOCKOUT_MODE" == "seed" ]]; then
    python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" up --include-uam-lockout >/dev/null
  fi
}

start_gatekeeper_helper() {
  drop_stale_pidfile "$STATE_DIR/gatekeeper.pid"
  case "$GATEKEEPER_MODE" in
    off)
      rm -f "$STATE_DIR/gatekeeper.pid"
      ;;
    marker-clear)
      if pid_is_live "$STATE_DIR/gatekeeper.pid"; then
        return
      fi
      nohup python3 "$ROOT_DIR/tools/gatekeeper_marker_clearer.py" \
        --tmp-dir "$RUNROOT/tmp" \
        --log "$GATEKEEPER_LOG" \
        >"$STATE_DIR/gatekeeper.stdout.log" 2>&1 &
      echo $! >"$STATE_DIR/gatekeeper.pid"
      ;;
    *)
      echo "Unsupported ZYXEL_GATEKEEPER_MODE: $GATEKEEPER_MODE" >&2
      exit 1
      ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

ensure_deps() {
  need_cmd python3
  need_cmd bwrap
  need_cmd qemu-aarch64-static
  need_cmd curl
  need_cmd ss
  if [[ "$UAM_TRACE_MODE" == "host-strace" ]]; then
    need_cmd strace
  fi
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

prepare_runroot() {
  local rebuild_flag=()
  if [[ "${1:-}" == "--rebuild" ]]; then
    rebuild_flag=(--rebuild)
  fi
  python3 "$ROOT_DIR/tools/prepare_zyxel_runroot.py" \
    --src "$SRC_ROOT" \
    --dst "$RUNROOT" \
    "${rebuild_flag[@]}"
}

pid_is_live() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

drop_stale_pidfile() {
  local pid_file="$1"
  if ! pid_is_live "$pid_file"; then
    rm -f "$pid_file"
  fi
}

unlink_path_if_present() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    rm -f "$path"
  fi
}

cleanup_runtime_paths() {
  rm -f \
    "$RUNROOT/var/run/lighttpd.pid" \
    "$RUNROOT/var/run/zylogd.pid" \
    "$RUNROOT/tmp/zylog_fifo1" \
    "$RUNROOT/tmp/zylog_fifo2" \
    "$RUNROOT/tmp/zylog_fifo3" \
    "$RUNROOT/tmp/zylog_fifo4" \
    "$RUNROOT"/tmp/zysh.client.* \
    "$RUNROOT"/tmp/zysh*.neglect \
    "$STATE_DIR"/uamd.strace*
  unlink_path_if_present "$RUNROOT/dev/user-request"
  unlink_path_if_present "$RUNROOT/dev/user-request2"
  unlink_path_if_present "$RUNROOT/dev/user-notify"
  unlink_path_if_present "$RUNROOT/tmp/link-updown-socket"
  unlink_path_if_present "$RUNROOT/tmp/wirelesshaldebug"
}

cleanup_dynamic_zysh_msg_queues() {
  command -v ipcs >/dev/null 2>&1 || return 0
  command -v ipcrm >/dev/null 2>&1 || return 0
  ipcs -q | awk '
    $1 ~ /^0x(6401|6601)[0-9a-f]+$/ {
      print $2
    }
  ' | xargs -r -n 1 ipcrm -q 2>/dev/null || true
}

zylogd_runtime_ready() {
  command -v ipcs >/dev/null 2>&1 || return 1
  ipcs -m -s | awk '
    $1 == "0x12340001" { sem_a=1 }
    $1 == "0x12340003" { sem_b=1 }
    $1 == "0x12340002" { shm_a=1 }
    $1 == "0x12340004" { shm_b=1 }
    END {
      if (sem_a && sem_b && shm_a && shm_b) {
        exit 0
      }
      exit 1
    }
  '
}

kill_orphan_qemu_guests() {
  local pids
  pids="$(
    ps -eo pid=,args= | awk '
      $0 ~ /\/usr\/bin\/qemu-aarch64-static .*\/usr\/bin\/zyshd(_wd)?$/ ||
      $0 ~ /\/usr\/libexec\/qemu-binfmt\/aarch64-binfmt-P .*\/bin\/zyshd( |$)/ ||
      $0 ~ /\/usr\/bin\/qemu-aarch64-static .*\/usr\/local\/lighttpd\/sbin\/lighttpd( |$)/ ||
      $0 ~ /\/usr\/libexec\/qemu-binfmt\/aarch64-binfmt-P .*\/usr\/local\/lighttpd\/sbin\/lighttpd( |$)/ ||
      $0 ~ /\/usr\/bin\/qemu-aarch64-static .*\/usr\/sbin\/zylogd$/ ||
      $0 ~ /\/usr\/libexec\/qemu-binfmt\/aarch64-binfmt-P .*\/usr\/sbin\/zylogd( |$)/ ||
      $0 ~ /\/usr\/bin\/qemu-aarch64-static .*\/usr\/local\/bin\/wireless_hal$/ ||
      $0 ~ /\/usr\/libexec\/qemu-binfmt\/aarch64-binfmt-P .*\/usr\/local\/bin\/wireless_hal( |$)/ ||
      $0 ~ /\/usr\/bin\/qemu-aarch64-static .*\/usr\/bin\/zysh -p 110( |$)/ ||
      $0 ~ /\/usr\/libexec\/qemu-binfmt\/aarch64-binfmt-P .*\/usr\/bin\/zysh zysh -p 110( |$)/ ||
      $0 ~ /\/usr\/libexec\/qemu-binfmt\/aarch64-binfmt-P .*\/bin\/sh sh -c zysh -p 110/ ||
      $0 ~ /\/usr\/libexec\/qemu-binfmt\/aarch64-binfmt-P .*\/usr\/bin\/grep grep zyshdata( |$)/ {
        print $1
      }
    '
  )"
  if [[ -n "$pids" ]]; then
    # Older launches can leave detached qemu children behind after the short-lived
    # bwrap launcher exits, so clean the real daemon processes explicitly.
    printf '%s\n' "$pids" | xargs -r kill 2>/dev/null || true
    sleep 0.2
    printf '%s\n' "$pids" | xargs -r kill -9 2>/dev/null || true
  fi
}

regenerate_portal_used_conf() {
  local service_conf="$RUNROOT/var/zyxel/service_conf"
  local portal_used="$service_conf/portal_used.conf"
  local include_path
  mkdir -p "$service_conf"
  : >"$portal_used"

  shopt -s nullglob
  for include_path in \
    "$service_conf"/captive_portal_*.conf \
    "$service_conf"/findme_*.conf \
    "$service_conf"/cdr_*.conf \
    "$service_conf"/ip_reputation_*.conf \
    "$service_conf"/dns_filter_*.conf \
    "$service_conf"/threat_mgmt_*.conf; do
    printf 'include "/var/zyxel/service_conf/%s"\n' "$(basename "$include_path")" >>"$portal_used"
  done
  shopt -u nullglob
}

run_local_zysh_p110() {
  local command_text="${1:-show running-config}"
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()
  build_vendor_binds proc_bind sys_bind dev_bind uam_bind "$RUNROOT"
  timeout 12s bwrap \
    --bind "$RUNROOT" / \
    --chdir / \
    --dev /dev \
    "${proc_bind[@]}" \
    "${sys_bind[@]}" \
    "${dev_bind[@]}" \
    "${uam_bind[@]}" \
    --setenv PATH /usr/bin:/bin \
    /usr/bin/qemu-aarch64-static /usr/bin/zysh -p 110 -e "$command_text"
}

run_local_zysh_p110_pty() {
  local command_text="${1:-show running-config}"
  local command_file="$STATE_DIR/zysh-ready.commands.txt"
  local transcript="$STATE_DIR/zysh-ready.transcript.txt"
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$command_text" "exit" "exit" >"$command_file"
  build_vendor_binds proc_bind sys_bind dev_bind uam_bind "$RUNROOT"

  timeout 20s python3 "$ROOT_DIR/tools/run_zysh_pty.py" \
    --commands-file "$command_file" \
    --transcript "$transcript" \
    --timeout-sec 20 \
    --startup-wait-sec 1.5 \
    --step-wait-sec 0.6 \
    --tail-wait-sec 1.5 \
    --send-eof \
    -- \
    bwrap \
      --bind "$RUNROOT" / \
      --chdir / \
      --dev /dev \
      "${proc_bind[@]}" \
      "${sys_bind[@]}" \
      "${dev_bind[@]}" \
      "${uam_bind[@]}" \
      --setenv PATH /usr/bin:/bin \
      /usr/bin/qemu-aarch64-static /usr/bin/zysh -p 110
}

zysh_ready_output_ok() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  grep -q "interface-name ge1 lan1" "$path"
}

probe_zysh_ready_once() {
  local transcript="$STATE_DIR/zysh-ready.transcript.txt"
  local ready_out="$STATE_DIR/zysh-ready.out"
  local ready_err="$STATE_DIR/zysh-ready.err"

  mkdir -p "$STATE_DIR"
  : >"$ready_err"

  if run_local_zysh_p110_pty "show running-config" >>"$ready_err" 2>&1; then
    if zysh_ready_output_ok "$transcript"; then
      return 0
    fi
  fi

  if run_local_zysh_p110 "show running-config" >"$ready_out" 2>>"$ready_err"; then
    if zysh_ready_output_ok "$ready_out"; then
      cat "$ready_out" >>"$transcript"
      return 0
    fi
  fi

  return 1
}

wait_for_zysh_ready() {
  local attempts="${1:-4}"
  local i
  local ready_out="$STATE_DIR/zysh-ready.transcript.txt"
  local ready_err="$STATE_DIR/zysh-ready.err"

  mkdir -p "$STATE_DIR"
  for ((i=0; i<attempts; i++)); do
    if probe_zysh_ready_once; then
      if zysh_ready_output_ok "$ready_out"; then
        return 0
      fi
    fi
    sleep 0.5
  done

  echo "Timed out waiting for zysh -p 110 readiness" >&2
  sed -n '1,80p' "$ready_out" >&2 || true
  sed -n '1,80p' "$ready_err" >&2 || true
  return 1
}

wait_for_port() {
  local port="$1"
  local attempts="${2:-50}"
  local i
  for ((i=0; i<attempts; i++)); do
    if ss -ltn "( sport = :$port )" | tail -n +2 | grep -q .; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for TCP port: $port" >&2
  return 1
}

timestamp_now() {
  date +%Y%m%d_%H%M%S
}

copy_state_logs() {
  local artifact_dir="$1"
  local log_dir="$artifact_dir/state_logs"
  local path
  mkdir -p "$log_dir"
  shopt -s nullglob
  for path in "$STATE_DIR"/*.log "$STATE_DIR"/*.txt "$STATE_DIR"/*.out "$STATE_DIR"/*.err; do
    cp -f "$path" "$log_dir"/
  done
  shopt -u nullglob
}

capture_lab_snapshot() {
  local output_path="$1"
  local pid_file

  mkdir -p "$(dirname "$output_path")"
  {
    echo "date: $(date --iso-8601=seconds)"
    echo "phase: $LAB_PHASE"
    echo "wireless_hal_mode: $WIRELESS_HAL_MODE"
    echo "uam_mode: $UAM_MODE"
    echo "gatekeeper_mode: $GATEKEEPER_MODE"
    echo "uam_lockout_mode: $UAM_LOCKOUT_MODE"
    echo "uam_trace_mode: $UAM_TRACE_MODE"
    echo "--- pidfiles ---"
    for pid_file in \
      "$STATE_DIR/lighttpd.pid" \
      "$STATE_DIR/zyshd.pid" \
      "$STATE_DIR/zylogd.pid" \
      "$STATE_DIR/wireless_hal.pid" \
      "$STATE_DIR/gatekeeper.pid" \
      "$STATE_DIR/uam.pid" \
      "$STATE_DIR/uam2.pid" \
      "$STATE_DIR/uam_notify.pid" \
      "$STATE_DIR/link_socket.pid"; do
      if [[ -f "$pid_file" ]]; then
        local pid
        pid="$(cat "$pid_file")"
        if kill -0 "$pid" 2>/dev/null; then
          echo "$(basename "$pid_file" .pid): running (pid $pid)"
        else
          echo "$(basename "$pid_file" .pid): stale pid $pid"
        fi
      else
        echo "$(basename "$pid_file" .pid): stopped"
      fi
    done
    echo "--- sockets ---"
    ls -l \
      "$RUNROOT/dev/user-request" \
      "$RUNROOT/dev/user-request2" \
      "$RUNROOT/dev/user-notify" \
      "$RUNROOT/tmp/link-updown-socket" \
      "$RUNROOT/tmp/wirelesshaldebug" 2>/dev/null || true
    echo "--- port 8080 ---"
    ss -ltnp | rg ':8080' || true
    echo "--- key processes ---"
    ps -eo pid,ppid,stat,args | rg '/usr/sbin/zylogd|/usr/bin/zyshd_wd|/usr/bin/uamd|/usr/local/bin/wireless_hal|/usr/local/lighttpd/sbin/lighttpd|uam_unix_server|uam_notify_server|gatekeeper_marker_clearer' || true
  } >"$output_path"
}

start_uam() {
  local uam_user_args=()
  local uam2_user_args=()
  mkdir -p "$STATE_DIR"
  if [[ ! -d "$RUNROOT/dev" ]]; then
    echo "Runroot /dev missing; re-run prepare." >&2
    exit 1
  fi
  rm -f "$UAMD_STRACE_PREFIX"*

  drop_stale_pidfile "$STATE_DIR/uam.pid"
  unlink_path_if_present "$RUNROOT/dev/user-request"
  unlink_path_if_present "$RUNROOT/dev/user-notify"
  case "$UAM_MODE" in
    fake)
      if [[ -n "$UAM_USERNAME" ]]; then
        uam_user_args=(--username "$UAM_USERNAME")
      fi
      if pid_is_live "$STATE_DIR/uam.pid"; then
        :
      else
        nohup python3 "$ROOT_DIR/tools/uam_unix_server.py" \
          --socket "$RUNROOT/dev/user-request" \
          --user-type "$UAM_USER_TYPE" \
          --token "$UAM_TOKEN" \
          --ipv4 127.0.0.1 \
          "${uam_user_args[@]}" \
          --log "$UAM_LOG" \
          >"$STATE_DIR/uam.stdout.log" 2>&1 &
        echo $! >"$STATE_DIR/uam.pid"
      fi
      wait_for_socket "$RUNROOT/dev/user-request"

      drop_stale_pidfile "$STATE_DIR/uam_notify.pid"
      if pid_is_live "$STATE_DIR/uam_notify.pid"; then
        :
      else
        nohup python3 "$ROOT_DIR/tools/uam_notify_server.py" \
          --socket "$RUNROOT/dev/user-notify" \
          --log "$UAM_NOTIFY_LOG" \
          >"$STATE_DIR/uam_notify.stdout.log" 2>&1 &
        echo $! >"$STATE_DIR/uam_notify.pid"
      fi
      wait_for_socket "$RUNROOT/dev/user-notify"
      ;;
    vendor-mixed)
      python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true
      seed_uam_lockout_ipc
      rm -f "$RUNROOT/var/run/uamd.pid"
      if pid_is_live "$STATE_DIR/uam.pid"; then
        :
      else
        start_uamd_guest "$UAMD_LOG" /usr/bin/uamd >"$STATE_DIR/uam.pid"
        sleep 2
      fi
      wait_for_socket "$RUNROOT/dev/user-request"
      wait_for_socket "$RUNROOT/dev/user-notify"
      rm -f "$STATE_DIR/uam_notify.pid"
      ;;
    vendor-debug)
      python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true
      seed_uam_lockout_ipc
      rm -f "$RUNROOT/var/run/uamd.pid"
      if pid_is_live "$STATE_DIR/uam.pid"; then
        :
      else
        start_uamd_guest "$UAMD_LOG" /usr/bin/uamd -d >"$STATE_DIR/uam.pid"
        sleep 2
      fi
      wait_for_socket "$RUNROOT/dev/user-request"
      wait_for_socket "$RUNROOT/dev/user-notify"
      rm -f "$STATE_DIR/uam_notify.pid"
      ;;
    *)
      echo "Unsupported ZYXEL_UAM_MODE: $UAM_MODE" >&2
      exit 1
      ;;
  esac

  drop_stale_pidfile "$STATE_DIR/uam2.pid"
  unlink_path_if_present "$RUNROOT/dev/user-request2"
  if [[ -n "$UAM2_USERNAME" ]]; then
    uam2_user_args=(--username "$UAM2_USERNAME")
  fi
  if pid_is_live "$STATE_DIR/uam2.pid"; then
    :
  else
    nohup python3 "$ROOT_DIR/tools/uam_unix_server.py" \
      --socket "$RUNROOT/dev/user-request2" \
      --user-type "$UAM2_USER_TYPE" \
      --token "$UAM2_TOKEN" \
      --ipv4 127.0.0.1 \
      "${uam2_user_args[@]}" \
      --log "$UAM2_LOG" \
      >"$STATE_DIR/uam2.stdout.log" 2>&1 &
    echo $! >"$STATE_DIR/uam2.pid"
  fi
  wait_for_socket "$RUNROOT/dev/user-request2"
}

start_bwrap_guest() {
  local _name="$1"
  local logfile="$2"
  shift 2
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()
  build_vendor_binds proc_bind sys_bind dev_bind uam_bind "$RUNROOT"
  nohup bwrap \
    --bind "$RUNROOT" / \
    --chdir / \
    --dev /dev \
    "${proc_bind[@]}" \
    "${sys_bind[@]}" \
    "${dev_bind[@]}" \
    "${uam_bind[@]}" \
    --setenv PATH /usr/bin:/bin \
    /usr/bin/qemu-aarch64-static "$@" >"$logfile" 2>&1 &
  echo $!
}

start_bwrap_shared_dev_guest() {
  local _name="$1"
  local logfile="$2"
  shift 2
  local proc_bind=()
  local sys_bind=()
  build_proc_binds proc_bind "$RUNROOT"
  build_sys_binds sys_bind "$RUNROOT"
  nohup bwrap \
    --bind "$RUNROOT" / \
    --chdir / \
    --bind "$RUNROOT/dev" /dev \
    "${proc_bind[@]}" \
    "${sys_bind[@]}" \
    --setenv PATH /usr/bin:/bin \
    /usr/bin/qemu-aarch64-static "$@" >"$logfile" 2>&1 &
  echo $!
}

start_bwrap_shared_dev_guest_traced() {
  local _name="$1"
  local logfile="$2"
  local trace_prefix="$3"
  local trace_flavor="${4:-normal}"
  shift 4
  local proc_bind=()
  local sys_bind=()
  local trace_args=()
  build_proc_binds proc_bind "$RUNROOT"
  build_sys_binds sys_bind "$RUNROOT"

  case "$trace_flavor" in
    normal)
      trace_args=(
        -ff
        -tt
        -yy
        -s 256
        -o "$trace_prefix"
        -e trace=shmget,shmat,shmdt,semget,semop,semctl,write,writev,connect,openat,access,nanosleep
      )
      ;;
    deep)
      trace_args=(
        -ff
        -ttt
        -yy
        -k
        -s 256
        -o "$trace_prefix"
        -e trace=%ipc,%process,%desc,%network,write,writev,read,recvfrom,sendto,recvmsg,sendmsg,clock_nanosleep,nanosleep,alarm,setitimer,poll,ppoll,select,pselect6,futex
      )
      ;;
    *)
      echo "Unsupported trace flavor: $trace_flavor" >&2
      exit 1
      ;;
  esac

  nohup strace \
    "${trace_args[@]}" \
    bwrap \
      --bind "$RUNROOT" / \
      --chdir / \
      --bind "$RUNROOT/dev" /dev \
      "${proc_bind[@]}" \
      "${sys_bind[@]}" \
      --setenv PATH /usr/bin:/bin \
      /usr/bin/qemu-aarch64-static "$@" >"$logfile" 2>&1 &
  echo $!
}

start_uamd_guest() {
  local logfile="$1"
  shift
  case "$UAM_TRACE_MODE" in
    off)
      start_bwrap_shared_dev_guest uamd "$logfile" "$@"
      ;;
    host-strace)
      start_bwrap_shared_dev_guest_traced uamd "$logfile" "$UAMD_STRACE_PREFIX" normal "$@"
      ;;
    host-strace-deep)
      start_bwrap_shared_dev_guest_traced uamd "$logfile" "$UAMD_STRACE_PREFIX" deep "$@"
      ;;
    *)
      echo "Unsupported ZYXEL_UAM_TRACE_MODE: $UAM_TRACE_MODE" >&2
      exit 1
      ;;
  esac
}

start_zylogd() {
  mkdir -p "$STATE_DIR"
  drop_stale_pidfile "$STATE_DIR/zylogd.pid"
  rm -f "$RUNROOT/var/run/zylogd.pid"
  rm -f "$RUNROOT/tmp/zylog_fifo1" "$RUNROOT/tmp/zylog_fifo2" "$RUNROOT/tmp/zylog_fifo3" "$RUNROOT/tmp/zylog_fifo4"
  python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true

  if pid_is_live "$STATE_DIR/zylogd.pid"; then
    return
  fi

  start_bwrap_guest zylogd "$ZYLOGD_LOG" /usr/sbin/zylogd >"$STATE_DIR/zylogd.pid"
  sleep 2
}

start_link_socket() {
  drop_stale_pidfile "$STATE_DIR/link_socket.pid"
  unlink_path_if_present "$RUNROOT/tmp/link-updown-socket"
  if pid_is_live "$STATE_DIR/link_socket.pid"; then
    return
  fi
  nohup python3 "$ROOT_DIR/tools/link_updown_socket_server.py" \
    --socket "$RUNROOT/tmp/link-updown-socket" \
    --log "$LINK_LOG" \
    >"$STATE_DIR/link_socket.stdout.log" 2>&1 &
  echo $! >"$STATE_DIR/link_socket.pid"
  wait_for_socket "$RUNROOT/tmp/link-updown-socket"
}

start_wireless_hal() {
  mkdir -p "$STATE_DIR"
  drop_stale_pidfile "$STATE_DIR/wireless_hal.pid"
  unlink_path_if_present "$RUNROOT/tmp/wirelesshaldebug"
  if pid_is_live "$STATE_DIR/wireless_hal.pid"; then
    return
  fi

  case "$WIRELESS_HAL_MODE" in
    off)
      return
      ;;
    real)
      start_bwrap_guest wireless_hal "$WIRELESS_HAL_LOG" /usr/local/bin/wireless_hal >"$STATE_DIR/wireless_hal.pid"
      ;;
    shim)
      nohup python3 "$ROOT_DIR/tools/wireless_hal_debug_server.py" \
        --socket "$RUNROOT/tmp/wirelesshaldebug" \
        --radio 0 \
        --vap 1 \
        --log "$WIRELESS_HAL_SHIM_LOG" \
        >"$STATE_DIR/wireless_hal.stdout.log" 2>&1 &
      echo $! >"$STATE_DIR/wireless_hal.pid"
      ;;
    *)
      echo "Unsupported ZYXEL_WIRELESS_HAL_MODE: $WIRELESS_HAL_MODE" >&2
      exit 1
      ;;
  esac
  wait_for_socket "$RUNROOT/tmp/wirelesshaldebug"
}

start_lighttpd() {
  drop_stale_pidfile "$STATE_DIR/lighttpd.pid"
  if pid_is_live "$STATE_DIR/lighttpd.pid"; then
    return 0
  fi
  start_bwrap_guest lighttpd "$LIGHTTPD_LOG" /usr/local/lighttpd/sbin/lighttpd -D -f /usr/local/lighttpd/conf/lighttpd-lab.conf >"$STATE_DIR/lighttpd.pid"
  wait_for_port 8080
}

start_web_lane_services() {
  regenerate_portal_used_conf
  start_wireless_hal
  start_gatekeeper_helper
  start_lighttpd
}

seed_ipc() {
  python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" up
}

start_services() {
  local phase="${1:-full}"
  mkdir -p "$STATE_DIR"
  kill_orphan_qemu_guests
  zyxel_start_console_pty "$ROOT_DIR" "$STATE_DIR"
  start_zylogd
  seed_uam_lockout_ipc
  drop_stale_pidfile "$STATE_DIR/zyshd.pid"
  if pid_is_live "$STATE_DIR/zyshd.pid"; then
    :
  else
    seed_ipc
    start_link_socket
    start_bwrap_guest zyshd "$ZYSHD_LOG" /usr/bin/zyshd_wd >"$STATE_DIR/zyshd.pid"
    sleep 2
  fi
  wait_for_zysh_ready
  if [[ "$phase" == "core" ]]; then
    return 0
  fi
  start_web_lane_services
}

promote_full_phase() {
  local stamp
  local artifact_dir
  local summary_path
  local core_health_ok="no"
  local full_health_ok="no"
  local failed_step=""
  local step_name
  local -a step_names=(
    regenerate_portal_used_conf
    start_wireless_hal
    start_gatekeeper_helper
    start_lighttpd
  )

  stamp="$(timestamp_now)"
  artifact_dir="$ROOT_DIR/live_artifacts/full_transition_${stamp}"
  summary_path="$artifact_dir/summary.txt"
  mkdir -p "$artifact_dir"

  LAB_PHASE="core"
  capture_lab_snapshot "$artifact_dir/before.txt"
  if health_check core >"$artifact_dir/core_health.txt" 2>&1; then
    core_health_ok="yes"
  else
    capture_lab_snapshot "$artifact_dir/after_core_health_failure.txt"
    copy_state_logs "$artifact_dir"
    {
      echo "Date: $(date --iso-8601=seconds)"
      echo
      echo "Goal: promote a passing core lane into the full web lane with step-level artifacts."
      echo
      echo "Result:"
      echo
      echo "- core health failed before any web-lane promotion."
      echo "- core_health_ok=$core_health_ok"
      echo "- full_health_ok=$full_health_ok"
      echo "- artifact_dir=$artifact_dir"
    } >"$summary_path"
    return 1
  fi

  for step_name in "${step_names[@]}"; do
    if "$step_name" >"$artifact_dir/${step_name}.stdout.txt" 2>"$artifact_dir/${step_name}.stderr.txt"; then
      capture_lab_snapshot "$artifact_dir/after_${step_name}.txt"
    else
      failed_step="$step_name"
      capture_lab_snapshot "$artifact_dir/after_${step_name}.txt"
      copy_state_logs "$artifact_dir"
      {
        echo "Date: $(date --iso-8601=seconds)"
        echo
        echo "Goal: promote a passing core lane into the full web lane with step-level artifacts."
        echo
        echo "Result:"
        echo
        echo "- core health passed before promotion."
        echo "- promotion failed during step: $failed_step"
        echo "- core_health_ok=$core_health_ok"
        echo "- full_health_ok=$full_health_ok"
        echo "- artifact_dir=$artifact_dir"
      } >"$summary_path"
      return 1
    fi
  done

  LAB_PHASE="full"
  capture_lab_snapshot "$artifact_dir/after.txt"
  if health_check full >"$artifact_dir/full_health.txt" 2>&1; then
    full_health_ok="yes"
  fi
  copy_state_logs "$artifact_dir"
  {
    echo "Date: $(date --iso-8601=seconds)"
    echo
    echo "Goal: promote a passing core lane into the full web lane with step-level artifacts."
    echo
    echo "Results:"
    echo
    echo "- core_health_ok=$core_health_ok"
    echo "- full_health_ok=$full_health_ok"
    echo "- failed_step=${failed_step:-none}"
    echo "- artifact_dir=$artifact_dir"
    echo "- before snapshot: before.txt"
    echo "- final snapshot: after.txt"
  } >"$summary_path"

  if [[ "$full_health_ok" != "yes" ]]; then
    return 1
  fi
}

stop_lab() {
  local pid_file
  for pid_file in "$STATE_DIR/lighttpd.pid" "$STATE_DIR/zyshd.pid" "$STATE_DIR/zylogd.pid" "$STATE_DIR/wireless_hal.pid" "$STATE_DIR/gatekeeper.pid" "$STATE_DIR/uam.pid" "$STATE_DIR/uam2.pid" "$STATE_DIR/uam_notify.pid" "$STATE_DIR/link_socket.pid"; do
    if [[ -f "$pid_file" ]]; then
      kill "$(cat "$pid_file")" 2>/dev/null || true
      rm -f "$pid_file"
    fi
  done
  kill_orphan_qemu_guests
  cleanup_runtime_paths
  zyxel_stop_console_pty "$STATE_DIR"
  python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true
  cleanup_dynamic_zysh_msg_queues
}

show_status() {
  echo "State dir: $STATE_DIR"
  echo "phase: $LAB_PHASE"
  echo "wireless_hal_mode: $WIRELESS_HAL_MODE"
  echo "uam_mode: $UAM_MODE"
  echo "gatekeeper_mode: $GATEKEEPER_MODE"
  echo "uam_lockout_mode: $UAM_LOCKOUT_MODE"
  echo "uam_trace_mode: $UAM_TRACE_MODE"
  if [[ "$UAM_MODE" == "fake" ]]; then
    echo "uam_user_type: $UAM_USER_TYPE"
    echo "uam_token: $UAM_TOKEN"
    echo "uam2_user_type: $UAM2_USER_TYPE"
    echo "uam2_token: $UAM2_TOKEN"
  fi
  for pid_file in "$STATE_DIR/lighttpd.pid" "$STATE_DIR/zyshd.pid" "$STATE_DIR/zylogd.pid" "$STATE_DIR/wireless_hal.pid" "$STATE_DIR/gatekeeper.pid" "$STATE_DIR/uam.pid" "$STATE_DIR/uam2.pid" "$STATE_DIR/uam_notify.pid"; do
    if [[ -f "$pid_file" ]]; then
      local pid
      pid="$(cat "$pid_file")"
      if kill -0 "$pid" 2>/dev/null; then
        echo "$(basename "$pid_file" .pid): running (pid $pid)"
      else
        echo "$(basename "$pid_file" .pid): stale pid $pid"
      fi
    else
      echo "$(basename "$pid_file" .pid): stopped"
    fi
  done
  echo "--- sockets ---"
  ls -l "$RUNROOT/dev/user-request" "$RUNROOT/dev/user-request2" "$RUNROOT/dev/user-notify" "$RUNROOT/tmp/link-updown-socket" "$RUNROOT/tmp/wirelesshaldebug" 2>/dev/null || true
  echo "--- uamd trace files ---"
  ls -1 "$UAMD_STRACE_PREFIX"* 2>/dev/null || true
  echo "--- port 8080 ---"
  ss -ltnp | rg ':8080' || true
}

health_check() {
  local phase="${1:-full}"
  local ok=0
  if ! pid_is_live "$STATE_DIR/uam.pid"; then
    echo "health: uam is not running" >&2
    ok=1
  fi
  if ! pid_is_live "$STATE_DIR/uam2.pid"; then
    echo "health: uam2 is not running" >&2
    ok=1
  fi
  if [[ "$UAM_MODE" == "fake" ]] && ! pid_is_live "$STATE_DIR/uam_notify.pid"; then
    echo "health: uam_notify is not running" >&2
    ok=1
  fi
  if ! pid_is_live "$STATE_DIR/zyshd.pid"; then
    echo "health: zyshd is not running" >&2
    ok=1
  fi
  if ! pid_is_live "$STATE_DIR/zylogd.pid"; then
    if ! zylogd_runtime_ready; then
      echo "health: zylogd runtime is not ready" >&2
      ok=1
    fi
  fi
  [[ -S "$RUNROOT/dev/user-request" ]] || { echo "health: missing $RUNROOT/dev/user-request" >&2; ok=1; }
  [[ -S "$RUNROOT/dev/user-request2" ]] || { echo "health: missing $RUNROOT/dev/user-request2" >&2; ok=1; }
  [[ -S "$RUNROOT/dev/user-notify" ]] || { echo "health: missing $RUNROOT/dev/user-notify" >&2; ok=1; }
  [[ -S "$RUNROOT/tmp/link-updown-socket" ]] || { echo "health: missing $RUNROOT/tmp/link-updown-socket" >&2; ok=1; }
  if ! probe_zysh_ready_once; then
    echo "health: zysh -p 110 readiness probe failed" >&2
    ok=1
  fi

  if [[ "$phase" == "core" ]]; then
    return "$ok"
  fi

  if [[ "$WIRELESS_HAL_MODE" != "off" ]]; then
    if ! pid_is_live "$STATE_DIR/wireless_hal.pid"; then
      echo "health: wireless_hal is not running" >&2
      ok=1
    fi
    [[ -S "$RUNROOT/tmp/wirelesshaldebug" ]] || { echo "health: missing $RUNROOT/tmp/wirelesshaldebug" >&2; ok=1; }
  fi
  if [[ "$GATEKEEPER_MODE" == "marker-clear" ]] && ! pid_is_live "$STATE_DIR/gatekeeper.pid"; then
    echo "health: gatekeeper marker clearer is not running" >&2
    ok=1
  fi
  if ! ss -ltn "( sport = :8080 )" | tail -n +2 | grep -q .; then
    echo "health: nothing is listening on 8080" >&2
    ok=1
  fi
  local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/ || true)"
  if [[ "$http_code" == "000" || -z "$http_code" ]]; then
    echo "health: curl failed to reach http://127.0.0.1:8080/" >&2
    ok=1
  else
    echo "health: lighttpd responded with HTTP $http_code"
  fi
  return "$ok"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  prepare)
    parse_phase_args "$@"
    ensure_deps
    prepare_runroot
    ;;
  rebuild)
    parse_phase_args "$@"
    ensure_deps
    stop_lab
    prepare_runroot --rebuild
    start_uam
    start_services "$LAB_PHASE"
    show_status
    health_check "$LAB_PHASE"
    ;;
  start)
    parse_phase_args "$@"
    ensure_deps
    [[ -d "$RUNROOT" ]] || prepare_runroot
    start_uam
    start_services "$LAB_PHASE"
    show_status
    health_check "$LAB_PHASE"
    ;;
  promote-full)
    if [[ $# -gt 0 ]]; then
      echo "promote-full does not accept phase arguments" >&2
      exit 1
    fi
    ensure_deps
    [[ -d "$RUNROOT" ]] || prepare_runroot
    promote_full_phase
    show_status
    health_check full
    ;;
  stop)
    parse_phase_args "$@"
    stop_lab
    show_status
    ;;
  status)
    parse_phase_args "$@"
    show_status
    ;;
  health)
    parse_phase_args "$@"
    ensure_deps
    health_check "$LAB_PHASE"
    ;;
  *)
    usage
    exit 1
    ;;
esac
