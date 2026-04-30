#!/usr/bin/env bash
#
# Arcpanel Uninstaller
# Removes Arcpanel completely from the server.
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}${BOLD}Arcpanel Uninstaller${NC}"
echo ""
echo "This will remove:"
echo "  - Agent and API binaries and systemd services"
echo "  - PostgreSQL container and data volume"
echo "  - Nginx panel config"
echo "  - Config directory (/etc/arcpanel)"
echo "  - Source directory (/opt/arcpanel, if present)"
echo ""
echo -e "${YELLOW}Database and backup data will be DELETED.${NC}"
echo ""

if [ -t 0 ]; then
    echo -n "Continue? [y/N] "
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo ""

# Stop and remove agent service
echo -e "${GREEN}[+]${NC} Removing agent service..."
systemctl stop arc-agent 2>/dev/null || true
systemctl disable arc-agent 2>/dev/null || true
rm -f /etc/systemd/system/arc-agent.service
rm -f /usr/local/bin/arc-agent

# Stop and remove API service
echo -e "${GREEN}[+]${NC} Removing API service..."
systemctl stop arc-api 2>/dev/null || true
systemctl disable arc-api 2>/dev/null || true
rm -f /etc/systemd/system/arc-api.service
rm -f /usr/local/bin/arc-api

systemctl daemon-reload 2>/dev/null || true

# Remove PostgreSQL container and volume
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^arc-postgres$"; then
    echo -e "${GREEN}[+]${NC} Removing PostgreSQL container..."
    docker stop arc-postgres 2>/dev/null || true
    docker rm arc-postgres 2>/dev/null || true
fi

if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q "^arc-pgdata$"; then
    echo -e "${GREEN}[+]${NC} Removing PostgreSQL data volume..."
    docker volume rm arc-pgdata 2>/dev/null || true
fi

# Also handle old Docker Compose deployments
for DIR in /opt/arcpanel/panel /home/*/arcpanel/panel; do
    if [ -f "$DIR/docker-compose.yml" ]; then
        echo -e "${GREEN}[+]${NC} Stopping old Docker Compose deployment at $DIR..."
        (cd "$DIR" && docker compose down -v 2>/dev/null) || true
        break
    fi
done

# Remove nginx config
echo -e "${GREEN}[+]${NC} Removing nginx config..."
rm -f /etc/nginx/sites-enabled/arcpanel-panel.conf
rm -f /etc/nginx/conf.d/arcpanel-panel.conf
nginx -t > /dev/null 2>&1 && (nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null) || true

# Remove CLI binary
echo -e "${GREEN}[+]${NC} Removing CLI binary..."
rm -f /usr/local/bin/arc

# Remove directories
echo -e "${GREEN}[+]${NC} Removing data directories..."
rm -rf /etc/arcpanel
rm -rf /var/run/arcpanel
rm -rf /var/backups/arcpanel
rm -rf /var/lib/arcpanel
rm -rf /var/www/acme

# Remove tmpfiles.d config
rm -f /etc/tmpfiles.d/arcpanel.conf

# Remove Arcpanel crontab entries
(crontab -l 2>/dev/null | grep -v "# arcpanel:" | crontab -) 2>/dev/null || true

# Remove source (if installed to /opt/arcpanel by install.sh)
if [ -d /opt/arcpanel ]; then
    echo -e "${GREEN}[+]${NC} Removing source directory..."
    rm -rf /opt/arcpanel
fi

echo ""
echo -e "${GREEN}${BOLD}Arcpanel removed.${NC}"
echo -e "Note: Docker, Nginx, and Node.js were NOT uninstalled (they may be used by other services)."
echo ""
