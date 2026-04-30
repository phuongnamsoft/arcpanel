# DockPanel → Arcpanel full rebrand — design spec

**Status:** Approved — brand and domain locked  
**Date:** 2026-04-30 (updated with Arcpanel / arcpanel.top)

## 1. Goals and constraints

| Input | Choice |
|--------|--------|
| Scope | **Full technical rename** — not display-only. Binaries, on-disk paths, metrics, and internal identifiers move with the new brand. |
| Name / domain | **Locked:** product **Arcpanel**, primary domain **`arcpanel.top`** (see §2 and §7). |
| Tone | **Builder / developer** — Docker, Git, APIs, CLI-first. |
| “Docker” in the name | **No** — neutral platform brand; Docker remains in positioning and docs. |
| Domain budget | **Registration pricing** — **`arcpanel.top`** chosen explicitly (typically low registration cost; verify at registrar). |
| CLI vs product name | **Locked:** display name **Arcpanel**; CLI **`arc`** (3 chars); filesystem and technical slug **`arc`** (matches CLI). |

## 2. Naming model (locked)

| Role | Value | Notes |
|------|--------|--------|
| **Display name** | **Arcpanel** | UI titles, README, default From-name, marketing. Optional styling **ArcPanel** in logos only if desired — pick one for UI strings and stick to it. |
| **CLI binary** | **`arc`** | Shipped CLI command and primary artifact name root (e.g. `arc` executable). |
| **API / agent binaries** | **`arc-api`**, **`arc-agent`** | Replace `dockpanel-api`, `dockpanel-agent`; keep parallel naming under the `arc` family. |
| **Filesystem slug** | **`arc`** | Uniform roots: `/etc/arc`, `/var/lib/arc`, `/var/backups/arc`, sockets/tokens under `/etc/arc` or paths documented in migration. **No** mixed `arcpanel` vs `arc` on disk — single slug **`arc`**. |
| **Prometheus prefix** | **`arc_`** | Replace `dockpanel_*` metrics (breaking for scrapers). |
| **Docker / container prefixes** | **`arc-git-`**, **`arc-snapshot:`** (or equivalent) | Replace `dockpanel-git-*`, `dockpanel-snapshot:*` patterns and validation. |

Documentation must introduce **Arcpanel** and the **`arc`** command together early (e.g. first-run and CLI overview) so users map display name ↔ CLI.

### Canonical URLs (primary domain)

| Use | URL |
|-----|-----|
| **Marketing / install** | `https://arcpanel.top` — canonical home, `install.sh` host, links in README and in-product where a “website” URL is needed. |
| **Documentation** | **`https://docs.arcpanel.top`** — canonical docs base (same pattern as former `docs.dockpanel.dev`). |
| **Examples / reserved names** | Replace `dockpanel.dev` with **`arcpanel.top`** where the codebase reserves or exemplifies the project domain; keep neutral examples like `panel.example.com` where appropriate. |

## 3. Scope of changes

### 3.1 Ship artifacts

- Rename CLI to **`arc`**, API to **`arc-api`**, agent to **`arc-agent`**; CI/release packaging, checksums, archives.
- Update any systemd unit names or install scripts that reference old binary names (`dockpanel`, `dockpanel-agent`, etc.).

### 3.2 On-disk layout

- Replace fixed paths under current roots (`/etc/dockpanel`, `/var/lib/dockpanel`, `/var/backups/dockpanel`, agent socket/token paths, SSL trees, scanner dirs, etc.) with paths under **`/etc/arc`**, **`/var/lib/arc`**, **`/var/backups/arc`**, etc.

### 3.3 Identifiers in behavior

- Prometheus: rename metrics from `dockpanel_*` to **`arc_*`** (breaking for scrapers).
- Docker: rename tag/container prefixes per §2 (breaking for automation that filters on old prefixes).
- TLS / certs: update embedded identities (e.g. agent cert SAN/CN) from `dockpanel-agent` to **`arc-agent`** or equivalent **arc**-prefixed identity.

### 3.4 Product and API surfaces

- Default strings, test webhook payloads, reserved/example hostnames: use **`arcpanel.top`** / **`docs.arcpanel.top`** instead of `dockpanel.dev` / `docs.dockpanel.dev` where the product encodes its own domain.

### 3.5 Docs and tests

- All guides, CLI examples, E2E fixtures, and comments: **`arc`** commands and **`/etc/arc`** (etc.) paths; install examples use **`curl … arcpanel.top/install.sh`**.

## 4. Migration (existing installs)

(Unchanged strategy; paths and binary names now explicitly **dockpanel → arc** / **Arcpanel**.)

### 4.1 Required

- Documented migration procedure stopping services, moving trees from **`dockpanel`** roots to **`arc`** roots, rewriting configs with absolute paths, verifying with **`arc`** CLI smoke tests.

### 4.2 Release packaging

- Clearly signaled **BREAKING** release: list **`arc`**, **`arc-api`**, **`arc-agent`**, path map, metric prefixes, Docker prefixes, link to migration doc.

### 4.3 Optional softening (not default)

- Short-term wrappers/symlinks from old binaries; duplicate Prometheus metrics — only if justified.

### 4.4 Non-goals

- Indefinite dual path trees; silent zero-window migration.

## 5. External surfaces and coordination

### 5.1 Domains

- **`arcpanel.top`** is the **single canonical** public domain for marketing and install distribution.
- **`docs.arcpanel.top`** is the **canonical** documentation host.
- **Legacy `dockpanel.dev` (and `docs.dockpanel.dev`):** HTTP **redirects** to **`https://arcpanel.top`** and **`https://docs.arcpanel.top`** respectively, for a defined transition period; install script may warn and point to the new URLs. Set an **end date** for legacy redirects (e.g. 12–24 months).

### 5.2 GitHub

- Repo rename optional; update badges, release URLs, clone/install instructions to reflect **Arcpanel** and **`arcpanel.top`**.

### 5.3 Pre-ship checklist

- DNS: **`arcpanel.top`** and **`docs.arcpanel.top`** (and TLS).
- `install.sh` and downloads reference **`arcpanel.top`** and new binary names.
- Migration doc + script validated on realistic panel + remote agent.
- Legacy redirects live.
- GitHub metadata and CI badges updated.

## 6. Testing, risks, rollback

### 6.1 Testing

- Audit: denylist old strings (`dockpanel`, `/etc/dockpanel`, metric prefixes, tag prefixes).
- Clean install from **`https://arcpanel.top/install.sh`**; smoke with **`arc`**.
- Migration from DockPanel install to Arcpanel layout; focus SSL, agent TLS, git-build, scanners, path allowlists.

### 6.2 Risks

| Risk | Mitigation |
|------|------------|
| Partial upgrade | Order of operations + version matrix; errors with doc links. |
| Broken dashboards | Changelog: `dockpanel_*` → `arc_*`. |
| Failed migration | Idempotent script or documented recovery + backup restore. |

### 6.3 Rollback

- Backup before migrate; rollback = restore backup + pre-rename DockPanel binaries.

## 7. Brand summary (locked)

| Item | Value |
|------|--------|
| Product | **Arcpanel** |
| CLI | **`arc`** |
| API binary | **`arc-api`** |
| Agent binary | **`arc-agent`** |
| On-disk / metrics / Docker family | slug **`arc`** / **`arc_`** / **`arc-…`** |
| Primary domain | **`arcpanel.top`** |
| Docs | **`docs.arcpanel.top`** |

**Rationale (short):** Neutral developer-facing name; **`arc`** is a short, memorable CLI; **`.top`** keeps registration cost predictable; **`docs.`** subdomain matches prior docs pattern.

## 8. Next step

Implementation follows **`writing-plans`** to produce a detailed execution plan from this spec.
