#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"

LABEL="${1:-social_login_portal_config_only_probe}"
ART_DIR="$ROOT_DIR/live_artifacts/$LABEL"
RUNROOT="$ROOT_DIR/runroot"
STATE_DIR="$ROOT_DIR/.lab-state"

mkdir -p "$ART_DIR"

run_pty() {
  local command_file="$1"
  local transcript="$2"
  local stderr_log="$3"
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()

  build_vendor_binds proc_bind sys_bind dev_bind uam_bind "$RUNROOT"

  timeout 45s python3 "$ROOT_DIR/tools/run_zysh_pty.py" \
    --commands-file "$command_file" \
    --transcript "$transcript" \
    --timeout-sec 45 \
    --startup-wait-sec 1.5 \
    --step-wait-sec 0.6 \
    --tail-wait-sec 2.0 \
    --prompt-regex '(?m)Router(?:\([^)]*\))?[>#] ?$' \
    --prompt-wait-sec 10 \
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
    >"$stderr_log" 2>&1 || true
}

cleanup_marker() {
  rm -f \
    "$RUNROOT/tmp/cp_simulate" \
    "$RUNROOT/tmp/portal_config" \
    "$RUNROOT/var/zyxel/portal_info" \
    "$RUNROOT/var/portal_info.tmp" \
    "$RUNROOT/tmp/whybrid"
}

cat >"$ART_DIR/preseed.commands.txt" <<'EOF'
configure terminal
no netconf inactivate
hybrid-mode cloud
manager ap no login-ip
write
exit
exit
EOF

cat >"$ART_DIR/apply.commands.txt" <<'EOF'
configure terminal
captive-portal-profile THEME1
method click-through
portal-type internal
success-page internal
max-login-count 1
exit
wlan-ssid-profile SSID1
ssid zyxel-lab
captive-portal THEME1
exit
write
exit
exit
EOF

cat >"$ART_DIR/refresh.commands.txt" <<'EOF'
configure terminal
captive-portal-profile THEME1
method click-through
portal-type internal
success-page internal
max-login-count 2
exit
write
exit
exit
EOF

"$ROOT_DIR/tools/run_zyxel_lab.sh" stop >"$ART_DIR/stop.log" 2>&1 || true

python3 "$ROOT_DIR/tools/prepare_zyxel_runroot.py" \
  --src "$ROOT_DIR/710ABRM4C0_extracted/rootfs" \
  --dst "$RUNROOT" \
  --rebuild >"$ART_DIR/rebuild.log" 2>&1

python3 "$ROOT_DIR/tools/prepare_portal_runtime.py" \
  --runroot "$RUNROOT" \
  --mode vendor \
  --theme THEME1 \
  --write-includes \
  --hydrate-assets >"$ART_DIR/prepare_portal_runtime.txt"

cleanup_marker

ZYXEL_WIRELESS_HAL_MODE=shim \
ZYXEL_UAM_MODE=vendor-debug \
ZYXEL_GATEKEEPER_MODE=marker-clear \
ZYXEL_UAM_LOCKOUT_MODE=seed \
ZYXEL_UAM_TRACE_MODE=host-strace-deep \
"$ROOT_DIR/tools/run_zyxel_lab.sh" start >"$ART_DIR/lab_start.txt" 2>&1 || true

ZYXEL_WIRELESS_HAL_MODE=shim \
"$ROOT_DIR/tools/run_zyxel_lab.sh" health >"$ART_DIR/lab_health.txt" 2>&1 || true

run_pty "$ART_DIR/preseed.commands.txt" "$ART_DIR/preseed.transcript.txt" "$ART_DIR/preseed.stderr.txt"
run_pty "$ART_DIR/apply.commands.txt" "$ART_DIR/apply.transcript.txt" "$ART_DIR/apply.stderr.txt"
run_pty "$ART_DIR/refresh.commands.txt" "$ART_DIR/refresh.transcript.txt" "$ART_DIR/refresh.stderr.txt"

python3 "$ROOT_DIR/tools/repair_portal_config.py" \
  --runroot "$RUNROOT" \
  --theme THEME1 >"$ART_DIR/repair_portal_config.txt"

sleep 4

curl -sk -D "$ART_DIR/cp.headers" -o "$ART_DIR/cp.body" \
  -H 'Host: nap-slogin.nebula.zyxel.com' \
  'http://127.0.0.1:8080/CP/THEME1/login.html' --max-time 12 || true

curl -sk -D "$ART_DIR/click.headers" -o "$ART_DIR/click.body" \
  -H 'Host: nap-slogin.nebula.zyxel.com' \
  -X POST --data '' \
  'http://127.0.0.1:8080/cgi-bin/Clicktocontinue.cgi' --max-time 12 || true

curl -sk -D "$ART_DIR/social.headers" -o "$ART_DIR/social.body" \
  -X POST --data 'fb_user=test@example.com' \
  'http://127.0.0.1:8080/cgi-bin/social_login.cgi' --max-time 12 || true

cp "$STATE_DIR/uamd.log" "$ART_DIR/uamd.log" 2>/dev/null || true
if compgen -G "$STATE_DIR/uamd.strace*" >/dev/null; then
  mkdir -p "$ART_DIR/uamd_strace"
  cp "$STATE_DIR"/uamd.strace* "$ART_DIR/uamd_strace/" 2>/dev/null || true
fi

{
  echo "label=$LABEL"
  echo "prepare_mode=vendor"
  echo "prepare_bootstrap_state=no"
  echo "portal_config_repaired=yes"
  echo "cp_simulate_exists=$(test -e "$RUNROOT/tmp/cp_simulate" && echo yes || echo no)"
  echo "portal_config_exists=$(test -e "$RUNROOT/tmp/portal_config" && echo yes || echo no)"
  echo "portal_info_exists=$(test -e "$RUNROOT/var/zyxel/portal_info" && echo yes || echo no)"
  echo "whybrid_exists=$(test -e "$RUNROOT/tmp/whybrid" && echo yes || echo no)"
  echo "preseed_connected=$(grep -q 'Router(config' "$ART_DIR/preseed.transcript.txt" && echo yes || echo no)"
  echo "apply_connected=$(grep -q 'Router(config' "$ART_DIR/apply.transcript.txt" && echo yes || echo no)"
  echo "refresh_connected=$(grep -q 'Router(config' "$ART_DIR/refresh.transcript.txt" && echo yes || echo no)"
  echo "cp_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$ART_DIR/cp.headers" 2>/dev/null || true)"
  echo "click_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$ART_DIR/click.headers" 2>/dev/null || true)"
  echo "social_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$ART_DIR/social.headers" 2>/dev/null || true)"
} | tee "$ART_DIR/quick_summary.txt"
