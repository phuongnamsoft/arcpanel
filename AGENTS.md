# AGENTS.md — Arcpanel

Instructions for coding agents working in this repository. Humans may use this as a quick orientation map.

## What this project is

Arcpanel is a self-hosted server management panel. Runtime layout (from `scripts/setup.sh`): PostgreSQL, a Rust **agent** (systemd, Unix socket), Rust **API** (HTTP, default port 3080), Rust **CLI** (`arc`), and a **Vite-built** frontend served behind nginx.

## Repository map

| Path | Role |
|------|------|
| `panel/agent/` | `arcpanel-agent` — host agent (Axum, Docker/bollard, ACME/TLS, etc.). Binary: `arc-agent`. |
| `panel/backend/` | `arcpanel-api` — control-plane API (Axum, WebSockets, `sqlx` + PostgreSQL, auth, email). Binary: `arc-api`. |
| `panel/cli/` | `arcpanel-cli` — operator CLI. Binary: `arc`. |
| `panel/frontend/` | React 19 + TypeScript + Vite 6 + Tailwind 4 + React Router 7; terminal UI via `@xterm/xterm`. |
| `scripts/` | Bash installers and ops helpers (see below). |

Version numbers for shipped artifacts are aligned across `panel/*/Cargo.toml` and `panel/frontend/package.json` when releases are cut.

## Skills to apply (in-repo)

Use these project skills for depth; prefer them over generic web/Rust advice when they conflict with blog posts.

| Concern | Skill |
|---------|--------|
| Rust language, async (Tokio), Axum/tower, performance, error and test patterns | `.claude/skills/rust-pro/SKILL.md` |
| React/TypeScript structure, accessibility mindset, component and hook quality | `.claude/skills/senior-frontend/SKILL.md` |
| React performance and data-flow rules (waterfalls, bundle weight, re-renders, client fetching) | `.claude/skills/react-best-practices/AGENTS.md` |

**Stack caveat:** The frontend is a **Vite SPA**, not Next.js. Apply **senior-frontend** and **react-best-practices** to client-side React, routing, and API usage. Skip or adapt guidance that assumes React Server Components, the App Router, or Next-specific APIs unless you are explicitly introducing that stack.

### Distilled frontend priorities (from react-best-practices)

When touching `panel/frontend/`:

1. **Avoid request waterfalls** — parallelize independent async work; do not chain sequential `await`s when inputs do not depend on each other.
2. **Keep bundles lean** — prefer direct imports over heavy barrel files; lazy-load large routes or rare widgets (e.g. heavy editor/terminal paths) when it improves first paint without hurting UX.
3. **Stable hooks and narrow effects** — dependency arrays and state splits should match real data dependencies; avoid effects that re-run whole trees unnecessarily.
4. **Re-render discipline** — lift static JSX, memoize where profiling or structure warrants it, use transitions for non-urgent UI updates when appropriate.

### Distilled Rust priorities (from rust-pro)

When touching `panel/agent/`, `panel/backend/`, or `panel/cli/`:

1. **Edition and toolchain** — crates use **Rust 2024**; match existing patterns and `Cargo.lock` when adding dependencies.
2. **Async and I/O** — Tokio-first; respect cancellation and backpressure for long-lived tasks (agent, WS streams, outbound HTTP).
3. **Errors and observability** — propagate errors with context; use structured logging already present (`tracing`); do not swallow errors silently in request paths.
4. **Security** — treat auth, tokens, crypto, and file/socket paths as sensitive; preserve constant-time comparisons and existing crypto choices unless a change is explicitly scoped and reviewed.
5. **Databases** — backend uses **`sqlx`** with PostgreSQL; migrations and queries should stay compile-checked where the project already does so.

## `scripts/` — what agents should know

All scripts assume a **bash** environment and are intended for **Linux server** deployment flows (see headers in each file).

| Script | Purpose (high level) |
|--------|----------------------|
| `install.sh` | Quick installer (clone/update under `/opt/arcpanel`, optional build-from-source). |
| `setup.sh` | Full server setup: Postgres container, builds or release binaries, systemd units, nginx, paths under `/etc/arcpanel`. |
| `install-agent.sh` | Agent-only install path. |
| `update.sh` / `uninstall.sh` | Lifecycle maintenance. |
| `release.sh` | Release automation. |
| `deploy-check.sh` | Pre-flight checks for deploys. |
| `docs-audit.sh` / `audit-rebrand.sh` | Documentation and branding audits. |

When editing scripts:

- Preserve **`set -euo pipefail`** and explicit variable quoting unless there is a strong, documented reason not to.
- Keep **paths consistent** with `panel/agent`, `panel/backend`, `panel/cli`, `panel/frontend` as in `setup.sh` (`REPO_DIR`, `FRONTEND_DIR`, etc.).
- Prefer **idempotent** steps where the script is re-runnable on partially configured hosts.
- Do not embed secrets in the repo; use env vars and existing config locations (`/etc/arcpanel` on target systems).

## Commands agents should run locally

From the repo root:

```bash
# Rust — lint (matches CI style; individual crates)
cargo clippy --manifest-path panel/agent/Cargo.toml --release
cargo clippy --manifest-path panel/backend/Cargo.toml --release
cargo clippy --manifest-path panel/cli/Cargo.toml --release

# Rust — release build
cargo build --release --manifest-path panel/agent/Cargo.toml
cargo build --release --manifest-path panel/backend/Cargo.toml
cargo build --release --manifest-path panel/cli/Cargo.toml

# Frontend
cd panel/frontend && npm ci && npm run build
cd panel/frontend && npx tsc --noEmit
```

CI definition: `.github/workflows/ci.yml`.

## Change discipline

- Match **existing style** (imports, module layout, logging, React component patterns) in the crate or package you edit.
- Keep changes **scoped** to the requested behavior; avoid drive-by refactors across unrelated binaries.
- If a change spans API and UI, coordinate **types and routes** between `panel/backend` and `panel/frontend` in the same change set when possible.
- After substantive edits, run the **relevant** commands above for the areas you touched.

## Optional: OpenSpec / product workflow

This repo includes OpenSpec-oriented skills under `.claude/skills/openspec-*` and planning skills (`brainstorming`, `writing-plans`, `executing-plans`). Use them when the user asks for a spec-first or multi-phase change, not for every trivial fix.
