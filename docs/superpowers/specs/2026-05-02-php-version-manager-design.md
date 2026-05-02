# PHP Version Manager — Design Spec

**Date:** 2026-05-02  
**Status:** Draft  
**Scope:** Full-stack PHP version management for ArcPanel — install/remove versions, per-site selection, extension management, CLI parity.

---

## 1. Overview

ArcPanel currently stores a single `php_version` string on each site but has no server-level tracking of which PHP versions are actually installed, no install/remove UI, and no extension management. This spec adds a complete PHP version lifecycle: install versions on a server (native via Ondrej PPA or via Docker FPM containers), assign versions per site, manage extensions, and expose everything through the panel UI and CLI.

**Supported PHP versions:** 5.6, 7.4, 8.0, 8.1, 8.2, 8.3, 8.4

---

## 2. Data Model

### 2.1 New table: `php_versions`

```sql
CREATE TABLE php_versions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id      UUID NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    version        VARCHAR(10) NOT NULL,
    status         VARCHAR(20) NOT NULL DEFAULT 'installing',
    install_method VARCHAR(10) NOT NULL DEFAULT 'native',
    extensions     TEXT[]      NOT NULL DEFAULT '{}',
    error_message  TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (server_id, version)
);
```

**Status transitions:** `installing → active`, `active → removing → (deleted row)`, `installing/removing → error`

**`install_method`:** `native` (Ondrej PPA apt packages) | `docker` (PHP-FPM container)

**`extensions`:** flat `TEXT[]` of installed extension names, e.g. `{"mbstring","curl","zip","gd","redis","imagick"}`. Read/written as a unit — no separate extensions table needed.

### 2.2 Changes to `sites`

Two new columns in a migration:

```sql
ALTER TABLE sites ADD COLUMN php_max_execution_time INT NOT NULL DEFAULT 300;
ALTER TABLE sites ADD COLUMN php_upload_mb          INT NOT NULL DEFAULT 64;
```

The existing `php_version VARCHAR(10)`, `php_memory_mb INT`, and `php_max_workers INT` columns are already present and are sufficient otherwise.

### 2.3 Soft constraint: version in use

No hard DB foreign key between `sites.php_version` and `php_versions.version` (version is a string, not a UUID). Instead, the backend enforces in application logic:
- On site create/update: validate `php_version` exists in `php_versions` table for that server with `status = 'active'`.
- On PHP version delete: reject with `409 Conflict` if any `sites` rows reference that version on that server.

---

## 3. Agent API

New route module: `panel/agent/src/routes/php.rs`  
New service module: `panel/agent/src/services/php.rs`

### 3.1 Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/php/versions` | List installed PHP versions with FPM status and socket paths |
| `POST` | `/php/install` | Install a PHP version (body: `{version, method, extensions[]}`) |
| `DELETE` | `/php/versions/:version` | Uninstall a PHP version |
| `GET`  | `/php/versions/:version/extensions` | List installed extensions for a version |
| `POST` | `/php/versions/:version/extensions` | Install an extension |
| `DELETE` | `/php/versions/:version/extensions/:name` | Remove an extension |
| `GET`  | `/php/versions/:version/info` | PHP binary info (version string, loaded extensions, key ini values) |
| `POST` | `/php/versions/:version/reload-fpm` | Reload FPM for a version |

### 3.2 Install flow (native method)

The agent executes steps sequentially using `safe_command`. Progress is reported by writing structured step JSON to a temporary file that the backend SSE handler tails — same pattern as site provisioning in `routes/nginx.rs`.

```
Step 1: add-ppa       — apt-add-repository ppa:ondrej/php -y
Step 2: apt-update    — apt-get update -q
Step 3: install-fpm   — apt-get install -y php{v}-fpm php{v}-cli php{v}-common
Step 4: install-exts  — apt-get install -y php{v}-mbstring php{v}-curl php{v}-zip php{v}-xml php{v}-bcmath
Step 5: enable-fpm    — systemctl enable php{v}-fpm && systemctl start php{v}-fpm
Step 6: verify        — php{v} --version && systemctl is-active php{v}-fpm
```

On failure at any step: record step error, return `500`. Steps 1–2 are idempotent on re-run.

### 3.3 Install flow (Docker method)

```
Step 1: pull-image    — docker pull php:{v}-fpm-alpine
Step 2: create-vol    — docker volume create php{v}-fpm-socket
Step 3: run-container — docker run -d --name php{v}-fpm
                        -v /var/www:/var/www:ro
                        -v php{v}-fpm-socket:/run/php
                        --restart unless-stopped
                        php:{v}-fpm-alpine
Step 4: verify        — docker inspect php{v}-fpm → running
```

Socket lands at: `unix:/var/lib/docker/volumes/php{v}-fpm-socket/_data/php-fpm.sock`  
Symlinked to: `/run/php/php{v}-fpm.sock` for nginx compatibility.

### 3.4 Uninstall flow

**Native:**
```
1. Check no active site is using this version (agent reads /etc/php/{v}/fpm/pool.d/)
2. systemctl stop php{v}-fpm && systemctl disable php{v}-fpm
3. apt-get remove -y php{v}-fpm php{v}-cli php{v}-* --purge
4. rm -rf /etc/php/{v}
```

**Docker:**
```
1. docker stop php{v}-fpm && docker rm php{v}-fpm
2. docker volume rm php{v}-fpm-socket
3. docker rmi php:{v}-fpm-alpine
```

### 3.5 Extension install/remove (native only)

Extensions follow the naming convention `php{v}-{ext}` (e.g. `php8.3-redis`). Some extensions (like `redis`, `imagick`, `xdebug`) come from PECL via the Ondrej PPA.

```
install: apt-get install -y php{v}-{ext} && systemctl reload php{v}-fpm
remove:  apt-get remove -y php{v}-{ext} && systemctl reload php{v}-fpm
```

Extension names validated against a server-side allowlist:
```
common:  mbstring, curl, zip, gd, xml, bcmath, intl, soap, opcache,
         mysqli, pgsql, sqlite3, pdo, pdo-mysql, pdo-pgsql
extras:  redis, imagick, memcached, xdebug, mongodb, ldap, imap,
         enchant, tidy, xmlrpc, snmp, readline
```

### 3.6 FPM pool config

Existing `write_php_pool_config` in `services/nginx.rs` is updated to include the two new fields:

```ini
[{pool_name}]
user = www-data
group = www-data
listen = /run/php/php{v}-fpm-{pool_name}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = {max_workers}
pm.start_servers = {start}
pm.min_spare_servers = 1
pm.max_spare_servers = {spare}
pm.max_requests = 500

php_admin_value[memory_limit]        = {memory_mb}M
php_admin_value[upload_max_filesize] = {upload_mb}M
php_admin_value[post_max_size]       = {upload_mb}M
php_admin_value[max_execution_time]  = {max_execution_time}
```

Socket path convention:
- **Native:** `unix:/run/php/php{v}-fpm-{domain_underscored}.sock`
- **Docker:** `unix:/run/php/php{v}-fpm-docker-{domain_underscored}.sock`

When a site changes PHP version, the old pool config is deleted, new one written, both FPM versions reloaded.

### 3.7 Security

- `version` parameter validated against `SUPPORTED_PHP_VERSIONS: &[&str] = &["5.6", "7.4", "8.0", "8.1", "8.2", "8.3", "8.4"]` — hard-coded allowlist, not user-extensible.
- Extension names validated against the allowlist in §3.5.
- All subprocesses spawned via `safe_command` (clears environment, minimal PATH).
- `apt-get` locked to the Ondrej PPA only for PHP packages — no arbitrary package names.

---

## 4. Backend API

New route module: `panel/backend/src/routes/php.rs`

### 4.1 Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/api/php/versions` | List `php_versions` rows for the scoped server |
| `POST` | `/api/php/versions` | Record + trigger install; returns SSE stream URL |
| `DELETE` | `/api/php/versions/:version` | Check sites, trigger uninstall, delete row |
| `GET`  | `/api/php/versions/:version` | Single version record |
| `GET`  | `/api/php/versions/:version/extensions` | List extensions (from DB row) |
| `POST` | `/api/php/versions/:version/extensions` | Install extension via agent + update DB |
| `DELETE` | `/api/php/versions/:version/extensions/:name` | Remove extension via agent + update DB |
| `GET`  | `/api/php/install-progress/:id` | SSE stream for install progress |

### 4.2 Install request/response

**Request:** `POST /api/php/versions`
```json
{ "version": "8.3", "method": "native" }
```

**Response:** `202 Accepted`
```json
{
  "id": "<uuid>",
  "version": "8.3",
  "status": "installing",
  "progress_url": "/api/php/install-progress/<uuid>"
}
```

The `progress_url` is an SSE endpoint the frontend subscribes to. Each event is a step update:
```json
{"step":"install-fpm","label":"Installing PHP 8.3 FPM","status":"in_progress","message":null}
{"step":"install-fpm","label":"Installing PHP 8.3 FPM","status":"done","message":null}
{"step":"enable-fpm","label":"Starting PHP-FPM service","status":"in_progress","message":null}
```

When complete, a final `{"type":"complete","status":"active"}` event closes the stream.

### 4.3 Site create/update changes

`CreateSiteRequest` and `UpdateSiteRequest` in `routes/sites.rs` gain:
- `php_max_execution_time: Option<i32>` (default 300)
- `php_upload_mb: Option<i32>` (default 64)

On site create with `runtime = "php"`, the backend validates:
```sql
SELECT 1 FROM php_versions
WHERE server_id = $1 AND version = $2 AND status = 'active'
```
If not found: `422 Unprocessable Entity` — "PHP version X is not installed on this server."

On site PHP version change (PUT): old FPM pool is deleted, new one written, nginx config regenerated.

### 4.4 Version delete guard

`DELETE /api/php/versions/:version` checks:
```sql
SELECT COUNT(*) FROM sites WHERE server_id = $1 AND php_version = $2
```
If count > 0: `409 Conflict` with body listing the sites. Operator must migrate sites first.

---

## 5. Frontend UI

### 5.1 Server PHP page

**Route:** `/servers/:serverId/php`  
**Sidebar entry:** "PHP" under a server's sub-navigation (alongside Sites, DNS, Databases, etc.)

**Page contents:**
- Header with "Install PHP Version" button → modal
- List of `php_versions` rows as cards:
  - Version badge, status badge (active / installing / error), install method badge, site count
  - Installed extensions shown as chips (truncated after ~6, "show all" expander)
  - "Extensions" button → slide-over panel for managing extensions
  - "Remove" button → disabled if sites are using it (tooltip shows which sites)
- Empty state: "No PHP versions installed. Click Install to add your first version."

**Install modal:**
- Version dropdown: 5.6, 7.4, 8.0, 8.1, 8.2, 8.3, 8.4
- Install method: Native (Ondrej PPA) | Docker
- Pre-selected extensions checkboxes (common defaults)
- On submit: shows inline progress steps (SSE-fed), closes modal on success

**Extensions slide-over:**
- Two columns: installed | available
- Toggle to install/remove each extension
- Spinner during operation

### 5.2 Site create wizard — PHP tab

When runtime = "PHP" is selected:
- **PHP Version** dropdown: populated from `/api/php/versions?status=active` for this server. Shows version + "(recommended)" label on the newest stable.
- If no versions installed: warning banner with link to server PHP management page.
- **PHP Preset** dropdown: Laravel, WordPress, Symfony, Drupal, Joomla, CodeIgniter, Magento, Generic.

### 5.3 Site settings — PHP tab

Existing site settings gains a "PHP" tab:
- PHP Version selector (filtered to active installed versions) — changing triggers pool reconfiguration + nginx reload
- FPM Pool settings: Memory Limit (MB), Max Workers, Max Execution Time (s), Upload Max (MB)
- "Save & Reload PHP-FPM" button

---

## 6. CLI

Module: `panel/cli/src/commands/php.rs` (extend existing stub)

```
arc php list [--output json]
arc php install <version> [--method native|docker]
arc php remove <version> [--force]
arc php info <version>
arc php extensions list <version> [--output json]
arc php extensions install <version> <extension>
arc php extensions remove <version> <extension>
arc php fpm-reload <version>
```

**`arc php list` output:**
```
VERSION    STATUS       METHOD   SITES  EXTENSIONS
8.3        active       native   3      mbstring, curl, zip, gd, redis...
8.1        active       native   1      mbstring, curl, zip
7.4        installing   native   0      -
```

**`arc php install`** — calls `POST /api/php/versions`, polls `GET /api/php/versions/:version` until status `active` or `error`. Shows spinner with current install step.

**Supported versions:** 5.6, 7.4, 8.0, 8.1, 8.2, 8.3, 8.4 (validated client-side and server-side).

---

## 7. Component Boundaries

| Component | Responsibility | Does NOT handle |
|-----------|----------------|-----------------|
| Agent `routes/php.rs` | HTTP surface, request validation, progress file writes | DB, version conflict logic |
| Agent `services/php.rs` | apt/Docker execution, FPM pool writes, socket paths | HTTP, auth |
| Backend `routes/php.rs` | DB CRUD, agent call proxying, SSE fan-out, site guard | actual process execution |
| Frontend PHP page | Install/remove UX, extension toggles, SSE progress | nginx config details |
| Frontend site wizard | PHP version picker (filtered to installed) | install/remove of versions |
| CLI `php.rs` | Terminal UX, output formatting, version validation | direct agent calls (goes via API) |

---

## 8. Error Handling

| Scenario | Behavior |
|----------|----------|
| Version not in allowlist | `400 Bad Request` — "Unsupported PHP version" |
| Version already installed | `409 Conflict` — "PHP 8.3 is already installed on this server" |
| Install fails mid-way | Agent marks status `error`, records `error_message`; frontend shows last failed step |
| Delete version with active sites | `409 Conflict` — lists site domains in response body |
| PHP version not installed on server at site create | `422 Unprocessable Entity` |
| FPM socket missing at nginx reload | nginx config test fails → agent returns error, site flagged |
| Extension not in allowlist | `400 Bad Request` — "Extension 'xyz' is not supported" |

---

## 9. Migration Plan

1. Add `php_versions` table migration (`20260502000000_php_versions.sql`)
2. Add `php_max_execution_time` + `php_upload_mb` columns to `sites` migration (`20260502000001_php_site_fpm_fields.sql`)
3. Back-fill: any existing site with `php_version IS NOT NULL` and `status = 'active'` on a server where the agent returns that version as installed gets a synthetic `php_versions` row inserted at startup (one-time migration helper in the API boot path).

---

## 10. Out of Scope

- Global `php.ini` editing (per-version or global) — operators use SSH for now
- PHP version pinning per-deploy (git deploy continues to use site's current version)
- PHP-FPM slow log / error log viewer in the panel (can be added later via existing log streaming)
- PECL manual compilation (only Ondrej PPA packages supported)
- PHP version management for Docker app containers (those manage their own PHP inside the container image)
