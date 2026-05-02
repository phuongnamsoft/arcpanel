# PHP Version Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full PHP version lifecycle management — install/remove versions, per-site selection, extension management, and CLI parity — to ArcPanel.

**Architecture:** The agent (`panel/agent`) owns OS-level operations (apt/docker, FPM pool config, systemctl). The backend (`panel/backend`) owns DB state via a new `php_versions` table, provides SSE progress streaming to the frontend using the existing `provision_logs` broadcast pattern, and enforces invariants (version-in-use guard). The frontend adds a new `/php` page for server-level PHP management and updates the site create/settings flows with new fields.

**Tech Stack:** Rust 2024 (Axum, sqlx, PostgreSQL), React 19 + TypeScript + Tailwind 4.

---

## File Structure

### New files
| File | Responsibility |
|------|---------------|
| `panel/backend/migrations/20260502000000_php_versions.sql` | Creates `php_versions` table |
| `panel/backend/migrations/20260502000001_php_site_fpm_fields.sql` | Adds `php_max_execution_time`, `php_upload_mb` to `sites` |
| `panel/agent/src/services/php.rs` | PHP install/uninstall/extension logic (apt + docker) |
| `panel/backend/src/routes/php.rs` | Backend PHP CRUD with DB tracking + SSE progress |
| `panel/frontend/src/pages/PhpVersions.tsx` | Server PHP management page |

### Modified files
| File | Change |
|------|--------|
| `panel/agent/src/services/mod.rs` | Add `pub mod php` |
| `panel/agent/src/routes/php.rs` | Rewrite: new route paths, Docker support, extension allowlist, call services::php |
| `panel/agent/src/services/nginx.rs` | Update `write_php_pool_config` signature + body to accept `upload_mb`, `max_execution_time` |
| `panel/agent/src/routes/nginx.rs` | Update `SiteConfig` struct + `put_site` call to pass new FPM fields |
| `panel/backend/src/models.rs` | Add `php_max_execution_time`, `php_upload_mb` to `Site` struct |
| `panel/backend/src/routes/mod.rs` | Add `pub mod php`, replace old PHP routes with new ones |
| `panel/backend/src/routes/sites.rs` | Add new fields to `CreateSiteRequest`/`UpdateLimitsRequest`, PHP version validation, remove old proxy handlers, update SQL queries |
| `panel/frontend/src/main.tsx` | Add `/php` route + lazy import |
| `panel/frontend/src/components/CommandLayout.tsx` (and other layout files) | Add PHP nav entry |
| `panel/frontend/src/pages/Sites.tsx` | Load installed PHP versions for create wizard dropdown |
| `panel/frontend/src/pages/SiteDetail.tsx` | Add new FPM fields, load installed versions for version switcher |
| `panel/cli/src/commands/php.rs` | Full spec CLI commands |
| `panel/cli/src/main.rs` | Add new `PhpCmd` subcommands (Remove, Info, Extensions, FpmReload) |

---

## Task 1: Database migrations

**Files:**
- Create: `panel/backend/migrations/20260502000000_php_versions.sql`
- Create: `panel/backend/migrations/20260502000001_php_site_fpm_fields.sql`

- [ ] **Step 1: Write the php_versions migration**

Create `panel/backend/migrations/20260502000000_php_versions.sql`:

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

CREATE INDEX idx_php_versions_server_id ON php_versions(server_id);
CREATE INDEX idx_php_versions_status ON php_versions(server_id, status);
```

- [ ] **Step 2: Write the sites FPM fields migration**

Create `panel/backend/migrations/20260502000001_php_site_fpm_fields.sql`:

```sql
ALTER TABLE sites
    ADD COLUMN IF NOT EXISTS php_max_execution_time INT NOT NULL DEFAULT 300,
    ADD COLUMN IF NOT EXISTS php_upload_mb          INT NOT NULL DEFAULT 64;
```

- [ ] **Step 3: Verify migrations exist and are well-formed**

```bash
ls panel/backend/migrations/ | grep 20260502
```

Expected: two files listed — `20260502000000_php_versions.sql` and `20260502000001_php_site_fpm_fields.sql`.

- [ ] **Step 4: Commit**

```bash
git add panel/backend/migrations/20260502000000_php_versions.sql \
        panel/backend/migrations/20260502000001_php_site_fpm_fields.sql
git commit -m "feat(db): add php_versions table and sites FPM fields migrations"
```

---

## Task 2: Update Site model

**Files:**
- Modify: `panel/backend/src/models.rs` (add new fields to `Site` struct)

- [ ] **Step 1: Add fields to Site struct**

In `panel/backend/src/models.rs`, find the `Site` struct and add after `pub php_max_workers: i32`:

```rust
pub php_max_execution_time: i32,
pub php_upload_mb: i32,
```

The relevant section of the struct (show full context):

```rust
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Site {
    pub id: Uuid,
    pub user_id: Uuid,
    pub server_id: Option<Uuid>,
    // ... other fields ...
    pub php_memory_mb: i32,
    pub php_max_workers: i32,
    pub php_max_execution_time: i32,   // NEW
    pub php_upload_mb: i32,            // NEW
    pub custom_nginx: Option<String>,
    pub php_preset: Option<String>,
    pub app_command: Option<String>,
    // ... rest unchanged ...
}
```

- [ ] **Step 2: Verify the backend compiles**

```bash
cargo clippy --manifest-path panel/backend/Cargo.toml --release 2>&1 | head -30
```

Expected: warnings only (possibly about unused imports), zero errors.

> Note: If sqlx compile-time checks fail because the DB hasn't been migrated yet, set `SQLX_OFFLINE=true` for now. The queries will be verified in later tasks once all SQL is updated.

- [ ] **Step 3: Commit**

```bash
git add panel/backend/src/models.rs
git commit -m "feat(backend): add php_max_execution_time and php_upload_mb to Site model"
```

---

## Task 3: Create agent PHP service module

**Files:**
- Create: `panel/agent/src/services/php.rs`
- Modify: `panel/agent/src/services/mod.rs`

- [ ] **Step 1: Create services/php.rs**

Create `panel/agent/src/services/php.rs`:

```rust
use crate::safe_cmd::safe_command;

/// All PHP versions ArcPanel supports managing.
pub const SUPPORTED_VERSIONS: &[&str] = &["5.6", "7.4", "8.0", "8.1", "8.2", "8.3", "8.4"];

/// Extension allowlist. Names must match the `php{v}-{ext}` Ondrej PPA package suffix.
pub const ALLOWED_EXTENSIONS: &[&str] = &[
    // common
    "mbstring", "curl", "zip", "gd", "xml", "bcmath", "intl", "soap", "opcache",
    "mysqli", "pgsql", "sqlite3", "pdo", "pdo-mysql", "pdo-pgsql",
    // extras
    "redis", "imagick", "memcached", "xdebug", "mongodb", "ldap", "imap",
    "enchant", "tidy", "xmlrpc", "snmp", "readline",
];

pub fn is_supported_version(v: &str) -> bool {
    SUPPORTED_VERSIONS.contains(&v)
}

pub fn is_allowed_extension(ext: &str) -> bool {
    ALLOWED_EXTENSIONS.contains(&ext)
}

/// Check whether php{v}-fpm is installed via dpkg.
pub async fn is_installed(version: &str) -> bool {
    safe_command("dpkg")
        .args(["-s", &format!("php{version}-fpm")])
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Check whether the PHP-FPM systemd service is active.
pub async fn is_fpm_running(version: &str) -> bool {
    safe_command("systemctl")
        .args(["is-active", "--quiet", &format!("php{version}-fpm")])
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Check whether the default FPM socket file exists.
pub fn socket_exists(version: &str) -> bool {
    std::path::Path::new(&format!("/run/php/php{version}-fpm.sock")).exists()
}

/// Ensure the Ondrej PHP PPA is registered and apt is up to date.
async fn ensure_ppa() -> Result<(), String> {
    // Check whether PPA is already configured.
    let check = safe_command("apt-cache")
        .args(["policy", &format!("php8.3-fpm")])
        .output()
        .await;
    let already_added = check
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("ondrej"))
        .unwrap_or(false);

    if !already_added {
        tracing::info!("Adding ondrej/php PPA...");
        let r = safe_command("bash")
            .args(["-c",
                "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                 apt-get install -y -qq software-properties-common && \
                 add-apt-repository -y ppa:ondrej/php && \
                 apt-get update -qq",
            ])
            .output()
            .await
            .map_err(|e| format!("Failed to add PHP PPA: {e}"))?;
        if !r.status.success() {
            let stderr = String::from_utf8_lossy(&r.stderr);
            return Err(format!("PPA setup failed: {}", &stderr[..stderr.len().min(300)]));
        }
    }
    Ok(())
}

/// Install a PHP version via the Ondrej PPA (native).
/// `default_extensions` — additional package suffixes to install (e.g. `["redis","gd"]`).
pub async fn install_native(version: &str, extra_extensions: &[String]) -> Result<(), String> {
    ensure_ppa().await?;

    let mut packages = vec![
        format!("php{version}-fpm"),
        format!("php{version}-cli"),
        format!("php{version}-common"),
        format!("php{version}-mbstring"),
        format!("php{version}-curl"),
        format!("php{version}-zip"),
        format!("php{version}-xml"),
        format!("php{version}-bcmath"),
    ];
    for ext in extra_extensions {
        if is_allowed_extension(ext) {
            packages.push(format!("php{version}-{ext}"));
        }
    }
    let pkg_str = packages.join(" ");

    tracing::info!("Installing PHP {version}: {pkg_str}");

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(600),
        safe_command("bash")
            .args(["-c", &format!("DEBIAN_FRONTEND=noninteractive apt-get install -y -qq {pkg_str} 2>&1")])
            .output(),
    )
    .await
    .map_err(|_| "Installation timed out (10 min limit)".to_string())?
    .map_err(|e| format!("Install command error: {e}"))?;

    if !output.status.success() {
        let out = String::from_utf8_lossy(&output.stdout);
        return Err(format!("apt install failed: {}", &out[..out.len().min(500)]));
    }

    // Enable and start FPM
    let _ = safe_command("systemctl")
        .args(["enable", "--now", &format!("php{version}-fpm")])
        .output()
        .await;

    tracing::info!("PHP {version} (native) installed and started");
    Ok(())
}

/// Install a PHP-FPM Docker container for the given version.
pub async fn install_docker(version: &str) -> Result<(), String> {
    let image = format!("php:{version}-fpm-alpine");
    let container = format!("php{version}-fpm");
    let volume = format!("php{version}-fpm-socket");
    let symlink = format!("/run/php/php{version}-fpm.sock");
    let vol_data_path = format!("/var/lib/docker/volumes/{volume}/_data/php-fpm.sock");

    // Pull image
    let pull = tokio::time::timeout(
        std::time::Duration::from_secs(300),
        safe_command("docker").args(["pull", &image]).output(),
    )
    .await
    .map_err(|_| "Docker pull timed out".to_string())?
    .map_err(|e| format!("docker pull error: {e}"))?;
    if !pull.status.success() {
        return Err(format!("docker pull failed: {}", String::from_utf8_lossy(&pull.stderr)));
    }

    // Create socket volume
    let _ = safe_command("docker")
        .args(["volume", "create", &volume])
        .output()
        .await;

    // Run FPM container
    let run = safe_command("docker")
        .args([
            "run", "-d",
            "--name", &container,
            "-v", "/var/www:/var/www:ro",
            "-v", &format!("{volume}:/run/php"),
            "--restart", "unless-stopped",
            &image,
        ])
        .output()
        .await
        .map_err(|e| format!("docker run error: {e}"))?;
    if !run.status.success() {
        return Err(format!("docker run failed: {}", String::from_utf8_lossy(&run.stderr)));
    }

    // Wait briefly for the socket to appear then symlink for nginx compatibility
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let _ = std::fs::create_dir_all("/run/php");
    if std::path::Path::new(&symlink).exists() {
        let _ = std::fs::remove_file(&symlink);
    }
    if let Err(e) = std::os::unix::fs::symlink(&vol_data_path, &symlink) {
        tracing::warn!("Failed to create FPM socket symlink for docker PHP {version}: {e}");
    }

    tracing::info!("PHP {version} (docker) container started");
    Ok(())
}

/// Uninstall a PHP version installed via native apt.
pub async fn uninstall_native(version: &str) -> Result<(), String> {
    let _ = safe_command("systemctl")
        .args(["stop", &format!("php{version}-fpm")])
        .output()
        .await;
    let _ = safe_command("systemctl")
        .args(["disable", &format!("php{version}-fpm")])
        .output()
        .await;

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(300),
        safe_command("bash")
            .args(["-c", &format!("DEBIAN_FRONTEND=noninteractive apt-get purge -y php{version}-* 2>&1")])
            .output(),
    )
    .await
    .map_err(|_| "Uninstall timed out".to_string())?
    .map_err(|e| format!("apt purge error: {e}"))?;

    if !output.status.success() {
        let out = String::from_utf8_lossy(&output.stdout);
        return Err(format!("apt purge failed: {}", &out[..out.len().min(500)]));
    }

    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        safe_command("bash")
            .args(["-c", "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1"])
            .output(),
    )
    .await;

    let _ = std::fs::remove_dir_all(format!("/etc/php/{version}"));
    tracing::info!("PHP {version} (native) uninstalled");
    Ok(())
}

/// Uninstall a PHP version running as a Docker container.
pub async fn uninstall_docker(version: &str) -> Result<(), String> {
    let container = format!("php{version}-fpm");
    let volume = format!("php{version}-fpm-socket");
    let image = format!("php:{version}-fpm-alpine");
    let symlink = format!("/run/php/php{version}-fpm.sock");

    let _ = safe_command("docker").args(["stop", &container]).output().await;
    let _ = safe_command("docker").args(["rm", &container]).output().await;
    let _ = safe_command("docker").args(["volume", "rm", &volume]).output().await;
    let _ = safe_command("docker").args(["rmi", &image]).output().await;
    let _ = std::fs::remove_file(&symlink);

    tracing::info!("PHP {version} (docker) uninstalled");
    Ok(())
}

/// Install a single extension for a native PHP install.
pub async fn install_extension(version: &str, ext: &str) -> Result<(), String> {
    if !is_allowed_extension(ext) {
        return Err(format!("Extension '{ext}' is not in the supported allowlist"));
    }
    let package = format!("php{version}-{ext}");
    tracing::info!("Installing PHP extension: {package}");

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        safe_command("apt-get")
            .args(["install", "-y", &package])
            .env("DEBIAN_FRONTEND", "noninteractive")
            .output(),
    )
    .await
    .map_err(|_| "Extension install timed out".to_string())?
    .map_err(|e| format!("apt-get error: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Install failed: {}", &stderr[..stderr.len().min(300)]));
    }

    let _ = safe_command("systemctl")
        .args(["reload", &format!("php{version}-fpm")])
        .output()
        .await;

    Ok(())
}

/// Remove a single extension from a native PHP install.
pub async fn remove_extension(version: &str, ext: &str) -> Result<(), String> {
    if !is_allowed_extension(ext) {
        return Err(format!("Extension '{ext}' is not in the supported allowlist"));
    }
    let package = format!("php{version}-{ext}");
    tracing::info!("Removing PHP extension: {package}");

    let output = safe_command("apt-get")
        .args(["remove", "-y", &package])
        .env("DEBIAN_FRONTEND", "noninteractive")
        .output()
        .await
        .map_err(|e| format!("apt-get error: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Remove failed: {}", &stderr[..stderr.len().min(300)]));
    }

    let _ = safe_command("systemctl")
        .args(["reload", &format!("php{version}-fpm")])
        .output()
        .await;

    Ok(())
}

/// Reload PHP-FPM for a specific version.
pub async fn reload_fpm(version: &str) -> Result<(), String> {
    let service = format!("php{version}-fpm");
    let output = safe_command("systemctl")
        .args(["reload", &service])
        .output()
        .await
        .map_err(|e| format!("systemctl error: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("FPM reload failed: {}", &stderr[..stderr.len().min(200)]));
    }
    Ok(())
}

/// Return key PHP binary info: version string, loaded extension names, key ini values.
pub async fn get_php_info(version: &str) -> Result<serde_json::Value, String> {
    let binary = format!("php{version}");

    // Version string
    let ver_out = safe_command(&binary)
        .args(["--version"])
        .output()
        .await
        .map_err(|e| format!("Cannot run {binary}: {e}"))?;
    let ver_str = String::from_utf8_lossy(&ver_out.stdout)
        .lines()
        .next()
        .unwrap_or("")
        .to_string();

    // Loaded extensions
    let ext_out = safe_command(&binary)
        .args(["-r", "echo implode(',', get_loaded_extensions());"])
        .output()
        .await;
    let extensions: Vec<String> = ext_out
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split(',')
                .map(|s| s.trim().to_lowercase())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default();

    // Key ini values
    let ini_keys = ["memory_limit", "upload_max_filesize", "max_execution_time", "post_max_size"];
    let ini_query = ini_keys
        .iter()
        .map(|k| format!("echo '{k}='.ini_get('{k}');"))
        .collect::<Vec<_>>()
        .join("");
    let ini_out = safe_command(&binary)
        .args(["-r", &ini_query])
        .output()
        .await;
    let ini: std::collections::HashMap<String, String> = ini_out
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter_map(|l| {
                    let mut parts = l.splitn(2, '=');
                    Some((parts.next()?.to_string(), parts.next()?.to_string()))
                })
                .collect()
        })
        .unwrap_or_default();

    Ok(serde_json::json!({
        "version": version,
        "version_string": ver_str,
        "extensions": extensions,
        "ini": ini,
        "fpm_running": is_fpm_running(version).await,
        "socket": format!("/run/php/php{version}-fpm.sock"),
    }))
}
```

- [ ] **Step 2: Add php module to services/mod.rs**

In `panel/agent/src/services/mod.rs`, add at the end of the existing `pub mod` list:

```rust
pub mod php;
```

- [ ] **Step 3: Verify the agent compiles**

```bash
cargo clippy --manifest-path panel/agent/Cargo.toml --release 2>&1 | head -30
```

Expected: zero errors (warnings are fine).

- [ ] **Step 4: Commit**

```bash
git add panel/agent/src/services/php.rs panel/agent/src/services/mod.rs
git commit -m "feat(agent): add PHP service module with install/uninstall/extension logic"
```

---

## Task 4: Rewrite agent PHP routes

**Files:**
- Modify: `panel/agent/src/routes/php.rs` (full rewrite)

The existing routes use different paths and limited version list. This task replaces the file with spec-compliant routes that delegate to `services::php`.

- [ ] **Step 1: Replace routes/php.rs**

Replace `panel/agent/src/routes/php.rs` entirely:

```rust
use axum::{
    extract::Path,
    http::StatusCode,
    routing::{delete, get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::services;
use super::AppState;

// ── helper ──────────────────────────────────────────────────────────────────

type ApiErr = (StatusCode, Json<serde_json::Value>);

fn err(status: StatusCode, msg: &str) -> ApiErr {
    (status, Json(serde_json::json!({ "error": msg })))
}

// ── list ────────────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct PhpVersionInfo {
    version: String,
    installed: bool,
    install_method: String,
    fpm_running: bool,
    socket: String,
}

/// GET /php/versions — List all versions with install/running status.
async fn list_versions() -> Json<serde_json::Value> {
    let mut versions = Vec::new();
    for &v in services::php::SUPPORTED_VERSIONS {
        let installed = services::php::is_installed(v).await;
        let fpm_running = installed && (services::php::is_fpm_running(v).await || services::php::socket_exists(v));
        // Detect docker install by checking for container
        let method = if installed {
            let docker_check = crate::safe_cmd::safe_command("docker")
                .args(["inspect", "--format", "{{.State.Running}}", &format!("php{v}-fpm")])
                .output()
                .await;
            if docker_check.map(|o| o.status.success()).unwrap_or(false) {
                "docker"
            } else {
                "native"
            }
        } else {
            "native"
        };
        versions.push(PhpVersionInfo {
            version: v.to_string(),
            installed,
            install_method: method.to_string(),
            fpm_running,
            socket: format!("/run/php/php{v}-fpm.sock"),
        });
    }
    Json(serde_json::json!({ "versions": versions }))
}

// ── install ──────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct InstallRequest {
    version: String,
    #[serde(default = "default_method")]
    method: String,
    #[serde(default)]
    extensions: Vec<String>,
}

fn default_method() -> String {
    "native".into()
}

/// POST /php/install — Install a PHP version.
async fn install_version(
    Json(body): Json<InstallRequest>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    let version = body.version.trim().to_string();
    if !services::php::is_supported_version(&version) {
        return Err(err(
            StatusCode::BAD_REQUEST,
            &format!("Unsupported PHP version. Allowed: {}", services::php::SUPPORTED_VERSIONS.join(", ")),
        ));
    }
    if services::php::is_installed(&version).await {
        return Err(err(
            StatusCode::CONFLICT,
            &format!("PHP {version} is already installed on this server"),
        ));
    }

    match body.method.as_str() {
        "docker" => services::php::install_docker(&version).await,
        _ => services::php::install_native(&version, &body.extensions).await,
    }
    .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e))?;

    Ok(Json(serde_json::json!({
        "ok": true,
        "version": version,
        "method": body.method,
    })))
}

// ── uninstall ────────────────────────────────────────────────────────────────

/// DELETE /php/versions/:version — Uninstall a PHP version.
async fn uninstall_version(
    Path(version): Path<String>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !services::php::is_supported_version(&version) {
        return Err(err(StatusCode::BAD_REQUEST, "Unsupported PHP version"));
    }
    if !services::php::is_installed(&version).await {
        return Ok(Json(serde_json::json!({ "ok": true, "message": "Not installed" })));
    }

    // Detect method by checking docker container
    let is_docker = crate::safe_cmd::safe_command("docker")
        .args(["inspect", "--format", "{{.State.Running}}", &format!("php{version}-fpm")])
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);

    if is_docker {
        services::php::uninstall_docker(&version).await
    } else {
        services::php::uninstall_native(&version).await
    }
    .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e))?;

    Ok(Json(serde_json::json!({ "ok": true, "version": version })))
}

// ── extensions ───────────────────────────────────────────────────────────────

/// GET /php/versions/:version/extensions — List installed extensions.
async fn list_extensions(
    Path(version): Path<String>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !services::php::is_supported_version(&version) {
        return Err(err(StatusCode::BAD_REQUEST, "Unsupported PHP version"));
    }
    let binary = format!("php{version}");
    let out = crate::safe_cmd::safe_command(&binary)
        .args(["-r", "echo implode(',', get_loaded_extensions());"])
        .output()
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &format!("{e}")))?;

    let installed: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .split(',')
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();

    Ok(Json(serde_json::json!({
        "version": version,
        "installed": installed,
        "available": services::php::ALLOWED_EXTENSIONS,
    })))
}

#[derive(Deserialize)]
struct InstallExtRequest {
    name: String,
}

/// POST /php/versions/:version/extensions — Install an extension.
async fn install_extension(
    Path(version): Path<String>,
    Json(body): Json<InstallExtRequest>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !services::php::is_supported_version(&version) {
        return Err(err(StatusCode::BAD_REQUEST, "Unsupported PHP version"));
    }
    if !services::php::is_allowed_extension(&body.name) {
        return Err(err(
            StatusCode::BAD_REQUEST,
            &format!("Extension '{}' is not supported", body.name),
        ));
    }
    services::php::install_extension(&version, &body.name)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e))?;
    Ok(Json(serde_json::json!({ "ok": true, "extension": body.name })))
}

/// DELETE /php/versions/:version/extensions/:name — Remove an extension.
async fn remove_extension(
    Path((version, name)): Path<(String, String)>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !services::php::is_supported_version(&version) {
        return Err(err(StatusCode::BAD_REQUEST, "Unsupported PHP version"));
    }
    if !services::php::is_allowed_extension(&name) {
        return Err(err(
            StatusCode::BAD_REQUEST,
            &format!("Extension '{name}' is not supported"),
        ));
    }
    services::php::remove_extension(&version, &name)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e))?;
    Ok(Json(serde_json::json!({ "ok": true, "extension": name })))
}

// ── info ─────────────────────────────────────────────────────────────────────

/// GET /php/versions/:version/info — PHP binary info.
async fn get_info(
    Path(version): Path<String>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !services::php::is_supported_version(&version) {
        return Err(err(StatusCode::BAD_REQUEST, "Unsupported PHP version"));
    }
    let info = services::php::get_php_info(&version)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e))?;
    Ok(Json(info))
}

// ── FPM reload ───────────────────────────────────────────────────────────────

/// POST /php/versions/:version/reload-fpm — Reload FPM for a version.
async fn reload_fpm(
    Path(version): Path<String>,
) -> Result<Json<serde_json::Value>, ApiErr> {
    if !services::php::is_supported_version(&version) {
        return Err(err(StatusCode::BAD_REQUEST, "Unsupported PHP version"));
    }
    services::php::reload_fpm(&version)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, &e))?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

// ── router ───────────────────────────────────────────────────────────────────

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/php/versions", get(list_versions))
        .route("/php/install", post(install_version))
        .route("/php/versions/{version}", delete(uninstall_version))
        .route("/php/versions/{version}/extensions", get(list_extensions).post(install_extension))
        .route("/php/versions/{version}/extensions/{name}", delete(remove_extension))
        .route("/php/versions/{version}/info", get(get_info))
        .route("/php/versions/{version}/reload-fpm", post(reload_fpm))
}
```

- [ ] **Step 2: Verify the agent compiles**

```bash
cargo clippy --manifest-path panel/agent/Cargo.toml --release 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 3: Commit**

```bash
git add panel/agent/src/routes/php.rs
git commit -m "feat(agent): rewrite PHP routes — spec paths, Docker support, extension allowlist"
```

---

## Task 5: Update agent nginx service — FPM pool config

**Files:**
- Modify: `panel/agent/src/services/nginx.rs` (update `write_php_pool_config` signature)
- Modify: `panel/agent/src/routes/nginx.rs` (update `SiteConfig` and call site)

- [ ] **Step 1: Update write_php_pool_config signature and body**

In `panel/agent/src/services/nginx.rs`, replace the `write_php_pool_config` function (lines ~283–329):

```rust
/// Write a per-site PHP-FPM pool config with resource limits.
pub fn write_php_pool_config(
    domain: &str,
    php_version: &str,
    memory_mb: u32,
    max_workers: u32,
    upload_mb: u32,
    max_execution_time: u32,
) -> Result<(), String> {
    let pool_dir = format!("/etc/php/{php_version}/fpm/pool.d");
    if !std::path::Path::new(&pool_dir).exists() {
        return Ok(());
    }

    let pool_name = domain.replace('.', "_");
    let start = std::cmp::min(2, max_workers);
    let spare = std::cmp::min(3, max_workers);

    let config = format!(
        r#"[{pool_name}]
user = www-data
group = www-data
listen = /run/php/php{php_version}-fpm-{pool_name}.sock
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
"#
    );

    let pool_path = format!("{pool_dir}/{pool_name}.conf");
    std::fs::write(&pool_path, &config)
        .map_err(|e| format!("Failed to write FPM pool config: {e}"))?;

    tracing::info!(
        "PHP-FPM pool config written: {pool_path} \
         (workers={max_workers}, memory={memory_mb}M, upload={upload_mb}M, max_exec={max_execution_time}s)"
    );
    Ok(())
}
```

- [ ] **Step 2: Add new fields to SiteConfig in routes/nginx.rs**

In `panel/agent/src/routes/nginx.rs`, find the `SiteConfig` struct and add after `pub php_max_workers: Option<u32>`:

```rust
/// php_admin_value[max_execution_time]
pub php_max_execution_time: Option<u32>,
/// php_admin_value[upload_max_filesize] and post_max_size
pub php_upload_mb: Option<u32>,
```

- [ ] **Step 3: Update the write_php_pool_config call in put_site**

In `panel/agent/src/routes/nginx.rs`, find the call to `write_php_pool_config` (around line 167) and update it:

```rust
let memory = config.php_memory_mb.unwrap_or(256);
let workers = config.php_max_workers.unwrap_or(5);
let upload_mb = config.php_upload_mb.unwrap_or(64);
let max_exec = config.php_max_execution_time.unwrap_or(300);
if let Err(e) = services::nginx::write_php_pool_config(
    &domain, ver, memory, workers, upload_mb, max_exec,
) {
```

- [ ] **Step 4: Verify the agent compiles**

```bash
cargo clippy --manifest-path panel/agent/Cargo.toml --release 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add panel/agent/src/services/nginx.rs panel/agent/src/routes/nginx.rs
git commit -m "feat(agent): pass upload_mb and max_execution_time to FPM pool config"
```

---

## Task 6: Create backend PHP route module

**Files:**
- Create: `panel/backend/src/routes/php.rs`

This module owns all DB CRUD for PHP versions and proxies agent calls. It reuses the `provision_logs` broadcast pattern from `sites.rs` for SSE install progress.

- [ ] **Step 1: Create panel/backend/src/routes/php.rs**

```rust
use axum::{
    extract::Path,
    http::StatusCode,
    response::sse::{Event, KeepAlive, Sse},
    routing::{delete, get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use futures::StreamExt;
use std::time::{Duration, Instant};
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use uuid::Uuid;

use crate::auth::{AdminUser, AuthUser, ServerScope};
use crate::error::{err, internal_error, agent_error, ApiError};
use crate::routes::sites::ProvisionStep;
use crate::services::activity;
use crate::AppState;

// ── model ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, sqlx::FromRow)]
pub struct PhpVersion {
    pub id: Uuid,
    pub server_id: Uuid,
    pub version: String,
    pub status: String,
    pub install_method: String,
    pub extensions: Vec<String>,
    pub error_message: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

const SUPPORTED_VERSIONS: &[&str] = &["5.6", "7.4", "8.0", "8.1", "8.2", "8.3", "8.4"];

fn validate_version(v: &str) -> Result<(), ApiError> {
    if SUPPORTED_VERSIONS.contains(&v) {
        Ok(())
    } else {
        Err(err(StatusCode::BAD_REQUEST, "Unsupported PHP version"))
    }
}

// ── handlers ─────────────────────────────────────────────────────────────────

/// GET /api/php/versions — List php_versions rows for the current server.
pub async fn list_versions(
    axum::extract::State(state): axum::extract::State<AppState>,
    AuthUser(_claims): AuthUser,
    ServerScope(server_id, _agent): ServerScope,
) -> Result<Json<Vec<PhpVersion>>, ApiError> {
    let rows: Vec<PhpVersion> = sqlx::query_as(
        "SELECT * FROM php_versions WHERE server_id = $1 ORDER BY version DESC",
    )
    .bind(server_id)
    .fetch_all(&state.db)
    .await
    .map_err(|e| internal_error("list php versions", e))?;

    Ok(Json(rows))
}

/// GET /api/php/versions/:version — Single version record.
pub async fn get_version(
    axum::extract::State(state): axum::extract::State<AppState>,
    AuthUser(_claims): AuthUser,
    ServerScope(server_id, _agent): ServerScope,
    Path(version): Path<String>,
) -> Result<Json<PhpVersion>, ApiError> {
    validate_version(&version)?;
    let row: Option<PhpVersion> = sqlx::query_as(
        "SELECT * FROM php_versions WHERE server_id = $1 AND version = $2",
    )
    .bind(server_id)
    .bind(&version)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| internal_error("get php version", e))?;

    row.map(Json)
        .ok_or_else(|| err(StatusCode::NOT_FOUND, "PHP version not found"))
}

// ── install ───────────────────────────────────────────────────────────────────

#[derive(serde::Deserialize)]
pub struct InstallRequest {
    pub version: String,
    #[serde(default = "default_method")]
    pub method: String,
    #[serde(default)]
    pub extensions: Vec<String>,
}

fn default_method() -> String {
    "native".into()
}

#[derive(serde::Serialize)]
struct InstallResponse {
    id: Uuid,
    version: String,
    status: String,
    progress_url: String,
}

/// POST /api/php/versions — Insert DB row then trigger agent install via background task.
/// Returns 202 with a progress_url to subscribe to for SSE events.
pub async fn install_version(
    axum::extract::State(state): axum::extract::State<AppState>,
    AdminUser(claims): AdminUser,
    ServerScope(server_id, agent): ServerScope,
    Json(body): Json<InstallRequest>,
) -> Result<(StatusCode, Json<InstallResponse>), ApiError> {
    let version = body.version.trim().to_string();
    validate_version(&version)?;

    // Reject if already tracked in DB with non-error status
    let existing: Option<(String,)> = sqlx::query_as(
        "SELECT status FROM php_versions WHERE server_id = $1 AND version = $2",
    )
    .bind(server_id)
    .bind(&version)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| internal_error("check php version", e))?;

    if let Some((status,)) = existing {
        if status != "error" {
            return Err(err(
                StatusCode::CONFLICT,
                &format!("PHP {version} is already installed on this server"),
            ));
        }
        // Re-try after previous error: update to 'installing'
        sqlx::query(
            "UPDATE php_versions SET status = 'installing', error_message = NULL, updated_at = NOW() \
             WHERE server_id = $1 AND version = $2",
        )
        .bind(server_id)
        .bind(&version)
        .execute(&state.db)
        .await
        .map_err(|e| internal_error("reset php version status", e))?;
    } else {
        sqlx::query(
            "INSERT INTO php_versions (server_id, version, status, install_method) VALUES ($1, $2, 'installing', $3)",
        )
        .bind(server_id)
        .bind(&version)
        .bind(&body.method)
        .execute(&state.db)
        .await
        .map_err(|e| internal_error("insert php version", e))?;
    }

    let row: PhpVersion = sqlx::query_as(
        "SELECT * FROM php_versions WHERE server_id = $1 AND version = $2",
    )
    .bind(server_id)
    .bind(&version)
    .fetch_one(&state.db)
    .await
    .map_err(|e| internal_error("fetch inserted php version", e))?;

    let install_id = row.id;
    let progress_url = format!("/api/php/install-progress/{install_id}");

    // Set up broadcast channel in provision_logs
    let (tx, _) = broadcast::channel::<ProvisionStep>(32);
    {
        let mut logs = state.provision_logs.lock().unwrap_or_else(|e| e.into_inner());
        logs.insert(install_id, (Vec::new(), tx, Instant::now()));
    }

    let logs = state.provision_logs.clone();
    let db = state.db.clone();
    let version_clone = version.clone();
    let method = body.method.clone();
    let extensions = body.extensions.clone();
    let user_id = claims.sub;
    let email = claims.email.clone();

    let emit = move |step: &str, label: &str, status: &str, msg: Option<String>| {
        let ev = ProvisionStep {
            step: step.into(),
            label: label.into(),
            status: status.into(),
            message: msg,
        };
        if let Ok(mut map) = logs.lock() {
            if let Some((history, tx, _)) = map.get_mut(&install_id) {
                history.push(ev.clone());
                let _ = tx.send(ev);
            }
        }
    };

    let logs_cleanup = state.provision_logs.clone();

    tokio::spawn(async move {
        emit(
            "install",
            &format!("Installing PHP {version_clone}"),
            "in_progress",
            None,
        );

        let agent_body = serde_json::json!({
            "version": version_clone,
            "method": method,
            "extensions": extensions,
        });

        match agent.post("/php/install", agent_body).await {
            Ok(_) => {
                // Update DB: active + store installed extensions
                let ext_query = format!(
                    "UPDATE php_versions SET status = 'active', updated_at = NOW() \
                     WHERE server_id = $1 AND version = $2"
                );
                let _ = sqlx::query(&ext_query)
                    .bind(server_id)
                    .bind(&version_clone)
                    .execute(&db)
                    .await;

                emit(
                    "install",
                    &format!("Installing PHP {version_clone}"),
                    "done",
                    None,
                );
                emit("complete", "PHP version active", "done", None);

                activity::log_activity(
                    &db, user_id, &email, "php.install",
                    Some("php"), Some(&version_clone), None, None,
                )
                .await;
                tracing::info!("PHP {version_clone} installed successfully");
            }
            Err(e) => {
                let msg = format!("{e}");
                let _ = sqlx::query(
                    "UPDATE php_versions SET status = 'error', error_message = $3, updated_at = NOW() \
                     WHERE server_id = $1 AND version = $2",
                )
                .bind(server_id)
                .bind(&version_clone)
                .bind(&msg)
                .execute(&db)
                .await;

                emit("install", &format!("Installing PHP {version_clone}"), "error", Some(msg.clone()));
                emit("complete", "Installation failed", "error", Some(msg));
                tracing::error!("PHP {version_clone} install failed: {e}");
            }
        }

        tokio::time::sleep(Duration::from_secs(60)).await;
        logs_cleanup
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&install_id);
    });

    Ok((
        StatusCode::ACCEPTED,
        Json(InstallResponse {
            id: install_id,
            version,
            status: "installing".into(),
            progress_url,
        }),
    ))
}

// ── delete ────────────────────────────────────────────────────────────────────

/// DELETE /api/php/versions/:version — Check no sites use it, then uninstall + remove row.
pub async fn delete_version(
    axum::extract::State(state): axum::extract::State<AppState>,
    AdminUser(claims): AdminUser,
    ServerScope(server_id, agent): ServerScope,
    Path(version): Path<String>,
) -> Result<StatusCode, ApiError> {
    validate_version(&version)?;

    // Guard: reject if any site on this server uses this PHP version
    let site_count: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM sites WHERE server_id = $1 AND php_version = $2",
    )
    .bind(server_id)
    .bind(&version)
    .fetch_one(&state.db)
    .await
    .map_err(|e| internal_error("check sites for php version", e))?;

    if site_count.0 > 0 {
        return Err(err(
            StatusCode::CONFLICT,
            &format!(
                "PHP {version} is in use by {} site(s). Migrate those sites first.",
                site_count.0
            ),
        ));
    }

    // Mark as removing
    sqlx::query(
        "UPDATE php_versions SET status = 'removing', updated_at = NOW() \
         WHERE server_id = $1 AND version = $2",
    )
    .bind(server_id)
    .bind(&version)
    .execute(&state.db)
    .await
    .map_err(|e| internal_error("mark php version removing", e))?;

    // Call agent to uninstall
    agent
        .delete(&format!("/php/versions/{version}"))
        .await
        .map_err(|e| agent_error("PHP uninstall", e))?;

    // Remove the DB row
    sqlx::query("DELETE FROM php_versions WHERE server_id = $1 AND version = $2")
        .bind(server_id)
        .bind(&version)
        .execute(&state.db)
        .await
        .map_err(|e| internal_error("delete php version row", e))?;

    activity::log_activity(
        &state.db, claims.sub, &claims.email, "php.remove",
        Some("php"), Some(&version), None, None,
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

// ── extensions ────────────────────────────────────────────────────────────────

/// GET /api/php/versions/:version/extensions — Extensions list from DB row.
pub async fn list_extensions(
    axum::extract::State(state): axum::extract::State<AppState>,
    AuthUser(_claims): AuthUser,
    ServerScope(server_id, _agent): ServerScope,
    Path(version): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_version(&version)?;
    let row: Option<PhpVersion> = sqlx::query_as(
        "SELECT * FROM php_versions WHERE server_id = $1 AND version = $2",
    )
    .bind(server_id)
    .bind(&version)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| internal_error("get php version extensions", e))?;

    let row = row.ok_or_else(|| err(StatusCode::NOT_FOUND, "PHP version not found"))?;
    Ok(Json(serde_json::json!({
        "version": version,
        "installed": row.extensions,
    })))
}

#[derive(serde::Deserialize)]
pub struct ExtensionRequest {
    pub name: String,
}

/// POST /api/php/versions/:version/extensions — Install extension via agent + update DB.
pub async fn install_extension(
    axum::extract::State(state): axum::extract::State<AppState>,
    AdminUser(claims): AdminUser,
    ServerScope(server_id, agent): ServerScope,
    Path(version): Path<String>,
    Json(body): Json<ExtensionRequest>,
) -> Result<Json<PhpVersion>, ApiError> {
    validate_version(&version)?;

    agent
        .post(
            &format!("/php/versions/{version}/extensions"),
            serde_json::json!({ "name": body.name }),
        )
        .await
        .map_err(|e| agent_error("Install PHP extension", e))?;

    // Add to DB extensions array
    let updated: PhpVersion = sqlx::query_as(
        "UPDATE php_versions \
         SET extensions = array_append(extensions, $3), updated_at = NOW() \
         WHERE server_id = $1 AND version = $2 \
         RETURNING *",
    )
    .bind(server_id)
    .bind(&version)
    .bind(&body.name)
    .fetch_one(&state.db)
    .await
    .map_err(|e| internal_error("update php extensions", e))?;

    activity::log_activity(
        &state.db, claims.sub, &claims.email, "php.extension.install",
        Some("php"), Some(&version), None, None,
    )
    .await;

    Ok(Json(updated))
}

/// DELETE /api/php/versions/:version/extensions/:name — Remove extension via agent + update DB.
pub async fn delete_extension(
    axum::extract::State(state): axum::extract::State<AppState>,
    AdminUser(claims): AdminUser,
    ServerScope(server_id, agent): ServerScope,
    Path((version, name)): Path<(String, String)>,
) -> Result<Json<PhpVersion>, ApiError> {
    validate_version(&version)?;

    agent
        .delete(&format!("/php/versions/{version}/extensions/{name}"))
        .await
        .map_err(|e| agent_error("Remove PHP extension", e))?;

    let updated: PhpVersion = sqlx::query_as(
        "UPDATE php_versions \
         SET extensions = array_remove(extensions, $3), updated_at = NOW() \
         WHERE server_id = $1 AND version = $2 \
         RETURNING *",
    )
    .bind(server_id)
    .bind(&version)
    .bind(&name)
    .fetch_one(&state.db)
    .await
    .map_err(|e| internal_error("update php extensions", e))?;

    Ok(Json(updated))
}

// ── SSE progress ──────────────────────────────────────────────────────────────

/// GET /api/php/install-progress/:id — SSE stream for install progress.
pub async fn install_progress(
    axum::extract::State(state): axum::extract::State<AppState>,
    AuthUser(_claims): AuthUser,
    Path(id): Path<Uuid>,
) -> Result<Sse<impl futures::Stream<Item = Result<Event, axum::BoxError>>>, ApiError> {
    let (snapshot, rx) = {
        let logs = state.provision_logs.lock().unwrap_or_else(|e| e.into_inner());
        match logs.get(&id) {
            Some((history, tx, _)) => (history.clone(), Some(tx.subscribe())),
            None => (Vec::new(), None),
        }
    };

    let rx = rx.ok_or_else(|| err(StatusCode::NOT_FOUND, "No active install progress for this id"))?;

    let snapshot_stream = futures::stream::iter(snapshot.into_iter().map(|step| {
        let data = serde_json::to_string(&step).unwrap_or_default();
        Ok(Event::default().data(data))
    }));

    let live_stream = BroadcastStream::new(rx).filter_map(|result| async {
        match result {
            Ok(step) => {
                let data = serde_json::to_string(&step).ok()?;
                Some(Ok(Event::default().data(data)))
            }
            Err(_) => None,
        }
    });

    Ok(Sse::new(snapshot_stream.chain(live_stream)).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    ))
}

// ── router ────────────────────────────────────────────────────────────────────

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/php/versions", get(list_versions).post(install_version))
        .route("/api/php/versions/{version}", get(get_version).delete(delete_version))
        .route("/api/php/versions/{version}/extensions", get(list_extensions).post(install_extension))
        .route("/api/php/versions/{version}/extensions/{name}", delete(delete_extension))
        .route("/api/php/install-progress/{id}", get(install_progress))
}
```

- [ ] **Step 2: Check that the AgentClient has a `delete` method**

In `panel/backend/src/services/agent.rs`, search for `pub async fn delete` or `pub fn delete`. If it does not exist, add it next to the existing `get`/`post`/`put` methods:

```rust
pub async fn delete(&self, path: &str) -> Result<serde_json::Value, AgentError> {
    self.request(reqwest::Method::DELETE, path, None).await
}
```

- [ ] **Step 3: Verify backend compiles**

```bash
cargo clippy --manifest-path panel/backend/Cargo.toml --release 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 4: Commit**

```bash
git add panel/backend/src/routes/php.rs
git commit -m "feat(backend): add PHP version route module with DB tracking and SSE progress"
```

---

## Task 7: Register PHP routes and clean up sites.rs

**Files:**
- Modify: `panel/backend/src/routes/mod.rs`
- Modify: `panel/backend/src/routes/sites.rs`

- [ ] **Step 1: Add `pub mod php` to routes/mod.rs**

In `panel/backend/src/routes/mod.rs`, add near the other `pub mod` declarations:

```rust
pub mod php;
```

- [ ] **Step 2: Replace old PHP routes in mod.rs router()**

In `panel/backend/src/routes/mod.rs`, find the PHP versions block:

```rust
// PHP versions
.route("/api/php/versions", get(sites::php_versions))
.route("/api/php/install", post(sites::php_install))
.route("/api/php/uninstall", post(sites::php_uninstall))
```

Replace it with a merge of the new PHP router (which already defines its own routes internally):

```rust
// PHP versions — managed by routes/php.rs
.merge(php::router())
```

> Alternatively, if the codebase uses flat `.route()` calls, add each route from `php::router()` inline. Check the file structure to see whether other modules use `.merge()`. Since the existing code uses `.merge(sites::router())` patterns elsewhere, `.merge(php::router())` is correct.

Actually, looking at the mod.rs structure, it's a flat chain of `.route()` calls, not `.merge()`. Do NOT use `.merge()` here. Instead, delete the old PHP route lines and inline the new routes:

```rust
// PHP version management
.route("/api/php/versions", get(php::list_versions).post(php::install_version))
.route("/api/php/versions/{version}", get(php::get_version).delete(php::delete_version))
.route("/api/php/versions/{version}/extensions", get(php::list_extensions).post(php::install_extension))
.route("/api/php/versions/{version}/extensions/{name}", delete(php::delete_extension))
.route("/api/php/install-progress/{id}", get(php::install_progress))
```

- [ ] **Step 3: Remove old PHP proxy handlers from sites.rs**

In `panel/backend/src/routes/sites.rs`, delete the three handlers that are now replaced:
- `pub async fn php_versions(...)` (the one that calls `agent.get("/php/versions")`)
- `pub async fn php_install(...)` 
- `pub async fn php_uninstall(...)`

Also delete the `InstallPhpRequest` struct that was only used by those handlers.

- [ ] **Step 4: Verify backend compiles**

```bash
cargo clippy --manifest-path panel/backend/Cargo.toml --release 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add panel/backend/src/routes/mod.rs panel/backend/src/routes/sites.rs
git commit -m "refactor(backend): move PHP routes to dedicated module, remove proxy stubs from sites.rs"
```

---

## Task 8: Update backend sites.rs — new FPM fields and PHP version validation

**Files:**
- Modify: `panel/backend/src/routes/sites.rs`

- [ ] **Step 1: Add new fields to CreateSiteRequest**

In `panel/backend/src/routes/sites.rs`, find `CreateSiteRequest` and add:

```rust
#[derive(serde::Deserialize)]
pub struct CreateSiteRequest {
    pub domain: String,
    pub runtime: Option<String>,
    pub proxy_port: Option<i32>,
    pub php_version: Option<String>,
    pub php_preset: Option<String>,
    pub app_command: Option<String>,
    pub php_max_execution_time: Option<i32>,  // NEW — defaults to 300
    pub php_upload_mb: Option<i32>,           // NEW — defaults to 64
    // ... CMS fields unchanged ...
    pub cms: Option<String>,
    pub site_title: Option<String>,
    pub admin_email: Option<String>,
    pub admin_user: Option<String>,
    pub admin_password: Option<String>,
}
```

- [ ] **Step 2: Add PHP version validation at site create**

In the `create` handler, after the existing `if body.runtime == "php"` check (where it resolves `php_version`), add a DB validation. Find the spot just before the site INSERT and add:

```rust
// Validate the requested PHP version is installed and active on this server
if body.runtime.as_deref() == Some("php") || body.cms.is_some() {
    if let Some(ref ver) = body.php_version {
        let active: Option<(Uuid,)> = sqlx::query_as(
            "SELECT id FROM php_versions WHERE server_id = $1 AND version = $2 AND status = 'active'",
        )
        .bind(server_id)
        .bind(ver)
        .fetch_optional(&state.db)
        .await
        .map_err(|e| internal_error("validate php version", e))?;

        if active.is_none() {
            return Err(err(
                StatusCode::UNPROCESSABLE_ENTITY,
                &format!("PHP version {ver} is not installed on this server. Install it first via the PHP page."),
            ));
        }
    }
}
```

- [ ] **Step 3: Include new fields in the site INSERT**

Find the `INSERT INTO sites` query in the `create` handler. Extend it to include the new columns:

```sql
INSERT INTO sites (
    ..., php_max_execution_time, php_upload_mb
) VALUES (
    ..., $N, $N+1
) RETURNING *
```

Bind `body.php_max_execution_time.unwrap_or(300)` and `body.php_upload_mb.unwrap_or(64)`.

> The exact position in the query and bind index will depend on the existing INSERT. Read the full INSERT statement first and insert the two new columns at the end of the column list before `RETURNING *`.

- [ ] **Step 4: Add new fields to UpdateLimitsRequest**

Find `UpdateLimitsRequest` struct and add:

```rust
pub php_max_execution_time: Option<i32>,
pub php_upload_mb: Option<i32>,
```

- [ ] **Step 5: Update update_limits handler — SQL and agent body**

In the `update_limits` handler, find the UPDATE SQL (currently updating `rate_limit, max_upload_mb, php_memory_mb, php_max_workers, custom_nginx`). Extend it:

```sql
UPDATE sites SET
    rate_limit = $1,
    max_upload_mb = $2,
    php_memory_mb = $3,
    php_max_workers = $4,
    custom_nginx = $5,
    php_max_execution_time = $6,
    php_upload_mb = $7,
    updated_at = NOW()
WHERE id = $8
RETURNING *
```

Bind `body.php_max_execution_time.unwrap_or(site.php_max_execution_time)` and `body.php_upload_mb.unwrap_or(site.php_upload_mb)`.

Also extend the `agent_body` JSON sent to the agent's nginx PUT:

```rust
agent_body["php_max_execution_time"] = serde_json::json!(updated.php_max_execution_time);
agent_body["php_upload_mb"] = serde_json::json!(updated.php_upload_mb);
```

(Use `updated` which is the post-UPDATE `Site` row so the values are authoritative.)

- [ ] **Step 6: Update switch_php version validation to check php_versions table**

Find the `switch_php` handler. It currently checks `!["8.1", "8.2", "8.3", "8.4"].contains(&version)`. Replace that allowlist check with a DB lookup:

```rust
let active: Option<(Uuid,)> = sqlx::query_as(
    "SELECT id FROM php_versions WHERE server_id = $1 AND version = $2 AND status = 'active'",
)
.bind(server_id)
.bind(version)
.fetch_optional(&state.db)
.await
.map_err(|e| internal_error("validate php version for switch", e))?;

if active.is_none() {
    return Err(err(
        StatusCode::UNPROCESSABLE_ENTITY,
        &format!("PHP version {version} is not installed on this server"),
    ));
}
```

The `server_id` comes from `ServerScope`. Add `ServerScope(server_id, agent): ServerScope` if it is not already destructuring `server_id` (currently it uses `ServerScope(_server_id, agent)` — change the `_server_id` to `server_id`).

- [ ] **Step 7: Verify backend compiles**

```bash
cargo clippy --manifest-path panel/backend/Cargo.toml --release 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 8: Commit**

```bash
git add panel/backend/src/routes/sites.rs
git commit -m "feat(backend): PHP version validation at site create/switch, new FPM fields in sites"
```

---

## Task 9: Create frontend PHP Versions page

**Files:**
- Create: `panel/frontend/src/pages/PhpVersions.tsx`

- [ ] **Step 1: Create PhpVersions.tsx**

Create `panel/frontend/src/pages/PhpVersions.tsx`:

```tsx
import { useState, useEffect, useRef } from "react";
import { api } from "../api";

// ── types ─────────────────────────────────────────────────────────────────────

interface PhpVersion {
  id: string;
  server_id: string;
  version: string;
  status: "installing" | "active" | "removing" | "error";
  install_method: "native" | "docker";
  extensions: string[];
  error_message: string | null;
  created_at: string;
}

interface InstallStep {
  step: string;
  label: string;
  status: "pending" | "in_progress" | "done" | "error";
  message: string | null;
}

const ALL_VERSIONS = ["8.4", "8.3", "8.2", "8.1", "8.0", "7.4", "5.6"] as const;

const COMMON_EXTENSIONS = [
  "mbstring", "curl", "zip", "gd", "xml", "bcmath", "redis", "imagick",
];
const ALL_EXTENSIONS = [
  "mbstring", "curl", "zip", "gd", "xml", "bcmath", "intl", "soap", "opcache",
  "mysqli", "pgsql", "sqlite3", "pdo", "pdo-mysql", "pdo-pgsql",
  "redis", "imagick", "memcached", "xdebug", "mongodb", "ldap", "imap",
  "enchant", "tidy", "xmlrpc", "snmp", "readline",
];

// ── status badge ──────────────────────────────────────────────────────────────

function StatusBadge({ status }: { status: PhpVersion["status"] }) {
  const map: Record<string, string> = {
    active: "bg-emerald-500/15 text-emerald-400",
    installing: "bg-amber-500/15 text-amber-400",
    removing: "bg-amber-500/15 text-amber-400",
    error: "bg-red-500/15 text-red-400",
  };
  return (
    <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${map[status] ?? "bg-dark-700 text-dark-200"}`}>
      {status}
    </span>
  );
}

// ── SSE install progress ──────────────────────────────────────────────────────

function InstallProgress({ progressUrl, onDone }: { progressUrl: string; onDone: () => void }) {
  const [steps, setSteps] = useState<InstallStep[]>([]);
  const doneRef = useRef(false);

  useEffect(() => {
    const token = localStorage.getItem("dp-token") ?? "";
    const baseUrl = (import.meta.env.VITE_API_URL ?? "").replace(/\/$/, "");
    const es = new EventSource(`${baseUrl}${progressUrl}?token=${token}`);

    es.onmessage = (e) => {
      try {
        const step: InstallStep = JSON.parse(e.data);
        setSteps((prev) => {
          const idx = prev.findIndex((s) => s.step === step.step);
          if (idx >= 0) {
            const next = [...prev];
            next[idx] = step;
            return next;
          }
          return [...prev, step];
        });
        if (step.step === "complete" && !doneRef.current) {
          doneRef.current = true;
          es.close();
          setTimeout(onDone, 800);
        }
      } catch {
        // ignore malformed events
      }
    };

    es.onerror = () => es.close();
    return () => es.close();
  }, [progressUrl, onDone]);

  return (
    <div className="mt-4 space-y-2">
      {steps.map((s) => (
        <div key={s.step} className="flex items-center gap-2 text-sm">
          {s.status === "in_progress" && (
            <span className="w-3 h-3 border-2 border-dark-400 border-t-accent-400 rounded-full animate-spin" />
          )}
          {s.status === "done" && <span className="text-emerald-400">✓</span>}
          {s.status === "error" && <span className="text-red-400">✗</span>}
          {s.status === "pending" && <span className="w-3 h-3 rounded-full bg-dark-600" />}
          <span className={s.status === "error" ? "text-red-400" : "text-dark-100"}>{s.label}</span>
          {s.message && <span className="text-xs text-dark-300 truncate max-w-xs">{s.message}</span>}
        </div>
      ))}
    </div>
  );
}

// ── extensions slide-over ────────────────────────────────────────────────────

function ExtensionsPanel({
  version,
  installed,
  onClose,
  onRefresh,
}: {
  version: string;
  installed: string[];
  onClose: () => void;
  onRefresh: () => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");

  const toggle = async (ext: string, isInstalled: boolean) => {
    setBusy(ext);
    setError("");
    try {
      if (isInstalled) {
        await api.delete(`/php/versions/${version}/extensions/${ext}`);
      } else {
        await api.post(`/php/versions/${version}/extensions`, { name: ext });
      }
      onRefresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Operation failed");
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex">
      <div className="flex-1 bg-black/50" onClick={onClose} />
      <div className="w-96 bg-dark-900 border-l border-dark-600 flex flex-col">
        <div className="px-5 py-4 border-b border-dark-600 flex items-center justify-between">
          <h2 className="text-sm font-medium text-dark-50">
            PHP {version} Extensions
          </h2>
          <button onClick={onClose} className="text-dark-300 hover:text-dark-100">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
        {error && (
          <div className="mx-5 mt-3 px-3 py-2 bg-red-500/10 border border-red-500/20 rounded text-sm text-red-400">
            {error}
          </div>
        )}
        <div className="flex-1 overflow-y-auto p-5 space-y-2">
          {ALL_EXTENSIONS.map((ext) => {
            const isInstalled = installed.includes(ext);
            return (
              <div
                key={ext}
                className="flex items-center justify-between py-2 border-b border-dark-700 last:border-0"
              >
                <div>
                  <span className="text-sm text-dark-100 font-mono">{ext}</span>
                  {isInstalled && (
                    <span className="ml-2 text-xs text-emerald-400">installed</span>
                  )}
                </div>
                <button
                  onClick={() => toggle(ext, isInstalled)}
                  disabled={busy === ext}
                  className={`px-2.5 py-1 rounded text-xs font-medium transition-colors disabled:opacity-50 ${
                    isInstalled
                      ? "bg-red-500/10 text-red-400 hover:bg-red-500/20"
                      : "bg-dark-700 text-dark-200 hover:bg-dark-600"
                  }`}
                >
                  {busy === ext ? "..." : isInstalled ? "Remove" : "Install"}
                </button>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ── install modal ────────────────────────────────────────────────────────────

function InstallModal({
  installedVersions,
  onClose,
  onRefresh,
}: {
  installedVersions: string[];
  onClose: () => void;
  onRefresh: () => void;
}) {
  const available = ALL_VERSIONS.filter((v) => !installedVersions.includes(v));
  const [version, setVersion] = useState(available[0] ?? "8.3");
  const [method, setMethod] = useState<"native" | "docker">("native");
  const [selectedExts, setSelectedExts] = useState<string[]>(COMMON_EXTENSIONS);
  const [installing, setInstalling] = useState(false);
  const [progressUrl, setProgressUrl] = useState("");
  const [error, setError] = useState("");

  const toggleExt = (ext: string) => {
    setSelectedExts((prev) =>
      prev.includes(ext) ? prev.filter((e) => e !== ext) : [...prev, ext]
    );
  };

  const submit = async () => {
    setError("");
    setInstalling(true);
    try {
      const res = await api.post<{ progress_url: string }>("/php/versions", {
        version,
        method,
        extensions: selectedExts,
      });
      setProgressUrl(res.progress_url);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Install failed");
      setInstalling(false);
    }
  };

  if (available.length === 0) {
    return (
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
        <div className="bg-dark-800 border border-dark-600 rounded-xl p-6 w-full max-w-md">
          <p className="text-dark-200 text-sm">All supported PHP versions are already installed.</p>
          <button onClick={onClose} className="mt-4 px-4 py-2 bg-dark-700 text-dark-100 rounded-lg text-sm">
            Close
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
      <div className="bg-dark-800 border border-dark-600 rounded-xl p-6 w-full max-w-lg">
        <h2 className="text-sm font-medium text-dark-50 uppercase tracking-widest font-mono mb-5">
          Install PHP Version
        </h2>

        {progressUrl ? (
          <InstallProgress
            progressUrl={progressUrl}
            onDone={() => { onRefresh(); onClose(); }}
          />
        ) : (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-medium text-dark-200 mb-1">Version</label>
                <select
                  value={version}
                  onChange={(e) => setVersion(e.target.value)}
                  className="w-full px-3 py-2 border border-dark-500 rounded-lg text-sm bg-dark-700 focus:ring-2 focus:ring-accent-500 outline-none"
                >
                  {available.map((v) => (
                    <option key={v} value={v}>
                      PHP {v}
                      {v === "8.3" ? " (recommended)" : ""}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className="block text-xs font-medium text-dark-200 mb-1">Install method</label>
                <select
                  value={method}
                  onChange={(e) => setMethod(e.target.value as "native" | "docker")}
                  className="w-full px-3 py-2 border border-dark-500 rounded-lg text-sm bg-dark-700 focus:ring-2 focus:ring-accent-500 outline-none"
                >
                  <option value="native">Native (Ondrej PPA)</option>
                  <option value="docker">Docker (FPM Alpine)</option>
                </select>
              </div>
            </div>

            {method === "native" && (
              <div>
                <label className="block text-xs font-medium text-dark-200 mb-2">Extensions</label>
                <div className="grid grid-cols-3 gap-1.5 max-h-40 overflow-y-auto pr-1">
                  {ALL_EXTENSIONS.map((ext) => (
                    <label key={ext} className="flex items-center gap-1.5 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={selectedExts.includes(ext)}
                        onChange={() => toggleExt(ext)}
                        className="rounded border-dark-500"
                      />
                      <span className="text-xs text-dark-200 font-mono">{ext}</span>
                    </label>
                  ))}
                </div>
              </div>
            )}

            {error && (
              <p className="text-sm text-red-400">{error}</p>
            )}

            <div className="flex items-center justify-end gap-3 pt-2">
              <button
                onClick={onClose}
                className="px-4 py-2 text-sm text-dark-200 hover:text-dark-100"
              >
                Cancel
              </button>
              <button
                onClick={submit}
                disabled={installing}
                className="px-4 py-2 bg-accent-600 hover:bg-accent-500 text-white rounded-lg text-sm font-medium disabled:opacity-50"
              >
                Install PHP {version}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ── main page ─────────────────────────────────────────────────────────────────

export default function PhpVersions() {
  const [versions, setVersions] = useState<PhpVersion[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [showInstall, setShowInstall] = useState(false);
  const [extPanel, setExtPanel] = useState<PhpVersion | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [removeError, setRemoveError] = useState("");

  const load = async () => {
    setLoading(true);
    setError("");
    try {
      const data = await api.get<PhpVersion[]>("/php/versions");
      setVersions(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load PHP versions");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, []);

  const handleRemove = async (v: PhpVersion) => {
    if (!confirm(`Remove PHP ${v.version}? This cannot be undone.`)) return;
    setRemoving(v.version);
    setRemoveError("");
    try {
      await api.delete(`/php/versions/${v.version}`);
      await load();
    } catch (e) {
      setRemoveError(e instanceof Error ? e.message : "Remove failed");
    } finally {
      setRemoving(null);
    }
  };

  const installedVersions = versions.map((v) => v.version);

  return (
    <div className="p-6 lg:p-8">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-xs font-medium text-dark-300 uppercase font-mono tracking-widest">
            PHP Versions
          </h1>
          <p className="text-sm text-dark-300 mt-1">
            Manage installed PHP versions and extensions for this server.
          </p>
        </div>
        <button
          onClick={() => setShowInstall(true)}
          className="px-4 py-2 bg-accent-600 hover:bg-accent-500 text-white rounded-lg text-sm font-medium transition-colors"
        >
          Install PHP Version
        </button>
      </div>

      {/* Errors */}
      {error && (
        <div className="mb-4 px-4 py-3 bg-red-500/10 border border-red-500/20 rounded-lg text-sm text-red-400">
          {error}
        </div>
      )}
      {removeError && (
        <div className="mb-4 px-4 py-3 bg-red-500/10 border border-red-500/20 rounded-lg text-sm text-red-400">
          {removeError}
        </div>
      )}

      {/* Loading */}
      {loading && (
        <div className="animate-pulse space-y-3">
          {[1, 2].map((i) => (
            <div key={i} className="h-24 bg-dark-800 rounded-lg border border-dark-600" />
          ))}
        </div>
      )}

      {/* Empty state */}
      {!loading && versions.length === 0 && (
        <div className="text-center py-16 bg-dark-800 rounded-lg border border-dark-600">
          <p className="text-dark-200 font-medium">No PHP versions installed</p>
          <p className="text-dark-300 text-sm mt-1">
            Click "Install PHP Version" to add your first version.
          </p>
        </div>
      )}

      {/* Version cards */}
      {!loading && versions.length > 0 && (
        <div className="space-y-4">
          {versions.map((v) => {
            const VISIBLE_EXT_COUNT = 6;
            const visibleExts = v.extensions.slice(0, VISIBLE_EXT_COUNT);
            const extraCount = v.extensions.length - VISIBLE_EXT_COUNT;

            return (
              <div
                key={v.id}
                className="bg-dark-800 border border-dark-600 rounded-lg p-5"
              >
                <div className="flex items-start justify-between">
                  <div className="flex items-center gap-3">
                    <span className="text-lg font-mono font-semibold text-dark-50">
                      PHP {v.version}
                    </span>
                    <StatusBadge status={v.status} />
                    <span className="text-xs text-dark-400 bg-dark-700 px-2 py-0.5 rounded">
                      {v.install_method}
                    </span>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      onClick={() => setExtPanel(v)}
                      className="px-3 py-1.5 text-xs font-medium text-dark-200 bg-dark-700 hover:bg-dark-600 rounded-lg transition-colors"
                    >
                      Extensions
                    </button>
                    <button
                      onClick={() => handleRemove(v)}
                      disabled={removing === v.version || v.status === "installing" || v.status === "removing"}
                      title={v.status === "active" ? "" : "Cannot remove — version is not active"}
                      className="px-3 py-1.5 text-xs font-medium text-red-400 bg-red-500/10 hover:bg-red-500/20 rounded-lg transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                    >
                      {removing === v.version ? "Removing..." : "Remove"}
                    </button>
                  </div>
                </div>

                {/* Extensions chips */}
                {v.extensions.length > 0 && (
                  <div className="mt-3 flex flex-wrap gap-1.5">
                    {visibleExts.map((ext) => (
                      <span
                        key={ext}
                        className="text-xs px-2 py-0.5 bg-dark-700 text-dark-300 rounded font-mono"
                      >
                        {ext}
                      </span>
                    ))}
                    {extraCount > 0 && (
                      <button
                        onClick={() => setExtPanel(v)}
                        className="text-xs px-2 py-0.5 bg-dark-700 text-accent-400 rounded"
                      >
                        +{extraCount} more
                      </button>
                    )}
                  </div>
                )}

                {v.status === "error" && v.error_message && (
                  <p className="mt-2 text-xs text-red-400">{v.error_message}</p>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Modals / panels */}
      {showInstall && (
        <InstallModal
          installedVersions={installedVersions}
          onClose={() => setShowInstall(false)}
          onRefresh={load}
        />
      )}
      {extPanel && (
        <ExtensionsPanel
          version={extPanel.version}
          installed={extPanel.extensions}
          onClose={() => setExtPanel(null)}
          onRefresh={load}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
cd panel/frontend && npx tsc --noEmit 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 3: Commit**

```bash
git add panel/frontend/src/pages/PhpVersions.tsx
git commit -m "feat(frontend): add PHP Versions management page"
```

---

## Task 10: Wire frontend route and sidebar nav

**Files:**
- Modify: `panel/frontend/src/main.tsx`
- Modify: `panel/frontend/src/components/CommandLayout.tsx` (and other layout components that contain the sidebar nav)

- [ ] **Step 1: Add lazy import and route in main.tsx**

In `panel/frontend/src/main.tsx`, add the lazy import near the other page imports:

```tsx
const PhpVersions = lazyRetry(() => import("./pages/PhpVersions"));
```

Then add the route inside the `<Route element={<LayoutShell />}>` block:

```tsx
<Route path="/php" element={<PhpVersions />} />
```

- [ ] **Step 2: Add PHP nav entry to sidebar layouts**

Search for where "DNS", "Databases", or other feature nav items are rendered in the layout files:

```bash
grep -r "dns\|databases\|terminal" panel/frontend/src/components/ -l
```

In each layout file that has a nav link list (typically `CommandLayout.tsx`, `GlassLayout.tsx`, `AtlasLayout.tsx`), add a PHP nav entry adjacent to "Databases":

```tsx
<NavLink
  to="/php"
  className={({ isActive }) =>
    `flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors ${
      isActive
        ? "bg-accent-600/20 text-accent-400"
        : "text-dark-300 hover:text-dark-100 hover:bg-dark-700"
    }`
  }
>
  <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
    <path strokeLinecap="round" strokeLinejoin="round"
      d="M14.25 9.75 16.5 12l-2.25 2.25m-4.5 0L7.5 12l2.25-2.25M6 20.25h12A2.25 2.25 0 0 0 20.25 18V6A2.25 2.25 0 0 0 18 3.75H6A2.25 2.25 0 0 0 3.75 6v12A2.25 2.25 0 0 0 6 20.25Z"
    />
  </svg>
  PHP
</NavLink>
```

> Inspect each layout file to see the existing nav item pattern (some use `<Link>`, some use `<NavLink>`, some use a data array). Match the exact pattern used.

- [ ] **Step 3: Verify TypeScript compiles**

```bash
cd panel/frontend && npx tsc --noEmit 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 4: Commit**

```bash
git add panel/frontend/src/main.tsx panel/frontend/src/components/
git commit -m "feat(frontend): add /php route and PHP sidebar nav entry"
```

---

## Task 11: Update Sites.tsx — use installed PHP versions

**Files:**
- Modify: `panel/frontend/src/pages/Sites.tsx`

The current PHP version dropdown is hardcoded to `["8.4","8.3","8.2","8.1"]`. Replace it with a live fetch from the API.

- [ ] **Step 1: Add installed versions state and fetch**

In `panel/frontend/src/pages/Sites.tsx`, add state and a fetch after the existing state declarations:

```tsx
const [installedPhpVersions, setInstalledPhpVersions] = useState<string[]>([]);
const [phpVersionsLoading, setPhpVersionsLoading] = useState(false);

useEffect(() => {
  setPhpVersionsLoading(true);
  api.get<{ version: string; status: string }[]>("/php/versions")
    .then((rows) => {
      setInstalledPhpVersions(rows.filter((r) => r.status === "active").map((r) => r.version));
    })
    .catch(() => setInstalledPhpVersions([]))
    .finally(() => setPhpVersionsLoading(false));
}, []);
```

- [ ] **Step 2: Update PHP version dropdown to use installed versions**

Find the PHP version `<select>` block (currently has hardcoded `<option>` for 8.4/8.3/8.2/8.1):

```tsx
<select
  id="site-php-version"
  value={phpVersion}
  onChange={(e) => setPhpVersion(e.target.value)}
  disabled={phpVersionsLoading || installedPhpVersions.length === 0}
  className="w-full px-3 py-2.5 border border-dark-500 rounded-lg focus:ring-2 focus:ring-accent-500 focus:border-accent-500 outline-none text-sm bg-dark-800 disabled:opacity-50"
>
  {installedPhpVersions.length === 0 && !phpVersionsLoading ? (
    <option value="">No PHP versions installed</option>
  ) : (
    installedPhpVersions.map((v) => (
      <option key={v} value={v}>PHP {v}</option>
    ))
  )}
</select>
```

Also update the `useEffect` or `useState` initializer for `phpVersion` so it auto-selects the first installed version when the list loads:

```tsx
useEffect(() => {
  if (installedPhpVersions.length > 0 && !installedPhpVersions.includes(phpVersion)) {
    setPhpVersion(installedPhpVersions[0]);
  }
}, [installedPhpVersions]);
```

- [ ] **Step 3: Add warning banner when no PHP installed and PHP runtime is selected**

After the PHP version select block, add:

```tsx
{(runtime === "php" || cms) && installedPhpVersions.length === 0 && !phpVersionsLoading && (
  <p className="text-xs text-amber-400 mt-1.5">
    No PHP versions are installed on this server.{" "}
    <a href="/php" className="underline hover:text-amber-300">
      Install one first →
    </a>
  </p>
)}
```

- [ ] **Step 4: Verify TypeScript compiles**

```bash
cd panel/frontend && npx tsc --noEmit 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add panel/frontend/src/pages/Sites.tsx
git commit -m "feat(frontend): load installed PHP versions from API in site create wizard"
```

---

## Task 12: Update SiteDetail.tsx — new FPM fields and installed versions

**Files:**
- Modify: `panel/frontend/src/pages/SiteDetail.tsx`

- [ ] **Step 1: Add new fields to the Site interface**

In `panel/frontend/src/pages/SiteDetail.tsx`, find the `interface Site` (or similar type) and add:

```tsx
php_max_execution_time: number;
php_upload_mb: number;
```

- [ ] **Step 2: Add state variables for new fields**

Add after the existing `phpWorkers` state declaration:

```tsx
const [phpMaxExecTime, setPhpMaxExecTime] = useState("300");
const [phpUploadMb, setPhpUploadMb] = useState("64");
```

- [ ] **Step 3: Initialize new state from the loaded site**

In the site load `useEffect` (where `setPhpMemory` and `setPhpWorkers` are called), add:

```tsx
setPhpMaxExecTime(String(s.php_max_execution_time ?? 300));
setPhpUploadMb(String(s.php_upload_mb ?? 64));
```

- [ ] **Step 4: Add inputs for new fields in the limits section**

In the resource limits section (near the PHP Memory and PHP Workers inputs), add:

```tsx
{site.runtime === "php" && (
  <>
    {/* existing PHP Memory input */}
    {/* existing PHP Workers input */}
    <div>
      <label className="block text-xs font-medium text-dark-200 mb-1">Max Execution Time (s)</label>
      <input
        type="number"
        value={phpMaxExecTime}
        onChange={(e) => setPhpMaxExecTime(e.target.value)}
        min="10"
        max="3600"
        className="w-full px-3 py-2 border border-dark-500 rounded-lg text-sm focus:ring-2 focus:ring-accent-500 outline-none"
      />
    </div>
    <div>
      <label className="block text-xs font-medium text-dark-200 mb-1">Upload Max (MB)</label>
      <input
        type="number"
        value={phpUploadMb}
        onChange={(e) => setPhpUploadMb(e.target.value)}
        min="1"
        max="2048"
        className="w-full px-3 py-2 border border-dark-500 rounded-lg text-sm focus:ring-2 focus:ring-accent-500 outline-none"
      />
    </div>
  </>
)}
```

- [ ] **Step 5: Include new fields in the save limits API call**

Find the `api.put(`/sites/${id}/limits`, {...})` call and add the new fields:

```tsx
php_max_execution_time: parseInt(phpMaxExecTime) || 300,
php_upload_mb: parseInt(phpUploadMb) || 64,
```

- [ ] **Step 6: Load installed PHP versions and use them for the PHP version switcher**

Add a state and fetch for installed versions (same pattern as Sites.tsx):

```tsx
const [installedPhpVersions, setInstalledPhpVersions] = useState<string[]>([]);

useEffect(() => {
  api.get<{ version: string; status: string }[]>("/php/versions")
    .then((rows) => setInstalledPhpVersions(rows.filter((r) => r.status === "active").map((r) => r.version)))
    .catch(() => setInstalledPhpVersions([]));
}, []);
```

Then replace the hardcoded PHP version `<select>` options (currently `<option value="8.4">PHP 8.4</option>` etc.) with:

```tsx
{installedPhpVersions.map((v) => (
  <option key={v} value={v}>PHP {v}</option>
))}
{installedPhpVersions.length === 0 && (
  <option value={site.php_version ?? "8.3"}>PHP {site.php_version ?? "8.3"} (current)</option>
)}
```

- [ ] **Step 7: Verify TypeScript compiles**

```bash
cd panel/frontend && npx tsc --noEmit 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 8: Commit**

```bash
git add panel/frontend/src/pages/SiteDetail.tsx
git commit -m "feat(frontend): add FPM execution time/upload fields; use installed versions in PHP switcher"
```

---

## Task 13: CLI full expansion

**Files:**
- Modify: `panel/cli/src/commands/php.rs`
- Modify: `panel/cli/src/main.rs`

The existing CLI only covers `arc php` (list) and `arc php install <version>`. This task adds the remaining spec commands.

- [ ] **Step 1: Rewrite commands/php.rs**

Replace `panel/cli/src/commands/php.rs` entirely:

```rust
use crate::client;
use serde_json::json;

const SUPPORTED_VERSIONS: &[&str] = &["5.6", "7.4", "8.0", "8.1", "8.2", "8.3", "8.4"];

fn validate_version(version: &str) -> Result<(), String> {
    if SUPPORTED_VERSIONS.contains(&version) {
        Ok(())
    } else {
        Err(format!(
            "Invalid PHP version '{version}'. Supported: {}",
            SUPPORTED_VERSIONS.join(", ")
        ))
    }
}

/// arc php list [--output json]
pub async fn cmd_php_list(token: &str, output: &str) -> Result<(), String> {
    let result = client::agent_get("/php/versions", token).await?;

    if output == "json" {
        println!("{}", serde_json::to_string_pretty(&result).unwrap_or_default());
        return Ok(());
    }

    let versions = result["versions"]
        .as_array()
        .ok_or("Expected versions array from /php/versions")?;

    println!(
        "\x1b[1m{:<10} {:<12} {:<10} {:<8} {:<30}\x1b[0m",
        "VERSION", "STATUS", "METHOD", "FPM", "SOCKET"
    );

    for v in versions {
        let version = v["version"].as_str().unwrap_or("-");
        let installed = v["installed"].as_bool().unwrap_or(false);
        let fpm = v["fpm_running"].as_bool().unwrap_or(false);
        let method = v["install_method"].as_str().unwrap_or("native");
        let socket = v["socket"].as_str().unwrap_or("-");

        let status = if installed { "installed" } else { "not installed" };
        let status_color = if installed { "\x1b[32m" } else { "\x1b[90m" };
        let fpm_color = if fpm { "\x1b[32m" } else { "\x1b[90m" };

        println!(
            "{:<10} {status_color}{:<12}\x1b[0m {:<10} {fpm_color}{:<8}\x1b[0m {:<30}",
            version,
            status,
            method,
            if fpm { "running" } else { "stopped" },
            if installed { socket } else { "-" }
        );
    }

    Ok(())
}

/// arc php install <version> [--method native|docker]
pub async fn cmd_php_install(token: &str, version: &str, method: &str) -> Result<(), String> {
    validate_version(version)?;

    println!("Installing PHP {version} (method: {method})...");
    println!("This may take several minutes.");

    let body = json!({ "version": version, "method": method });
    let result = client::agent_post("/php/install", &body, token).await?;

    if result["ok"].as_bool() == Some(true) {
        println!("\x1b[32m✓\x1b[0m PHP {version} installed successfully");
    } else {
        return Err(format!(
            "Failed to install PHP {version}: {}",
            result["error"].as_str().unwrap_or("unknown error")
        ));
    }

    Ok(())
}

/// arc php remove <version> [--force]
pub async fn cmd_php_remove(token: &str, version: &str, force: bool) -> Result<(), String> {
    validate_version(version)?;

    if !force {
        print!("Remove PHP {version}? This will stop and purge the FPM service. [y/N] ");
        use std::io::{self, Write};
        io::stdout().flush().ok();
        let mut input = String::new();
        io::stdin().read_line(&mut input).ok();
        if !input.trim().eq_ignore_ascii_case("y") {
            println!("Aborted.");
            return Ok(());
        }
    }

    println!("Removing PHP {version}...");
    let result = client::agent_delete(&format!("/php/versions/{version}"), token).await?;

    if result["ok"].as_bool() == Some(true) {
        println!("\x1b[32m✓\x1b[0m PHP {version} removed");
    } else {
        return Err(format!(
            "Failed to remove PHP {version}: {}",
            result["error"].as_str().unwrap_or("unknown error")
        ));
    }

    Ok(())
}

/// arc php info <version>
pub async fn cmd_php_info(token: &str, version: &str, output: &str) -> Result<(), String> {
    validate_version(version)?;

    let result = client::agent_get(&format!("/php/versions/{version}/info"), token).await?;

    if output == "json" {
        println!("{}", serde_json::to_string_pretty(&result).unwrap_or_default());
        return Ok(());
    }

    println!("\x1b[1mPHP {version} Info\x1b[0m");
    println!("  Version string : {}", result["version_string"].as_str().unwrap_or("-"));
    println!("  FPM running    : {}", result["fpm_running"].as_bool().unwrap_or(false));
    println!("  Socket         : {}", result["socket"].as_str().unwrap_or("-"));

    if let Some(ini) = result["ini"].as_object() {
        println!("\n  \x1b[1mKey ini values:\x1b[0m");
        for (k, v) in ini {
            println!("    {k:<30} = {}", v.as_str().unwrap_or("-"));
        }
    }

    if let Some(exts) = result["extensions"].as_array() {
        let names: Vec<&str> = exts.iter().filter_map(|e| e.as_str()).collect();
        println!("\n  \x1b[1mLoaded extensions ({}):\x1b[0m", names.len());
        for chunk in names.chunks(8) {
            println!("    {}", chunk.join(", "));
        }
    }

    Ok(())
}

/// arc php extensions list <version> [--output json]
pub async fn cmd_extensions_list(token: &str, version: &str, output: &str) -> Result<(), String> {
    validate_version(version)?;

    let result = client::agent_get(&format!("/php/versions/{version}/extensions"), token).await?;

    if output == "json" {
        println!("{}", serde_json::to_string_pretty(&result).unwrap_or_default());
        return Ok(());
    }

    let installed = result["installed"].as_array().cloned().unwrap_or_default();
    let available = result["available"].as_array().cloned().unwrap_or_default();

    println!("\x1b[1mInstalled ({}):\x1b[0m", installed.len());
    let inst_names: Vec<&str> = installed.iter().filter_map(|e| e.as_str()).collect();
    for chunk in inst_names.chunks(8) {
        println!("  {}", chunk.join(", "));
    }

    println!("\n\x1b[1mAvailable to install:\x1b[0m");
    for ext in &available {
        let name = ext.as_str().unwrap_or("-");
        let mark = if inst_names.contains(&name) { "\x1b[32m✓\x1b[0m" } else { " " };
        print!("  {mark} {name:<20}");
    }
    println!();

    Ok(())
}

/// arc php extensions install <version> <extension>
pub async fn cmd_extensions_install(
    token: &str,
    version: &str,
    extension: &str,
) -> Result<(), String> {
    validate_version(version)?;
    println!("Installing php{version}-{extension}...");

    let body = json!({ "name": extension });
    let result = client::agent_post(
        &format!("/php/versions/{version}/extensions"),
        &body,
        token,
    )
    .await?;

    if result["ok"].as_bool() == Some(true) {
        println!("\x1b[32m✓\x1b[0m Extension {extension} installed for PHP {version}");
    } else {
        return Err(format!(
            "Failed: {}",
            result["error"].as_str().unwrap_or("unknown error")
        ));
    }

    Ok(())
}

/// arc php extensions remove <version> <extension>
pub async fn cmd_extensions_remove(
    token: &str,
    version: &str,
    extension: &str,
) -> Result<(), String> {
    validate_version(version)?;
    println!("Removing php{version}-{extension}...");

    let result = client::agent_delete(
        &format!("/php/versions/{version}/extensions/{extension}"),
        token,
    )
    .await?;

    if result["ok"].as_bool() == Some(true) {
        println!("\x1b[32m✓\x1b[0m Extension {extension} removed from PHP {version}");
    } else {
        return Err(format!(
            "Failed: {}",
            result["error"].as_str().unwrap_or("unknown error")
        ));
    }

    Ok(())
}

/// arc php fpm-reload <version>
pub async fn cmd_fpm_reload(token: &str, version: &str) -> Result<(), String> {
    validate_version(version)?;
    let result = client::agent_post_empty(
        &format!("/php/versions/{version}/reload-fpm"),
        token,
    )
    .await?;

    if result["ok"].as_bool() == Some(true) {
        println!("\x1b[32m✓\x1b[0m PHP-FPM {version} reloaded");
    } else {
        return Err(format!(
            "FPM reload failed: {}",
            result["error"].as_str().unwrap_or("unknown error")
        ));
    }

    Ok(())
}
```

- [ ] **Step 2: Update PhpCmd enum and dispatch in main.rs**

In `panel/cli/src/main.rs`, find the `PhpCmd` enum and replace it entirely:

```rust
#[derive(Subcommand)]
enum PhpCmd {
    /// Install a PHP version
    Install {
        /// PHP version (5.6, 7.4, 8.0, 8.1, 8.2, 8.3, 8.4)
        version: String,
        /// Install method: native (default) or docker
        #[arg(long, default_value = "native")]
        method: String,
    },
    /// Remove a PHP version
    Remove {
        /// PHP version
        version: String,
        /// Skip confirmation prompt
        #[arg(long)]
        force: bool,
    },
    /// Show PHP version info (binary version, ini values, loaded extensions)
    Info {
        /// PHP version
        version: String,
    },
    /// Manage PHP extensions
    Extensions {
        #[command(subcommand)]
        command: ExtensionsCmd,
    },
    /// Reload PHP-FPM for a version
    FpmReload {
        /// PHP version
        version: String,
    },
}

#[derive(Subcommand)]
enum ExtensionsCmd {
    /// List installed extensions
    List {
        /// PHP version
        version: String,
    },
    /// Install an extension
    Install {
        /// PHP version
        version: String,
        /// Extension name (e.g. redis, imagick, xdebug)
        extension: String,
    },
    /// Remove an extension
    Remove {
        /// PHP version
        version: String,
        /// Extension name
        extension: String,
    },
}
```

Then update the dispatch block in the `Commands::Php` match arm:

```rust
Commands::Php { command } => match command {
    None => commands::php::cmd_php_list(&token, &output).await,
    Some(PhpCmd::Install { version, method }) => {
        commands::php::cmd_php_install(&token, &version, &method).await
    }
    Some(PhpCmd::Remove { version, force }) => {
        commands::php::cmd_php_remove(&token, &version, force).await
    }
    Some(PhpCmd::Info { version }) => {
        commands::php::cmd_php_info(&token, &version, &output).await
    }
    Some(PhpCmd::FpmReload { version }) => {
        commands::php::cmd_fpm_reload(&token, &version).await
    }
    Some(PhpCmd::Extensions { command }) => match command {
        ExtensionsCmd::List { version } => {
            commands::php::cmd_extensions_list(&token, &version, &output).await
        }
        ExtensionsCmd::Install { version, extension } => {
            commands::php::cmd_extensions_install(&token, &version, &extension).await
        }
        ExtensionsCmd::Remove { version, extension } => {
            commands::php::cmd_extensions_remove(&token, &version, &extension).await
        }
    },
},
```

- [ ] **Step 3: Verify CLI compiles**

```bash
cargo clippy --manifest-path panel/cli/Cargo.toml --release 2>&1 | head -30
```

Expected: zero errors.

- [ ] **Step 4: Verify CLI help shows all commands**

```bash
cargo run --manifest-path panel/cli/Cargo.toml -- php --help 2>&1
```

Expected output includes: `install`, `remove`, `info`, `extensions`, `fpm-reload`.

- [ ] **Step 5: Commit**

```bash
git add panel/cli/src/commands/php.rs panel/cli/src/main.rs
git commit -m "feat(cli): expand PHP commands — remove, info, extensions, fpm-reload, all versions"
```

---

## Self-Review

**Spec coverage check:**

| Spec section | Covered in task |
|---|---|
| §2.1 `php_versions` table | Task 1 |
| §2.2 `sites` FPM columns | Task 1 |
| §2.3 Soft constraint version-in-use | Tasks 6 (delete guard), 8 (create/switch validation) |
| §3.1 Agent endpoints (8 routes) | Task 4 |
| §3.2 Native install flow (6 steps, all in one agent call) | Tasks 3, 4 |
| §3.3 Docker install flow | Tasks 3, 4 |
| §3.4 Uninstall flow (native + docker) | Tasks 3, 4 |
| §3.5 Extension install/remove + allowlist | Tasks 3, 4 |
| §3.6 FPM pool config with new fields | Task 5 |
| §3.7 Security (version allowlist, extension allowlist, safe_command) | Tasks 3, 4 |
| §4.1 Backend endpoints (8 routes) | Task 6 |
| §4.2 Install request/response + SSE | Task 6 |
| §4.3 Site create/update changes | Tasks 8 |
| §4.4 Version delete guard | Task 6 |
| §5.1 Server PHP page | Task 9 |
| §5.2 Site create wizard PHP tab | Task 11 |
| §5.3 Site settings PHP tab (new fields) | Task 12 |
| §6 CLI (all 8 commands) | Task 13 |
| §8 Error handling (400/409/422 codes) | Tasks 4, 6, 8 |
| §9 Migration plan (SQL files) | Task 1 |

**Known simplifications vs spec:**
- SSE progress shows two steps (install start/done) rather than six granular steps. The agent does all work in one call. Granular streaming would require breaking the agent install into separate endpoint calls — a future enhancement.
- CLI calls the agent directly (Unix socket) rather than the backend API, consistent with all other CLI commands. The spec description of "calls POST /api/php/versions" applies to frontend behavior; the agent-direct path is appropriate for the CLI's server-local deployment model.
- The `/servers/:serverId/php` route spec becomes `/php` in the frontend because the app uses a global server selector (via `localStorage` / `X-Server-Id` header), not per-server route prefixes.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-02-php-version-manager.md`.**

**Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
