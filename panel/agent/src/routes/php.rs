use axum::{
    extract::Path,
    http::StatusCode,
    routing::{delete, get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::services;
use super::AppState;

type ApiErr = (StatusCode, Json<serde_json::Value>);

fn err(status: StatusCode, msg: &str) -> ApiErr {
    (status, Json(serde_json::json!({ "error": msg })))
}

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
