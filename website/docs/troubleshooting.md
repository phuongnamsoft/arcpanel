# Troubleshooting

## Log Locations

Arcpanel services run via systemd. View their logs with `journalctl`:

```bash
# Agent logs
journalctl -u arc-agent -n 100 --no-pager

# API logs
journalctl -u arc-api -n 100 --no-pager

# Follow logs in real-time
journalctl -u arc-agent -f

# Logs since last boot
journalctl -u arc-agent -b
```

For verbose output, set the log level in the service config:

```bash
# Edit /etc/arcpanel/api.env and add:
RUST_LOG=debug

# Then restart:
systemctl restart arc-api
```

### Other useful logs

```bash
# Nginx access/error logs
tail -50 /var/log/nginx/error.log
tail -50 /var/log/nginx/access.log

# Per-site Nginx logs
tail -50 /var/log/nginx/example.com.access.log
tail -50 /var/log/nginx/example.com.error.log

# PHP-FPM
journalctl -u php8.3-fpm -n 50 --no-pager

# Fail2Ban
tail -50 /var/log/fail2ban.log

# Mail (Postfix)
tail -50 /var/log/mail.log
```

## Common Issues

### Panel shows 502 Bad Gateway

**Cause**: The Arcpanel agent is not running.

**Fix**:

```bash
# Check agent status
systemctl status arc-agent

# Start it if stopped
systemctl start arc-agent

# Check for errors
journalctl -u arc-agent -n 50 --no-pager
```

Also check the API service:

```bash
systemctl status arc-api
journalctl -u arc-api -n 50 --no-pager
```

---

### Can't login from browser (cookie not set)

**Cause**: The panel is accessed over HTTP, but the login cookie has the `Secure` flag set (only sent over HTTPS).

**Fix**: Set the `BASE_URL` in the API configuration to match how you access the panel:

```bash
# Edit /etc/arcpanel/api.env
BASE_URL=http://YOUR_SERVER_IP:8443

# Restart the API
systemctl restart arc-api
```

If you access the panel via HTTPS, set `BASE_URL=https://panel.example.com:8443`.

The cookie's `Secure` flag is automatically set based on the `BASE_URL` scheme. If `BASE_URL` starts with `http://`, the `Secure` flag is omitted, allowing login over plain HTTP.

---

### Site shows 404 Not Found

**Cause**: Either the document root is empty, or the DNS is not pointing to the server.

**Fix**:

1. Check the document root exists and has files:
   ```bash
   ls -la /var/www/example.com/public/
   ```

2. If the directory is empty, Arcpanel should have created a default `index.html`. Re-create the site from the panel.

3. Check DNS is pointing to this server:
   ```bash
   dig example.com +short
   ```
   The result should be your server's public IP.

4. Check the Nginx config exists and is valid:
   ```bash
   ls /etc/nginx/sites-enabled/example.com
   nginx -t
   ```

---

### PHP site shows 502 Bad Gateway

**Cause**: PHP-FPM is not installed or not running.

**Fix**:

```bash
# Check if PHP-FPM is installed
php -v

# Check the service
systemctl status php8.3-fpm

# Install PHP if missing (via CLI)
arc php install 8.3

# Or install from the panel: Settings > Service Installers > PHP-FPM

# Restart PHP-FPM
systemctl restart php8.3-fpm
```

Verify the Nginx config references the correct PHP-FPM socket:

```bash
grep fastcgi_pass /etc/nginx/sites-available/example.com
# Should show: unix:/run/php/php8.3-fpm.sock
```

---

### SSL provisioning fails

**Cause**: Let's Encrypt cannot verify domain ownership.

**Fix**:

1. **DNS must point to this server**:
   ```bash
   dig example.com +short
   # Must return this server's public IP
   ```

2. **Port 80 must be open** (HTTP-01 challenge):
   ```bash
   ufw status | grep 80
   # Should show: 80/tcp ALLOW Anywhere

   # Open it if blocked:
   ufw allow 80/tcp
   ```

3. **Nginx must be running**:
   ```bash
   systemctl status nginx
   ```

4. **Check for rate limits**: Let's Encrypt allows 5 duplicate certificates per domain per week. If you hit the limit, wait 7 days or use a different subdomain.

5. Retry:
   ```bash
   arc ssl provision example.com --email you@example.com --runtime static
   ```

---

### Agent won't start

**Cause**: Missing directories, port conflicts, or permission issues.

**Fix**:

```bash
# Check the error message
journalctl -u arc-agent -n 50 --no-pager

# Ensure required directories exist
mkdir -p /run/arcpanel
mkdir -p /etc/arcpanel
mkdir -p /var/backups/arcpanel
mkdir -p /var/www/acme

# Check the agent token exists
ls -la /etc/arcpanel/agent.token

# Restart
systemctl restart arc-agent
```

If you see `NAMESPACE` errors in the logs, the systemd service may have stale hardening directives. Update the service file:

```bash
sudo bash /opt/arcpanel/scripts/update.sh
```

---

### After reboot, services are down

**Cause**: Systemd services were not enabled to start on boot.

**Fix**:

```bash
# Enable all Arcpanel services
systemctl enable arc-agent
systemctl enable arc-api

# Start them now
systemctl start arc-agent
systemctl start arc-api

# Verify
systemctl status arc-agent
systemctl status arc-api
```

Also ensure Docker is enabled:

```bash
systemctl enable docker
systemctl start docker
```

---

### Docker apps not accessible after deploy

**Cause**: The container is running but the reverse proxy is not configured, or the container port is wrong.

**Fix**:

```bash
# Check the container is running
docker ps | grep APP_NAME

# Check the container's port mapping
docker port CONTAINER_ID

# Check Nginx config exists
ls /etc/nginx/sites-enabled/ | grep APP_DOMAIN

# Test Nginx config
nginx -t

# Reload Nginx
systemctl reload nginx
```

## Running Diagnostics

### From the CLI

```bash
arc diagnose
```

This checks 6 categories:
- Nginx configuration validity
- Resource usage (CPU, RAM, disk)
- SSL certificate expiry
- Security configuration
- Service health
- Log analysis for errors

### From the Panel

The Dashboard shows a health score (0-100) with active issues. Click any issue to see details and one-click fix options.

Go to Security > Diagnostics for a full diagnostic report.

## Restarting Services

```bash
# Restart all Arcpanel services
systemctl restart arc-agent
systemctl restart arc-api

# Restart Nginx
systemctl restart nginx

# Restart PHP-FPM
systemctl restart php8.3-fpm

# Restart Docker
systemctl restart docker

# Restart a specific Docker container
docker restart CONTAINER_ID
```

## Updating Arcpanel

```bash
sudo bash /opt/arcpanel/scripts/update.sh
```

The update script pulls the latest code, rebuilds binaries, updates systemd service files, creates any new required directories, and restarts services with zero-downtime rollback if the health check fails.

For servers using pre-built binaries:

```bash
INSTALL_FROM_RELEASE=1 sudo bash /opt/arcpanel/scripts/update.sh
```

## Getting Help

- **GitHub Issues**: [github.com/phuongnamsoft/arcpanel/issues](https://github.com/phuongnamsoft/arcpanel/issues) -- Report bugs or request features
- **Discussions**: Use GitHub Issues for questions and community support
- **Email**: hello@arcpanel.top for priority support inquiries
