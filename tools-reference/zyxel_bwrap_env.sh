#!/usr/bin/env bash

build_proc_binds() {
  local -n out_ref=$1
  local runroot="$2"
  out_ref=(--bind "$runroot/proc" /proc --bind /proc/self /proc/self)
  if [[ -e /proc/thread-self ]]; then
    out_ref+=(--bind /proc/thread-self /proc/thread-self)
  fi
  if [[ -e /proc/uptime ]]; then
    out_ref+=(--bind /proc/uptime /proc/uptime)
  fi
}

build_sys_binds() {
  local -n out_ref=$1
  local runroot="$2"
  out_ref=(--bind "$runroot/sys" /sys)
}

append_console_bind() {
  local -n out_ref=$1
  local runroot="$2"
  if [[ -n "${ZYXEL_CONSOLE_BIND_SOURCE:-}" && -c "${ZYXEL_CONSOLE_BIND_SOURCE:-}" ]]; then
    out_ref+=(--dev-bind "$ZYXEL_CONSOLE_BIND_SOURCE" /dev/console)
  elif [[ -c "$runroot/dev/console" ]]; then
    out_ref+=(--dev-bind "$runroot/dev/console" /dev/console)
  elif [[ -c /dev/console ]]; then
    out_ref+=(--dev-bind /dev/console /dev/console)
  elif [[ -e "$runroot/dev/console" && ! -d "$runroot/dev/console" ]]; then
    out_ref+=(--bind "$runroot/dev/console" /dev/console)
  fi
}

append_vendor_device_binds() {
  local -n out_ref=$1
  local runroot="$2"
  if [[ -f "$runroot/dev/CP_dev" ]]; then
    out_ref+=(--bind "$runroot/dev/CP_dev" /dev/CP_dev)
  fi
  if [[ -f "$runroot/dev/switch0" ]]; then
    out_ref+=(--bind "$runroot/dev/switch0" /dev/switch0)
  fi
}

append_uam_binds() {
  local -n out_ref=$1
  local runroot="$2"
  if [[ -S "$runroot/dev/user-request" ]]; then
    out_ref+=(--bind "$runroot/dev/user-request" /dev/user-request)
  fi
  if [[ -S "$runroot/dev/user-request2" ]]; then
    out_ref+=(--bind "$runroot/dev/user-request2" /dev/user-request2)
  fi
  if [[ -S "$runroot/dev/user-notify" ]]; then
    out_ref+=(--bind "$runroot/dev/user-notify" /dev/user-notify)
  fi
}

build_vendor_binds() {
  local -n proc_ref=$1
  local -n sys_ref=$2
  local -n dev_ref=$3
  local -n uam_ref=$4
  local runroot="$5"

  build_proc_binds proc_ref "$runroot"
  build_sys_binds sys_ref "$runroot"
  dev_ref=()
  append_console_bind dev_ref "$runroot"
  append_vendor_device_binds dev_ref "$runroot"
  uam_ref=()
  append_uam_binds uam_ref "$runroot"
}
