#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"
source "$ROOT_DIR/tools/zyxel_manual_core_lane.sh"

RUNROOT="$ROOT_DIR/runroot"
ART_DIR="$ROOT_DIR/live_artifacts"
STATE_DIR="$ROOT_DIR/.lab-state"

usage() {
  cat <<'EOF'
Usage: tools/replay_zysh_fakeproc.sh <guest|admin> [cmd_payload] [label]

Examples:
  tools/replay_zysh_fakeproc.sh guest
  tools/replay_zysh_fakeproc.sh admin 'cmd=show+running-config'
  tools/replay_zysh_fakeproc.sh guest 'cmd=show+version' guest_show_version_fakeproc
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

bind_vendor_proc_and_devices() {
  local dummy_uam=()
  build_vendor_binds "$1" "$3" "$2" dummy_uam "$RUNROOT"
}

report_lock_holder() {
  local lock_path="$1"
  echo "Replay lock is already held: $lock_path" >&2
  if command -v lsof >/dev/null 2>&1; then
    lsof "$lock_path" 2>/dev/null >&2 || true
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser -v "$lock_path" 2>/dev/null >&2 || true
  fi
}

maybe_reexec_under_lock() {
  local lock_path="$STATE_DIR/replay_zysh_fakeproc.lock"
  if [[ "${ZYXEL_REPLAY_LOCK_HELD:-0}" == 1 ]]; then
    unset ZYXEL_REPLAY_LOCK_HELD
    return 0
  fi
  export ZYXEL_REPLAY_LOCK_HELD=1
  if ! flock -n -o "$lock_path" "$0" "$@"; then
    report_lock_holder "$lock_path"
    exit 1
  fi
  exit 0
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

maybe_reexec_under_lock "$@"

mode="${1:-}"
arg2="${2:-}"
arg3="${3:-}"

case "$mode" in
  guest)
    user_type=1
    token=testtoken
    ;;
  admin)
    user_type=0
    token=admin0
    ;;
  *)
    usage
    exit 1
    ;;
esac

if [[ -n "$arg2" && "$arg2" != cmd=* ]]; then
  label="$arg2"
  cmd_payload="${arg3:-cmd=show+running-config}"
else
  cmd_payload="${arg2:-cmd=show+running-config}"
  label="${arg3:-${mode}_fakeproc}"
fi

need_cmd python3
need_cmd bwrap
need_cmd qemu-aarch64-static
need_cmd flock
[[ -f "$RUNROOT/proc/MRD" ]] || {
  echo "Missing $RUNROOT/proc/MRD. Seed the runroot first." >&2
  exit 1
}

mkdir -p "$ART_DIR" "$STATE_DIR"
replay_state="$STATE_DIR/$label"
mkdir -p "$replay_state"

proc_binds=()
dev_binds=()
sys_binds=()
bind_vendor_proc_and_devices proc_binds dev_binds sys_binds

trace_out="$ART_DIR/direct_zysh_trace_${label}.log"
body_out="$ART_DIR/direct_zysh_trace_${label}_body.txt"
zyshd_log="$ART_DIR/zyshd_wd_${label}.log"
zylogd_log="$ART_DIR/zylogd_${label}.log"
link_log="$replay_state/link-updown.log"

rm -f "$RUNROOT/dev/user-request" "$RUNROOT/dev/user-request2"

cleanup() {
  zyxel_stop_manual_core_lane
  python3 "$ROOT_DIR/tools/seed_zyxel_ipc.py" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

zyxel_start_manual_core_lane "$ROOT_DIR" "$RUNROOT" "$STATE_DIR" "$user_type" "$token" "$label"
cp -f "$STATE_DIR/${label}_zylogd.log" "$zylogd_log"
cp -f "$STATE_DIR/${label}_zyshd_wd.log" "$zyshd_log"
cp -f "$STATE_DIR/${label}_link.log" "$link_log"

printf '%s' "$cmd_payload" | timeout 20s \
  bwrap \
    --bind "$RUNROOT" / \
    --chdir / \
    --dev /dev \
    "${proc_binds[@]}" \
    "${sys_binds[@]}" \
    "${dev_binds[@]}" \
    --bind "$RUNROOT/dev/user-request" /dev/user-request \
    --bind "$RUNROOT/dev/user-request2" /dev/user-request2 \
    --setenv PATH /usr/bin:/bin \
    --setenv REQUEST_METHOD POST \
    --setenv CONTENT_LENGTH "${#cmd_payload}" \
    --setenv HTTP_COOKIE "authtok=$token" \
    --setenv CONTENT_TYPE 'application/x-www-form-urlencoded' \
    --setenv REMOTE_ADDR '127.0.0.1' \
    --setenv SCRIPT_NAME '/cgi-bin/zysh-cgi' \
    /usr/bin/qemu-aarch64-static -strace /usr/local/lighttpd/cgi-bin/zysh-cgi \
    >"$body_out" 2>"$trace_out" || true

echo "Trace: $trace_out"
echo "Body:  $body_out"
echo "Zyshd: $zyshd_log"
