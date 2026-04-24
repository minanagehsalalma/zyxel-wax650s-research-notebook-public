#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"

RUNROOT="$ROOT_DIR/runroot"
STATE_DIR="$ROOT_DIR/.lab-state"
ARTIFACT_ROOT="$ROOT_DIR/live_artifacts"
LABEL="${1:-web_lane_corpus_manual}"
COMMAND_FILE="${2:-$ROOT_DIR/tools/zysh_web_guest_readonly_commands.txt}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$LABEL"
SUMMARY_OUT="$ARTIFACT_DIR/summary.txt"
NOTES_OUT="$ARTIFACT_DIR/notes.txt"
TABLE_OUT="$ARTIFACT_DIR/command_matrix.tsv"
COMMANDS_OUT="$ARTIFACT_DIR/commands.txt"
START_LOG="$ARTIFACT_DIR/start_core.log"
CORE_HEALTH_LOG="$ARTIFACT_DIR/core_health.log"
STOP_LOG="$ARTIFACT_DIR/stop.log"
LIGHTTPD_START_LOG="$ARTIFACT_DIR/manual_lighttpd_start.log"
LIGHTTPD_HEALTH_LOG="$ARTIFACT_DIR/manual_lighttpd_health.log"
DIRECT_CONTROL_OUT="$ARTIFACT_DIR/direct_control_show_running_config.txt"
NOCOOKIE_HEADERS="$ARTIFACT_DIR/baseline_nocookie_headers.txt"
NOCOOKIE_BODY="$ARTIFACT_DIR/baseline_nocookie_body.txt"
TRACE_HEADERS="$ARTIFACT_DIR/baseline_guest_show_running_config_headers.txt"
TRACE_BODY="$ARTIFACT_DIR/baseline_guest_show_running_config_body.txt"
TRACE_LIGHTTPD_DELTA="$ARTIFACT_DIR/baseline_guest_show_running_config.lighttpd_delta.txt"
TRACE_CGI_DUMP="$ARTIFACT_DIR/baseline_guest_show_running_config.zysh-cgi.dump.txt"
TRACE_CLIDUMP="$ARTIFACT_DIR/baseline_guest_show_running_config.clidump.gui.txt"
TRACE_PREFIX="$ARTIFACT_DIR/zyshd.hosttrace"
IPCS_AFTER="$ARTIFACT_DIR/ipcs_after_trace.txt"
LIGHTTPD_LOG_COPY="$ARTIFACT_DIR/lighttpd.log"

usage() {
  cat <<'EOF'
Usage: tools/run_zysh_web_corpus.sh [label] [command_file]

Runs the saved web-lane healthy seam:
1. stop lab
2. start core phase
3. verify direct zysh -p 110 show running-config
4. start manual lighttpd on top of the healthy seam
5. capture no-cookie and guest baseline requests
6. run the command corpus with direct-vs-web captures
7. stop cleanly
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
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

build_binds() {
  build_vendor_binds "$1" "$2" "$3" "$4" "$RUNROOT"
}

run_local_zysh_p110() {
  local command_text="$1"
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()
  build_binds proc_bind sys_bind dev_bind uam_bind
  timeout 15s bwrap \
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

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9][^a-z0-9]*/_/g; s/^_//; s/_$//'
}

capture_lighttpd_delta() {
  local start_line="$1"
  local output_path="$2"
  if [[ -f "$STATE_DIR/lighttpd.log" ]]; then
    sed -n "${start_line},\$p" "$STATE_DIR/lighttpd.log" >"$output_path" || true
  else
    : >"$output_path"
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

body_has_nonempty_zyshdata() {
  local path="$1"
  grep -Eq 'var zyshdata[0-9]+=\[[^]]+\];' "$path"
}

body_has_sensitive_lines() {
  local path="$1"
  rg -q 'interface-name |ssid|passphrase|password|wpa|radius|captive|serial|firmware|uptime|wlan|country|channel' "$path"
}

http_code_from_headers() {
  awk 'NR==1 {print $2}' "$1"
}

body_bytes() {
  wc -c <"$1" | tr -d ' '
}

run_http_request() {
  local command_text="$1"
  local headers_out="$2"
  local body_out="$3"
  local cookie_mode="$4"
  local payload
  payload="cmd=${command_text// /+}"
  if [[ "$cookie_mode" == "guest" ]]; then
    curl -sS --max-time 15 -D "$headers_out" -o "$body_out" \
      -H 'Host: 127.0.0.1:8080' \
      --cookie 'authtok=testtoken' \
      --data "$payload" \
      http://127.0.0.1:8080/cgi-bin/zysh-cgi
  else
    curl -sS --max-time 15 -D "$headers_out" -o "$body_out" \
      -H 'Host: 127.0.0.1:8080' \
      --data "$payload" \
      http://127.0.0.1:8080/cgi-bin/zysh-cgi || true
  fi
}

start_manual_lighttpd() {
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()
  build_binds proc_bind sys_bind dev_bind uam_bind
  rm -f "$STATE_DIR/lighttpd.pid"
  nohup bwrap \
    --bind "$RUNROOT" / \
    --chdir / \
    --dev /dev \
    "${proc_bind[@]}" \
    "${sys_bind[@]}" \
    "${dev_bind[@]}" \
    "${uam_bind[@]}" \
    --setenv PATH /usr/bin:/bin \
    /usr/bin/qemu-aarch64-static /usr/local/lighttpd/sbin/lighttpd -D -f /usr/local/lighttpd/conf/lighttpd-lab.conf \
    >"$STATE_DIR/lighttpd.log" 2>&1 &
  echo $! >"$STATE_DIR/lighttpd.pid"
  wait_for_port 8080
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://127.0.0.1:8080/ >"$LIGHTTPD_HEALTH_LOG"
}

cleanup() {
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$STOP_LOG" 2>&1 || true
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd bwrap
need_cmd curl
need_cmd qemu-aarch64-static
need_cmd python3
need_cmd rg
need_cmd ss
need_cmd strace
need_cmd timeout

if [[ ! -f "$COMMAND_FILE" ]]; then
  echo "Missing command file: $COMMAND_FILE" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR/direct" "$ARTIFACT_DIR/web" "$ARTIFACT_DIR/staging"
trap cleanup EXIT

cp -f "$COMMAND_FILE" "$COMMANDS_OUT"

"$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$ARTIFACT_DIR/pre_stop.log" 2>&1 || true
"$ROOT_DIR/tools/run_zyxel_lab.sh" start --phase core >"$START_LOG" 2>&1
"$ROOT_DIR/tools/run_zyxel_lab.sh" health --phase core >"$CORE_HEALTH_LOG" 2>&1
run_local_zysh_p110 "show running-config" >"$DIRECT_CONTROL_OUT"

start_manual_lighttpd >"$LIGHTTPD_START_LOG" 2>&1

run_http_request "show running-config" "$NOCOOKIE_HEADERS" "$NOCOOKIE_BODY" "nocookie"

trace_start_line=$(( $(wc -l <"$STATE_DIR/lighttpd.log" 2>/dev/null || echo 0) + 1 ))
strace -ff -tt -s 256 -yy -o "$TRACE_PREFIX" -p "$(cat "$STATE_DIR/zyshd.pid")" >"$ARTIFACT_DIR/zyshd_trace_attach.log" 2>&1 &
trace_pid=$!
sleep 1
run_http_request "show running-config" "$TRACE_HEADERS" "$TRACE_BODY" "guest"
sleep 1
kill "$trace_pid" 2>/dev/null || true
wait "$trace_pid" 2>/dev/null || true
capture_lighttpd_delta "$trace_start_line" "$TRACE_LIGHTTPD_DELTA"
copy_if_present "$RUNROOT/tmp/zysh-cgi.dump" "$TRACE_CGI_DUMP"
copy_if_present "$RUNROOT/db/etc/zyxel/ftp/tmp/clidump.gui" "$TRACE_CLIDUMP"
ipcs -q >"$IPCS_AFTER" 2>&1 || true

printf 'command\tdirect_exit\tdirect_bytes\tdirect_has_interface_name\tweb_http\tweb_bytes\tweb_has_data_ready\tweb_has_usr_type\tweb_has_nonempty_zyshdata\tweb_has_sensitive_lines\tweb_has_insufficient_privilege\n' >"$TABLE_OUT"

while IFS= read -r command_text || [[ -n "$command_text" ]]; do
  [[ -z "$command_text" ]] && continue
  [[ "$command_text" =~ ^# ]] && continue

  slug="$(slugify "$command_text")"
  direct_out="$ARTIFACT_DIR/direct/${slug}.txt"
  direct_err="$ARTIFACT_DIR/direct/${slug}.err.txt"
  web_headers="$ARTIFACT_DIR/web/${slug}.headers.txt"
  web_body="$ARTIFACT_DIR/web/${slug}.body.txt"
  web_log_delta="$ARTIFACT_DIR/web/${slug}.lighttpd_delta.txt"
  cgi_dump_out="$ARTIFACT_DIR/staging/${slug}.zysh-cgi.dump.txt"
  clidump_out="$ARTIFACT_DIR/staging/${slug}.clidump.gui.txt"

  lighttpd_start_line=$(( $(wc -l <"$STATE_DIR/lighttpd.log" 2>/dev/null || echo 0) + 1 ))

  if run_local_zysh_p110 "$command_text" >"$direct_out" 2>"$direct_err"; then
    direct_exit=0
  else
    direct_exit=$?
  fi

  run_http_request "$command_text" "$web_headers" "$web_body" "guest"
  capture_lighttpd_delta "$lighttpd_start_line" "$web_log_delta"
  copy_if_present "$RUNROOT/tmp/zysh-cgi.dump" "$cgi_dump_out"
  copy_if_present "$RUNROOT/db/etc/zyxel/ftp/tmp/clidump.gui" "$clidump_out"

  direct_bytes="$(body_bytes "$direct_out")"
  if rg -q 'interface-name ge1 lan1' "$direct_out"; then
    direct_has_interface_name="yes"
  else
    direct_has_interface_name="no"
  fi
  web_http="$(http_code_from_headers "$web_headers")"
  web_bytes="$(body_bytes "$web_body")"
  if rg -q 'data_ready = 1' "$web_body"; then
    web_has_data_ready="yes"
  else
    web_has_data_ready="no"
  fi
  if rg -q 'usr_type = 1' "$web_body"; then
    web_has_usr_type="yes"
  else
    web_has_usr_type="no"
  fi
  if body_has_nonempty_zyshdata "$web_body"; then
    web_has_nonempty_zyshdata="yes"
  else
    web_has_nonempty_zyshdata="no"
  fi
  if body_has_sensitive_lines "$web_body"; then
    web_has_sensitive_lines="yes"
  else
    web_has_sensitive_lines="no"
  fi
  if rg -q 'Insufficient privilege' "$web_log_delta"; then
    web_has_insufficient_privilege="yes"
  else
    web_has_insufficient_privilege="no"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$command_text" \
    "$direct_exit" \
    "$direct_bytes" \
    "$direct_has_interface_name" \
    "$web_http" \
    "$web_bytes" \
    "$web_has_data_ready" \
    "$web_has_usr_type" \
    "$web_has_nonempty_zyshdata" \
    "$web_has_sensitive_lines" \
    "$web_has_insufficient_privilege" >>"$TABLE_OUT"
done <"$COMMAND_FILE"

cp -f "$STATE_DIR/lighttpd.log" "$LIGHTTPD_LOG_COPY" 2>/dev/null || true

python3 - "$TABLE_OUT" "$SUMMARY_OUT" "$NOTES_OUT" <<'PY'
import csv
import sys
from pathlib import Path

table_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
notes_path = Path(sys.argv[3])
rows = list(csv.DictReader(table_path.open(), delimiter="\t"))

http_200 = sum(1 for row in rows if row["web_http"] == "200")
nonempty = [row["command"] for row in rows if row["web_has_nonempty_zyshdata"] == "yes"]
sensitive = [row["command"] for row in rows if row["web_has_sensitive_lines"] == "yes"]
priv = [row["command"] for row in rows if row["web_has_insufficient_privilege"] == "yes"]
direct_nonempty = [row["command"] for row in rows if int(row["direct_bytes"]) > 0]

summary = [
    "result_class=web_lane_corpus_pass",
    f"commands_tested={len(rows)}",
    f"web_http_200_count={http_200}",
    f"web_nonempty_zyshdata_count={len(nonempty)}",
    f"web_sensitive_line_count={len(sensitive)}",
    f"web_insufficient_privilege_count={len(priv)}",
    f"direct_nonempty_count={len(direct_nonempty)}",
    "",
    "[baseline]",
    "- same-run direct control: direct_control_show_running_config.txt",
    "- no-cookie baseline: baseline_nocookie_headers.txt",
    "- traced guest baseline: baseline_guest_show_running_config_headers.txt, baseline_guest_show_running_config_body.txt, zyshd.hosttrace.*",
    "",
    "[web corpus hits]",
]
if nonempty:
    summary.extend(f"- {cmd}" for cmd in nonempty[:20])
else:
    summary.append("- none")
summary.append("")
summary.append("[web sensitive-line hits]")
if sensitive:
    summary.extend(f"- {cmd}" for cmd in sensitive[:20])
else:
    summary.append("- none")
summary.append("")
summary.append("[immediate privilege markers]")
if priv:
    summary.extend(f"- {cmd}" for cmd in priv[:20])
else:
    summary.append("- none")
summary_path.write_text("\n".join(summary) + "\n")

notes = [
    "Interpretation notes:",
    "- `web_has_nonempty_zyshdata=yes` means the returned body contains at least one non-empty `zyshdataN=[...]` array.",
    "- `web_has_sensitive_lines=yes` is a broad text hit for config-adjacent or environment strings in the web body; confirm against the saved body file before promoting any claim.",
    "- `web_has_insufficient_privilege=yes` is derived from the per-request lighttpd log delta, not from the body alone.",
    "- `direct_bytes` is included to separate parser-miss commands from web-only suppression.",
]
notes_path.write_text("\n".join(notes) + "\n")
PY

echo "Artifact directory: $ARTIFACT_DIR"
echo "Summary: $SUMMARY_OUT"
