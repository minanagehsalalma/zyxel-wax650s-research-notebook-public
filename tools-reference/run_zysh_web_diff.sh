#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"
source "$ROOT_DIR/tools/zyxel_manual_core_lane.sh"

RUNROOT="$ROOT_DIR/runroot"
STATE_DIR="$ROOT_DIR/.lab-state"
ARTIFACT_ROOT="$ROOT_DIR/live_artifacts"
LABEL="${1:-web_lane_diff_manual}"
COMMAND_FILE="${2:-$ROOT_DIR/tools/zysh_web_diff_commands.txt}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$LABEL"
SUMMARY_OUT="$ARTIFACT_DIR/summary.txt"
COMPARISON_OUT="$ARTIFACT_DIR/comparison.tsv"

usage() {
  cat <<'EOF'
Usage: tools/run_zysh_web_diff.sh [label] [command_file]

Run the same healthy web seam twice:
1. guest fake-UAM session
2. admin fake-UAM session

For each mode it:
- stops the lab
- starts core
- verifies direct zysh -p 110 control
- launches manual lighttpd
- captures a baseline show running-config request
- runs the command list through web zysh-cgi with same-run direct controls
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

build_binds() {
  build_vendor_binds "$1" "$2" "$3" "$4" "$RUNROOT"
}

run_local_zysh_p110() {
  local command_text="$1"
  local output_path="$2"
  local error_path="$3"
  local command_file="$STATE_DIR/zysh-web-diff.commands.txt"
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()
  build_binds proc_bind sys_bind dev_bind uam_bind
  printf '%s\nexit\nexit\n' "$command_text" >"$command_file"
  timeout 25s python3 "$ROOT_DIR/tools/run_zysh_pty.py" \
    --commands-file "$command_file" \
    --transcript "$output_path" \
    --timeout-sec 25 \
    --startup-wait-sec 1.5 \
    --step-wait-sec 0.6 \
    --tail-wait-sec 2.0 \
    --prompt-regex 'Router[^\r\n]*#' \
    --prompt-wait-sec 8 \
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
      /usr/bin/qemu-aarch64-static /usr/bin/zysh -p 110 \
    >"$error_path" 2>&1
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
  rg -q 'interface-name |ssid|passphrase|password|wpa|radius|captive|serial|firmware|uptime|wlan|country|channel|cpu|memory' "$path"
}

http_code_from_headers() {
  awk 'NR==1 {print $2}' "$1"
}

body_bytes() {
  wc -c <"$1" | tr -d ' '
}

run_http_request() {
  local token="$1"
  local command_text="$2"
  local headers_out="$3"
  local body_out="$4"
  local payload
  payload="cmd=${command_text// /+}"
  curl -sS --max-time 20 -D "$headers_out" -o "$body_out" \
    -H 'Host: 127.0.0.1:8080' \
    --cookie "authtok=$token" \
    --data "$payload" \
    http://127.0.0.1:8080/cgi-bin/zysh-cgi || true
  [[ -f "$headers_out" ]] || : >"$headers_out"
  [[ -f "$body_out" ]] || : >"$body_out"
}

stop_lab() {
  zyxel_stop_manual_core_lane
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
}

run_mode() {
  local mode="$1"
  local user_type="$2"
  local token="$3"
  local mode_dir="$ARTIFACT_DIR/$mode"
  local table_out="$mode_dir/command_matrix.tsv"
  local direct_control_out="$mode_dir/direct_control_show_running_config.txt"
  local direct_control_err="$mode_dir/direct_control_show_running_config.err.txt"
  local direct_control_exit_file="$mode_dir/direct_control_show_running_config.exit.txt"
  local no_cookie_headers="$mode_dir/baseline_nocookie_headers.txt"
  local no_cookie_body="$mode_dir/baseline_nocookie_body.txt"
  local baseline_headers="$mode_dir/baseline_${mode}_show_running_config.headers.txt"
  local baseline_body="$mode_dir/baseline_${mode}_show_running_config.body.txt"
  local baseline_lighttpd="$mode_dir/baseline_${mode}_show_running_config.lighttpd_delta.txt"
  local baseline_dump="$mode_dir/baseline_${mode}_show_running_config.zysh-cgi.dump.txt"
  local baseline_clidump="$mode_dir/baseline_${mode}_show_running_config.clidump.gui.txt"
  local start_log="$mode_dir/start_core.log"
  local core_health_log="$mode_dir/core_health.log"
  local manual_lighttpd_log="$mode_dir/manual_lighttpd_start.log"
  local status_log="$mode_dir/status.log"
  local trace_start_line

  mkdir -p "$mode_dir/direct" "$mode_dir/web" "$mode_dir/staging"

  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$mode_dir/pre_stop.log" 2>&1 || true
  zyxel_start_manual_core_lane "$ROOT_DIR" "$RUNROOT" "$STATE_DIR" "$user_type" "$token" "${LABEL}_${mode}" >"$start_log" 2>&1
  cp -f "$STATE_DIR/${LABEL}_${mode}_zyshd_wd.log" "$core_health_log" 2>/dev/null || : >"$core_health_log"

  if run_local_zysh_p110 "show running-config" "$direct_control_out" "$direct_control_err"; then
    printf '0\n' >"$direct_control_exit_file"
  else
    printf '%s\n' "$?" >"$direct_control_exit_file"
  fi
  zyxel_start_manual_lighttpd "$RUNROOT" "$STATE_DIR" "${LABEL}_${mode}" >"$manual_lighttpd_log" 2>&1
  cp -f "$STATE_DIR/${LABEL}_${mode}_lighttpd.log" "$status_log" 2>/dev/null || : >"$status_log"

  curl -sS --max-time 10 -D "$no_cookie_headers" -o "$no_cookie_body" \
    -H 'Host: 127.0.0.1:8080' \
    --data 'cmd=show+running-config' \
    http://127.0.0.1:8080/cgi-bin/zysh-cgi || true

  trace_start_line=$(( $(wc -l <"$STATE_DIR/lighttpd.log" 2>/dev/null || echo 0) + 1 ))
  run_http_request "$token" "show running-config" "$baseline_headers" "$baseline_body"
  capture_lighttpd_delta "$trace_start_line" "$baseline_lighttpd"
  copy_if_present "$RUNROOT/tmp/zysh-cgi.dump" "$baseline_dump"
  copy_if_present "$RUNROOT/db/etc/zyxel/ftp/tmp/clidump.gui" "$baseline_clidump"

  printf 'command\tdirect_exit\tdirect_bytes\tweb_http\tweb_bytes\tweb_has_data_ready\tweb_has_usr_type\tweb_has_nonempty_zyshdata\tweb_has_sensitive_lines\tweb_has_insufficient_privilege\n' >"$table_out"

  while IFS= read -r command_text || [[ -n "$command_text" ]]; do
    [[ -z "$command_text" ]] && continue
    [[ "$command_text" =~ ^# ]] && continue

    local slug
    local direct_out
    local direct_err
    local web_headers
    local web_body
    local web_log_delta
    local cgi_dump_out
    local clidump_out
    local lighttpd_start_line
    local direct_exit
    local direct_bytes
    local web_http
    local web_bytes
    local web_has_data_ready
    local web_has_usr_type
    local web_has_nonempty_zyshdata
    local web_has_sensitive_lines
    local web_has_insufficient_privilege

    slug="$(slugify "$command_text")"
    direct_out="$mode_dir/direct/${slug}.txt"
    direct_err="$mode_dir/direct/${slug}.err.txt"
    web_headers="$mode_dir/web/${slug}.headers.txt"
    web_body="$mode_dir/web/${slug}.body.txt"
    web_log_delta="$mode_dir/web/${slug}.lighttpd_delta.txt"
    cgi_dump_out="$mode_dir/staging/${slug}.zysh-cgi.dump.txt"
    clidump_out="$mode_dir/staging/${slug}.clidump.gui.txt"

    lighttpd_start_line=$(( $(wc -l <"$STATE_DIR/lighttpd.log" 2>/dev/null || echo 0) + 1 ))

    if run_local_zysh_p110 "$command_text" "$direct_out" "$direct_err"; then
      direct_exit=0
    else
      direct_exit=$?
    fi

    run_http_request "$token" "$command_text" "$web_headers" "$web_body"
    capture_lighttpd_delta "$lighttpd_start_line" "$web_log_delta"
    copy_if_present "$RUNROOT/tmp/zysh-cgi.dump" "$cgi_dump_out"
    copy_if_present "$RUNROOT/db/etc/zyxel/ftp/tmp/clidump.gui" "$clidump_out"

    direct_bytes="$(body_bytes "$direct_out")"
    web_http="$(http_code_from_headers "$web_headers")"
    web_bytes="$(body_bytes "$web_body")"

    if rg -q 'data_ready = 1' "$web_body"; then
      web_has_data_ready="yes"
    else
      web_has_data_ready="no"
    fi
    if rg -q "usr_type = $user_type" "$web_body"; then
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
    if rg -q '% Insufficient privilege' "$web_body" "$web_log_delta"; then
      web_has_insufficient_privilege="yes"
    else
      web_has_insufficient_privilege="no"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$command_text" \
      "$direct_exit" \
      "$direct_bytes" \
      "$web_http" \
      "$web_bytes" \
      "$web_has_data_ready" \
      "$web_has_usr_type" \
      "$web_has_nonempty_zyshdata" \
      "$web_has_sensitive_lines" \
      "$web_has_insufficient_privilege" >>"$table_out"
  done <"$COMMAND_FILE"

  stop_lab >"$mode_dir/post_stop.log" 2>&1 || true
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd awk
need_cmd bwrap
need_cmd curl
need_cmd python3
need_cmd qemu-aarch64-static
need_cmd rg
need_cmd ss
need_cmd timeout

if [[ ! -f "$COMMAND_FILE" ]]; then
  echo "Missing command file: $COMMAND_FILE" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
cp -f "$COMMAND_FILE" "$ARTIFACT_DIR/commands.txt"

trap stop_lab EXIT

run_mode guest 1 testtoken
run_mode admin 0 admin0

python3 - "$ARTIFACT_DIR/guest/command_matrix.tsv" "$ARTIFACT_DIR/admin/command_matrix.tsv" "$COMPARISON_OUT" <<'PY'
import csv
import sys

guest_path, admin_path, out_path = sys.argv[1:4]
with open(guest_path, newline="", encoding="utf-8") as fh:
    guest_rows = {row["command"]: row for row in csv.DictReader(fh, delimiter="\t")}
with open(admin_path, newline="", encoding="utf-8") as fh:
    admin_rows = {row["command"]: row for row in csv.DictReader(fh, delimiter="\t")}

fieldnames = [
    "command",
    "guest_web_http",
    "admin_web_http",
    "guest_web_bytes",
    "admin_web_bytes",
    "guest_usr_type_ok",
    "admin_usr_type_ok",
    "guest_nonempty_zyshdata",
    "admin_nonempty_zyshdata",
    "guest_sensitive_lines",
    "admin_sensitive_lines",
    "guest_insufficient_privilege",
    "admin_insufficient_privilege",
]

with open(out_path, "w", newline="", encoding="utf-8") as fh:
    writer = csv.DictWriter(fh, fieldnames=fieldnames, delimiter="\t")
    writer.writeheader()
    for command in guest_rows:
      g = guest_rows[command]
      a = admin_rows.get(command, {})
      writer.writerow({
          "command": command,
          "guest_web_http": g.get("web_http", ""),
          "admin_web_http": a.get("web_http", ""),
          "guest_web_bytes": g.get("web_bytes", ""),
          "admin_web_bytes": a.get("web_bytes", ""),
          "guest_usr_type_ok": g.get("web_has_usr_type", ""),
          "admin_usr_type_ok": a.get("web_has_usr_type", ""),
          "guest_nonempty_zyshdata": g.get("web_has_nonempty_zyshdata", ""),
          "admin_nonempty_zyshdata": a.get("web_has_nonempty_zyshdata", ""),
          "guest_sensitive_lines": g.get("web_has_sensitive_lines", ""),
          "admin_sensitive_lines": a.get("web_has_sensitive_lines", ""),
          "guest_insufficient_privilege": g.get("web_has_insufficient_privilege", ""),
          "admin_insufficient_privilege": a.get("web_has_insufficient_privilege", ""),
      })
PY

python3 - "$ARTIFACT_DIR" "$SUMMARY_OUT" <<'PY'
import csv
import sys
from pathlib import Path

root = Path(sys.argv[1])
summary_path = Path(sys.argv[2])

def read_rows(path):
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh, delimiter="\t"))

guest_rows = read_rows(root / "guest" / "command_matrix.tsv")
admin_rows = read_rows(root / "admin" / "command_matrix.tsv")

def count(rows, key, value):
    return sum(1 for row in rows if row.get(key) == value)

def baseline_fields(mode):
    path = root / mode / f"baseline_{mode}_show_running_config.body.txt"
    body = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    return (
        "data_ready = 1" in body,
        f"usr_type = {'1' if mode == 'guest' else '0'}" in body,
        "interface-name ge1 lan1" in body,
    )

guest_data_ready, guest_usr_ok, guest_cfg = baseline_fields("guest")
admin_data_ready, admin_usr_ok, admin_cfg = baseline_fields("admin")

guest_more = []
admin_more = []
for g, a in zip(guest_rows, admin_rows):
    command = g["command"]
    g_sig = (g["web_has_nonempty_zyshdata"], g["web_has_sensitive_lines"], g["web_bytes"], g["web_has_insufficient_privilege"])
    a_sig = (a["web_has_nonempty_zyshdata"], a["web_has_sensitive_lines"], a["web_bytes"], a["web_has_insufficient_privilege"])
    if a_sig > g_sig:
        admin_more.append(command)
    elif g_sig > a_sig:
        guest_more.append(command)

lines = [
    "result_class=web_lane_guest_admin_diff",
    "date=2026-04-20",
    f"command_count={len(guest_rows)}",
    f"guest_baseline_data_ready={'yes' if guest_data_ready else 'no'}",
    f"guest_baseline_usr_type_ok={'yes' if guest_usr_ok else 'no'}",
    f"guest_baseline_config_in_body={'yes' if guest_cfg else 'no'}",
    f"admin_baseline_data_ready={'yes' if admin_data_ready else 'no'}",
    f"admin_baseline_usr_type_ok={'yes' if admin_usr_ok else 'no'}",
    f"admin_baseline_config_in_body={'yes' if admin_cfg else 'no'}",
    f"guest_http_200_count={count(guest_rows, 'web_http', '200')}",
    f"admin_http_200_count={count(admin_rows, 'web_http', '200')}",
    f"guest_nonempty_zyshdata_count={count(guest_rows, 'web_has_nonempty_zyshdata', 'yes')}",
    f"admin_nonempty_zyshdata_count={count(admin_rows, 'web_has_nonempty_zyshdata', 'yes')}",
    f"guest_sensitive_line_count={count(guest_rows, 'web_has_sensitive_lines', 'yes')}",
    f"admin_sensitive_line_count={count(admin_rows, 'web_has_sensitive_lines', 'yes')}",
    f"guest_insufficient_privilege_count={count(guest_rows, 'web_has_insufficient_privilege', 'yes')}",
    f"admin_insufficient_privilege_count={count(admin_rows, 'web_has_insufficient_privilege', 'yes')}",
    "",
    "[baseline]",
    "- guest baseline body is in `guest/baseline_guest_show_running_config.body.txt`.",
    "- admin baseline body is in `admin/baseline_admin_show_running_config.body.txt`.",
    "- both runs preserve the same-run direct control in `guest/direct_control_show_running_config.txt` and `admin/direct_control_show_running_config.txt`.",
    "",
    "[comparison]",
]

if admin_more:
    lines.append(f"- admin improved over guest for: {', '.join(admin_more)}")
else:
    lines.append("- admin did not produce a stronger web body than guest on this command set.")

if guest_more:
    lines.append(f"- guest exceeded admin for: {', '.join(guest_more)}")

lines.extend([
    f"- guest baseline contains config lines: {'yes' if guest_cfg else 'no'}",
    f"- admin baseline contains config lines: {'yes' if admin_cfg else 'no'}",
    f"- guest non-empty zyshdata count: {count(guest_rows, 'web_has_nonempty_zyshdata', 'yes')}",
    f"- admin non-empty zyshdata count: {count(admin_rows, 'web_has_nonempty_zyshdata', 'yes')}",
    f"- guest sensitive-line count: {count(guest_rows, 'web_has_sensitive_lines', 'yes')}",
    f"- admin sensitive-line count: {count(admin_rows, 'web_has_sensitive_lines', 'yes')}",
    "",
    "[artifacts]",
    f"- comparison table: `{root.name}/comparison.tsv`",
    f"- guest matrix: `{root.name}/guest/command_matrix.tsv`",
    f"- admin matrix: `{root.name}/admin/command_matrix.tsv`",
])

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

printf 'Summary: %s\n' "$SUMMARY_OUT"
