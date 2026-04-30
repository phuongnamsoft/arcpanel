#!/usr/bin/env bash
# Arcpanel Remote Agent Installer
# Usage: curl -sSL https://panel.example.com/install-agent.sh | sudo bash -s -- \
#   --panel-url https://panel.example.com \
#   --token <agent_token> \
#   --server-id <server_uuid>
#
# This installs ONLY the Arcpanel agent binary (no database, no API, no frontend).
# The agent connects back to the panel via HTTPS on port 9443.

set -euo pipefail

PANEL_URL=""
TOKEN=""
SERVER_ID=""
AGENT_PORT="9443"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel-url) PANEL_URL="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --server-id) SERVER_ID="$2"; shift 2 ;;
        --port) AGENT_PORT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$TOKEN" ]]; then
    echo "Error: --token is required"
    echo "Usage: $0 --panel-url <url> --token <token> --server-id <uuid>"
    exit 1
fi

echo "======================================"
echo "  Arcpanel Agent Installer (Remote)"
echo "======================================"
echo ""

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_LABEL="amd64" ;;
    aarch64) ARCH_LABEL="arm64" ;;
    arm64)   ARCH_LABEL="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "[1/7] Architecture: $ARCH_LABEL"

# Detect package manager
detect_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
    else
        echo "Error: No supported package manager found (apt/dnf/yum)"
        exit 1
    fi
}

pkg_install() {
    case "$PKG_MGR" in
        apt)
            apt-get update -qq > /dev/null 2>&1
            apt-get install -y -qq "$@" > /dev/null 2>&1
            ;;
        dnf) dnf install -y -q "$@" > /dev/null 2>&1 ;;
        yum) yum install -y -q "$@" > /dev/null 2>&1 ;;
    esac
}

# Install dependencies
echo "[2/7] Installing dependencies..."
detect_pkg_manager

# Install Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
fi
systemctl enable --now docker > /dev/null 2>&1 || true

# Install curl and openssl if missing
pkg_install curl openssl

# Create directories
echo "[3/7] Creating directories..."
mkdir -p /etc/arcpanel/ssl
mkdir -p /var/run/arcpanel
mkdir -p /var/www
mkdir -p /var/backups/arcpanel
mkdir -p /var/lib/arcpanel/git

# Ensure socket directory persists across reboots
echo "d /run/arcpanel 0755 root root -" > /etc/tmpfiles.d/arcpanel.conf

# Save agent token and server ID
echo "[4/7] Saving configuration..."
echo "$TOKEN" > /etc/arcpanel/agent.token
chmod 600 /etc/arcpanel/agent.token

# Persist agent configuration
# AGENT_TOKEN + AGENT_LISTEN_TCP = direct multi-server TCP access
# ARCPANEL_* vars = phone-home mode (agent checks in with central panel)
cat > /etc/arcpanel/agent.env << ENVEOF
AGENT_TOKEN=$TOKEN
AGENT_LISTEN_TCP=0.0.0.0:$AGENT_PORT
ARCPANEL_SERVER_TOKEN=$TOKEN
ARCPANEL_SERVER_ID=$SERVER_ID
ARCPANEL_CENTRAL_URL=$PANEL_URL
ENVEOF
chmod 600 /etc/arcpanel/agent.env

# Download agent binary (naming matches GitHub release assets)
echo "[5/7] Downloading agent binary..."
DOWNLOAD_URL="https://github.com/ovexro/dockpanel/releases/latest/download/arc-agent-linux-${ARCH_LABEL}"
if ! curl -fsSL "$DOWNLOAD_URL" -o /usr/local/bin/arc-agent; then
    echo "  Release download failed. Trying panel download..."
    if [[ -n "$PANEL_URL" ]]; then
        curl -fsSL "${PANEL_URL}/api/agent/download?arch=${ARCH_LABEL}" -o /usr/local/bin/arc-agent || {
            echo "Error: Could not download agent binary"
            exit 1
        }
    else
        echo "Error: Could not download agent binary (no --panel-url provided)"
        exit 1
    fi
fi
chmod +x /usr/local/bin/arc-agent

# Generate self-signed TLS cert for agent HTTPS
echo "[6/7] Generating TLS certificate..."
if [[ ! -f /etc/arcpanel/ssl/agent.crt ]]; then
    openssl req -x509 -newkey rsa:2048 -keyout /etc/arcpanel/ssl/agent.key \
        -out /etc/arcpanel/ssl/agent.crt -days 3650 -nodes \
        -subj "/CN=arc-agent" > /dev/null 2>&1
    chmod 600 /etc/arcpanel/ssl/agent.key
fi

# Create systemd service (matching local agent hardening)
echo "[7/7] Creating systemd service..."
cat > /etc/systemd/system/arc-agent.service << 'UNIT'
[Unit]
Description=Arcpanel Agent
After=network.target docker.service
Wants=docker.service
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'mkdir -p /run/arcpanel /var/lib/arcpanel/git'
ExecStart=/usr/local/bin/arc-agent
EnvironmentFile=/etc/arcpanel/agent.env
Environment=RUST_LOG=info
Restart=always
RestartSec=5
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
UNIT

# Allow agent port through firewall
if command -v ufw &> /dev/null; then
    ufw allow ${AGENT_PORT}/tcp > /dev/null 2>&1 || true
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=${AGENT_PORT}/tcp > /dev/null 2>&1 || true
    firewall-cmd --reload > /dev/null 2>&1 || true
fi

# Start agent
systemctl daemon-reload
systemctl enable arc-agent
systemctl start arc-agent

echo ""
echo "======================================"
echo "  Arcpanel Agent installed!"
echo "======================================"
echo ""
echo "  Agent listening on: 0.0.0.0:${AGENT_PORT}"
echo "  Token: ${TOKEN:0:12}..."
echo "  Server ID: ${SERVER_ID}"
echo "  Config: /etc/arcpanel/agent.env"
echo ""
echo "  Return to your Arcpanel and click"
echo "  'Test Connection' to verify."
echo ""
