use axum::{
    extract::Path,
    http::StatusCode,
    response::sse::{Event, KeepAlive, Sse},
    Json,
};
use chrono::{DateTime, Utc};
use futures::StreamExt;
use std::time::{Duration, Instant};
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use uuid::Uuid;

use crate::auth::{AdminUser, AuthUser, ServerScope};
use crate::error::{agent_error, err, internal_error, ApiError};
use crate::routes::sites::ProvisionStep;
use crate::services::activity;
use crate::AppState;

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
pub async fn install_version(
    axum::extract::State(state): axum::extract::State<AppState>,
    AdminUser(claims): AdminUser,
    ServerScope(server_id, agent): ServerScope,
    Json(body): Json<InstallRequest>,
) -> Result<(StatusCode, Json<InstallResponse>), ApiError> {
    let version = body.version.trim().to_string();
    validate_version(&version)?;

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

        match agent.post("/php/install", Some(agent_body)).await {
            Ok(_) => {
                let _ = sqlx::query(
                    "UPDATE php_versions SET status = 'active', updated_at = NOW() \
                     WHERE server_id = $1 AND version = $2",
                )
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

/// DELETE /api/php/versions/:version — Check no sites use it, then uninstall + remove row.
pub async fn delete_version(
    axum::extract::State(state): axum::extract::State<AppState>,
    AdminUser(claims): AdminUser,
    ServerScope(server_id, agent): ServerScope,
    Path(version): Path<String>,
) -> Result<StatusCode, ApiError> {
    validate_version(&version)?;

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

    sqlx::query(
        "UPDATE php_versions SET status = 'removing', updated_at = NOW() \
         WHERE server_id = $1 AND version = $2",
    )
    .bind(server_id)
    .bind(&version)
    .execute(&state.db)
    .await
    .map_err(|e| internal_error("mark php version removing", e))?;

    agent
        .delete(&format!("/php/versions/{version}"))
        .await
        .map_err(|e| agent_error("PHP uninstall", e))?;

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

/// GET /api/php/versions/:version/extensions — Live installed + allowlist from agent.
pub async fn list_extensions(
    axum::extract::State(_state): axum::extract::State<AppState>,
    AuthUser(_claims): AuthUser,
    ServerScope(_server_id, agent): ServerScope,
    Path(version): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_version(&version)?;
    let data = agent
        .get(&format!("/php/versions/{version}/extensions"))
        .await
        .map_err(|e| agent_error("PHP extensions list", e))?;
    Ok(Json(data))
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
            Some(serde_json::json!({ "name": body.name })),
        )
        .await
        .map_err(|e| agent_error("Install PHP extension", e))?;

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
    AdminUser(_claims): AdminUser,
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
