#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNROOT="$ROOT_DIR/runroot"
ART_ROOT="$ROOT_DIR/live_artifacts"
LABEL="${1:-portal_smoke}"
MODE="${2:-synthetic-minimal}"
THEME="${3:-THEME1}"
WIRELESS_MODE="${4:-}"
UAM_MODE="${ZYXEL_UAM_MODE:-fake}"
GATEKEEPER_MODE="${ZYXEL_GATEKEEPER_MODE:-off}"
UAM_LOCKOUT_MODE="${ZYXEL_UAM_LOCKOUT_MODE:-off}"
UAM_TRACE_MODE="${ZYXEL_UAM_TRACE_MODE:-off}"
POST_WAIT_SEC="${ZYXEL_PORTAL_POST_WAIT_SEC:-0}"
PORTAL_POST_LOGIN_STATE="${ZYXEL_PORTAL_POST_LOGIN_STATE:-}"
PORTAL_POST_LOGIN_TARGET="${ZYXEL_PORTAL_POST_LOGIN_TARGET:-}"
SEED_SYSTEM_DEFAULT_PROFILE="${ZYXEL_SEED_SYSTEM_DEFAULT_PROFILE:-0}"
SKIP_PORTAL_CONFIG="${ZYXEL_PORTAL_SKIP_PORTAL_CONFIG:-0}"
SSID_PROFILE="${ZYXEL_PORTAL_SSID_PROFILE:-SSID1}"
SSID_NAME="${ZYXEL_PORTAL_SSID_NAME:-zyxel-lab}"
HOST_HEADER="nap-slogin.nebula.zyxel.com"
BASE_URL="http://127.0.0.1:8080"
SOCIAL_LOGIN_PAYLOAD="${ZYXEL_SOCIAL_LOGIN_PAYLOAD:-fb_user=test@example.com}"
ART_DIR="$ART_ROOT/$LABEL"

if [[ -z "$WIRELESS_MODE" ]]; then
  if [[ "$MODE" == "synthetic-minimal" ]]; then
    WIRELESS_MODE="shim"
  else
    WIRELESS_MODE="real"
  fi
fi

command -v curl >/dev/null 2>&1
command -v python3 >/dev/null 2>&1

mkdir -p "$ART_DIR"

portal_prepare_args=()
if [[ -n "$PORTAL_POST_LOGIN_STATE" ]]; then
  portal_prepare_args+=(--post-login-state "$PORTAL_POST_LOGIN_STATE")
fi
if [[ -n "$PORTAL_POST_LOGIN_TARGET" ]]; then
  portal_prepare_args+=(--post-login-target "$PORTAL_POST_LOGIN_TARGET")
fi
if [[ "$SEED_SYSTEM_DEFAULT_PROFILE" == "1" ]]; then
  portal_prepare_args+=(--seed-system-default-profile)
fi
if [[ "$SKIP_PORTAL_CONFIG" == "1" ]]; then
  portal_prepare_args+=(--skip-portal-config)
fi

"$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true

python3 "$ROOT_DIR/tools/prepare_zyxel_runroot.py" \
  --src "$ROOT_DIR/710ABRM4C0_extracted/rootfs" \
  --dst "$RUNROOT" >/dev/null

python3 "$ROOT_DIR/tools/prepare_portal_runtime.py" \
  --runroot "$RUNROOT" \
  --mode "$MODE" \
  --theme "$THEME" \
  --ssid-profile "$SSID_PROFILE" \
  --ssid-name "$SSID_NAME" \
  "${portal_prepare_args[@]}" \
  --write-includes \
  --hydrate-assets \
  --bootstrap-state \
  >"$ART_DIR/prepare_portal_runtime.txt"

"$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
ZYXEL_WIRELESS_HAL_MODE="$WIRELESS_MODE" "$ROOT_DIR/tools/run_zyxel_lab.sh" start >"$ART_DIR/lab_start.txt" 2>&1 || true
ZYXEL_WIRELESS_HAL_MODE="$WIRELESS_MODE" "$ROOT_DIR/tools/run_zyxel_lab.sh" health >"$ART_DIR/lab_health.txt" 2>&1 || true

curl_common=(-sS --max-time 10 -H "Host: $HOST_HEADER")

curl -D "$ART_DIR/cp_login.headers" -o "$ART_DIR/cp_login.body" \
  "${curl_common[@]}" \
  "$BASE_URL/CP/$THEME/login.html" || true

curl -D "$ART_DIR/click_to_continue.headers" -o "$ART_DIR/click_to_continue.body" \
  "${curl_common[@]}" \
  -X POST \
  --data '' \
  "$BASE_URL/cgi-bin/Clicktocontinue.cgi" || true

curl -D "$ART_DIR/social_login.headers" -o "$ART_DIR/social_login.body" \
  "${curl_common[@]}" \
  -X POST \
  --data "$SOCIAL_LOGIN_PAYLOAD" \
  "$BASE_URL/cgi-bin/social_login.cgi" || true

if [[ "$POST_WAIT_SEC" != "0" ]]; then
  sleep "$POST_WAIT_SEC"
fi

{
  echo "label=$LABEL"
  echo "mode=$MODE"
  echo "theme=$THEME"
  echo "wireless_mode=$WIRELESS_MODE"
  echo "uam_mode=$UAM_MODE"
  echo "gatekeeper_mode=$GATEKEEPER_MODE"
  echo "uam_lockout_mode=$UAM_LOCKOUT_MODE"
  echo "uam_trace_mode=$UAM_TRACE_MODE"
  echo "post_wait_sec=$POST_WAIT_SEC"
  echo "portal_post_login_state=${PORTAL_POST_LOGIN_STATE:-}"
  echo "portal_post_login_target=${PORTAL_POST_LOGIN_TARGET:-}"
  echo "seed_system_default_profile=$SEED_SYSTEM_DEFAULT_PROFILE"
  echo "skip_portal_config=$SKIP_PORTAL_CONFIG"
  echo "ssid_profile=$SSID_PROFILE"
  echo "ssid_name=$SSID_NAME"
  echo
  echo "cp_login_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$ART_DIR/cp_login.headers" 2>/dev/null || true)"
  echo "click_to_continue_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$ART_DIR/click_to_continue.headers" 2>/dev/null || true)"
  echo "social_login_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$ART_DIR/social_login.headers" 2>/dev/null || true)"
  echo
  echo "click_to_continue_set_cookie=$(rg -n '^Set-Cookie: authtok=' "$ART_DIR/click_to_continue.headers" -N || true)"
  echo "social_login_set_cookie=$(rg -n '^Set-Cookie: authtok=' "$ART_DIR/social_login.headers" -N || true)"
} >"$ART_DIR/summary.txt"

if compgen -G "$ROOT_DIR/.lab-state/uamd.strace*" >/dev/null; then
  mkdir -p "$ART_DIR/uamd_strace"
  cp "$ROOT_DIR"/.lab-state/uamd.strace* "$ART_DIR/uamd_strace/" 2>/dev/null || true
fi

cp "$ROOT_DIR/.lab-state/uamd.log" "$ART_DIR/uamd.log" 2>/dev/null || true
cp "$ROOT_DIR/.lab-state/lighttpd.log" "$ART_DIR/lighttpd.log" 2>/dev/null || true
cp "$ROOT_DIR/.lab-state/gatekeeper-marker-clearer.log" "$ART_DIR/gatekeeper-marker-clearer.log" 2>/dev/null || true
cp "$ROOT_DIR/.lab-state/wireless_hal_shim.log" "$ART_DIR/wireless_hal_shim.log" 2>/dev/null || true

cat "$ART_DIR/summary.txt"

if rg -q '^Set-Cookie: authtok=' "$ART_DIR/click_to_continue.headers" "$ART_DIR/social_login.headers"; then
  exit 0
fi

echo "No guest authtok cookie was issued. Portal bootstrap is still incomplete." >&2
exit 1
