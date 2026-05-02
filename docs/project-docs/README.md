# Arcpanel — project technical documentation

This folder holds **long-form technical references** for each major codebase area. They were written to serve onboarding, architecture review, and maintenance: executive summaries, module maps, integration points, operations notes, and security-relevant behavior grounded in the repository.

## Documents

| Document | Scope | Start here if you… |
|----------|--------|---------------------|
| [features.md](./features.md) | **Product capabilities** — curated list aligned with [`website/docs/`](../../website/docs/) (guides, getting started, references) | Need a **feature-oriented overview** before reading implementation docs |
| [folder-structure.md](./folder-structure.md) | Whole repo — directories, crates, `website/`, `scripts/`, `docs/`, `tests/`, `openspec/` | Need a **structural map** before diving into a subtree |
| [agent.md](./agent.md) | `panel/agent/` — `arc-agent`, Tokio/Axum, Unix socket, Docker/ACME/host work | Operate or extend the **host agent**, phone-home, or agent TLS |
| [backend.md](./backend.md) | `panel/backend/` — `arc-api`, PostgreSQL, auth, email, agent orchestration | Work on the **control-plane API**, migrations, or sessions |
| [cli.md](./cli.md) | `panel/cli/` — `arc`, clap, HTTP over UDS to the agent | Build **operator CLI** flows or automation against the agent socket |
| [frontend.md](./frontend.md) | `panel/frontend/` — Vite SPA, React Router, API/WebSocket usage | Change the **web UI**, routing, or client API layer |
| [website.md](./website.md) | `website/` — marketing SPA, small Express API, mdBook doc sources | Deploy or extend the **public site**, installer links, or user docs book |

## How the pieces connect (mental model)

- **Browser** → nginx → **`arc-api`** (HTTP, Postgres, sessions) and proxied WebSockets where configured.
- **`arc-api`** → **`arc-agent`** (HTTP/1.1 over a Unix socket, bearer token) for privileged host operations.
- **`arc`** (CLI) → **`arc-agent`** on the same host (same socket pattern as the API’s agent client), not direct HTTP to `arc-api` for routine commands.

Read **agent.md** and **backend.md** together for the full API↔agent contract; read **cli.md** alongside **agent.md** for local operator paths.

The **`website/`** tree is separate from the control plane: it serves marketing pages, optional companion HTTP endpoints, and mdBook markdown sources for published documentation. It does not replace **`panel/frontend/`** for logged-in panel usage.

## Repository map (from `AGENTS.md`)

| Path | Role |
|------|------|
| `panel/agent/` | Host agent (`arc-agent`) |
| `panel/backend/` | Control-plane API (`arc-api`) |
| `panel/cli/` | Operator CLI (`arc`) |
| `panel/frontend/` | Vite-built SPA |
| `website/` | Public marketing site, docs sources (`website/docs/`), companion API (`website/server/`) |

For a **fuller directory layout** (including `scripts/`, `tests/`, `docs/`, `openspec/`, and tooling folders), see [folder-structure.md](./folder-structure.md).

For install paths and systemd layout on servers, see `scripts/setup.sh` and project `AGENTS.md` at the repository root.
