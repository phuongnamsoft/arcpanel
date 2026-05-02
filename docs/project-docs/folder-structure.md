# Arcpanel — repository folder structure

This document is a **structural map** of the repository: what lives where at a glance. For behavior, APIs, and integration details, use the area-specific docs linked from [README.md](./README.md) and root [AGENTS.md](../../AGENTS.md).

## Top level

| Path | Purpose |
|------|---------|
| `panel/` | Shipped control plane: Rust **agent**, **API**, **CLI**, and Vite **frontend** (see below). |
| `website/` | Public marketing site, mdBook-style doc sources, optional companion **server** (see [website.md](./website.md)). |
| `scripts/` | Bash installers and ops helpers (`install.sh`, `setup.sh`, `update.sh`, etc.); assume Linux server targets. |
| `tests/` | Shell-based E2E and integration scripts (feature-scoped `*-e2e.sh`, `e2e.sh`, `full-e2e.sh`). |
| `docs/` | Human-written documentation: **`project-docs/`** (this tree’s technical references), **`superpowers/`** (plans/specs). |
| `openspec/` | OpenSpec workflow: `specs/`, `changes/`, `changes/archive/`, `config.yaml`. |
| `dashboards/` | Grafana (or similar) dashboard JSON exports (e.g. `arcpanel-grafana.json`). |
| `.github/` | CI workflows (`workflows/`), issue/PR templates, screenshots. |
| `.claude/` | Claude Code skills, commands, hooks (agent guidance; not runtime). |
| `.cursor/` | Cursor IDE commands and mirrored OpenSpec skills. |
| Root files | `README.md`, `AGENTS.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `FEATURES.md`, `LICENSE`, repo-wide `docker-compose.yml`, etc. |

## `panel/` — control plane

| Path | Role |
|------|------|
| `panel/agent/` | Host agent crate (`arcpanel-agent`); binary **`arc-agent`**. Axum, Tokio, Unix socket, Docker, ACME, nginx templates. |
| `panel/agent/src/routes/` | HTTP route handlers exposed over the agent’s transport. |
| `panel/agent/src/services/` | Long-lived and request-scoped services (Docker, backups, mail, etc.). |
| `panel/agent/src/templates/` | Templated config (e.g. nginx fragments). |
| `panel/backend/` | Control-plane API crate (`arcpanel-api`); binary **`arc-api`**. PostgreSQL (`sqlx`), auth, WebSockets, orchestration toward the agent. |
| `panel/backend/migrations/` | Versioned SQL migrations applied by the API. |
| `panel/backend/src/routes/` | HTTP/WebSocket API surface. |
| `panel/backend/src/services/` | Domain services (schedulers, exporters, etc.). |
| `panel/backend/.cargo/` | Crate-local Cargo config (if present). |
| `panel/cli/` | Operator CLI crate (`arcpanel-cli`); binary **`arc`**. Talks to the agent (e.g. over UDS), not the primary browser/API path. |
| `panel/cli/src/commands/` | Subcommand implementations (`clap` entry points). |
| `panel/frontend/` | Vite + React SPA for the logged-in panel; built assets consumed with nginx in production layouts (see [frontend.md](./frontend.md)). |
| `panel/frontend/src/components/` | Shared UI components. |
| `panel/frontend/src/pages/` | Route-level screens. |
| `panel/frontend/src/hooks/`, `context/`, `utils/`, `data/` | Client hooks, React context, helpers, static data. |
| `panel/frontend/public/` | Static assets for the SPA. |
| `panel/docker-compose.yml` | Local/dev-oriented compose for panel services (alongside root `docker-compose.yml` if used). |
| `panel/.env.example` | Example environment variables for local panel development. |

## `website/` — public site and doc book sources

| Path | Role |
|------|------|
| `website/client/` | Marketing SPA (**Vite** + React): `src/`, `public/`, `nginx.conf`. |
| `website/server/` | TypeScript **Express** companion API (`src/`, `Dockerfile`); billing/integrations (e.g. Stripe) as wired in code. |
| `website/docs/` | Markdown sources for published user/docs content (e.g. `guides/`, reference pages). |

## `scripts/`

Installer and lifecycle scripts (`install.sh`, `setup.sh`, `update.sh`, `uninstall.sh`, `release.sh`, `deploy-check.sh`, audits, etc.). Paths inside scripts align with `panel/agent`, `panel/backend`, `panel/cli`, `panel/frontend` as documented in `AGENTS.md` and `setup.sh`.

## `docs/`

| Path | Role |
|------|------|
| `docs/project-docs/` | Long-form technical references per subsystem ([README.md](./README.md) index). |
| `docs/superpowers/` | Internal planning/spec material (`plans/`, `specs/`). |

## `tests/`

Executable shell scripts that drive end-to-end scenarios against a running stack. Names typically encode the feature area (`backup-orchestrator-e2e.sh`, `webhook-gateway-e2e.sh`, …).

## `openspec/`

Product/spec workflow: living specs under `openspec/specs/`, proposed changes under `openspec/changes/`, completed work under `openspec/changes/archive/`.

## Abbreviated tree (directories only)

Depth is limited for readability; leaf crates/packages are implied by the tables above.

```text
arcpanel/
├── .claude/                 # Claude skills, commands, hooks
├── .cursor/                 # Cursor commands / skills
├── .github/                 # CI, templates, screenshots
├── dashboards/              # Observability dashboard JSON
├── docs/
│   ├── project-docs/        # Technical manuals (this folder)
│   └── superpowers/         # Plans / specs
├── openspec/
│   ├── changes/
│   │   └── archive/
│   └── specs/
├── panel/
│   ├── agent/               # arc-agent
│   ├── backend/             # arc-api
│   ├── cli/                 # arc
│   ├── frontend/            # Panel SPA
│   └── docker-compose.yml
├── scripts/                 # Bash installers & ops
├── tests/                   # E2E shell scripts
└── website/
    ├── client/              # Marketing SPA
    ├── docs/                # mdBook-style sources
    └── server/              # Companion API
```

## Related reading

- [README.md](./README.md) — index of subsystem docs and how agent, API, CLI, and frontend connect.
- [AGENTS.md](../../AGENTS.md) — agent-oriented map, commands to run locally, and script conventions.
