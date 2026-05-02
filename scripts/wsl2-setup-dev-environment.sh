#!/usr/bin/env bash
#
# One-time (or idempotent) panel dev environment: PostgreSQL in Docker, /etc/arcpanel/api.env, agent socket dir.
# Intended for WSL2 Ubuntu; see docs/project-docs/development-local-setup-wsl2.md
#
# Usage (from repository root):
#   bash scripts/wsl2-setup-dev-environment.sh
#
# Environment overrides:
#   POSTGRES_CONTAINER=arc-postgres  POSTGRES_PORT=5450
#   POSTGRES_USER=arc  POSTGRES_PASSWORD=changeme  POSTGRES_DB=arc_panel
#   API_ENV_PATH=/etc/arcpanel/api.env
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-arc-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5450}"
POSTGRES_USER="${POSTGRES_USER:-arc}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-changeme}"
POSTGRES_DB="${POSTGRES_DB:-arc_panel}"
PG_IMAGE="${PG_IMAGE:-postgres:16}"
API_ENV_PATH="${API_ENV_PATH:-/etc/arcpanel/api.env}"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:3062}"
RUNTIME_DIR="${RUNTIME_DIR:-/var/run/arcpanel}"

log() { printf '%s\n' "$*"; }
die() { log "Error: $*" >&2; exit 1; }

if ! command -v docker &>/dev/null; then
  die "docker not found; complete scripts/wsl2-install-prerequisites.sh and Docker Desktop setup first"
fi
if ! docker info &>/dev/null; then
  log "docker info failed: $(docker info 2>&1 || true)"
  die "cannot connect to Docker daemon — fix Docker Desktop WSL integration or start docker service (see scripts/wsl2-install-prerequisites.sh messages)"
fi

ensure_postgres_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "${POSTGRES_CONTAINER}"; then
    if docker ps --format '{{.Names}}' | grep -Fxq "${POSTGRES_CONTAINER}"; then
      log "Postgres container '${POSTGRES_CONTAINER}' already running."
    else
      log "Starting existing container '${POSTGRES_CONTAINER}'..."
      docker start "${POSTGRES_CONTAINER}"
    fi
  else
    log "Creating Postgres container '${POSTGRES_CONTAINER}' (host port ${POSTGRES_PORT} -> 5432)..."
    docker run -d --name "${POSTGRES_CONTAINER}" \
      -e "POSTGRES_USER=${POSTGRES_USER}" \
      -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
      -e "POSTGRES_DB=${POSTGRES_DB}" \
      -p "${POSTGRES_PORT}:5432" \
      "${PG_IMAGE}"
  fi
}

ensure_postgres_container

log "Waiting for Postgres to accept connections..."
for _ in $(seq 1 30); do
  if docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; then
    break
  fi
  sleep 1
done
if ! docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; then
  die "Postgres did not become ready; check: docker logs ${POSTGRES_CONTAINER}"
fi

if [ -f "${API_ENV_PATH}" ]; then
  log "Keeping existing ${API_ENV_PATH} (remove it to regenerate)."
else
  log "Creating ${API_ENV_PATH}..."
  command -v openssl &>/dev/null || die "openssl is required"
  JWT_SECRET="$(openssl rand -hex 32)"
  if command -v uuidgen &>/dev/null; then
    AGENT_TOKEN="$(uuidgen)"
  else
    AGENT_TOKEN="$(openssl rand -hex 32)"
  fi
  sudo mkdir -p "$(dirname "${API_ENV_PATH}")"
  tmp_env="$(mktemp)"
  {
    echo "DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB}"
    echo "JWT_SECRET=${JWT_SECRET}"
    echo "AGENT_SOCKET=${RUNTIME_DIR}/agent.sock"
    echo "AGENT_TOKEN=${AGENT_TOKEN}"
    echo "LISTEN_ADDR=${LISTEN_ADDR}"
  } >"${tmp_env}"
  sudo install -m 600 -T "${tmp_env}" "${API_ENV_PATH}"
  rm -f "${tmp_env}"
  log "Wrote secrets to ${API_ENV_PATH} (matches Vite proxy port 3062; see panel/frontend/vite.config.ts)"
fi

log "Creating agent runtime directory ${RUNTIME_DIR}..."
sudo mkdir -p "${RUNTIME_DIR}"
sudo chmod 755 "${RUNTIME_DIR}"

log ""
log "Environment ready. Repository root: ${REPO_ROOT}"
log "Build (from repo root):"
log "  cargo build --release --manifest-path panel/agent/Cargo.toml"
log "  cargo build --release --manifest-path panel/backend/Cargo.toml"
log "  cargo build --release --manifest-path panel/cli/Cargo.toml"
log "  (cd panel/frontend && npm ci)"
log "Then start services:"
log "  bash scripts/wsl2-start-services.sh"
