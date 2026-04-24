#!/usr/bin/env bash

zyxel_console_pid_is_live() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

zyxel_wait_for_console_path() {
  local path_file="$1"
  local attempts="${2:-50}"
  local i
  local console_path
  for ((i=0; i<attempts; i++)); do
    if [[ -s "$path_file" ]]; then
      console_path="$(head -n 1 "$path_file" 2>/dev/null || true)"
      if [[ -n "$console_path" && -c "$console_path" ]]; then
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "Timed out waiting for PTY console path in $path_file" >&2
  return 1
}

zyxel_start_console_pty() {
  local root_dir="$1"
  local state_dir="$2"
  local pid_file="$state_dir/console_pty.pid"
  local path_file="$state_dir/console_pty.path"
  local log_file="$state_dir/console_pty.log"
  local stdout_log="$state_dir/console_pty.stdout.log"
  local console_path

  mkdir -p "$state_dir"

  if ! zyxel_console_pid_is_live "$pid_file"; then
    rm -f "$pid_file" "$path_file"
    nohup python3 "$root_dir/tools/hold_pty_console.py" \
      --path-file "$path_file" \
      --log "$log_file" \
      >"$stdout_log" 2>&1 &
    echo $! >"$pid_file"
  fi

  zyxel_wait_for_console_path "$path_file"
  console_path="$(head -n 1 "$path_file")"
  export ZYXEL_CONSOLE_BIND_SOURCE="$console_path"
}

zyxel_stop_console_pty() {
  local state_dir="$1"
  local pid_file="$state_dir/console_pty.pid"
  local path_file="$state_dir/console_pty.path"

  if zyxel_console_pid_is_live "$pid_file"; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
  fi
  rm -f "$pid_file" "$path_file"
  unset ZYXEL_CONSOLE_BIND_SOURCE
}
