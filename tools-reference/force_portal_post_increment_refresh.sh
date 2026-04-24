#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tools/zyxel_bwrap_env.sh"

RUNROOT="$ROOT_DIR/runroot"
ART_DIR="$ROOT_DIR/live_artifacts"
LABEL="${1:-portal_post_increment_refresh}"
OUT_DIR="$ART_DIR/$LABEL"
SYSTEM_DEFAULT_XML="$RUNROOT/db/etc_writable/zyxel/conf/__system_default.xml"
STARTUP_CONFIG_XML="$RUNROOT/db/etc_writable/zyxel/conf/startup-config.conf.xml"

SSID_PROFILE="${ZYXEL_PORTAL_SSID_PROFILE:-SSID1}"
SSID_NAME="${ZYXEL_PORTAL_SSID_NAME:-zyxel-lab}"
PORTAL_PROFILE="${ZYXEL_PORTAL_PROFILE:-THEME1}"
PATCH_RUNTIME_REFERENCE_BEFORE_REFRESH="${ZYXEL_PATCH_RUNTIME_REFERENCE_BEFORE_REFRESH:-0}"
APPLY_MAX_LOGIN_COUNT="${ZYXEL_APPLY_MAX_LOGIN_COUNT:-1}"
REFRESH_MAX_LOGIN_COUNT="${ZYXEL_REFRESH_MAX_LOGIN_COUNT:-1}"
SEED_SYSTEM_DEFAULT_PROFILE="${ZYXEL_SEED_SYSTEM_DEFAULT_PROFILE:-0}"
SEED_RADIO_PROFILE_SLOTS="${ZYXEL_SEED_RADIO_PROFILE_SLOTS:-0}"
INCLUDE_INTERNAL_PAGE_TOKENS="${ZYXEL_PORTAL_INCLUDE_INTERNAL_PAGE_TOKENS:-1}"
TOUCH_WHYBRID="${ZYXEL_TOUCH_WHYBRID:-1}"
REPAIR_PORTAL_CONFIG_AFTER_REFRESH="${ZYXEL_REPAIR_PORTAL_CONFIG_AFTER_REFRESH:-0}"
REPAIR_PORTAL_POST_LOGIN_STATE="${ZYXEL_REPAIR_PORTAL_POST_LOGIN_STATE:-}"
REPAIR_PORTAL_POST_LOGIN_TARGET="${ZYXEL_REPAIR_PORTAL_POST_LOGIN_TARGET:-}"
PTY_PROMPT_REGEX="${ZYXEL_PTY_PROMPT_REGEX:-Router(?:\\([^)]*\\))?# }"
PTY_PROMPT_WAIT_SEC="${ZYXEL_PTY_PROMPT_WAIT_SEC:-10.0}"
HOST_HEADER="${ZYXEL_PORTAL_HOST_HEADER:-nap-slogin.nebula.zyxel.com}"
BASE_URL="${ZYXEL_PORTAL_BASE_URL:-http://127.0.0.1:8080}"
SOCIAL_LOGIN_PAYLOAD="${ZYXEL_SOCIAL_LOGIN_PAYLOAD:-fb_user=test@example.com}"

export ZYXEL_UAM_MODE="${ZYXEL_UAM_MODE:-vendor-debug}"
export ZYXEL_GATEKEEPER_MODE="${ZYXEL_GATEKEEPER_MODE:-marker-clear}"
export ZYXEL_UAM_LOCKOUT_MODE="${ZYXEL_UAM_LOCKOUT_MODE:-seed}"
export ZYXEL_WIRELESS_HAL_MODE="${ZYXEL_WIRELESS_HAL_MODE:-shim}"

START_CORE_LOG="$OUT_DIR/start_core.log"
CORE_HEALTH_LOG="$OUT_DIR/core_health.txt"
PROMOTE_LOG="$OUT_DIR/promote_full.log"
FULL_HEALTH_LOG="$OUT_DIR/full_health.txt"
PRESEED_CMDS="$OUT_DIR/preseed.commands.txt"
APPLY_CMDS="$OUT_DIR/apply.commands.txt"
REFRESH_CMDS="$OUT_DIR/refresh.commands.txt"
PRESEED_TRANSCRIPT="$OUT_DIR/preseed.transcript.txt"
APPLY_TRANSCRIPT="$OUT_DIR/apply.transcript.txt"
REFRESH_TRANSCRIPT="$OUT_DIR/refresh.transcript.txt"
PRESEED_TRACE="$OUT_DIR/preseed.strace"
APPLY_TRACE="$OUT_DIR/apply.strace"
REFRESH_TRACE="$OUT_DIR/refresh.strace"
CP_LOGIN_HEADERS="$OUT_DIR/cp_login_after_refresh.headers"
CP_LOGIN_BODY="$OUT_DIR/cp_login_after_refresh.body"
CLICK_HEADERS="$OUT_DIR/click_to_continue_after_refresh.headers"
CLICK_BODY="$OUT_DIR/click_to_continue_after_refresh.body"
SOCIAL_HEADERS="$OUT_DIR/social_login_after_refresh.headers"
SOCIAL_BODY="$OUT_DIR/social_login_after_refresh.body"
REPAIR_LOG="$OUT_DIR/repair_portal_config.txt"
CHECKPOINTS="$OUT_DIR/checkpoints.txt"
SUMMARY="$OUT_DIR/summary.txt"

CORE_HEALTH_OK="no"
FULL_HEALTH_OK="no"
PRESEED_EXIT="not_run"
APPLY_EXIT="not_run"
REFRESH_EXIT="not_run"

mkdir -p "$OUT_DIR"

cleanup() {
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_bwrap_pty() {
  local command_file="$1"
  local transcript="$2"
  local trace_log="$3"
  local proc_bind=()
  local sys_bind=()
  local dev_bind=()
  local uam_bind=()
  local pty_args=()

  build_vendor_binds proc_bind sys_bind dev_bind uam_bind "$RUNROOT"
  if [[ -n "$PTY_PROMPT_REGEX" ]]; then
    pty_args+=(
      --prompt-regex "$PTY_PROMPT_REGEX"
      --prompt-wait-sec "$PTY_PROMPT_WAIT_SEC"
    )
  fi

  python3 "$ROOT_DIR/tools/run_zysh_pty.py" \
    --commands-file "$command_file" \
    --transcript "$transcript" \
    --trace-log "$trace_log" \
    --timeout-sec 45 \
    --startup-wait-sec 1.0 \
    --step-wait-sec 0.6 \
    --tail-wait-sec 2.0 \
    "${pty_args[@]}" \
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

write_command_files() {
  cat >"$PRESEED_CMDS" <<'EOF'
no netconf inactivate
hybrid-mode cloud
manager ap no login-ip
write
exit
exit
EOF

  {
    cat <<EOF
captive-portal-profile $PORTAL_PROFILE
method click-through
EOF
    if [[ "$INCLUDE_INTERNAL_PAGE_TOKENS" == "1" ]]; then
      cat <<'EOF'
portal-type internal
success-page internal
EOF
    fi
    cat <<EOF
max-login-count $APPLY_MAX_LOGIN_COUNT
exit
EOF
    cat <<EOF
wlan-ssid-profile $SSID_PROFILE
ssid $SSID_NAME
captive-portal $PORTAL_PROFILE
EOF
    cat <<'EOF'
exit
write
exit
exit
EOF
  } >"$APPLY_CMDS"

  {
    cat <<EOF
captive-portal-profile $PORTAL_PROFILE
method click-through
EOF
    if [[ "$INCLUDE_INTERNAL_PAGE_TOKENS" == "1" ]]; then
      cat <<'EOF'
portal-type internal
success-page internal
EOF
    fi
    cat <<EOF
max-login-count $REFRESH_MAX_LOGIN_COUNT
exit
write
exit
exit
EOF
  } >"$REFRESH_CMDS"
}

prepare_runtime() {
  "$ROOT_DIR/tools/run_zyxel_lab.sh" stop >/dev/null 2>&1 || true
  rm -rf "$RUNROOT"
  python3 "$ROOT_DIR/tools/prepare_zyxel_runroot.py" \
    --src "$ROOT_DIR/710ABRM4C0_extracted/rootfs" \
    --dst "$RUNROOT" >/dev/null
  python3 "$ROOT_DIR/tools/prepare_portal_runtime.py" \
    --runroot "$RUNROOT" \
    --mode synthetic-minimal \
    --theme "$PORTAL_PROFILE" \
    --ssid-profile "$SSID_PROFILE" \
    --ssid-name "$SSID_NAME" \
    --write-includes \
    --hydrate-assets \
    --bootstrap-state \
    ${SEED_SYSTEM_DEFAULT_PROFILE:+$([[ "$SEED_SYSTEM_DEFAULT_PROFILE" == "1" ]] && printf '%s' '--seed-system-default-profile')} \
    ${SEED_RADIO_PROFILE_SLOTS:+$([[ "$SEED_RADIO_PROFILE_SLOTS" == "1" ]] && printf '%s' '--seed-radio-profile-slots')} \
    --skip-portal-config >/dev/null
  rm -f \
    "$RUNROOT/tmp/portal_config" \
    "$RUNROOT/var/zyxel/portal_info" \
    "$RUNROOT/var/portal_info.tmp" \
    "$RUNROOT/tmp/whybrid"
}

extract_captive_reference() {
  local path="$1"
  if [[ -f "$path" ]]; then
    perl -0777 -ne 'print "$1\n" if /<captive_profile_list name="\Q'"$PORTAL_PROFILE"'\E"[^>]*reference="([^"]+)"/s' \
      "$path" | head -n 1
  fi
}

extract_ssid_binding() {
  local path="$1"
  if [[ -f "$path" ]]; then
    perl -0777 -ne 'print "$1\n" if /<ssid_profile_list name="\Q'"$SSID_PROFILE"'\E".*?<Captive_profile>([^<]*)<\/Captive_profile>/s' \
      "$path" | head -n 1
  fi
}

copy_checkpoint_xmls() {
  local prefix="$1"
  [[ -f "$STARTUP_CONFIG_XML" ]] && cp -f "$STARTUP_CONFIG_XML" "$OUT_DIR/${prefix}.startup-config.conf.xml"
  [[ -f "$SYSTEM_DEFAULT_XML" ]] && cp -f "$SYSTEM_DEFAULT_XML" "$OUT_DIR/${prefix}.__system_default.xml"
  [[ -f "$RUNROOT/tmp/captive_profile_db.xml" ]] && cp -f "$RUNROOT/tmp/captive_profile_db.xml" "$OUT_DIR/${prefix}.captive_profile_db.xml"
  [[ -f "$RUNROOT/tmp/ssid_profile_db.xml" ]] && cp -f "$RUNROOT/tmp/ssid_profile_db.xml" "$OUT_DIR/${prefix}.ssid_profile_db.xml"
  [[ -f "$RUNROOT/tmp/radio_profile_db.xml" ]] && cp -f "$RUNROOT/tmp/radio_profile_db.xml" "$OUT_DIR/${prefix}.radio_profile_db.xml"
  [[ -f "$RUNROOT/tmp/wlan_slot_db.xml" ]] && cp -f "$RUNROOT/tmp/wlan_slot_db.xml" "$OUT_DIR/${prefix}.wlan_slot_db.xml"
  [[ -f "$RUNROOT/var/zyxel/portal_info" ]] && cp -f "$RUNROOT/var/zyxel/portal_info" "$OUT_DIR/${prefix}.portal_info.txt"
}

record_checkpoint() {
  local prefix="$1"
  {
    echo "${prefix}_saved_captive_reference=$(extract_captive_reference "$STARTUP_CONFIG_XML" || true)"
    echo "${prefix}_system_default_captive_reference=$(extract_captive_reference "$SYSTEM_DEFAULT_XML" || true)"
    echo "${prefix}_runtime_captive_db_reference=$(extract_captive_reference "$RUNROOT/tmp/captive_profile_db.xml" || true)"
    echo "${prefix}_runtime_ssid_db_captive_profile=$(extract_ssid_binding "$RUNROOT/tmp/ssid_profile_db.xml" || true)"
    echo "${prefix}_portal_config_exists=$(test -e "$RUNROOT/tmp/portal_config" && echo yes || echo no)"
    echo "${prefix}_portal_info_exists=$(test -e "$RUNROOT/var/zyxel/portal_info" && echo yes || echo no)"
  } >>"$CHECKPOINTS"
  copy_checkpoint_xmls "$prefix"
}

patch_runtime_reference() {
  [[ -f "$RUNROOT/tmp/captive_profile_db.xml" ]] || return 1
  PORTAL_PROFILE="$PORTAL_PROFILE" perl -0pi -e '
    s{(<captive_profile_list name="\Q$ENV{PORTAL_PROFILE}\E"[^>]*reference=")[^"]*(")}
     {$1 . "1" . $2}gse
  ' "$RUNROOT/tmp/captive_profile_db.xml"
}

capture_portal_http() {
  local curl_common=(-sS --max-time 10 -H "Host: $HOST_HEADER")

  curl -D "$CP_LOGIN_HEADERS" -o "$CP_LOGIN_BODY" \
    "${curl_common[@]}" \
    "$BASE_URL/CP/$PORTAL_PROFILE/login.html" || true

  curl -D "$CLICK_HEADERS" -o "$CLICK_BODY" \
    "${curl_common[@]}" \
    -X POST \
    --data '' \
    "$BASE_URL/cgi-bin/Clicktocontinue.cgi" || true

  curl -D "$SOCIAL_HEADERS" -o "$SOCIAL_BODY" \
    "${curl_common[@]}" \
    -X POST \
    --data "$SOCIAL_LOGIN_PAYLOAD" \
    "$BASE_URL/cgi-bin/social_login.cgi" || true
}

repair_portal_config() {
  local repair_args=(
    --runroot "$RUNROOT"
    --theme "$PORTAL_PROFILE"
  )

  if [[ -n "$REPAIR_PORTAL_POST_LOGIN_STATE" ]]; then
    repair_args+=(--post-login-state "$REPAIR_PORTAL_POST_LOGIN_STATE")
  fi
  if [[ -n "$REPAIR_PORTAL_POST_LOGIN_TARGET" ]]; then
    repair_args+=(--post-login-target "$REPAIR_PORTAL_POST_LOGIN_TARGET")
  fi

  python3 "$ROOT_DIR/tools/repair_portal_config.py" "${repair_args[@]}" >"$REPAIR_LOG"
}

write_summary() {
  local result_class="negative_refresh_confirmation"
  if [[ "$(test -e "$RUNROOT/tmp/portal_config" && echo yes || echo no)" == "yes" ]]; then
    result_class="positive_refresh_confirmation"
  fi

  {
    echo "label=$LABEL"
    echo "transport=core-plus-promote-full-plus-pty-plus-post-increment-refresh"
    echo "result_class=$result_class"
    echo "patch_runtime_reference_before_refresh=$PATCH_RUNTIME_REFERENCE_BEFORE_REFRESH"
    echo "apply_max_login_count=$APPLY_MAX_LOGIN_COUNT"
    echo "refresh_max_login_count=$REFRESH_MAX_LOGIN_COUNT"
    echo "seed_system_default_profile=$SEED_SYSTEM_DEFAULT_PROFILE"
    echo "seed_radio_profile_slots=$SEED_RADIO_PROFILE_SLOTS"
    echo "repair_portal_config_after_refresh=$REPAIR_PORTAL_CONFIG_AFTER_REFRESH"
    echo "repair_portal_post_login_state=${REPAIR_PORTAL_POST_LOGIN_STATE:-}"
    echo "repair_portal_post_login_target=${REPAIR_PORTAL_POST_LOGIN_TARGET:-}"
    echo "ssid_profile=$SSID_PROFILE"
    echo "ssid_name=$SSID_NAME"
    echo "portal_profile=$PORTAL_PROFILE"
    echo "core_health_ok=$CORE_HEALTH_OK"
    echo "full_health_ok=$FULL_HEALTH_OK"
    echo "preseed_exit=$PRESEED_EXIT"
    echo "apply_exit=$APPLY_EXIT"
    echo "refresh_exit=$REFRESH_EXIT"
    echo "portal_config_exists=$(test -e "$RUNROOT/tmp/portal_config" && echo yes || echo no)"
    echo "portal_info_exists=$(test -e "$RUNROOT/var/zyxel/portal_info" && echo yes || echo no)"
    echo "whybrid_exists=$(test -e "$RUNROOT/tmp/whybrid" && echo yes || echo no)"
    echo "cp_login_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$CP_LOGIN_HEADERS" 2>/dev/null || true)"
    echo "click_to_continue_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$CLICK_HEADERS" 2>/dev/null || true)"
    echo "social_login_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2; exit}' "$SOCIAL_HEADERS" 2>/dev/null || true)"
    echo
    echo "[checkpoints]"
    sed -n '1,80p' "$CHECKPOINTS" || true
    echo
    echo "[portal_info]"
    sed -n '1,40p' "$RUNROOT/var/zyxel/portal_info" || true
    echo
    echo "[apply transcript tail]"
    tail -n 120 "$APPLY_TRANSCRIPT" || true
    echo
    echo "[refresh transcript tail]"
    tail -n 120 "$REFRESH_TRANSCRIPT" || true
    echo
    echo "[refresh trace refs]"
    rg -n 'portal_config|portal_info|whybrid|captive_profile_db|ssid_profile_db|THEME1|SSID1' \
      "$REFRESH_TRACE" || true
  } >"$SUMMARY"
}

prepare_runtime
write_command_files

if "$ROOT_DIR/tools/run_zyxel_lab.sh" start --phase core >"$START_CORE_LOG" 2>&1; then
  :
fi
if "$ROOT_DIR/tools/run_zyxel_lab.sh" health --phase core >"$CORE_HEALTH_LOG" 2>&1; then
  CORE_HEALTH_OK="yes"
fi
if "$ROOT_DIR/tools/run_zyxel_lab.sh" promote-full >"$PROMOTE_LOG" 2>&1; then
  :
fi
if "$ROOT_DIR/tools/run_zyxel_lab.sh" health --phase full >"$FULL_HEALTH_LOG" 2>&1; then
  FULL_HEALTH_OK="yes"
fi

if run_bwrap_pty "$PRESEED_CMDS" "$PRESEED_TRANSCRIPT" "$PRESEED_TRACE"; then
  PRESEED_EXIT="0"
else
  PRESEED_EXIT="$?"
fi

if [[ "$TOUCH_WHYBRID" == "1" ]]; then
  touch "$RUNROOT/tmp/whybrid"
fi

if run_bwrap_pty "$APPLY_CMDS" "$APPLY_TRANSCRIPT" "$APPLY_TRACE"; then
  APPLY_EXIT="0"
else
  APPLY_EXIT="$?"
fi
record_checkpoint "after_apply"

if [[ "$PATCH_RUNTIME_REFERENCE_BEFORE_REFRESH" == "1" ]]; then
  if patch_runtime_reference; then
    record_checkpoint "after_runtime_patch"
  fi
fi

if run_bwrap_pty "$REFRESH_CMDS" "$REFRESH_TRANSCRIPT" "$REFRESH_TRACE"; then
  REFRESH_EXIT="0"
else
  REFRESH_EXIT="$?"
fi

record_checkpoint "after_refresh"
if [[ "$REPAIR_PORTAL_CONFIG_AFTER_REFRESH" == "1" && ! -e "$RUNROOT/tmp/portal_config" ]]; then
  repair_portal_config
  record_checkpoint "after_repair"
fi
capture_portal_http
write_summary
echo "$OUT_DIR"
