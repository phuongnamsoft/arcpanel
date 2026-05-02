# Arcpanel Agent — Technical Reference

**Crate:** `arcpanel-agent` (`panel/agent/Cargo.toml`)  
**Binary:** `arc-agent`  
**Scope:** This document covers `panel/agent/` only. It describes how the host agent fits Arcpanel, how it is structured, and how operators and contributors should reason about it.

---

## 1. Executive summary

The **Arcpanel agent** (`arc-agent`) is a **long-running Tokio + Axum service** that runs **on each managed Linux host**. It exposes an **HTTP API over a Unix domain socket** (default `/var/run/arcpanel/agent.sock`) so the **control-plane API** (`arc-api`) and **operator CLI** (`arc`) can perform **privileged, host-local work** without running the API as root: Docker lifecycle, nginx/site config, ACME/Let’s Encrypt provisioning, backups, diagnostics, WebSocket terminals, log streaming, and related operations.

**Where it sits in the stack**

| Layer | Binary / artifact | Role relative to the agent |
|--------|-------------------|----------------------------|
| Browser | Vite-built SPA | Talks to `arc-api` and WebSockets proxied by nginx — not directly to the agent socket. |
| API | `arc-api` | **Primary driver:** opens `UnixStream` to the agent socket, speaks **HTTP/1.1** with `Authorization: Bearer <agent token>`. See `panel/backend/src/services/agent.rs` (`AgentClient`). |
| Agent | `arc-agent` | **Host executor:** Docker (bollard), filesystem, systemd-invoked commands, ACME, TLS material, PTY terminal, etc. |
| CLI | `arc` | On-server use: can hit the same socket path when co-located (`panel/cli/src/client.rs`). |

**When it runs**

- **Standard panel install:** `systemd` unit `arc-agent.service` starts `arc-agent` after network (and typically after Docker/nginx per unit). See `panel/agent/arc-agent.service` and `scripts/setup.sh` / `scripts/update.sh`.
- **Remote / central mode:** If `ARCPANEL_CENTRAL_URL`, `ARCPANEL_SERVER_TOKEN`, and `ARCPANEL_SERVER_ID` are set, the agent enables **phone-home** (`panel/agent/src/services/phone_home.rs`): outbound HTTPS check-ins, command polling, optional auto-update, plus a **localhost TCP** listener on `127.0.0.1:9090` for forwarded commands.
- **Multi-server / TLS ingress:** Optional `AGENT_LISTEN_TCP` (e.g. `0.0.0.0:9443`) starts an additional **TLS-terminated** Axum listener using the self-signed cert under `/etc/arcpanel/ssl/agent.{crt,key}` for remote panels that pin the cert fingerprint (TOFU).

---

## 2. Architecture overview

### 2.1 Process and I/O boundaries

- **Single process, async multi-task:** One `#[tokio::main]` entry (`panel/agent/src/main.rs`), one shared `Router` + `AppState`, **graceful shutdown** on `SIGINT` / `SIGTERM` (Unix) via `shutdown_signal()`.
- **Primary listener:** `tokio::net::UnixListener` bound to **`SOCKET_PATH`** (`/var/run/arcpanel/agent.sock`). Stale socket file is removed before bind. Permissions are set to **0o600** at bind time; production units often **`chgrp` + `chmod 660`** in `ExecStartPost` so nginx/`www-data` can proxy (see `arc-agent.service` and `scripts/setup.sh`).
- **HTTP semantics on UDS:** Clients use **HTTP/1.1 over the Unix stream** (same pattern as the backend’s `AgentClient`: `hyper` handshake with `http://localhost<path>` style URIs).
- **No `lib.rs`:** The crate is **binary-centric**; library-like modules live under `panel/agent/src/` as submodules of `main.rs` (`mod routes`, `mod services`, `mod tls`, `pub mod safe_cmd`).

### 2.2 Shared application state (`AppState`)

Defined in `panel/agent/src/routes/mod.rs`:

- **`token` / `previous_token`:** `Arc<RwLock<...>>` for the **agent shared secret** and a **60s grace window** after rotation (`TOKEN_ROTATION_GRACE_SECS`).
- **`templates`:** `Arc<Tera>` — nginx template rendering (`services::nginx::init_templates()` in `main.rs`).
- **`system`:** `Arc<Mutex<sysinfo::System>>` — refreshed for metrics-style endpoints.
- **`docker`:** `bollard::Docker` from `Docker::connect_with_local_defaults()` — **local Docker socket**.
- **`network_snapshot`:** `Arc<Mutex<Option<NetworkSnapshot>>>` — cached network counters for rate calculations.

### 2.3 Concurrency patterns

- **Tokio** for all async I/O (HTTP, WebSockets, subprocesses, Docker API).
- **Spawned tasks:** Phone-home loops, optional **TCP** servers (`127.0.0.1:9090`, `AGENT_LISTEN_TCP`), and per-connection work inside Axum (e.g. WebSocket handlers).
- **Global allocator:** `tikv_jemallocator::Jemalloc` in `main.rs` for predictable allocation behavior under load.

### 2.4 Host and Docker integration

- **Docker:** All container operations go through **bollard** (`Docker` in `AppState`). Route modules such as `routes/docker_apps.rs` and services under `services/docker_apps.rs` orchestrate compose, builds, and metadata.
- **Host:** `sysinfo` for CPU/memory/disk; **`rustix`** + **`libc`** for PTY/shell in `routes/terminal.rs`; **`tokio::process`** with **`safe_cmd`** wrappers for sanitized child environments.

---

## 3. Design decisions and rationale

| Decision | Evidence in code | Rationale (inferred) |
|----------|------------------|------------------------|
| **Unix socket, not TCP, for local API** | `SOCKET_PATH`, `UnixListener::bind` in `main.rs` | Keeps the agent **off the network** on localhost; only local users/peers with socket access + token can drive it. |
| **Bearer token + constant-time compare** | `auth_middleware`, `subtle::ConstantTimeEq` in `routes/mod.rs` | Mitigate **timing leaks** on the shared secret; align with common API patterns consumed by `AgentClient`. |
| **JWT for terminal and log stream only** | `routes/terminal.rs`, `routes/logs.rs` (`StreamTicket`), `jsonwebtoken` | Browser WebSockets cannot set `Authorization` headers uniformly; **short-lived tickets** signed with the agent secret allow nginx to **proxy** `Upgrade` while keeping auth meaningful. |
| **Rustls / aws-lc-rs** | `rustls::crypto::aws_lc_rs::default_provider().install_default()` in `main.rs` | Deterministic TLS crypto provider before any TLS (agent listener, ACME, outbound HTTPS). |
| **Self-signed agent TLS + fingerprint** | `panel/agent/src/tls.rs`, `AGENT_LISTEN_TCP` branch in `main.rs` | Remote multi-server access without public PKI for the agent identity; **pin SHA-256 of cert DER** on first check-in (TOFU), logged at startup. |
| **instant-acme + HTTP-01** | `services/ssl.rs`, webroot `/var/www/acme` | Industry-standard **Let’s Encrypt** automation on the host where nginx answers `/.well-known/acme-challenge`. |
| **Sanitized child environment** | `safe_cmd.rs` | Prevent **`LD_PRELOAD` / `PATH` hijacking** via inherited env when spawning shells and tools. |
| **Tera for nginx** | `tera` dependency, `services/nginx.rs` | Safe-ish templating for site configs rather than string concatenation only. |
| **Circuit breaker / timeouts (caller side)** | `panel/backend/src/services/agent.rs` | Agent stays simple; **API** bounds blast radius when the agent or Docker is slow. |

---

## 4. Core components

### 4.1 Entry point and router assembly

**File:** `panel/agent/src/main.rs`

Responsibilities:

1. Install **jemalloc** and **rustls** crypto provider.
2. Configure **`tracing_subscriber`** from `RUST_LOG` / default `info`; optional **`LOG_FORMAT=json`**.
3. Create standard directories (`/etc/arcpanel`, `/var/run/arcpanel`, backups, ACME webroot, etc.).
4. Resolve **`AGENT_TOKEN`** env vs `/etc/arcpanel/agent.token` vs generate UUID; enforce **0o600** on the token file.
5. Build **`AppState`** and merge all **`routes::*::router()`** modules, then:
   - Global layers: **`auth_middleware`** (stateful), **`audit_middleware`**.
   - Exceptions merged **after** auth layer: **`terminal::router()`**, **`logs::stream_router()`** (self-authenticated paths).
6. Expose **`POST /auth/rotate-token`** (`routes::rotate_token`) inside the authed tree for token rotation.
7. Bind **Unix socket**, load **TLS** via `tls::load_or_generate()`, optionally start **phone-home** / **TCP** / **TLS TCP** servers, then **`axum::serve`** with graceful shutdown.

**Illustrative excerpt (router merge pattern):**

```rust
// panel/agent/src/main.rs (conceptual — see file for full list)
let app = Router::new()
    .merge(routes::health::router())
    .merge(routes::system::router())
    // ... many route modules ...
    .route("/auth/rotate-token", axum::routing::post(routes::rotate_token))
    .layer(middleware::from_fn_with_state(state.clone(), routes::auth_middleware))
    .layer(middleware::from_fn(routes::audit_middleware))
    .merge(routes::terminal::router())
    .merge(routes::logs::stream_router())
    .with_state(state);
```

### 4.2 Routes (`panel/agent/src/routes/`)

| Module | Responsibility |
|--------|----------------|
| `mod.rs` | `AppState`, **`auth_middleware`**, **`audit_middleware`**, **`rotate_token`**, validation helpers (`is_valid_domain`, `is_valid_name`, `is_valid_container_id`). |
| `health.rs` | **`GET /health`** — unauthenticated liveness; returns version. |
| `system.rs` | Host operations (restart, updates, sync-config, etc.). |
| `nginx.rs` / `ssl.rs` | Nginx site config and TLS/ACME orchestration (delegates to `services::nginx`, `services::ssl`). |
| `docker_apps.rs` | Dockerized applications lifecycle. |
| `database.rs` / `database_backup.rs` | DB management and backup hooks. |
| `files.rs` | Controlled file operations. |
| `backups.rs` / `remote_backup.rs` / `volume_backup.rs` / `backup_verify.rs` | Backup orchestration. |
| `logs.rs` | Log read/search/stats + **`/logs/stream`** WebSocket (via `stream_router`). |
| `terminal.rs` | **`GET /terminal/ws`** — WebSocket PTY; JWT query param; limits (`MAX_TERMINAL_SESSIONS`, rate limit). |
| `deploy.rs` / `git_build.rs` | Deploy and build pipelines. |
| `security.rs` / `image_scan.rs` / `sbom.rs` | Security scanning and SBOM. |
| `wordpress.rs` / `cms.rs` | CMS-oriented flows. |
| `traefik.rs` | Traefik file provider layout under `/etc/arcpanel/traefik`. |
| `telemetry.rs` | Telemetry hooks (metrics-oriented paths; see module). |
| `phone_home.rs` | (Service, not route) — see §6. |

### 4.3 Services (`panel/agent/src/services/`)

Heavy logic lives here; routes stay thin. Notable modules:

- **`ssl.rs`** — ACME account persistence (`/etc/arcpanel/ssl/acme-account.json`), **`provision_cert`**, profiles/ARI hints (`ProvisionOpts`), Let’s Encrypt production URL.
- **`nginx.rs`** — Tera templates and site config generation.
- **`docker_apps.rs`**, **`compose.rs`** — Docker Compose integration.
- **`phone_home.rs`** — Central panel check-in, remote command execution loop, auto-update.
- **`encryption.rs`**, **`command_filter.rs`** — Security-sensitive helpers (terminal command filtering, etc.).
- **`logs.rs`** — Implementation behind `routes/logs.rs`.
- **`backups.rs`**, **`database_backup.rs`**, **`volume_backup.rs`**, **`remote_backup.rs`**, **`backup_verify.rs`** — Backup engines.
- **`deploy.rs`**, **`git_build.rs`**, **`staging.rs`** — Deployment pipeline support.
- **`security_scanner.rs`**, **`image_scanner.rs`**, **`sbom_scanner.rs`** — Supply chain and vulnerability tooling.

### 4.4 TLS module

**File:** `panel/agent/src/tls.rs`

- Paths: **`/etc/arcpanel/ssl/agent.crt`**, **`agent.key`**.
- **`load_or_generate()`** — loads PEM into **`axum_server::tls_rustls::RustlsConfig`**, returns **SHA-256 fingerprint** of first cert DER (`fingerprint_from_pem`).
- If missing, **`rcgen`** generates a self-signed cert with SAN/CN style identity **`arc-agent`** (see `generate_simple_self_signed`).

### 4.5 Safe command execution

**File:** `panel/agent/src/safe_cmd.rs`

- **`safe_command` / `safe_command_sync`** — `env_clear()` then minimal `PATH`, `HOME`, `LANG`, `LC_ALL`.
- **Contract:** Any new subprocess spawn from the agent should use these helpers unless there is an exceptional, reviewed reason not to.

---

## 5. Data and control flow

### 5.1 Typical request path (panel API → agent)

1. Operator action in UI → **`arc-api`** handler.
2. **`AgentClient::request`** (`panel/backend/src/services/agent.rs`) connects **`UnixStream`** to **`AGENT_SOCKET`** (default `/var/run/arcpanel/agent.sock`).
3. HTTP/1.1 request with **`Authorization: Bearer`** and JSON body if needed.
4. **`auth_middleware`** (`routes/mod.rs`) validates token (current or previous within grace), except **`GET /health`**.
5. **`audit_middleware`** logs **POST/PUT/DELETE** outcomes to tracing target **`audit`** (with `x-forwarded-for` / `x-real-ip` when present).
6. Route handler invokes **`AppState`** (`docker`, `system`, `templates`, …) and/or **`services::*`**.
7. JSON response returned over the same UDS connection.

### 5.2 WebSocket paths (browser-facing, often via nginx)

- **Terminal:** `GET /terminal/ws?token=<jwt>&domain=...&cols=&rows=` — **outside** bearer middleware; JWT validated with **`DecodingKey::from_secret(agent_token)`**, claims `purpose == "terminal"` (`routes/terminal.rs`).
- **Log stream:** `GET /logs/stream?token=<jwt>&...` — **`stream_router()`** merged without auth layer; ticket purpose checked in handler (`routes/logs.rs`).

> **Warning:** Treat JWT query parameters as **secrets in transit** — always terminate TLS at nginx and restrict who can obtain tickets from the API.

### 5.3 Phone-home control flow

When **`PhoneHomeConfig::from_env()`** is `Some`:

1. **`run()`** logs config, sleeps briefly, spawns **`command_poll_loop`** and **`auto_update_loop`**, then loops **POST** `{central_url}/api/agent/checkin` every **60s** with **`ARCPANEL_SERVER_TOKEN`** and optional **`cert_fingerprint`**.
2. **`command_poll_loop`** **GET** `{central}/api/agent/commands` and, for each action, forwards to **`http://127.0.0.1:9090`** with **`AGENT_TOKEN`** — strict **allowlist** (`ALLOWED_COMMANDS` in `phone_home.rs`).
3. **`auto_update_loop`** polls **`/api/agent/version`**, verifies **SHA-256 checksum** before replacing binary, then **`systemctl restart arc-agent`**.

### 5.4 Config loading

- **Agent token:** env **`AGENT_TOKEN`** preferred, else file, else generated — see §7.
- **Phone-home:** **`ARCPANEL_CENTRAL_URL`**, **`ARCPANEL_SERVER_TOKEN`**, **`ARCPANEL_SERVER_ID`** (all required and non-empty).
- **TLS multi-listen:** **`AGENT_LISTEN_TCP`** as `host:port` **`SocketAddr`** string.
- **ACME account:** JSON at **`/etc/arcpanel/ssl/acme-account.json`** (`services/ssl.rs`).
- **Logging:** standard **`tracing`** filters via env (systemd unit often sets **`RUST_LOG=info`**).

---

## 6. Integration points

### 6.1 API / CLI → agent

| Mechanism | Details |
|-----------|---------|
| **Unix socket + HTTP** | Default path `/var/run/arcpanel/agent.sock`; backend env **`AGENT_SOCKET`** (`panel/backend/src/config.rs`). |
| **Bearer token** | Header `Authorization: Bearer <token>`; must match `/etc/arcpanel/agent.token` (or in-memory after rotation). |
| **Token rotation** | `POST /auth/rotate-token` atomically writes new token and sets grace period (`routes/mod.rs`). Backend should call this and then **`AgentClient::update_token`**. |
| **JWT tickets** | API issues HS256 JWT for terminal/log stream using the **same** agent secret; agent validates **`exp`**, **`sub`**, **`purpose`**. |

### 6.2 CLI

- **`panel/cli/src/client.rs`** — uses **`SOCKET_PATH`** constant matching the agent default; surfaces actionable error if socket missing.

### 6.3 External dependencies

| Dependency | Role |
|------------|------|
| **Docker Engine** | Local socket API via **bollard**. |
| **nginx / filesystem** | Site roots (`/var/www/...`), config under `/etc/nginx` (per unit `ReadWritePaths`). |
| **Let’s Encrypt / ACME** | **instant-acme**, HTTP-01 under **`/var/www/acme/.well-known/acme-challenge`**. |
| **Central panel (optional)** | **reqwest** (rustls TLS) for check-in, commands, updates. |
| **systemd** | Service lifecycle, `systemctl` from phone-home updates and some routes. |

---

## 7. Deployment and operations

### 7.1 systemd

Reference unit: **`panel/agent/arc-agent.service`**

- **`ExecStart=/usr/local/bin/arc-agent`**
- **`Environment=RUST_LOG=info`**
- **`ExecStartPost`** adjusts socket group **`www-data`** and **`chmod 660`** for nginx reverse proxy.
- **Hardening:** `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, cgroup/memory caps, **`ReadWritePaths`** listing nginx, arcpanel state, backups, `/var/www`, logs, etc.

Install scripts **`scripts/setup.sh`** and **`scripts/update.sh`** emit a similar unit and wire **`AGENT_SOCKET=/var/run/arcpanel/agent.sock`** into API environment.

### 7.2 nginx proxy (from `scripts/setup.sh`)

Typical pattern: **`proxy_pass http://unix:/var/run/arcpanel/agent.sock:/...`** for HTTP upgrades to **`/terminal/ws`** and **`/logs/stream`**.

### 7.3 Environment variables

| Variable | Purpose |
|----------|---------|
| **`RUST_LOG`** / **`tracing` `EnvFilter`** | Log levels (default `info` if unset). |
| **`LOG_FORMAT=json`** | Structured JSON logs via `tracing_subscriber::fmt().json()`. |
| **`AGENT_TOKEN`** | Seed/sync agent bearer token to disk. |
| **`ARCPANEL_CENTRAL_URL`**, **`ARCPANEL_SERVER_TOKEN`**, **`ARCPANEL_SERVER_ID`** | Enable **phone-home** remote mode. |
| **`AGENT_LISTEN_TCP`** | Optional **`SocketAddr`** for **TLS** multi-server listener. |

### 7.4 Paths created at startup (`main.rs`)

| Path | Purpose |
|------|---------|
| `/var/run/arcpanel` | Runtime (socket). |
| `/etc/arcpanel` | Token, SSL material, ACME account. |
| `/etc/arcpanel/ssl` | Agent TLS cert/key, ACME artifacts. |
| `/var/backups/arcpanel` (+ subdirs) | Backup staging. |
| `/var/www/acme/.well-known/acme-challenge` | ACME HTTP-01 responses. |

### 7.5 Logging and audit

- **General:** `tracing` macros throughout services/routes.
- **Audit:** `audit_middleware` emits **`target: "audit"`** for mutating methods with method, path, source IP, status.

### 7.6 Common operations

- **Status / logs:** `systemctl status arc-agent`, `journalctl -u arc-agent -f` (see `website/docs/troubleshooting.md` in repo).
- **Updates:** `scripts/update.sh` replaces `/usr/local/bin/arc-agent` and restarts units.

---

## 8. Security model (high level)

1. **Local access control:** Unix socket permissions (600 from agent, often 660 + group in production) gate which OS users can connect; nginx runs as unprivileged user with group access.
2. **Bearer secret:** High-entropy token; **constant-time** validation; **rotation** with **60s** overlap for rolling API config updates.
3. **TLS for remote agent:** Self-signed cert; **fingerprint** exposed to central panel for pinning; avoids trusting ambiguous hostnames alone.
4. **Child processes:** **`safe_cmd`** clears hostile inherited environment.
5. **WebSocket tickets:** Short-lived JWTs, narrow **`purpose`** claim, domain validation against traversal in terminal path.
6. **Phone-home commands:** Strict **allowlist** mapping to existing HTTP routes; checksum-mandatory agent binary updates.
7. **Supply chain:** Release SBOMs for `arc-agent` documented in **`SECURITY.md`** (signing and verification).

> **Warning:** Anyone who can read **`/etc/arcpanel/agent.token`** or **`AGENT_TOKEN`** can invoke most agent endpoints. File permissions (**0o600**) and service isolation matter.

---

## 9. Appendices

### Appendix A — Glossary

| Term | Meaning |
|------|---------|
| **Agent token** | Shared secret between `arc-agent` and `arc-api` / CLI; Bearer auth + JWT HMAC secret. |
| **Phone-home** | Outbound-only registration and command polling toward a central `arc-api`. |
| **TOFU** | Trust on first use — pin TLS cert fingerprint on first successful check-in. |
| **UDS** | Unix domain socket — here, HTTP/1.1 over stream socket. |

### Appendix B — `Cargo.toml` dependency highlights

| Crate | Role in agent |
|-------|----------------|
| **axum** (+ **ws**) | HTTP server, WebSocket upgrades. |
| **tokio** | Async runtime, net, process, signal. |
| **bollard** | Docker Engine API. |
| **instant-acme** | ACME/Let’s Encrypt client. |
| **rustls**, **axum-server** (tls-rustls) | TLS for optional TCP listener. |
| **jsonwebtoken** | Terminal/stream JWT validation. |
| **reqwest** | Outbound HTTPS (central panel, downloads). |
| **sysinfo** | Host metrics. |
| **rustix** / **libc** | PTY and low-level POSIX. |
| **tera** | Template rendering for nginx. |
| **tracing** / **tracing-subscriber** | Observability. |
| **sha2**, **subtle**, **hex**, **base64**, **rand** | Crypto hygiene, fingerprints, rotation, updates. |

### Appendix C — Suggested reading order for new contributors

1. **`panel/agent/src/main.rs`** — lifecycle, directory layout, router composition, listeners.
2. **`panel/agent/src/routes/mod.rs`** — `AppState`, auth, audit, rotation, validators.
3. **`panel/agent/src/safe_cmd.rs`** — subprocess contract.
4. **`panel/agent/src/tls.rs`** — multi-server TLS identity.
5. **`panel/agent/src/routes/health.rs`** — minimal unauthenticated surface.
6. **`panel/agent/src/services/ssl.rs`** — ACME and certificate lifecycle.
7. **`panel/agent/src/routes/terminal.rs`** — WebSocket + PTY + JWT pattern.
8. **`panel/agent/src/services/phone_home.rs`** — remote mode.
9. **`panel/backend/src/services/agent.rs`** — how the API actually calls the agent (complements this doc).

---

*Document generated for the Arcpanel project (`arcpanel-agent` / `arc-agent`). For stack-wide orientation, see repository **`AGENTS.md`**.
