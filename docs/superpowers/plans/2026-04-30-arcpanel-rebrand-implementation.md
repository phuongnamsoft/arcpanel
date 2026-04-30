# Arcpanel full rebrand (DockPanel → Arcpanel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the full technical rebrand to **Arcpanel** with CLI **`arc`**, API **`arc-api`**, agent **`arc-agent`**, **on-disk paths under `/etc/arcpanel`, `/var/.../arcpanel`, `/opt/arcpanel`** (readable slug `arcpanel`), **Prometheus metrics and Docker image/container family prefixes** still using the short **`arc_` / `arc-git-` / `arc-snapshot:`** form, primary domain **`arcpanel.top`**, docs **`docs.arcpanel.top`**, and updated identifiers per the approved design spec.

**Architecture:** Rename Rust package/binary names and every hard-coded path, label, and user-facing string in the monorepo in a single coordinated release. Treat **Prometheus metrics**, **Git/snapshot image prefixes**, **Postgres/Docker object names**, and **service unit names** as breaking changes with explicit CHANGELOG and migration documentation. **Do not** change cryptographic KDF context bytes used for secrets (`dockpanel-secrets-*` labels in `secrets.rs` / `secrets_crypto.rs`) without a separate data-rekeying migration; those strings are **protocol labels** for existing ciphertext, not marketing names.

**Tech stack:** Rust (axum, clap, sqlx), React (Vite) panel, mdBook docs, GitHub Actions CI, bash install/update scripts, Docker Compose for local dev, optional Debian packages / systemd.

---

## File structure (create / modify)

| Path | Role |
|------|------|
| `panel/cli/Cargo.toml` | Package `arcpanel-cli`, binary `arc` |
| `panel/backend/Cargo.toml` | Package `arcpanel-api`, binary `arc-api` |
| `panel/agent/Cargo.toml` | Package `arcpanel-agent`, binary `arc-agent` |
| `panel/cli/Cargo.lock`, `panel/backend/Cargo.lock`, `panel/agent/Cargo.lock` | Regenerated after renames |
| `panel/backend/Dockerfile` | COPY/ENTRYPOINT `arc-api` |
| `panel/docker-compose.yml` | DB user/db names, `AGENT_SOCKET`, volume names, healthcheck |
| `panel/.env.example` | Document new env names and connection strings |
| `panel/agent/arc-agent.service` | Renamed from `dockpanel-agent.service` (content updated) |
| `panel/cli/src/main.rs` | clap `name = "arc"`, completions binary name `arc` |
| `panel/backend/src/main.rs` | Log lines, version banner |
| `panel/agent/src/main.rs` | Socket and path constants under `/etc/arcpanel`, `/var/.../arcpanel` |
| `panel/agent/src/tls.rs` | Cert paths, rcgen CN `arc-agent` |
| `panel/backend/src/config.rs` | Default `AGENT_SOCKET` path |
| `panel/backend/src/services/prometheus_exporter.rs` | All `arc_*` metric names and HELP text |
| `panel/backend/src/routes/prometheus.rs` | Token prefix `arcms_`, tests (length 70) |
| `panel/backend/src/routes/sites.rs` | Reserved hostnames `arcpanel.top`, `docs.arcpanel.top` |
| `panel/backend/src/routes/whmcs.rs` | Default domain `pending.arcpanel.top` |
| `panel/backend/migrations/20260430120000_arcpanel_default_branding.sql` | **New** — update default `panel_name` for existing default only |
| `panel/backend/src/**` + `panel/agent/src/**` | Every `dockpanel` path, label, container prefix, User-Agent, JSON key as per tasks below |
| `panel/frontend/**` | Branding, service log names, examples, download filenames |
| `scripts/*.sh` | `install.sh`, `setup.sh`, `update.sh`, `install-agent.sh`, `uninstall.sh`, `release.sh`, `deploy-check.sh` |
| `website/client/public/install.sh` | Public copy of installer entrypoint |
| `dashboards/dockpanel-grafana.json` | Rename to `dashboards/arcpanel-grafana.json` and replace metric names / titles |
| `docs/**` (except this plan and the spec) | Global domain, CLI, paths, product name |
| `docs/book.toml` | Book title, authors, git URL (if repo moves) |
| `.github/workflows/ci.yml` | Binary paths in summary |
| `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md` | Entry for BREAKING release |
| `docs/guides/migration-dockpanel-to-arcpanel.md` | **New** — operator migration procedure |

**Intentionally unchanged (compatibility):**

- `panel/backend/src/routes/secrets.rs` — `hasher.update(b"dockpanel-secrets-encryption:")` **must stay** unless secrets rekey migration ships.
- `panel/backend/src/services/secrets_crypto.rs` — `b"dockpanel-secrets-v1:"` **must stay** for the same reason.

---

## Reference replacement tables (use with review, not blind-only)

**Filesystem / systemd (slug `arcpanel` — easy to grep and match the product name):**

- `/etc/dockpanel` → `/etc/arcpanel`
- `/var/run/dockpanel` → `/var/run/arcpanel`
- `/var/lib/dockpanel` → `/var/lib/arcpanel`
- `/var/backups/dockpanel` → `/var/backups/arcpanel`
- `/opt/dockpanel` → `/opt/arcpanel`
- `dockpanel-agent.service` → `arc-agent.service`
- `dockpanel-api.service` → `arc-api.service`
- `RuntimeDirectory=dockpanel` → `RuntimeDirectory=arcpanel`
- `tmpfiles.d/dockpanel.conf` → `tmpfiles.d/arcpanel.conf` (contents: `d /run/arcpanel 0755 root root -`)
- Nginx snippet filenames: `dockpanel-panel.conf` → `arcpanel-panel.conf`

**Note:** CLI binaries remain **`arc` / `arc-api` / `arc-agent`**; only directory trees use the **`arcpanel`** path segment.

**Binaries:**

- `/usr/local/bin/dockpanel` → `/usr/local/bin/arc`
- `/usr/local/bin/dockpanel-api` → `/usr/local/bin/arc-api`
- `/usr/local/bin/dockpanel-agent` → `/usr/local/bin/arc-agent`

**Docker resources:**

- Container `dockpanel-postgres` → `arc-postgres`
- Volume `dockpanel-pgdata` → `arc-pgdata`
- Network `dockpanel-db` → `arc-db`
- Labels `dockpanel.managed` → `arc.managed`, `dockpanel.db.name` → `arc.db.name`, `dockpanel.db.engine` → `arc.db.engine`, `dockpanel.app.*` → `arc.app.*`
- Git image/container prefix `dockpanel-git-` → `arc-git-`
- Snapshot prefix `dockpanel-snapshot:` → `arc-snapshot:`
- DB container prefix `dockpanel-db-` → `arc-db-`

**Postgres identifiers (greenfield / new compose):**

- User `dockpanel` → `arc`
- Database name in setup (currently `dockpanel`) → `arc` (align `panel/docker-compose.yml` which used `dockpanel_panel` → use **`arc_panel`** for the DB name and **`arc`** as user for consistency across scripts).

**Prometheus:**

- All metric names `dockpanel_*` → `arc_*` (including HELP lines).
- Scrape token prefix `dpms_` → `arcms_` (6 chars). New token length = **70** (`arcms_` + 64 hex chars).

**Telemetry JSON keys:**

- `dockpanel_version` → `arc_version`
- `dockpanel_agent_version` → `arc_agent_version`

**Installer release artifacts (in `scripts/release.sh`):**

- `dockpanel-agent-linux-*` → `arc-agent-linux-*`
- `dockpanel-api-linux-*` → `arc-api-linux-*`
- `dockpanel-cli-linux-*` → `arc-linux-*` (CLI command is `arc`)
- `dockpanel-frontend.tar.gz` → `arcpanel-frontend.tar.gz`
- SBOM filenames → `arc-agent.spdx.json`, `arc-api.spdx.json`, `arc-cli.spdx.json`

**Environment variable:**

- `DOCKPANEL_VERSION` → `ARCPANEL_VERSION` (document both in migration doc for one release if you support a transition).

---

### Task 1: Rust crates — package names, binaries, descriptions

**Files:**

- Modify: `panel/cli/Cargo.toml`
- Modify: `panel/backend/Cargo.toml`
- Modify: `panel/agent/Cargo.toml`

- [ ] **Step 1: Edit `panel/cli/Cargo.toml`**

Replace the file header with:

```toml
[package]
name = "arcpanel-cli"
version = "2.7.20"
edition = "2024"
description = "CLI for Arcpanel — self-hosted server management"

[[bin]]
name = "arc"
path = "src/main.rs"
```

Remove any duplicate `[[bin]]` if present after merge.

- [ ] **Step 2: Edit `panel/backend/Cargo.toml`**

Set:

```toml
[package]
name = "arcpanel-api"
version = "2.7.20"
edition = "2024"

[[bin]]
name = "arc-api"
path = "src/main.rs"
```

(Ensure `src/main.rs` exists as the binary root — it does today.)

- [ ] **Step 3: Edit `panel/agent/Cargo.toml`**

Set:

```toml
[package]
name = "arcpanel-agent"
version = "2.7.20"
edition = "2024"

[[bin]]
name = "arc-agent"
path = "src/main.rs"
```

- [ ] **Step 4: Regenerate lockfiles**

Run:

```bash
cd panel/cli && cargo generate-lockfile
cd ../backend && cargo generate-lockfile
cd ../agent && cargo generate-lockfile
```

Expected: Three `Cargo.lock` files update with new package names.

- [ ] **Step 5: Verify release build**

Run:

```bash
cargo build --release --manifest-path panel/cli/Cargo.toml
cargo build --release --manifest-path panel/backend/Cargo.toml
cargo build --release --manifest-path panel/agent/Cargo.toml
ls panel/cli/target/release/arc panel/backend/target/release/arc-api panel/agent/target/release/arc-agent
```

Expected: All three paths exist.

- [ ] **Step 6: Commit**

```bash
git add panel/cli/Cargo.toml panel/cli/Cargo.lock panel/backend/Cargo.toml panel/backend/Cargo.lock panel/agent/Cargo.toml panel/agent/Cargo.lock
git commit -m "feat(rebrand): rename Rust packages and binaries to arc / arc-api / arc-agent"
```

---

### Task 2: CLI user-facing strings and completions

**Files:**

- Modify: `panel/cli/src/main.rs`

- [ ] **Step 1: Update clap root**

In `#[command(...)]` on `struct Cli`, set:

```rust
#[command(
    name = "arc",
    about = "Arcpanel CLI — self-hosted server management",
    version
)]
```

- [ ] **Step 2: Update completion generator**

Find (approx. line 376):

```rust
clap_complete::generate(shell, &mut Cli::command(), "dockpanel", &mut std::io::stdout());
```

Replace with:

```rust
clap_complete::generate(shell, &mut Cli::command(), "arc", &mut std::io::stdout());
```

- [ ] **Step 3: Grep CLI crate for remaining `dockpanel`**

Run:

```bash
rg -n "dockpanel|DockPanel" panel/cli/
```

Expected: No matches (fix any in `client.rs`, `commands/*.rs`).

- [ ] **Step 4: Run clippy and tests**

```bash
cargo clippy --manifest-path panel/cli/Cargo.toml --release -D warnings
cargo test --manifest-path panel/cli/Cargo.toml
```

Expected: clippy clean; `cargo test` either runs 0 tests or all pass.

- [ ] **Step 5: Commit**

```bash
git add panel/cli/src
git commit -m "feat(rebrand): arc CLI branding and shell completions name"
```

---

### Task 3: Backend Docker image and API strings

**Files:**

- Modify: `panel/backend/Dockerfile`
- Modify: `panel/backend/src/main.rs`
- Modify: `panel/backend/src/config.rs`

- [ ] **Step 1: Dockerfile ENTRYPOINT**

In `panel/backend/Dockerfile`, replace:

```dockerfile
COPY --from=builder /app/target/release/dockpanel-api /usr/local/bin/
ENTRYPOINT ["dockpanel-api"]
```

with:

```dockerfile
COPY --from=builder /app/target/release/arc-api /usr/local/bin/
ENTRYPOINT ["arc-api"]
```

- [ ] **Step 2: Default agent socket in config**

In `panel/backend/src/config.rs`, locate `unwrap_or_else` for `AGENT_SOCKET` and set default to `"/var/run/arcpanel/agent.sock"`.

- [ ] **Step 3: Startup log lines in `main.rs`**

Replace substrings `DockPanel API` with `Arcpanel API` in `tracing::info!` messages (listen and shutdown lines).

- [ ] **Step 4: Build**

```bash
cargo build --release --manifest-path panel/backend/Cargo.toml
```

- [ ] **Step 5: Commit**

```bash
git add panel/backend/Dockerfile panel/backend/src/main.rs panel/backend/src/config.rs
git commit -m "feat(rebrand): arc-api container entrypoint and default paths"
```

---

### Task 4: Prometheus metrics and scrape token

**Files:**

- Modify: `panel/backend/src/services/prometheus_exporter.rs`
- Modify: `panel/backend/src/routes/prometheus.rs`
- Modify: `dashboards/dockpanel-grafana.json` → `dashboards/arcpanel-grafana.json`

- [ ] **Step 1: Rename every metric in `prometheus_exporter.rs`**

Mechanically replace:

- `dockpanel_info` → `arc_info` (and HELP text "Arcpanel build information.")
- `dockpanel_cpu_percent` → `arc_cpu_percent`
- `dockpanel_memory_percent` → `arc_memory_percent`
- `dockpanel_disk_percent` → `arc_disk_percent`
- `dockpanel_gpu_*` → `arc_gpu_*` (all variants in file)
- `dockpanel_site_count` → `arc_site_count`
- `dockpanel_alerts_firing` → `arc_alerts_firing`

- [ ] **Step 2: Update scrape token in `prometheus.rs`**

Replace the generator and comments:

```rust
// 256 bits of entropy via two UUIDs. "arcms_" = Arcpanel Metrics Scrape.
format!(
    "arcms_{}{}",
    Uuid::new_v4().simple(),
    Uuid::new_v4().simple()
)
```

Update tests:

```rust
#[test]
fn token_prefix_is_stable_length() {
    let t = generate_token();
    assert!(t.starts_with("arcms_"));
    // First 9 hex chars after the prefix (same display window as before, indices shift by +1 vs dpms_)
    assert!(t[6..15].chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn token_is_sufficiently_long() {
    // "arcms_" + two UUIDs with dashes stripped = 6 + 32 + 32 = 70 chars.
    assert_eq!(generate_token().len(), 70);
}
```

Update any UI in `panel/frontend` that references the 69-character / `dpms_` length to **70** / `arcms_` (see Task 11).

- [ ] **Step 3: Run backend unit tests for these modules**

```bash
cargo test --manifest-path panel/backend/Cargo.toml prometheus -- --nocapture
```

- [ ] **Step 4: Rename and update Grafana dashboard**

```bash
git mv dashboards/dockpanel-grafana.json dashboards/arcpanel-grafana.json
```

Inside `arcpanel-grafana.json`, replace every `dockpanel_` with `arc_` in PromQL / metric references; update human-readable "DockPanel" strings to "Arcpanel"; change `uid` `dockpanel-fleet` → `arc-fleet`.

- [ ] **Step 5: Commit**

```bash
git add panel/backend/src/services/prometheus_exporter.rs panel/backend/src/routes/prometheus.rs dashboards/arcpanel-grafana.json
git commit -m "feat(rebrand)!: arc_* Prometheus metrics and arcms_ scrape token"
```

---

### Task 5: Telemetry JSON and collector

**Files:**

- Modify: `panel/backend/src/routes/telemetry.rs`
- Modify: `panel/backend/src/services/telemetry_collector.rs`
- Modify: `panel/agent/src/routes/telemetry.rs`
- Modify: `panel/frontend/src/pages/Telemetry.tsx` (imports keys / download filename — coordinate with Task 8)

- [ ] **Step 1: Backend telemetry JSON keys**

In `panel/backend/src/routes/telemetry.rs`, replace `"dockpanel_version"` with `"arc_version"` (both occurrences).

- [ ] **Step 2: Telemetry collector**

In `telemetry_collector.rs`, replace `"dockpanel_version"` with `"arc_version"` and User-Agent `DockPanel/` → `Arcpanel/`.

- [ ] **Step 3: Agent telemetry struct**

In `panel/agent/src/routes/telemetry.rs`:

- Rename field `dockpanel_agent_version` → `arc_agent_version` (serde rename if external compatibility needed — spec requires rename; use `#[serde(rename = "arc_agent_version")]` on struct field `arc_agent_version`).

- [ ] **Step 4: Compile**

```bash
cargo build --release --manifest-path panel/backend/Cargo.toml
cargo build --release --manifest-path panel/agent/Cargo.toml
```

- [ ] **Step 5: Commit**

```bash
git add panel/backend/src/routes/telemetry.rs panel/backend/src/services/telemetry_collector.rs panel/agent/src/routes/telemetry.rs
git commit -m "feat(rebrand)!: telemetry JSON keys arc_version / arc_agent_version"
```

---

### Task 6: Agent paths, TLS CN, systemd unit file

**Files:**

- Modify: `panel/agent/src/main.rs`
- Modify: `panel/agent/src/tls.rs`
- Rename: `panel/agent/dockpanel-agent.service` → `panel/agent/arc-agent.service`
- Modify: `panel/agent/arc-agent.service`

- [ ] **Step 1: Path constants in `main.rs`**

Replace:

```rust
const SOCKET_PATH: &str = "/var/run/arcpanel/agent.sock";
const CONFIG_DIR: &str = "/etc/arcpanel";
```

Update every `create_dir_all` path from `dockpanel` to `arcpanel` (including `/var/backups/arcpanel/...`).

- [ ] **Step 2: TLS generation in `tls.rs`**

```rust
const CERT_PATH: &str = "/etc/arcpanel/ssl/agent.crt";
const KEY_PATH: &str = "/etc/arcpanel/ssl/agent.key";
```

In `generate_self_signed`, use:

```rust
let cert = rcgen::generate_simple_self_signed(vec!["arc-agent".to_string()])
```

Update mkdir to `/etc/arcpanel/ssl`.

- [ ] **Step 3: Service file**

Rename file on disk. Content adjustments:

- `Description=Arcpanel Agent`
- `ExecStart=/usr/local/bin/arc-agent`
- `RuntimeDirectory=arcpanel`
- `ReadWritePaths=...` replace every `dockpanel` segment with `arc`

- [ ] **Step 4: Commit**

```bash
git add panel/agent/src/main.rs panel/agent/src/tls.rs panel/agent/arc-agent.service
git rm panel/agent/dockpanel-agent.service
git commit -m "feat(rebrand): arc-agent paths, TLS identity, systemd unit"
```

---

### Task 7: Docker labels, networks, git-build and snapshot prefixes

**Files (representative — grep-driven):**

- Modify: `panel/agent/src/services/database.rs`
- Modify: `panel/agent/src/services/git_build.rs`
- Modify: `panel/agent/src/routes/git_build.rs`
- Modify: `panel/agent/src/routes/docker_apps.rs`
- Modify: `panel/backend/src/routes/git_deploys.rs`
- Modify: `panel/backend/src/routes/databases.rs`
- Modify: `panel/backend/src/routes/backup_orchestrator.rs`
- Modify: `panel/backend/src/services/backup_policy_executor.rs`

- [ ] **Step 1: Replace git/snapshot prefixes**

Per grep results, replace:

- `dockpanel-git-` → `arc-git-` in Rust strings and validation (`tag.starts_with(...)`).
- `dockpanel-snapshot:` → `arc-snapshot:` in `docker_apps.rs`.

- [ ] **Step 2: Database Docker network and containers**

In `database.rs`:

- `dockpanel-db` → `arc-db`
- `dockpanel-db-{name}` → `arc-db-{name}`
- Labels `dockpanel.managed` → `arc.managed`, `dockpanel.db.name` → `arc.db.name`, `dockpanel.db.engine` → `arc.db.engine`
- Filter `dockpanel.managed=true` → `arc.managed=true`

- [ ] **Step 3: Strip prefix in cleanup**

In `git_deploys.rs`, `strip_prefix("dockpanel-git-")` → `strip_prefix("arc-git-")`.

- [ ] **Step 4: Build agent and backend**

```bash
cargo build --release --manifest-path panel/agent/Cargo.toml
cargo build --release --manifest-path panel/backend/Cargo.toml
```

- [ ] **Step 5: Commit**

```bash
git add panel/agent/src panel/backend/src/routes/git_deploys.rs panel/backend/src/routes/databases.rs panel/backend/src/routes/backup_orchestrator.rs panel/backend/src/services/backup_policy_executor.rs
git commit -m "feat(rebrand)!: arc Docker labels, arc-git/arc-snapshot prefixes, arc-db containers"
```

---

### Task 8: Backend route helpers and reserved domains

**Files:**

- Modify: `panel/backend/src/routes/sites.rs`
- Modify: `panel/backend/src/routes/whmcs.rs`
- Modify: `panel/backend/src/routes/system.rs`
- Modify: `panel/backend/src/routes/auth.rs`
- Modify: `panel/backend/src/routes/oauth.rs`
- Modify: `panel/backend/src/routes/passkeys.rs`
- Modify: `panel/backend/src/routes/security.rs`
- Modify: `panel/backend/src/services/backup_scheduler.rs`
- Modify: `panel/backend/src/services/auto_healer.rs` (if contains paths)

- [ ] **Step 1: Reserved hostnames**

In `sites.rs`:

```rust
let reserved = ["arcpanel.top", "panel.example.com", "docs.arcpanel.top"];
```

- [ ] **Step 2: WHMCS default**

`pending.dockpanel.dev` → `pending.arcpanel.top`

- [ ] **Step 3: Service name in health JSON**

`system.rs`: `"service": "arc-api"` for both entries.

- [ ] **Step 4: TOTP / OAuth / Passkeys issuer strings**

Replace `"DockPanel"` with `"Arcpanel"` in `auth.rs`, `oauth.rs`, `passkeys.rs` where it is the issuer/display name.

- [ ] **Step 5: HTML report titles in `security.rs`**

Replace visible "DockPanel" with "Arcpanel"; update `/var/lib/dockpanel/recordings` → `/var/lib/arcpanel/recordings`.

- [ ] **Step 6: Backup paths**

`backup_scheduler.rs`: `/var/backups/dockpanel/` → `/var/backups/arcpanel/`

- [ ] **Step 7: Commit**

```bash
git add panel/backend/src/routes panel/backend/src/services/backup_scheduler.rs
git commit -m "feat(rebrand): reserved domains, arc-api health, Arcpanel issuer strings, arc backup paths"
```

---

### Task 9: Agent remaining path strings and services

**Files:** All under `panel/agent/src/` still matching `dockpanel` from:

```bash
rg -n "dockpanel|DockPanel|/etc/dockpanel|/var/.*dockpanel" panel/agent/src
```

- [ ] **Step 1: Mechanical replace per reference table** for paths, nginx unit names, scanner dirs, quarantine paths, mail paths, etc.

- [ ] **Step 2: `cargo build --release --manifest-path panel/agent/Cargo.toml`**

- [ ] **Step 3: Commit**

```bash
git add panel/agent/src
git commit -m "feat(rebrand): arc paths across agent services"
```

---

### Task 10: Database migration — default panel name

**Files:**

- Create: `panel/backend/migrations/20260430120000_arcpanel_default_branding.sql`

- [ ] **Step 1: Add migration**

```sql
-- Migrate default product name for installs that still use the old seed.
UPDATE settings
SET value = 'Arcpanel', updated_at = NOW()
WHERE key = 'panel_name' AND value = 'DockPanel';
```

- [ ] **Step 2: Apply locally**

```bash
# against dev DB only — example:
# sqlx migrate run --database-url "$DATABASE_URL"
```

- [ ] **Step 3: Commit**

```bash
git add panel/backend/migrations/20260430120000_arcpanel_default_branding.sql
git commit -m "feat(rebrand): migration for default panel_name Arcpanel"
```

---

### Task 11: Frontend branding and technical strings

**Files:**

- Modify: `panel/frontend/index.html` (`<title>Arcpanel</title>`)
- Modify: `panel/frontend/src/context/BrandingContext.tsx` (default `panelName: "Arcpanel"`, fallback strings)
- Modify: `panel/frontend/src/pages/Login.tsx`, `CommandLayout.tsx`, `NexusLayout.tsx` — replace `DockPanel` split-logo checks with `Arcpanel` / optional new styled split (`Arc` + `panel`) per design preference; **minimal change:** treat default name `"Arcpanel"` with same rust/accent split using substring logic for `"Arc"` + `"panel"` if desired.
- Modify: `panel/frontend/src/api.ts` header and agent message
- Modify: remaining pages from grep list in `panel/frontend/src` for `dockpanel`, `DockPanel`, paths, job names

- [ ] **Step 1: Settings Prometheus YAML snippet**

In `Settings.tsx`, job_name `'dockpanel'` → `'arcpanel'` or `'arc'`.

- [ ] **Step 2: Token prefix UI**

Replace `dpms_` display hints with `arcms_` and length note **70**.

- [ ] **Step 3: Logs page service names**

`dockpanel-agent` / `dockpanel-api` → `arc-agent` / `arc-api`.

- [ ] **Step 4: Build**

```bash
cd panel/frontend && npm ci && npx tsc --noEmit && npx vite build
```

- [ ] **Step 5: Commit**

```bash
git add panel/frontend/index.html panel/frontend/src
git commit -m "feat(rebrand): Arcpanel UI strings, arc token hint, arc log services"
```

---

### Task 12: `panel/docker-compose.yml` and `.env.example`

**Files:**

- Modify: `panel/docker-compose.yml`
- Modify: `panel/.env.example`

- [ ] **Step 1: Postgres**

Set `POSTGRES_USER: arc`, `POSTGRES_DB: arc_panel`, healthcheck `pg_isready -U arc -d arc_panel`, `DATABASE_URL` `postgres://arc:...@.../arc_panel`, volume rename `arc-pgdata`, container name `arc-postgres`.

- [ ] **Step 2: API service**

`AGENT_SOCKET: /var/run/arcpanel/agent.sock`

- [ ] **Step 3: Document in `.env.example`**

- [ ] **Step 4: Commit**

```bash
git add panel/docker-compose.yml panel/.env.example
git commit -m "feat(rebrand)!: docker-compose postgres and arc socket paths"
```

---

### Task 13: Shell scripts — install, setup, update, agent, uninstall, release, deploy-check

**Files:**

- Modify: `scripts/install.sh`, `scripts/setup.sh`, `scripts/update.sh`, `scripts/install-agent.sh`, `scripts/uninstall.sh`, `scripts/release.sh`, `scripts/deploy-check.sh`
- Modify: `website/client/public/install.sh`

- [ ] **Step 1: Variable names**

`INSTALL_DIR="/opt/arcpanel"`, `VERSION="${ARCPANEL_VERSION:-main}"`, `DB_CONTAINER="arc-postgres"`, volume `arc-pgdata`, URLs `https://arcpanel.top/...`, binary curl names per artifact table.

- [ ] **Step 2: systemd units embedded in heredocs**

Use `arc-agent` / `arc-api` service names and `/etc/arcpanel/api.env`, `/etc/arcpanel` paths.

- [ ] **Step 3: install-agent OpenSSL**

`-subj "/CN=arc-agent"`

- [ ] **Step 4: release.sh**

Copy `arc`, `arc-api`, `arc-agent` from `target/release/` to distribution filenames per artifact table; frontend tarball `arcpanel-frontend.tar.gz`.

- [ ] **Step 5: Smoke grep**

```bash
rg -n "dockpanel|DockPanel|dockpanel\.dev|docs\.dockpanel" scripts/ website/client/public/install.sh
```

Expected: no matches (except optional commented migration warnings you explicitly add).

- [ ] **Step 6: Commit**

```bash
git add scripts website/client/public/install.sh
git commit -m "feat(rebrand): installer and release scripts for arcpanel.top and arc binaries"
```

---

### Task 14: Documentation (mdBook + guides)

**Files:**

- Modify: `docs/book.toml`
- Modify: all markdown under `docs/` that references old name, domain, paths, or CLI (use `rg` list).

- [ ] **Step 1: book.toml**

```toml
[book]
title = "Arcpanel Documentation"
authors = ["Arcpanel"]
git-repository-url = "https://github.com/ovexro/dockpanel"
```

(Adjust GitHub URL when the repo is renamed.)

- [ ] **Step 2: Replace domains**

`dockpanel.dev` → `arcpanel.top`, `docs.dockpanel.dev` → `docs.arcpanel.top` globally in `docs/`.

- [ ] **Step 3: Replace CLI and paths**

`dockpanel` command → `arc`, paths `/etc/dockpanel` → `/etc/arcpanel`, etc.

- [ ] **Step 4: prometheus.md token docs**

Update bearer token example prefix to `arcms_` and length 70.

- [ ] **Step 5: Build book**

```bash
cd docs && mdbook build 2>/dev/null || (echo "install mdbook if missing"; exit 1)
```

- [ ] **Step 6: Commit**

```bash
git add docs/book.toml docs/
git commit -m "docs(rebrand): Arcpanel, arcpanel.top, arc CLI, arc paths"
```

---

### Task 15: Root README, CONTRIBUTING, CHANGELOG, CI

**Files:**

- Modify: `README.md`
- Modify: `CONTRIBUTING.md`
- Modify: `CHANGELOG.md` (prepend BREAKING section)
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: README**

Product name Arcpanel, install `curl -sL https://arcpanel.top/install.sh`, links to `arcpanel.top` and `docs.arcpanel.top`.

- [ ] **Step 2: CONTRIBUTING**

Local dev Postgres env vars and binary paths using `arc`.

- [ ] **Step 3: CHANGELOG**

```markdown
## [x.y.z] - BREAKING: Arcpanel rebrand

- Binaries: `arc`, `arc-api`, `arc-agent` (was dockpanel, dockpanel-api, dockpanel-agent).
- Paths: `/etc/arcpanel`, `/var/lib/arcpanel`, `/var/run/arcpanel`, `/var/backups/arcpanel`, `/opt/arcpanel`.
- Prometheus: `dockpanel_*` → `arc_*`; scrape tokens now prefix `arcms_` (regenerate panel token).
- Docker: `dockpanel-git-*` / `dockpanel-snapshot:` → `arc-git-*` / `arc-snapshot:`; DB containers `arc-db-*`; labels `arc.*`.
- See docs/guides/migration-dockpanel-to-arcpanel.md.
```

- [ ] **Step 4: CI summary paths**

In `.github/workflows/ci.yml`, `du -h` lines must reference `arc-agent`, `arc-api`, `arc`.

- [ ] **Step 5: Commit**

```bash
git add README.md CONTRIBUTING.md CHANGELOG.md .github/workflows/ci.yml
git commit -m "docs(ci): BREAKING changelog and workflow paths for Arcpanel"
```

---

### Task 16: Migration guide (required by spec)

**Files:**

- Create: `docs/guides/migration-dockpanel-to-arcpanel.md`

- [ ] **Step 1: Document ordered steps**

Include:

1. Full backup of Postgres (`docker exec arc-postgres` / legacy commands) and `/var/backups/dockpanel` tarball.
2. `systemctl stop arc-agent arc-api` (after upgrade; first stop **old** `dockpanel-*` units if migrating mid-release).
3. Move directories: `mv /etc/dockpanel /etc/arcpanel`, `mv /var/lib/dockpanel /var/lib/arcpanel`, etc.; merge if partially overlapping (detail edge cases).
4. Rewrite `api.env`: `DATABASE_URL`, `AGENT_SOCKET`, any absolute paths.
5. `sed` path rewrites in nginx configs `dockpanel-panel.conf` → `arcpanel-panel.conf` and paths.
6. Docker: rename containers/volumes or recreate with `pg_dump`/`pg_restore` (document destructive vs in-place).
7. Relabel or recreate managed containers for `arc.managed` (call out downtime).
8. Update Prometheus/Grafana dashboards and scrape bearer token.
9. Start `arc-agent`, `arc-api`; run `arc status`.

- [ ] **Step 2: Commit**

```bash
git add docs/guides/migration-dockpanel-to-arcpanel.md
git commit -m "docs: migration from DockPanel paths and binaries to Arcpanel"
```

---

### Task 17: Audit — denylist old strings

**Files:**

- Create: `scripts/audit-rebrand.sh`

- [ ] **Step 1: Add script**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0
patterns=(
  '/etc/dockpanel'
  '/var/lib/dockpanel'
  '/var/run/dockpanel'
  '/etc/arc'
  '/var/run/arc'
  '/var/lib/arc'
  'dockpanel.dev'
  'docs.dockpanel.dev'
  'dockpanel_'
  'dockpanel-git-'
  'dockpanel-snapshot:'
)
for p in "${patterns[@]}"; do
  if rg -n --glob '!**/migration-dockpanel-to-arcpanel.md' --glob '!**/CHANGELOG.md' --glob '!**/.claude/**' --glob '!**/node_modules/**' --glob '!**/target/**' "$p" .; then
    echo "AUDIT FAIL: found $p"
    FAIL=1
  fi
done
exit $FAIL
```

- [ ] **Step 2: chmod +x** and run until clean (excluding intentional docs/history if you exclude them — tighten globs as needed).

- [ ] **Step 3: Commit**

```bash
git add scripts/audit-rebrand.sh
git commit -m "chore: audit script for legacy dockpanel strings"
```

---

## Self-review checklist (completed while authoring)

1. **Spec coverage:** Ship artifacts, paths, Prometheus, Docker prefixes, TLS CN, domains, docs/tests, migration doc, breaking release notes — all mapped to tasks above. Legacy HTTP redirects (`dockpanel.dev` → `arcpanel.top`) are **infrastructure/DNS**, not this repo — note for ops in migration guide only.
2. **Placeholders:** No TBD steps; concrete strings and commands provided.
3. **Type consistency:** Token length updated to 70 for `arcms_`; JSON keys `arc_version` / `arc_agent_version` used consistently; metric prefix `arc_`.

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-30-arcpanel-rebrand-implementation.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**

If **Subagent-Driven** is chosen:

- **REQUIRED SUB-SKILL:** Use superpowers:subagent-driven-development — fresh subagent per task + two-stage review.

If **Inline Execution** is chosen:

- **REQUIRED SUB-SKILL:** Use superpowers:executing-plans — batch execution with checkpoints for review.
