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
    let avail_names: Vec<&str> = available.iter().filter_map(|e| e.as_str()).collect();
    for chunk in avail_names.chunks(8) {
        println!("  {}", chunk.join(", "));
    }

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
