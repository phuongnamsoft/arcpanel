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
    #[cfg(unix)]
    if let Err(e) = std::os::unix::fs::symlink(&vol_data_path, &symlink) {
        tracing::warn!("Failed to create FPM socket symlink for docker PHP {version}: {e}");
    }
    #[cfg(not(unix))]
    tracing::warn!("Docker PHP symlink skipped on non-Unix host");

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
    let ini_query: String = ini_keys
        .iter()
        .map(|k| format!("echo '{k}='.ini_get('{k}');"))
        .collect();
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
