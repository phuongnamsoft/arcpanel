#!/usr/bin/env bash
#
# Start Arcpanel local dev stack: arc-agent (sudo), arc-api, Vite (panel/frontend).
# For WSL2 Ubuntu; see docs/project-docs/development-local-setup-wsl2.md
#
# Usage (from repository root, after build):
#   bash scripts/wsl2-start-services.sh          # start in background, write logs + pids
#   bash scripts/wsl2-start-services.sh stop     # stop processes started by this script
#   bash scripts/wsl2-start-services.sh status   # show listening ports / pid files
#
# Environment:
#   API_ENV_PATH=/etc/arcpanel/api.env
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
API_ENV_PATH="${API_ENV_PATH:-/etc/arcpanel/api.env}"
STATE_DIR="${REPO_ROOT}/.arcpanel-wsl2-dev"
LOG_DIR="${STATE_DIR}/logs"
PID_DIR="${STATE_DIR}/pids"

AGENT_BIN="${REPO_ROOT}/panel/agent/target/release/arc-agent"
API_BIN="${REPO_ROOT}/panel/backend/target/release/arc-api"

log() { printf '%s\n' "$*"; }
die() { log "Error: $*" >&2; exit 1; }

usage() {
  log "Usage: $0 [start|stop|status]"
  log "  (default) start — background agent, API, and Vite; logs under ${LOG_DIR}"
  log "  stop      — terminate processes recorded in ${PID_DIR}"
  log "  status    — show pid files and suggest health checks"
}

cmd="${1:-start}"

ensure_built() {
  [ -x "${AGENT_BIN}" ] || die "missing ${AGENT_BIN} — run cargo build --release --manifest-path panel/agent/Cargo.toml"
  [ -x "${API_BIN}" ] || die "missing ${API_BIN} — run cargo build --release --manifest-path panel/backend/Cargo.toml"
  [ -f "${REPO_ROOT}/panel/frontend/package.json" ] || die "frontend missing at panel/frontend/"
}

ensure_env() {
  [ -r "${API_ENV_PATH}" ] || die "missing ${API_ENV_PATH} — run scripts/wsl2-setup-dev-environment.sh"
}

load_env() {
  set -a
  # shellcheck source=/dev/null
  source "${API_ENV_PATH}"
  set +a
  [ -n "${AGENT_TOKEN:-}" ] || die "AGENT_TOKEN not set in ${API_ENV_PATH}"
  [ -n "${AGENT_SOCKET:-}" ] || die "AGENT_SOCKET not set in ${API_ENV_PATH}"
}

do_start() {
  ensure_built
  ensure_env
  load_env

  mkdir -p "${LOG_DIR}" "${PID_DIR}"

  if [ -f "${PID_DIR}/agent.pid" ] && kill -0 "$(cat "${PID_DIR}/agent.pid")" 2>/dev/null; then
    die "agent already running (pid $(cat "${PID_DIR}/agent.pid")). Run: $0 stop"
  fi
  if [ -f "${PID_DIR}/api.pid" ] && kill -0 "$(cat "${PID_DIR}/api.pid")" 2>/dev/null; then
    die "api already running (pid $(cat "${PID_DIR}/api.pid")). Run: $0 stop"
  fi
  if [ -f "${PID_DIR}/frontend.pid" ] && kill -0 "$(cat "${PID_DIR}/frontend.pid")" 2>/dev/null; then
    die "frontend already running (pid $(cat "${PID_DIR}/frontend.pid")). Run: $0 stop"
  fi

  log "Starting arc-agent (sudo)..."
  agent_pid="$(
    # shellcheck disable=SC2016
    sudo -E env PATH="${PATH}" AGENT_TOKEN="${AGENT_TOKEN}" AGENT_SOCKET="${AGENT_SOCKET}" \
      bash -c "cd '${REPO_ROOT}' && nohup '${AGENT_BIN}' >'${LOG_DIR}/agent.log' 2>&1 & echo \$!"
  )"
  echo "${agent_pid}" >"${PID_DIR}/agent.pid"

  log "Starting arc-api..."
  (
    cd "${REPO_ROOT}"
    set -a
    # shellcheck source=/dev/null
    source "${API_ENV_PATH}"
    set +a
    nohup "${API_BIN}" >"${LOG_DIR}/api.log" 2>&1 &
    echo $! >"${PID_DIR}/api.pid"
  )

  # Wait briefly for API to bind (avoids instant frontend proxy failures)
  sleep 1

  log "Starting Vite (npm run dev)..."
  (
    cd "${REPO_ROOT}/panel/frontend"
    nohup npm run dev >"${LOG_DIR}/frontend.log" 2>&1 &
    echo $! >"${PID_DIR}/frontend.pid"
  )

  log ""
  log "Started. Logs:"
  log "  ${LOG_DIR}/agent.log"
  log "  ${LOG_DIR}/api.log"
  log "  ${LOG_DIR}/frontend.log"
  log ""
  log "Health:  curl -sS http://${LISTEN_ADDR}/api/health"
  log "UI:      see ${LOG_DIR}/frontend.log for the Vite URL (usually http://127.0.0.1:5173)"
  log "Stop:    $0 stop"
}

do_stop() {
  for name in frontend api agent; do
    f="${PID_DIR}/${name}.pid"
    if [ -f "$f" ]; then
      pid="$(cat "$f" || true)"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        log "Stopping ${name} (pid ${pid})..."
        if [ "${name}" = agent ]; then
          sudo kill "${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
        else
          kill "${pid}" 2>/dev/null || true
        fi
      fi
    fi
    rm -f "$f"
  done
  # npm may leave a child node process; best-effort cleanup on common port
  pkill -f "panel/frontend/node_modules/.bin/vite" 2>/dev/null || true
  log "Stop complete."
}

do_status() {
  log "State directory: ${STATE_DIR}"
  for name in agent api frontend; do
    f="${PID_DIR}/${name}.pid"
    if [ -f "$f" ]; then
      pid="$(cat "$f" || true)"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        log "  ${name}: pid ${pid} (running)"
      else
        log "  ${name}: stale pid file ${f}"
      fi
    else
      log "  ${name}: no pid file"
    fi
  done
  log ""
  log "ss listeners (3062=api, 5173=vite, 5450=postgres):"
  ss -tlnp 2>/dev/null | grep -E '(:3062|:5173|:5450)\b' || log "  (install iproute2 for ss, or use: curl -sS http://127.0.0.1:3062/api/health)"
}

case "${cmd}" in
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  -h|--help|help) usage ;;
  *) die "unknown command: ${cmd}" ;;
esac
