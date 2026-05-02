# Arcpanel CLI (`arcpanel-cli`) — Technical Reference

**Crate:** `arcpanel-cli`  
**Binary:** `arc`  
**Source:** `panel/cli/`  
**Rust edition:** 2024  

This document describes the operator-facing command-line client only. It reflects the code as of the crate version in `panel/cli/Cargo.toml`.

---

## 1. Executive summary

The **`arc`** binary is the **on-server operator CLI** for Arcpanel: it is intended for SSH sessions, automation scripts, and emergency operations where a browser is unavailable or undesirable. It exercises **host-level capabilities** (nginx sites, Docker apps, backups, diagnostics, SSL, firewall, PHP runtimes) by talking to the **host agent** over a local Unix socket.

By contrast:

| Surface | Role |
|--------|------|
| **Web UI** | Full interactive management in the browser; richer workflows and visualization. |
| **Control-plane API (`arc-api`)** | HTTP API (default port **3080** in typical installs) used by the panel frontend and integrations; backed by PostgreSQL and session/auth flows. |
| **CLI (`arc`)** | **Does not** open a TCP connection to `arc-api`. It sends **HTTP/1.1 requests over a Unix domain socket** to **`arc-agent`**, using the same path-oriented JSON API the agent exposes locally. |

Operators should assume **`arc` requires co-location with the agent** (same machine as `arc-agent`, readable token file, and socket present). Remote administration is out of scope for this crate: use the web UI or API, or SSH to the host and run `arc` there.

---

## 2. Architecture overview

### 2.1 Command-line structure (`clap`)

The entrypoint uses **`clap` 4 with the `derive` feature**: a root `Cli` struct and nested `Subcommand` enums define the full tree. Global output format is **`--output` / `-o`** with allowed values **`table`** (default) or **`json`** on commands that support it.

**Primary files:**

- `panel/cli/src/main.rs` — `Cli`, all subcommand enums (`Commands`, `SitesCmd`, `DbCmd`, …), `#[tokio::main]`, dispatch to `commands::*`, and **`arc completions`** handling.

**Conceptual tree (abbreviated):**

```
arc [-o table|json] <subcommand>
├── status
├── sites [--filter] [create|delete|info]
├── db [--filter] [create|delete]
├── apps [--filter] [templates|deploy|stop|start|restart|remove|logs|compose]
├── services [--filter]
├── ssl [status|provision]
├── backup [create|list|restore|delete|db-create|db-list|vol-create|vol-list|verify|health]
├── logs [-d domain] [-t type] [-n lines] [-f filter] [-s search]
├── security [overview|scan|firewall [list|add|remove]]
├── top
├── php [list|install]
├── diagnose
├── export [-O file]
├── apply <file> [--dry-run] [--email ...]
└── completions <shell>
```

### 2.2 Async runtime

Every command path is **`async`** and invoked from **`#[tokio::main] async fn main()`**. I/O is **Tokio**-based: the HTTP client uses **`tokio::net::UnixStream`** with **`AsyncReadExt` / `AsyncWriteExt`** for request/response (`panel/cli/src/client.rs`). There is **no blocking HTTP client** to a remote URL in this crate.

### 2.3 Configuration and “base URL”

There is **no** environment-variable-driven base URL or configurable socket path in the CLI source. The following are **compile-time string constants** in `client.rs`:

| Constant | Value | Purpose |
|----------|--------|---------|
| `SOCKET_PATH` | `/var/run/arcpanel/agent.sock` | Unix socket for agent HTTP |
| `TOKEN_PATH` | `/etc/arcpanel/agent.token` | Shared secret for `Authorization: Bearer` |

**Implication:** operations staff must ensure the agent creates the socket and token at these paths (standard Arcpanel server layout). The CLI does not read `http://`, `https://`, or `ARC_API_URL`-style configuration.

---

## 3. Design decisions

### 3.1 `clap` derive (`clap_derive`)

**Why:** Strong typing for arguments, automatic `--help`, subcommand nesting, and **`clap_complete` integration** via `CommandFactory` on the root `Cli`. The entire UX is declared in `main.rs` enums, keeping routing explicit and grep-friendly.

### 3.2 Shell completion generation

**`arc completions <shell>`** uses **`clap_complete::generate`** and exits **before** loading the agent token (`main.rs`). That avoids requiring a valid server install when generating completion scripts in CI or on a dev machine.

### 3.3 JSON and YAML I/O

| Library | Use |
|---------|-----|
| **`serde_json`** | Request bodies, all agent responses parsed as **`serde_json::Value`**, and pretty-printed output when `-o json`. |
| **`serde_yaml_ng`** | **`arc export`**: serializes agent JSON to YAML. **`arc apply`**: parses YAML to JSON **`Value`**, compares with **`GET /iac/export`**, then applies deltas via agent HTTP calls. |

**Why YAML for IaC:** human-editable dumps suitable for Git; round-tripping through JSON **`Value`** avoids maintaining duplicate Rust structs for the full server state in the CLI.

### 3.4 Loose JSON parsing in commands

Handlers typically use **`Value` field access** (e.g. `info["cpu_usage"].as_f64()`) rather than strongly typed DTOs. **Why:** fewer CLI-only structs to maintain; agent schema can evolve with clearer errors only when parsing fails entirely.

---

## 4. Core components

### 4.1 `panel/cli/src/main.rs`

- Defines **global** `-o/--output` (`table` | `json`).
- Implements **completions** early exit.
- **`load_token()`** then **single large `match`** on `Commands` delegating to modules under `commands/`.
- **Unreachable** arm for `Completions` after token load (defensive).

### 4.2 `panel/cli/src/client.rs`

- **`load_token()`** — reads `TOKEN_PATH`, trims whitespace.
- **`agent_request`** — builds minimal HTTP/1.1 requests manually (status line, `Host`, **`Authorization: Bearer <token>`**, optional `Content-Type: application/json` + body, **`Connection: close`**).
- Parses response: splits headers/body on `\r\n\r\n`, accepts **200** or **201**, handles **`Transfer-Encoding: chunked`** via **`decode_chunked`**, maps error JSON **`error`** or **`message`** fields to `Err(String)`.
- Public helpers: **`agent_get`**, **`agent_post`**, **`agent_post_empty`**, **`agent_put`**, **`agent_delete`**.

### 4.3 Command modules (`panel/cli/src/commands/`)

| Module | File | Responsibility |
|--------|------|------------------|
| **Registry** | `mod.rs` | `pub mod` exports for all command groups. |
| **Status & diagnostics** | `status.rs` | `status`, `services`, `top`, `diagnose` — system info, process list, service health, bundled diagnostics report. |
| **Sites** | `sites.rs` | `sites` list (local nginx scan + optional agent ping), create/update/delete sites via agent, site info. **List** reads **`/etc/nginx/sites-enabled`** locally; create/delete/info use agent. |
| **Databases** | `db.rs` | List/create/delete DB containers via agent. |
| **Apps** | `apps.rs` | Docker app list, templates, deploy, lifecycle, logs, compose deploy. |
| **SSL** | `ssl.rs` | Certificate status and Let’s Encrypt provisioning. |
| **Backups** | `backup.rs` | Site, DB, and volume backups; verify; **`health`** uses **local filesystem** under `/var/backups/arcpanel` (see §6). |
| **Logs** | `logs.rs` | Tail/search logs via agent; URL-encodes query parts (uses `urlenc` from `iac`). |
| **Security** | `security.rs` | Overview, scan, firewall list/add/remove. |
| **PHP** | `php.rs` | List installed versions; install via agent. |
| **IaC** | `iac.rs` | **`export`** / **`apply`**: YAML ↔ JSON, diff/plan against `/iac/export`, applies sites, DBs, apps, crons, PHP. |

---

## 5. Data flow

### 5.1 Request construction

1. User invokes `arc …`; **`clap`** parses argv.
2. Unless **`completions`**, **`load_token()`** reads **`/etc/arcpanel/agent.token`**.
3. Handler calls **`client::agent_*`** with a **path** (e.g. `/system/info`) and optional **`serde_json::Value`** body.
4. **`client`** connects to **`UnixStream::connect(SOCKET_PATH)`**, writes HTTP request with **Bearer** token.

### 5.2 Authentication

- **Scheme:** `Authorization: Bearer <token>` on every agent request.
- **Token source:** file on disk; **not** passed on the command line (reduces process listing exposure). **No** token env var is read in this crate.

### 5.3 Response handling

- Success: status **200** or **201**; body parsed as JSON (or empty → synthetic `{"success": true}`).
- Failure: non-2xx → try JSON for **`error`** / **`message`**; else stringify status line.
- **Chunked** responses are decoded for both success and error paths.

### 5.4 Output rendering

- **`table`:** ANSI-colored tables and banners (see `status::usage_color`, etc.).
- **`json`:** **`serde_json::to_string_pretty`** where implemented per command.

---

## 6. Integration points

### 6.1 Primary integration: `arc-agent` HTTP over Unix socket

All network I/O in **`client.rs`** targets the **agent**, not **`arc-api`**. Agent routes are path-based (examples used by the CLI):

- `/system/info`, `/system/processes`
- `/services/health`, `/diagnostics`
- `/nginx/sites/...`, `/ssl/...`, `/databases`, `/apps`, `/apps/...`
- `/backups/...`, `/db-backups/...`, `/volume-backups/...`
- `/logs`, `/logs/search`, `/logs/{domain}`
- `/security/...`, `/php/...`, `/iac/export`, `/crons/sync`

### 6.2 Relationship to `arc-api` (control plane)

The CLI crate **does not** implement HTTP clients to **`localhost:3080`** or configurable API hosts. Any alignment between **agent routes** and **REST routes** on the API is an **implementation detail of the server stack**, not something the CLI depends on at compile time.

**Shared assumptions:** JSON field names and shapes returned by the agent must match what each command expects (`success`, `message`, `container_id`, arrays of objects with `name`/`status`, etc.). Breaking changes to the agent API require CLI updates in the corresponding `commands/*.rs` files.

### 6.3 Local filesystem integration (no agent)

| Feature | Path / behavior |
|---------|-------------------|
| **Sites list** | Reads **`/etc/nginx/sites-enabled`**; skips panel-specific configs; infers domain, SSL, runtime heuristically. |
| **`backup health`** | Scans **`/var/backups/arcpanel`**, **`.../databases`**, **`.../volumes`**; **does not** send the token to an HTTP endpoint for this summary (token is intentionally unused in that handler). |

---

## 7. Deployment and operations

### 7.1 Binary install path

Project scripts (`scripts/setup.sh`, `scripts/update.sh`) install the CLI as:

- **`/usr/local/bin/arc`**

Release artifacts are named **`arc-linux-<arch>`** (see `scripts/release.sh` / update flow).

### 7.2 Runtime dependencies (from code)

| Requirement | Details |
|---------------|---------|
| **Agent socket** | **`/var/run/arcpanel/agent.sock`** must exist; **`arc-agent`** service running. |
| **Token file** | **`/etc/arcpanel/agent.token`** readable by the user running `arc` (often **root** for restricted permissions). |
| **Backup health** | Directories under **`/var/backups/arcpanel`** for meaningful output. |
| **Sites list** | **`/etc/nginx/sites-enabled`** readable for local enumeration. |

### 7.3 Environment variables

**None** are read by `panel/cli` for URL, socket, or token paths. Operational tuning is **outside** this crate (systemd unit, agent config, file permissions).

---

## 8. Security model

### 8.1 Credential flow

1. **Agent token** is stored **only** in **`/etc/arcpanel/agent.token`** (created/managed by the server install, not committed to the repo).
2. The CLI reads the file **once per invocation** and sends it as **Bearer** token to the **local agent** only.
3. **Database passwords** and similar secrets appear **only** as:
   - CLI flags (e.g. `db create --password`), passed in JSON bodies to the agent — **visible in shell history** unless users wrap calls carefully; and
   - **Ephemeral generated passwords** printed by **`arc apply`** when creating databases (stdout/stderr).

### 8.2 Threat considerations

- **Physical/socket access:** Anyone who can write to the socket or steal the token file can impersonate the CLI to the agent.
- **No TLS:** Unix socket traffic is local; not encrypted in user space beyond OS file permissions.
- **Completions:** No secret loading for **`arc completions`**, reducing leakage surface when generating scripts offline.

---

## 9. Appendices

### Appendix A — Command cheat sheet

Global: **`arc [-o table|json] <command>`** (`-o` is **global** in `main.rs`).

| Command | Notes |
|---------|--------|
| `status` | Server metrics; `-o json` |
| `sites` | List (local nginx); `--filter` |
| `sites create <domain> [--runtime] [--proxy-port] [--ssl --ssl-email]` | |
| `sites delete <domain>` | |
| `sites info <domain>` | |
| `db` | List; `--filter` |
| `db create <name> --engine --password --port` | |
| `db delete <container_id>` | |
| `apps` | List; `--filter` |
| `apps templates` | |
| `apps deploy <template> --name --port [--domain] [--ssl-email]` | |
| `apps stop\|start\|restart\|remove <container_id>` | |
| `apps logs <container_id>` | |
| `apps compose <file>` | docker-compose YAML |
| `services` | Health; `--filter` |
| `ssl status <domain>` | |
| `ssl provision <domain> --email [--runtime] [--proxy-port]` | |
| `backup create <domain>` | |
| `backup list <domain>` | |
| `backup restore <domain> <filename>` | |
| `backup delete <domain> <filename>` | |
| `backup db-create --container --db-name [--db-type] [--user] --password` | |
| `backup db-list <db_name>` | |
| `backup vol-create --volume --container` | |
| `backup vol-list <container>` | |
| `backup verify --type site\|database\|volume <name> <filename>` | |
| `backup health` | Local disk stats |
| `logs [-d domain] [-t type] [-n lines] [-f filter] [-s search]` | |
| `security` | Overview when no subcommand |
| `security scan` | |
| `security firewall` | List rules |
| `security firewall add --port [--proto] [--action] [--from]` | |
| `security firewall remove <number>` | |
| `top` | Process list |
| `php` | List versions |
| `php install <version>` | 8.1–8.4 |
| `diagnose` | Full diagnostic JSON/report |
| `export [-O path]` | YAML to file or stdout |
| `apply <file> [--dry-run] [--email]` | IaC |
| `completions <shell>` | No token required |

### Appendix B — Glossary

| Term | Meaning |
|------|--------|
| **Agent** | `arc-agent` — host daemon serving HTTP over **`agent.sock`**. |
| **API (control plane)** | `arc-api` — PostgreSQL-backed HTTP service for the panel UI; **not** contacted by this CLI. |
| **Bearer token** | Shared secret in **`agent.token`** authorizing local agent requests. |
| **IaC** | Infrastructure as Code — **`export`** / **`apply`** YAML workflows. |

### Appendix C — Dependencies (`panel/cli/Cargo.toml`)

| Crate | Version constraint | Role |
|-------|-------------------|------|
| `clap` | 4, features `derive` | CLI parsing |
| `clap_complete` | 4 | Shell completions |
| `tokio` | 1, features `full`, `net` | Async runtime, Unix socket |
| `serde` | 1, features `derive` | Serialization |
| `serde_json` | 1 | JSON |
| `serde_yaml_ng` | 0.10 | YAML for IaC |

**Release profile:** `strip = true`, `lto = true`, `codegen-units = 1` for smaller, optimized binaries.

---

## Document maintenance

When adding commands or agent paths, update **`main.rs`** (and this file). When changing socket/token locations, update **`client.rs`** and §2.3, §7, and §8 of this document.
