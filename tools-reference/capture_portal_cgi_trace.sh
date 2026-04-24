#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"

RUNROOT="$ROOT_DIR/runroot"
ART_DIR="$ROOT_DIR/live_artifacts"
STATE_DIR="$ROOT_DIR/.lab-state"
TARGET="${1:-Clicktocontinue.cgi}"
LABEL="${2:-manual}"
REQUEST_METHOD="${3:-GET}"
PAYLOAD="${4:-}"
WIRELESS_MODE="${ZYXEL_WIRELESS_HAL_MODE:-real}"
PORTAL_MODE="${ZYXEL_PORTAL_MODE:-synthetic-minimal}"
PORTAL_THEME="${ZYXEL_PORTAL_THEME:-THEME1}"
UAM_MODE="${ZYXEL_UAM_MODE:-fake}"
GATEKEEPER_MODE="${ZYXEL_GATEKEEPER_MODE:-off}"
UAM_LOCKOUT_MODE="${ZYXEL_UAM_LOCKOUT_MODE:-off}"
UAM_TRACE_MODE="${ZYXEL_UAM_TRACE_MODE:-off}"
PORTAL_POST_LOGIN_STATE="${ZYXEL_PORTAL_POST_LOGIN_STATE:-}"
PORTAL_POST_LOGIN_TARGET="${ZYXEL_PORTAL_POST_LOGIN_TARGET:-}"

command -v bwrap >/dev/null 2>&1
command -v qemu-aarch64-static >/dev/null 2>&1
command -v python3 >/dev/null 2>&1

mkdir -p "$ART_DIR" "$STATE_DIR"

portal_prepare_args=()
if [[ -n "$PORTAL_POST_LOGIN_STATE" ]]; then
  portal_prepare_args+=(--post-login-state "$PORTAL_POST_LOGIN_STATE")
fi
if [[ -n "$PORTAL_POST_LOGIN_TARGET" ]]; then
  portal_prepare_args+=(--post-login-target "$PORTAL_POST_LOGIN_TARGET")
fi

python3 "$ROOT_DIR/tools/prepare_zyxel_runroot.py" \
  --src "$ROOT_DIR/710ABRM4C0_extracted/rootfs" \
  --dst "$RUNROOT" >/dev/null
python3 "$ROOT_DIR/tools/prepare_portal_runtime.py" \
  --runroot "$RUNROOT" \
  --mode "$PORTAL_MODE" \
  --theme "$PORTAL_THEME" \
  "${portal_prepare_args[@]}" \
  --write-includes \
  --hydrate-assets \
  --bootstrap-state >/dev/null

proc_binds=()
sys_binds=()
dev_binds=()
uam_binds=()
build_vendor_binds proc_binds sys_binds dev_binds uam_binds "$RUNROOT"

BODY_OUT="$ART_DIR/${TARGET%.*}_${LABEL}.body.txt"
TRACE_OUT="$ART_DIR/${TARGET%.*}_${LABEL}.trace.txt"
STDERR_OUT="$ART_DIR/${TARGET%.*}_${LABEL}.stderr.txt"

"$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
ZYXEL_WIRELESS_HAL_MODE="$WIRELESS_MODE" \
ZYXEL_UAM_MODE="$UAM_MODE" \
ZYXEL_GATEKEEPER_MODE="$GATEKEEPER_MODE" \
ZYXEL_UAM_LOCKOUT_MODE="$UAM_LOCKOUT_MODE" \
ZYXEL_UAM_TRACE_MODE="$UAM_TRACE_MODE" \
  "$ROOT_DIR/tools/run_zyxel_lab.sh" start >/dev/null || true
build_vendor_binds proc_binds sys_binds dev_binds uam_binds "$RUNROOT"

if [[ "$REQUEST_METHOD" == "POST" ]]; then
  CONTENT_TYPE='application/x-www-form-urlencoded'
  CONTENT_LENGTH="${#PAYLOAD}"
  printf '%s' "$PAYLOAD" | \
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
      --setenv CONTENT_TYPE "$CONTENT_TYPE" \
      --setenv REMOTE_ADDR 127.0.0.1 \
      --setenv HTTP_HOST nap-slogin.nebula.zyxel.com \
      --setenv SCRIPT_NAME "/cgi-bin/$TARGET" \
      /usr/bin/qemu-aarch64-static -strace "/usr/local/lighttpd/cgi-bin/$TARGET" \
      >"$BODY_OUT" 2>"$TRACE_OUT" || true
else
  bwrap \
    --bind "$RUNROOT" / \
    --chdir / \
    --dev /dev \
    "${proc_binds[@]}" \
    "${sys_binds[@]}" \
    "${dev_binds[@]}" \
    "${uam_binds[@]}" \
    --setenv PATH /usr/bin:/bin \
    --setenv REQUEST_METHOD GET \
    --setenv QUERY_STRING "$PAYLOAD" \
    --setenv REMOTE_ADDR 127.0.0.1 \
    --setenv HTTP_HOST nap-slogin.nebula.zyxel.com \
    --setenv SCRIPT_NAME "/cgi-bin/$TARGET" \
    /usr/bin/qemu-aarch64-static -strace "/usr/local/lighttpd/cgi-bin/$TARGET" \
    >"$BODY_OUT" 2>"$TRACE_OUT" || true
fi

cp "$TRACE_OUT" "$STDERR_OUT"

printf 'body=%s\n' "$BODY_OUT"
printf 'trace=%s\n' "$TRACE_OUT"
