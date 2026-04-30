# CLI Reference

The `arc` CLI provides full command-line access to all panel operations. It communicates with the agent via Unix socket using the token stored at `/etc/arcpanel/agent.token`.

## Global Options

| Option | Default | Description |
|--------|---------|-------------|
| `-o, --output <FORMAT>` | `table` | Output format: `table` or `json` |
| `--version` | | Print version and exit |
| `--help` | | Print help |

## Commands

---

### `arc status`

Show server status including CPU, memory, disk, and uptime.

```bash
arc status
```

```
SERVER STATUS
─────────────────────────────────
Hostname:    web-1
OS:          Ubuntu 22.04.4 LTS
Kernel:      6.8.0-106-generic
Uptime:      14 days, 3 hours
Load:        0.12 0.08 0.05

CPU:         3.2% (2 cores)
Memory:      847 MB / 2048 MB (41.4%)
Disk:        12.3 GB / 50.0 GB (24.6%)
```

JSON output:

```bash
arc status -o json
```

---

### `arc sites`

List all Nginx sites.

```bash
arc sites
```

```
DOMAIN                RUNTIME    SSL    STATUS
example.com           php        ✓      active
api.example.com       proxy      ✓      active
blog.example.com      static     ✓      active
```

Filter by domain:

```bash
arc sites -f blog
```

#### `arc sites create`

Create a new site.

```bash
arc sites create example.com --runtime php --ssl --ssl-email admin@example.com
```

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `DOMAIN` | Yes | | Domain name |
| `--runtime` | No | `static` | Runtime type: `static`, `php`, or `proxy` |
| `--proxy-port` | No | | Upstream port (required for `--runtime proxy`) |
| `--ssl` | No | | Provision Let's Encrypt SSL |
| `--ssl-email` | No | | Email for Let's Encrypt (required with `--ssl`) |

```
Site created: example.com
  Runtime:  php
  Root:     /var/www/example.com/public
  SSL:      provisioned (expires 2026-06-18)
```

#### `arc sites info`

Show site details.

```bash
arc sites info example.com
```

```
SITE DETAILS
─────────────────────────────────
Domain:      example.com
Runtime:     php
Root:        /var/www/example.com/public
SSL:         active (expires 2026-06-18)
Created:     2026-03-15 10:30:00
```

#### `arc sites delete`

Delete a site and its Nginx configuration.

```bash
arc sites delete example.com
```

```
Site deleted: example.com
```

---

### `arc db`

List databases.

```bash
arc db
```

```
NAME              ENGINE      PORT    STATUS     SIZE
mysite_db         mysql       3306    running    245 MB
analytics_db      postgres    5433    running    1.2 GB
```

Filter by name:

```bash
arc db -f analytics
```

#### `arc db create`

Create a new database in a Docker container.

```bash
arc db create blog_db --engine mysql --password "s3cureP@ss" --port 3307
```

| Argument | Required | Description |
|----------|----------|-------------|
| `NAME` | Yes | Database name |
| `--engine` | Yes | Engine: `mysql`, `mariadb`, or `postgres` |
| `--password` | Yes | Root/admin password |
| `--port` | Yes | Host port to expose |

```
Database created: blog_db
  Engine:    mysql
  Port:      3307
  Container: arc-db-blog_db
```

#### `arc db delete`

Delete a database container.

```bash
arc db delete abc123def456
```

---

### `arc apps`

List Docker apps.

```bash
arc apps
```

```
NAME           IMAGE                   PORT    STATUS     DOMAIN
ghost          ghost:5-alpine          2368    running    blog.example.com
grafana        grafana/grafana:latest  3000    running    metrics.example.com
n8n            n8nio/n8n:latest        5678    running    —
```

Filter by name or domain:

```bash
arc apps -f grafana
```

#### `arc apps templates`

List all available app templates.

```bash
arc apps templates
```

```
ID                CATEGORY      NAME             DESCRIPTION
ghost             cms           Ghost            Modern publishing platform
wordpress         cms           WordPress        Popular CMS and blogging platform
grafana           monitoring    Grafana          Observability dashboards
prometheus        monitoring    Prometheus       Metrics collection
uptime-kuma       monitoring    Uptime Kuma      Uptime monitoring
nextcloud         storage       Nextcloud        Self-hosted cloud storage
...
(152 templates across 14 categories)
```

#### `arc apps deploy`

Deploy an app from a template.

```bash
arc apps deploy ghost --name my-blog --port 2368 --domain blog.example.com --ssl-email admin@example.com
```

| Argument | Required | Description |
|----------|----------|-------------|
| `TEMPLATE` | Yes | Template ID (from `apps templates`) |
| `--name` | Yes | App name |
| `--port` | Yes | Host port |
| `--domain` | No | Domain for auto reverse proxy + SSL |
| `--ssl-email` | No | Email for Let's Encrypt (requires `--domain`) |

```
Deploying ghost as "my-blog"...
  Pulling image: ghost:5-alpine
  Starting container on port 2368
  Configuring reverse proxy: blog.example.com → localhost:2368
  Provisioning SSL for blog.example.com
App deployed: my-blog (blog.example.com)
```

#### `arc apps stop`

```bash
arc apps stop abc123def456
```

#### `arc apps start`

```bash
arc apps start abc123def456
```

#### `arc apps restart`

```bash
arc apps restart abc123def456
```

#### `arc apps remove`

```bash
arc apps remove abc123def456
```

#### `arc apps logs`

View container logs.

```bash
arc apps logs abc123def456
```

#### `arc apps compose`

Deploy from a Docker Compose file.

```bash
arc apps compose /path/to/docker-compose.yml
```

---

### `arc services`

Check service health.

```bash
arc services
```

```
SERVICE              STATUS      PID     MEMORY
arc-agent      ● running   1234    30 MB
arc-api        ● running   1235    27 MB
nginx                ● running   1236    12 MB
docker               ● running   1237    45 MB
php8.3-fpm           ● running   1238    18 MB
fail2ban             ● running   1239    8 MB
ufw                  ● active    —       —
```

Filter by service name:

```bash
arc services -f nginx
```

---

### `arc ssl`

SSL certificate management.

#### `arc ssl status`

Check certificate details for a domain.

```bash
arc ssl status example.com
```

```
SSL CERTIFICATE
─────────────────────────────────
Domain:      example.com
Issuer:      Let's Encrypt
Valid From:  2026-03-15
Expires:     2026-06-13
Days Left:   85
Auto-Renew:  yes
```

#### `arc ssl provision`

Provision a Let's Encrypt certificate.

```bash
arc ssl provision example.com --email admin@example.com --runtime php
```

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `DOMAIN` | Yes | | Domain name |
| `--email` | Yes | | Let's Encrypt email |
| `--runtime` | No | `static` | Site runtime: `static`, `php`, or `proxy` |
| `--proxy-port` | No | | Upstream port (for proxy runtime) |

---

### `arc backup`

Backup management.

#### `arc backup create`

```bash
arc backup create example.com
```

```
Creating backup for example.com...
Backup created: example.com_2026-03-20_143022.tar.gz (45.2 MB)
```

#### `arc backup list`

```bash
arc backup list example.com
```

#### `arc backup restore`

```bash
arc backup restore example.com example.com_2026-03-20_143022.tar.gz
```

```
Restoring example.com from example.com_2026-03-20_143022.tar.gz...
Restore complete.
```

#### `arc backup delete`

```bash
arc backup delete example.com example.com_2026-03-18_020000.tar.gz
```

---

### `arc logs`

View system and site logs.

```bash
arc logs
```

| Option | Default | Description |
|--------|---------|-------------|
| `-d, --domain` | | Domain for site-specific logs |
| `-t, --type` | `syslog` | Log type: `syslog`, `nginx`, `auth`, `php`, `mysql` |
| `-n, --lines` | `50` | Number of lines to show |
| `-f, --filter` | | Filter text (substring match) |
| `-s, --search` | | Search pattern (regex) |

Examples:

```bash
# View system log
arc logs

# View Nginx error log for a site
arc logs -d example.com -t nginx -n 100

# Search for errors in auth log
arc logs -t auth -s "Failed password"

# Filter PHP logs
arc logs -t php -f "Fatal error" -n 200
```

---

### `arc security`

Security overview.

```bash
arc security
```

```
SECURITY OVERVIEW
─────────────────────────────────
Score:           82/100
Firewall:        active (UFW)
Fail2Ban:        active (3 jails)
SSH Root Login:  disabled
SSH Password:    disabled
2FA:             enabled
Last Scan:       2026-03-19 02:00
```

#### `arc security scan`

Run a security scan.

```bash
arc security scan
```

```
Running security scan...

FINDINGS
  [HIGH]   Port 3306 exposed to all IPs
  [MEDIUM] SSH password authentication still enabled
  [LOW]    Unattended upgrades not configured
  [PASS]   Firewall active
  [PASS]   Fail2Ban running
  [PASS]   SSH root login disabled
  [PASS]   SSL certificates valid

Score: 78/100 (3 findings)
```

#### `arc security firewall`

List firewall rules.

```bash
arc security firewall
```

```
#    ACTION    FROM           PORT      PROTO
1    allow     Anywhere       22/tcp    tcp
2    allow     Anywhere       80/tcp    tcp
3    allow     Anywhere       443/tcp   tcp
4    allow     Anywhere       8443/tcp  tcp
```

#### `arc security firewall add`

Add a firewall rule.

```bash
arc security firewall add --port 3000 --proto tcp --action allow
arc security firewall add --port 5432 --proto tcp --action allow --from 10.0.0.0/8
```

| Option | Default | Description |
|--------|---------|-------------|
| `--port` | | Port number |
| `--proto` | `tcp` | Protocol: `tcp` or `udp` |
| `--action` | `allow` | Action: `allow` or `deny` |
| `--from` | | Source IP or CIDR (optional) |

#### `arc security firewall remove`

Remove a rule by number.

```bash
arc security firewall remove 4
```

---

### `arc top`

Show top processes by CPU usage.

```bash
arc top
```

```
PID      CPU%    MEM%    COMMAND
1234     12.3    2.1     /usr/sbin/mysqld
5678     8.7     1.4     php-fpm: pool www
9012     3.2     0.8     nginx: worker process
1357     2.1     1.2     arc-agent
2468     1.8     1.1     arc-api
```

---

### `arc php`

PHP version management.

```bash
arc php
```

```
VERSION    STATUS     FPM SOCKET
8.1        installed  /run/php/php8.1-fpm.sock
8.3        installed  /run/php/php8.3-fpm.sock
```

#### `arc php install`

Install a PHP version.

```bash
arc php install 8.4
```

Supported versions: `8.1`, `8.2`, `8.3`, `8.4`.

---

### `arc diagnose`

Run server diagnostics across 6 categories.

```bash
arc diagnose
```

```
DIAGNOSTICS
─────────────────────────────────
[✓] Nginx configuration valid
[✓] All SSL certificates valid (next expiry: 85 days)
[✓] Disk usage: 24.6% (12.3 GB / 50 GB)
[✓] Memory usage: 41.4% (847 MB / 2048 MB)
[✓] Docker: 5 containers running, 0 unhealthy
[!] PHP-FPM: high average response time (320ms)
[✓] Fail2Ban: 3 jails active
[✓] Firewall: active

Score: 95/100 (1 warning)
```

---

### `arc export`

Export server configuration as YAML (Infrastructure as Code).

```bash
# Print to stdout
arc export

# Save to file
arc export -O config.yml
```

Sample output:

```yaml
version: "1"
sites:
  - domain: example.com
    runtime: php
    ssl: true
  - domain: api.example.com
    runtime: proxy
    proxy_port: 3000
    ssl: true
databases:
  - name: mysite_db
    engine: mysql
    port: 3306
apps:
  - name: ghost
    template: ghost
    port: 2368
    domain: blog.example.com
```

---

### `arc apply`

Apply server configuration from a YAML file.

```bash
# Dry run (show what would change)
arc apply config.yml --dry-run

# Apply changes
arc apply config.yml --email admin@example.com
```

| Argument | Required | Description |
|----------|----------|-------------|
| `FILE` | Yes | Path to YAML config file |
| `--dry-run` | No | Show changes without applying |
| `--email` | No | Email for Let's Encrypt SSL provisioning |

Dry run output:

```
DRY RUN — no changes will be made
  [+] Create site: staging.example.com (static, SSL)
  [~] Update site: api.example.com (proxy_port 3000 → 3001)
  [=] No change: example.com
  [+] Create database: staging_db (postgres, port 5434)
```

---

### `arc completions`

Generate shell completions.

```bash
# Bash
arc completions bash > /etc/bash_completion.d/arc

# Zsh
arc completions zsh > ~/.zfunc/_arc

# Fish
arc completions fish > ~/.config/fish/completions/arc.fish
```

Supported shells: `bash`, `zsh`, `fish`, `powershell`, `elvish`.
