# Arcpanel — product features (from user docs)

This page is a **curated feature catalog** aligned with the published documentation sources under [`website/docs/`](../../website/docs/). It is meant for quick orientation; authoritative how-tos remain in that book (Getting Started, guides, references).

## Platform & installation

- **Self-hosted, Docker-native** server management panel (Rust control plane).
- **Single-command install** with OS detection; optional **pre-built binaries** (e.g. low-RAM ARM64) or release-based install.
- **Lightweight footprint** — small idle memory for panel services; bundled PostgreSQL in typical layouts.
- **x86_64 and ARM64** support.
- **Reverse proxy** — Nginx fronting the panel; default panel port **8443** (configurable in setup).
- **First-login admin setup** — account creation on first access.

## Sites, runtimes & apps

- **Sites** — create sites with a domain and runtime: **static**, **PHP**, **Node.js**, **Python**; Nginx and document roots as documented in Getting Started.
- **SSL** — automatic certificate provisioning (Let's Encrypt) when DNS is correct.
- **Docker apps** — catalog of **one-click templates** across many categories (see Getting Started for current counts/categories).
- **WordPress** — dedicated guide for WordPress workflows ([`guides/wordpress.md`](../../website/docs/guides/wordpress.md)).
- **Git deploy** — deploy from Git repositories ([`guides/git-deploy.md`](../../website/docs/guides/git-deploy.md)).

## DNS & certificates

- **DNS management** — Cloudflare and PowerDNS integration for records from the panel (Getting Started).
- **ACME profiles & renewal** — certificate profiles and renewal behavior ([`guides/acme-profiles.md`](../../website/docs/guides/acme-profiles.md)).

## Email

- Outbound and mail-related configuration covered in [**Email**](../../website/docs/guides/email.md) (SMTP, routing, panel email behavior as documented there).

## Multi-server

- **Central panel, remote agents** — manage **unlimited remote servers** from one UI; remotes run the lightweight agent; **HTTPS** and **token-based** auth between panel and agents ([`guides/multi-server.md`](../../website/docs/guides/multi-server.md)).
- **Per-server targeting** via `X-Server-Id` on API calls (see API reference).

## Backups

- **Per-site / scheduled backups** with optional **S3-compatible** remote destinations ([`guides/backups.md`](../../website/docs/guides/backups.md)).
- **Backup Orchestrator** — infrastructure-level backups for **PostgreSQL, MySQL/MariaDB, MongoDB** containers and **Docker volumes**; **policies**, **retention**, **AES-256-GCM** encryption option, **verification** / restore tests, destinations including **S3, SFTP, B2, GCS** ([`guides/backup-orchestrator.md`](../../website/docs/guides/backup-orchestrator.md)).

## Monitoring, metrics & status

- **Monitors** — HTTP, TCP, Ping, Keyword, and **Heartbeat** (dead-man's switch) checks with intervals, alerts ([`guides/monitoring.md`](../../website/docs/guides/monitoring.md)).
- **Prometheus metrics** — expose metrics for scraping ([`guides/prometheus.md`](../../website/docs/guides/prometheus.md)).
- **Public status page** — operational status surface ([`guides/status-page.md`](../../website/docs/guides/status-page.md)).
- **Incidents** — incident workflow alongside status ([`guides/incidents.md`](../../website/docs/guides/incidents.md)).

## Security & compliance

- **2FA (TOTP)** and recovery codes (Getting Started).
- **Secrets Manager** — centralized secrets ([`guides/secrets.md`](../../website/docs/guides/secrets.md)).
- **Security hardening** guide ([`guides/security-hardening.md`](../../website/docs/guides/security-hardening.md)).
- **Image vulnerability scanning** ([`guides/image-scanning.md`](../../website/docs/guides/image-scanning.md)).
- **SBOMs** — software bill of materials ([`guides/sbom.md`](../../website/docs/guides/sbom.md)).
- **Sessions** — session management documentation ([`guides/sessions.md`](../../website/docs/guides/sessions.md)).

## Integrations & notifications

- **Webhook Gateway** — receive, inspect, **route**, and **replay** inbound webhooks; **HMAC** verification; deliveries log ([`guides/webhook-gateway.md`](../../website/docs/guides/webhook-gateway.md)).
- **Notifications** — channel and routing options as documented ([`guides/notifications.md`](../../website/docs/guides/notifications.md)).

## UI & experience

- **Themes & layouts** — appearance and layout options ([`guides/themes.md`](../../website/docs/guides/themes.md)).

## Operator interfaces

- **REST API** — broad surface documented in [**API Reference**](../../website/docs/api-reference.md) (auth via cookie JWT or `Authorization: Bearer`).
- **CLI (`arc`)** — operator commands documented in [**CLI Reference**](../../website/docs/cli-reference.md).
- **Diagnostics** — e.g. `arc diagnose` (Getting Started) and troubleshooting ([`troubleshooting.md`](../../website/docs/troubleshooting.md)).

## Configuration & billing (optional)

- **Environment-based configuration** for API, agent paths, DB, JWT, agent token, logging, CORS, etc. ([`CONFIGURATION.md`](../../website/docs/CONFIGURATION.md)).
- **Stripe** — optional billing-related env vars when billing is enabled ([`CONFIGURATION.md`](../../website/docs/CONFIGURATION.md)).

## Migration

- **Dockpanel → Arcpanel** migration guide ([`guides/migration-dockpanel-to-arcpanel.md`](../../website/docs/guides/migration-dockpanel-to-arcpanel.md)).

---

**Doc map:** [`website/docs/SUMMARY.md`](../../website/docs/SUMMARY.md) lists all chapters. For **repository** architecture (agent, API, CLI, frontend, website tree), see [folder-structure.md](./folder-structure.md) and the other files in this folder.
