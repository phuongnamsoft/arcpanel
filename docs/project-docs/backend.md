# Arcpanel API backend (`arcpanel-api` / `arc-api`)

Technical reference for the Rust control-plane service in `panel/backend/`. All paths below are relative to the repository root unless noted.

---

## 1. Executive summary

The **Arcpanel API** (`arcpanel-api`, binary `arc-api`) is the **control plane** for Arcpanel: it exposes HTTP JSON APIs (and selected WebSocket/SSE endpoints), persists configuration and tenancy data in **PostgreSQL**, authenticates operators, sends **email** via configurable SMTP, and orchestrates work on managed hosts by talking to the **Rust agent** over a Unix socket (local) or TLS-pinned HTTPS (remote servers).

In the product stack, nginx typically reverse-proxies `/api/*` to this service while the SPA loads on the same origin. The backend does **not** serve static frontend assets; it focuses on auth, CRUD, background schedulers, and **agent RPC** (Docker, nginx, mail, backups, metrics, etc.).

---

## 2. Architecture overview

### 2.1 Process model

| Concern | Location |
|--------|----------|
| Entry point, `AppState`, router composition, middleware, DB pool, migration run | `panel/backend/src/main.rs` |
| HTTP route table | `panel/backend/src/routes/mod.rs` (`router()`), per-domain modules under `panel/backend/src/routes/*.rs` |
| JWT extractors, `ServerScope` (multi-server agent dispatch) | `panel/backend/src/auth.rs` |
| Environment-backed secrets and tuning | `panel/backend/src/config.rs` |
| Typed rows shared by handlers | `panel/backend/src/models.rs` |
| Agent HTTP-over-UDS + remote agent clients | `panel/backend/src/services/agent.rs` |
| Cross-cutting HTTP errors | `panel/backend/src/error.rs` |

### 2.2 Axum application shape

The server builds a single `Router<AppState>`:

```426:431:panel/backend/src/main.rs
    let app = Router::new()
        .merge(routes::router())
        .layer(cors)
        .layer(TimeoutLayer::with_status_code(axum::http::StatusCode::GATEWAY_TIMEOUT, Duration::from_secs(300)))
        .layer(TraceLayer::new_for_http())
        .with_state(state);
```

**Layers (outer → inner as applied):** `TraceLayer` (HTTP request logging), `TimeoutLayer` (300s gateway timeout), `CorsLayer` (cross-origin policy; same-origin UI is unaffected), then route handlers.

**State:** `AppState` holds the `PgPool`, `Arc<Config>`, local `AgentClient`, `AgentRegistry`, rate-limit maps, JWT blacklist, session revocation watermark, notification broadcast sender, passkey challenge store, and related mutexes (`panel/backend/src/main.rs`).

### 2.3 Layering pattern

There is no separate “service layer” package for every feature; instead:

- **Routes / handlers** live under `panel/backend/src/routes/` and call `sqlx` directly or invoke helpers in `panel/backend/src/services/` (email, agent, scanners, schedulers, crypto).
- **Background tasks** are spawned from `main.rs` via a small supervisor (`spawn_supervised`) that restarts panicked workers with exponential backoff until graceful shutdown.

### 2.4 Tower / Axum ecosystem

From `panel/backend/Cargo.toml`: **Axum 0.8** (with `ws`), **Tower** 0.5, **tower-http** (`cors`, `trace`, `timeout`), **Hyper** 1.x for the low-level HTTP stack. WebSockets use Axum’s `WebSocketUpgrade` (see `panel/backend/src/routes/ws_metrics.rs`).

---

## 3. Design decisions

### 3.1 SQLx and PostgreSQL

- **Runtime queries:** Handlers overwhelmingly use `sqlx::query`, `sqlx::query_as`, and `sqlx::FromRow` with SQL strings. There is no widespread use of `sqlx::query!` compile-time-checked macros in this tree; type safety comes from `FromRow` structs and careful binding.
- **Embedded migrations:** At startup the API runs:

```131:135:panel/backend/src/main.rs
    // Run migrations
    sqlx::migrate!("./migrations")
        .run(&db)
        .await
        .expect("Failed to run database migrations");
```

  Migration sources live in `panel/backend/migrations/` (versioned `*.sql` files). This ties schema evolution to the shipped binary.

- **Connection policy:** Pool sizing from `DB_MAX_CONNECTIONS` (default 20), `statement_timeout` set to 30s on connect, retry loop for DB readiness (`main.rs`).

### 3.2 JWT and sessions (as implemented)

- **Algorithm / validation:** HS256, strict expiry (`leeway = 0`), secret from `JWT_SECRET` (minimum 32 chars enforced in `config.rs`).
- **Transport:** `AuthUser` accepts `Authorization: Bearer <jwt>` **or** a `token=` HTTP cookie (`panel/backend/src/auth.rs`).
- **CSRF:** Cookie-based auth on mutating methods requires `X-Requested-With`; pure Bearer JWT is exempt (same file). This reduces cross-site form risk for browser sessions.
- **Revocation:** JWT may carry `jti`; a process-wide blacklist (`token_blacklist`) plus DB table `token_blacklist` (loaded at startup). `sessions_revoked_at` in settings invalidates older `iat` without per-request DB reads for the common case.
- **Roles:** `Claims.role` drives `AdminUser` and `ResellerUser` extractors (`auth.rs`).

### 3.3 Multi-server agent routing

`ServerScope` reads optional `X-Server-Id`, verifies `servers.user_id` matches the JWT subject, then resolves an `AgentHandle` via `AgentRegistry::for_server`—local Unix agent or remote TLS client (`auth.rs`, `services/agent.rs`).

### 3.4 Error handling policy

`ApiError` is `(StatusCode, Json<Value>)`. Internal failures use `internal_error` / `agent_error` to log with an **incident UUID** while returning a generic client message (`panel/backend/src/error.rs`).

---

## 4. Core components

### 4.1 Router and modules

The canonical route list is **`routes::router()`** in `panel/backend/src/routes/mod.rs` (1000+ lines). It groups REST endpoints under prefixes such as:

| Prefix / area | Module directory | Notes |
|----------------|------------------|--------|
| `/api/auth/*`, passkeys, 2FA | `routes/auth.rs`, `routes/passkeys.rs` | Login, cookies, JWT |
| `/api/users`, `/api/sites`, SSL, files, backups, crons | `routes/users.rs`, `routes/sites.rs`, `routes/ssl.rs`, `routes/files.rs`, … | Core tenancy |
| `/api/apps/*`, stacks, docker | `routes/docker_apps.rs`, `routes/stacks.rs` | Container lifecycle via agent |
| `/api/servers`, `/api/agent/*` | `routes/servers.rs`, `routes/agent_checkin.rs`, `routes/agent_commands.rs`, `routes/agent_updates.rs` | Fleet + agent protocol |
| Security, scans, mail, DNS, CDN | `routes/security.rs`, `routes/security_scans.rs`, `routes/mail.rs`, `routes/dns.rs`, `routes/cdn.rs` | |
| Observability | `routes/metrics.rs`, `routes/ws_metrics.rs`, `routes/prometheus.rs`, `routes/telemetry.rs` | WS metrics, Prometheus scrape |
| Integrations | `routes/billing.rs`, `routes/whmcs.rs`, `routes/webhook_gateway.rs`, `routes/extensions.rs` | Webhooks, third parties |
| `/api/health`, `/api/system/*` | `routes/system.rs`, `routes/system_logs.rs` | Health + diagnostics proxies to agent |

Validation helpers (`client_ip`, `is_valid_domain`, `is_safe_shell_command`, `validate_compose_yaml`, etc.) are colocated in `routes/mod.rs`.

### 4.2 Agent integration

- **`AgentClient`:** HTTP/1.1 over **Unix domain socket** to the agent, `Authorization: Bearer <AGENT_TOKEN>`, JSON bodies, response size cap (50MB), circuit breaker, separate semaphores for quick vs long calls (`services/agent.rs`).
- **`RemoteAgentClient`:** HTTPS to remote agents with optional **certificate fingerprint pinning** (TOFU aligned with agent check-in data).
- **`AgentRegistry`:** Caches remote clients; `ensure_local_server` links DB `servers` row to local agent token at startup (`main.rs`, `services/agent.rs`).

### 4.3 Background services (`main.rs`)

Supervised tasks include: `backup_scheduler`, `server_monitor`, `uptime_monitor`, `security_scanner`, `image_scanner`, `alert_engine`, `auto_healer`, `metrics_collector`, `deploy_scheduler`, `preview_cleanup`, `backup_verifier`, `backup_policy_executor`, `telemetry_collector`, and a periodic **cleanup** task (token blacklist, rate limits, OAuth state, provisioning logs).

Service modules: `panel/backend/src/services/mod.rs` exports `agent`, `email`, `notifications`, `secrets_crypto`, scanners, schedulers, etc.

### 4.4 Real-time channels

| Mechanism | File | Purpose |
|-----------|------|---------|
| SSE | `routes/notifications.rs` | `/api/notifications/stream` using `tokio::sync::broadcast` |
| WebSocket | `routes/ws_metrics.rs` | `/api/ws/metrics` pushes periodic metrics (JWT via query or cookie) |

---

## 5. Data models

### 5.1 Rust models

`panel/backend/src/models.rs` defines primary **`User`** and **`Site`** structs with `sqlx::FromRow` + serde for API projection. Many handlers use ad hoc tuples or inline `query_as` mappings instead of expanding this file for every table.

### 5.2 Database schema

- **Initial core tables** (`users`, `sites`, `databases`) appear in `panel/backend/migrations/20260311000000_initial.sql`.
- **Evolving schema:** 80+ subsequent migrations add features (multi-server, mail, git deploys, security hardening, webhook gateway, incidents, image scanning, passkeys, etc.). Naming convention: `YYYYMMDDHHMMSS_description.sql`.

**Representative domains (discover exact columns via migrations):** users/sessions/auth, sites/ssl/caching/WAF, servers/agent tokens & cert pins, backups/restic/orchestrator, monitors/incidents/status page, billing (Stripe), resellers, secrets vaults, API keys, IaC tokens, telemetry events, panel notifications.

---

## 6. Integration points

### 6.1 Agent

- **Operator APIs** call the agent for privileged host operations (Docker, nginx, system packages, logs). Token: `AGENT_TOKEN` env, persisted per server row for remotes.
- **Agent → API** callbacks use dedicated routes under `/api/agent/*` (check-in, command poll/result, version) authenticated by **per-server Bearer token** (hashed storage + constant-time compare in `routes/agent_checkin.rs`), with optional **timestamp replay window** and **TLS cert fingerprint** lifecycle.

### 6.2 CLI (`arc`)

The shipped CLI (`panel/cli/`) talks **directly to the agent Unix socket** with the machine’s agent token (`panel/cli/src/client.rs`), not to `arc-api` HTTP. Operators using **HTTP automation** should treat this backend as the contract surface (`/api/...`) with JWT session or documented token flows.

### 6.3 Frontend

The React SPA (outside this crate) calls **`/api/*`** JSON endpoints, sets `X-Requested-With` for cookie auth mutating calls, optionally passes **`X-Server-Id`** for multi-server, and consumes SSE/WebSocket endpoints documented above. Public/unauthenticated routes include health, branding, select webhooks, status pages, and similar (see `routes/mod.rs`).

### 6.4 External HTTP

`reqwest` (Rustls) is used for outbound integrations (DNS/CDN providers, webhooks, etc.). SMTP uses **Lettre** with Tokio + Rustls (`services/email.rs`).

---

## 7. Deployment and operations

### 7.1 Listen address and defaults

| Variable | Role | Default (if any) |
|----------|------|------------------|
| `LISTEN_ADDR` | TCP bind | `127.0.0.1:3080` (`config.rs`) |
| `DATABASE_URL` | PostgreSQL DSN | **required** |
| `JWT_SECRET` | HS256 key | **required**, min 32 chars |
| `AGENT_SOCKET` | Local agent UDS | `/var/run/arcpanel/agent.sock` |
| `AGENT_TOKEN` | Shared agent/API auth secret | **required** |
| `DB_MAX_CONNECTIONS` | Pool size | `20` |
| `BASE_URL` | Panel URL (cookies, CORS fallback) | empty |
| `CORS_ORIGINS` | Comma-separated allowlist | derived / empty |
| `LOG_FORMAT` | `json` for structured logs | plain text |
| `SECRETS_ENCRYPTION_KEY` | Optional separate key for credential encryption | falls back to JWT secret derivation (`secrets_crypto.rs`) |

`Config` uses `zeroize` to clear secrets on drop (`config.rs`).

### 7.2 Observability

- **Tracing:** `tracing-subscriber` with `RUST_LOG`-style filter (`EnvFilter`), optional JSON formatting (`main.rs`).
- **HTTP:** `TraceLayer::new_for_http()`.
- **Prometheus:** Admin-gated `/api/metrics` with bearer scrape token and SHA-256 comparison (`routes/prometheus.rs`, `services/prometheus_exporter.rs`).

### 7.3 Graceful shutdown

`axum::serve` uses `shutdown_signal()` (Ctrl+C / SIGTERM). Then a broadcast stops background tasks, waits briefly, and `PgPool::close()` drains DB connections (`main.rs`).

### 7.4 Allocator

Release builds use **tikv-jemallocator** (`main.rs`, `Cargo.toml`).

---

## 8. Security model

### 8.1 Authentication

- **Human operators:** Password login with **Argon2id** password hashes; JWT session (`routes/auth.rs`). Optional TOTP and WebAuthn/passkey flows in the same area.
- **JWT extraction:** `AuthUser` / `AdminUser` / `ResellerUser` (`auth.rs`).
- **Agent:** High-entropy tokens; stored as **SHA-256** hash when migrated (`helpers::hash_agent_token` in `helpers.rs`); verification uses `subtle::ConstantTimeEq` where applicable (`agent_checkin.rs`).

### 8.2 Authorization

- Role checks on claims (`require_admin`, extractors).
- Resource ownership enforced in SQL (`user_id = $1`, site joins, etc.) and `ServerScope` for cross-server safety.

### 8.3 Cryptography (code-visible)

| Use | Mechanism | Location |
|-----|------------|----------|
| Passwords | Argon2 default | `routes/auth.rs`, `routes/users.rs`, … |
| JWT | HS256 (`jsonwebtoken`, `aws_lc_rs`) | `auth.rs`, `routes/auth.rs` |
| Agent / API tokens | SHA-256 | `helpers.rs`, `routes/prometheus.rs`, API key creation |
| Secrets Manager + SMTP secrets | AES-256-GCM, nonces, HKDF-based key derivation, optional `SECRETS_ENCRYPTION_KEY` | `services/secrets_crypto.rs` |
| 2FA shared secrets | Encrypted with credential helpers | `routes/auth.rs` |
| TLS to remote agents | `rustls`; custom verifier for pinned fingerprints | `services/agent.rs`, `main.rs` installs `aws_lc_rs` crypto provider |
| WebAuthn | `p256`, `ciborium`, challenge store | `routes/passkeys.rs` |

### 8.4 Hardening hooks

Login respects optional **IP allowlist** (`settings.allowed_panel_ips`), **lockdown** mode, and **pending user approval** queries (`routes/auth.rs`). Security incident routes live under `routes/security.rs` and related modules.

---

## 9. Appendices

### 9.1 Glossary

| Term | Meaning |
|------|---------|
| Agent | Host daemon (`arc-agent`) executing Docker/nginx/system work |
| Control plane | This API + PostgreSQL |
| `ServerScope` | Axum extractor binding request to a server + `AgentHandle` |
| TOFU | Trust-on-first-use capture of remote TLS cert fingerprint |
| JTI | JWT ID used for logout / blacklist |

### 9.2 Key dependencies (`panel/backend/Cargo.toml`)

| Crate | Role |
|-------|------|
| `axum` | HTTP server, WebSockets |
| `tokio` | Async runtime |
| `tower` / `tower-http` | Middleware (CORS, trace, timeout) |
| `sqlx` | PostgreSQL access + migrations |
| `jsonwebtoken` | JWT |
| `argon2` | Password hashing |
| `tracing` / `tracing-subscriber` | Logging |
| `reqwest` | Outbound HTTPS |
| `lettre` | SMTP email |
| `aes-gcm`, `hkdf`, `sha2`, `hmac`, `rustls`, `totp-rs`, `p256`, … | Crypto & security features |

### 9.3 Suggested reading order for backend developers

1. `panel/backend/src/main.rs` — lifecycle, `AppState`, middleware, background jobs.  
2. `panel/backend/src/routes/mod.rs` — full API surface.  
3. `panel/backend/src/auth.rs` — authentication, multi-server header.  
4. `panel/backend/src/services/agent.rs` — how work reaches hosts.  
5. `panel/backend/migrations/20260311000000_initial.sql` then newer migrations for the feature you touch.  
6. `panel/backend/src/error.rs` — response conventions.  
7. Feature-specific `routes/<feature>.rs` + any helper under `services/`.

---

*This document reflects the `panel/backend/` tree as of the repository revision where it was authored. When behavior and docs diverge, trust the code.*
