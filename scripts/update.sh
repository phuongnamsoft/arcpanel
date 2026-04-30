#!/usr/bin/env bash
#
# Arcpanel Updater
# Pulls latest code, rebuilds binaries + frontend, restarts services.
# Preserves database, secrets, and configuration.
#
# Usage: bash scripts/update.sh
#        INSTALL_FROM_RELEASE=1 bash scripts/update.sh  # Download pre-built binaries
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[x]${NC} $1" >&2; }

# ── Checks ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "Run as root"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_SRC="$REPO_DIR/panel/agent"
API_SRC="$REPO_DIR/panel/backend"
CLI_SRC="$REPO_DIR/panel/cli"
FRONTEND_DIR="$REPO_DIR/panel/frontend"
AGENT_BIN="/usr/local/bin/arc-agent"
API_BIN="/usr/local/bin/arc-api"
CLI_BIN="/usr/local/bin/arc"
INSTALL_FROM_RELEASE="${INSTALL_FROM_RELEASE:-0}"
GITHUB_REPO="phuongnamsoft/arcpanel"

# ── Self-refresh ──────────────────────────────────────────────────────────
# In binary-release mode, the on-disk copy of this script can lag the
# repo by several releases (it's only refreshed by re-running install.sh).
# That means a bug in update.sh — like the 405-rollback bug fixed in
# v2.7.13 — strands operators unable to upgrade. Pull the latest script
# from the latest release tag and re-exec ourselves before running any
# update logic. SELF_REFRESHED=1 prevents an infinite re-exec loop.
if [ "${SELF_REFRESHED:-0}" != "1" ] && [ "$INSTALL_FROM_RELEASE" = "1" ]; then
    LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)
    if [ -n "$LATEST_TAG" ]; then
        REMOTE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${LATEST_TAG}/scripts/update.sh"
        TMP=$(mktemp)
        if curl -fsSL "$REMOTE_URL" -o "$TMP" 2>/dev/null && [ -s "$TMP" ]; then
            # Compare to current to avoid an unnecessary re-exec on every run
            if ! cmp -s "$TMP" "${BASH_SOURCE[0]}"; then
                log "Refreshing update.sh from $LATEST_TAG (current copy is stale)"
                cp "$TMP" "${BASH_SOURCE[0]}" 2>/dev/null || true
                rm -f "$TMP"
                export SELF_REFRESHED=1
                exec bash "${BASH_SOURCE[0]}" "$@"
            fi
            rm -f "$TMP"
        else
            rm -f "$TMP"
        fi
    fi
fi

# Auto-detect: if no source available, use release binaries
if [ "$INSTALL_FROM_RELEASE" != "1" ] && [ ! -d "$AGENT_SRC/src" ]; then
    log "No source found — switching to pre-built binary download"
    INSTALL_FROM_RELEASE=1
fi

# For source builds, verify source exists
if [ "$INSTALL_FROM_RELEASE" != "1" ] && [ ! -d "$AGENT_SRC/src" ]; then
    error "Cannot find agent source at $AGENT_SRC"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}Arcpanel Updater${NC}"
echo ""

# ── Pull latest code (only for source builds) ────────────────────────────
if [ "$INSTALL_FROM_RELEASE" != "1" ] && [ -d "$REPO_DIR/.git" ]; then
    log "Pulling latest changes..."
    (cd "$REPO_DIR" && git stash -q 2>/dev/null; git pull --ff-only; git stash pop -q 2>/dev/null || true) || {
        error "Git pull failed. Resolve conflicts manually."
        exit 1
    }
fi

# ── Backup database before upgrade ────────────────────────────────────────
BACKUP_DIR="/var/backups/arcpanel/db"
mkdir -p "$BACKUP_DIR"
log "Backing up database..."
if docker exec arc-postgres pg_dump -U arc arc_panel | gzip > "$BACKUP_DIR/pre-upgrade-$(date +%Y%m%d%H%M%S).sql.gz"; then
    log "Database backup saved to $BACKUP_DIR/"
else
    error "Database backup failed, aborting upgrade"
    exit 1
fi

# ── Build or download binaries ────────────────────────────────────────────
if [ "$INSTALL_FROM_RELEASE" = "1" ]; then
    # Download pre-built binaries from GitHub Releases
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  DL_ARCH="amd64" ;;
        aarch64) DL_ARCH="arm64" ;;
        *) error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    log "Fetching latest release..."
    RELEASE_TAG=$(curl -sf "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    if [ -z "$RELEASE_TAG" ]; then
        error "Could not determine latest release. Check https://github.com/${GITHUB_REPO}/releases"
        exit 1
    fi
    log "Latest release: $RELEASE_TAG"
    BASE_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"

    log "Downloading agent (${DL_ARCH})..."
    curl -sfL "${BASE_URL}/arc-agent-linux-${DL_ARCH}" -o /tmp/arc-agent-new
    chmod +x /tmp/arc-agent-new

    log "Downloading API (${DL_ARCH})..."
    curl -sfL "${BASE_URL}/arc-api-linux-${DL_ARCH}" -o /tmp/arc-api-new
    chmod +x /tmp/arc-api-new

    log "Downloading CLI (${DL_ARCH})..."
    curl -sfL "${BASE_URL}/arc-linux-${DL_ARCH}" -o /tmp/arcpanel-cli-new
    chmod +x /tmp/arcpanel-cli-new

    # Download and extract frontend
    log "Downloading frontend..."
    curl -sfL "${BASE_URL}/arcpanel-frontend.tar.gz" -o /tmp/arcpanel-frontend.tar.gz
    FE_DIR="/opt/arcpanel/frontend"
    mkdir -p "$FE_DIR"
    tar xzf /tmp/arcpanel-frontend.tar.gz -C "$FE_DIR"
    rm -f /tmp/arcpanel-frontend.tar.gz
    log "Frontend updated"
else
    # Build from source
    # Detect Rust toolchain
    if command -v cargo &> /dev/null; then
        CARGO_CMD="cargo"
    elif [ -f "$HOME/.cargo/bin/cargo" ]; then
        CARGO_CMD="$HOME/.cargo/bin/cargo"
    else
        error "Rust toolchain not found. Install with: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        error "Or use: INSTALL_FROM_RELEASE=1 bash scripts/update.sh"
        exit 1
    fi

    log "Building agent..."
    (cd "$AGENT_SRC" && $CARGO_CMD build --release 2>&1 | tail -1)

    log "Building API..."
    (cd "$API_SRC" && $CARGO_CMD build --release 2>&1 | tail -1)

    log "Building CLI..."
    (cd "$CLI_SRC" && $CARGO_CMD build --release 2>&1 | tail -1)

    if [ -d "$FRONTEND_DIR" ]; then
        log "Building frontend..."
        (cd "$FRONTEND_DIR" && npm ci --silent 2>/dev/null || npm install --silent 2>/dev/null)
        (cd "$FRONTEND_DIR" && npx vite build 2>&1 | tail -3)
        log "Frontend rebuilt"
    fi
fi

# ── Ensure required directories exist (may be new in this version) ────────
log "Ensuring required directories exist..."
mkdir -p /etc/arcpanel/ssl /var/run/arcpanel /var/backups/arcpanel
mkdir -p /var/www/acme/.well-known/acme-challenge
mkdir -p /var/lib/arcpanel/git
# Directories needed by agent ReadWritePaths (created only if missing)
for d in /etc/postfix /etc/dovecot /var/vmail /var/spool/postfix /run/opendkim /var/lib/nginx; do
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
done
echo "d /run/arcpanel 0755 root root -" > /etc/tmpfiles.d/arcpanel.conf 2>/dev/null || true

# ── Refresh systemd service files (may have changed between versions) ─────
log "Updating systemd service files..."
cat > /etc/systemd/system/arc-agent.service << 'EOF'
[Unit]
Description=Arcpanel Agent
After=network.target nginx.service
Wants=nginx.service
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'mkdir -p /run/arcpanel /var/lib/arcpanel/git'
ExecStart=/usr/local/bin/arc-agent
ExecStartPost=/bin/sh -c 'sleep 1 && chgrp $(getent group www-data >/dev/null 2>&1 && echo www-data || echo nginx) /var/run/arcpanel/agent.sock 2>/dev/null; chmod 660 /var/run/arcpanel/agent.sock 2>/dev/null; true'
Restart=always
RestartSec=5
Environment=RUST_LOG=info
NoNewPrivileges=no
ProtectSystem=no
ProtectHome=no
PrivateTmp=no
ProtectKernelLogs=yes
ProtectKernelModules=yes
MemoryMax=512M
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/arc-api.service << 'EOF'
[Unit]
Description=Arcpanel API
After=network.target docker.service arc-agent.service
Wants=arc-agent.service
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
ExecStart=/usr/local/bin/arc-api
Restart=always
RestartSec=5
Environment=RUST_LOG=info
EnvironmentFile=/etc/arcpanel/api.env
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectSystem=no
ReadWritePaths=/var/run/arcpanel /tmp
MemoryMax=1G
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# ── Update nginx frontend path if needed ──────────────────────────────────
if [ "$INSTALL_FROM_RELEASE" = "1" ]; then
    FE_DIST="/opt/arcpanel/frontend/dist"
    for conf in /etc/nginx/sites-enabled/arcpanel-panel.conf /etc/nginx/conf.d/arcpanel-panel.conf; do
        if [ -f "$conf" ] && grep -q "panel/frontend/dist" "$conf" 2>/dev/null; then
            sed -i "s|/opt/arcpanel/panel/frontend/dist|${FE_DIST}|g" "$conf"
            log "Updated nginx frontend path in $conf"
            nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1
        fi
    done
fi

# Ensure BASE_URL is set in api.env for CORS
if [ -f /etc/arcpanel/api.env ] && ! grep -q "BASE_URL" /etc/arcpanel/api.env; then
    # Detect panel URL from nginx config
    PANEL_DOMAIN=""
    for conf in /etc/nginx/sites-enabled/arcpanel-panel.conf /etc/nginx/conf.d/arcpanel-panel.conf; do
        if [ -f "$conf" ]; then
            PANEL_DOMAIN=$(grep "server_name" "$conf" | head -1 | awk '{print $2}' | tr -d ';')
            break
        fi
    done
    if [ -n "$PANEL_DOMAIN" ] && [ "$PANEL_DOMAIN" != "_" ]; then
        echo "BASE_URL=https://${PANEL_DOMAIN}" >> /etc/arcpanel/api.env
        log "Added BASE_URL=https://${PANEL_DOMAIN} to api.env"
    fi
fi

# ── Deploy binaries ───────────────────────────────────────────────────────
# Note: ~2-5s downtime during binary swap is expected for self-hosted deployments.
log "Backing up current binaries..."
cp "$AGENT_BIN" "${AGENT_BIN}.bak" 2>/dev/null || true
cp "$API_BIN" "${API_BIN}.bak" 2>/dev/null || true
cp "$CLI_BIN" "${CLI_BIN}.bak" 2>/dev/null || true

log "Stopping services..."
systemctl stop arc-agent arc-api 2>/dev/null || true

if [ "$INSTALL_FROM_RELEASE" = "1" ]; then
    mv /tmp/arc-agent-new "$AGENT_BIN"
    mv /tmp/arc-api-new "$API_BIN"
    mv /tmp/arcpanel-cli-new "$CLI_BIN"
else
    cp "$AGENT_SRC/target/release/arc-agent" "$AGENT_BIN"
    cp "$API_SRC/target/release/arc-api" "$API_BIN"
    cp "$CLI_SRC/target/release/arc" "$CLI_BIN"
fi
chmod +x "$AGENT_BIN" "$API_BIN" "$CLI_BIN"
log "Binaries updated (agent: $(du -h "$AGENT_BIN" | cut -f1), api: $(du -h "$API_BIN" | cut -f1), cli: $(du -h "$CLI_BIN" | cut -f1))"

systemctl daemon-reload
systemctl start arc-agent
sleep 1
systemctl start arc-api
log "Services restarted"

# ── Health check with rollback ────────────────────────────────────────────
rollback() {
    error "Health check failed, rolling back..."
    cp "${AGENT_BIN}.bak" "$AGENT_BIN" 2>/dev/null || true
    cp "${API_BIN}.bak" "$API_BIN" 2>/dev/null || true
    cp "${CLI_BIN}.bak" "$CLI_BIN" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart arc-agent arc-api
    warn "Rolled back to previous binaries"
    exit 1
}

log "Running post-deploy health check..."
sleep 20

# Basic health endpoint
if ! curl -sf --max-time 30 http://127.0.0.1:3080/api/health > /dev/null 2>&1; then
    rollback
fi
log "Health check: /api/health OK"

# Auth subsystem (setup-status is unauthenticated, tests DB connectivity).
# Note: this endpoint is GET-only — using POST returns 405 and triggered an
# unconditional rollback on every update before this fix.
if ! curl -sf --max-time 30 http://127.0.0.1:3080/api/auth/setup-status > /dev/null 2>&1; then
    rollback
fi
log "Health check: /api/auth/setup-status OK"

# Agent reachable (non-fatal — agent may start slower)
if ! curl -sf --max-time 30 http://127.0.0.1:3080/api/system/info > /dev/null 2>&1; then
    warn "Agent connectivity check failed (non-fatal, agent may still be starting)"
fi

# CLI health check (non-fatal)
if ! arc --version > /dev/null 2>&1; then
    warn "CLI health check failed (non-fatal)"
fi

log "Health checks passed"
# Clean up backups
rm -f "${AGENT_BIN}.bak" "${API_BIN}.bak" "${CLI_BIN}.bak"

echo ""
echo -e "${GREEN}${BOLD}Update complete!${NC}"
echo ""
echo -e "  Agent: $(systemctl is-active arc-agent)"
echo -e "  API:   $(systemctl is-active arc-api)"
echo -e "  Version: $($CLI_BIN --version 2>/dev/null || echo 'unknown')"
echo ""
