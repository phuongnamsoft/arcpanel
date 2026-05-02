# Arcpanel — project technical documentation

This folder holds **long-form technical references** for each major codebase area. They were written to serve onboarding, architecture review, and maintenance: executive summaries, module maps, integration points, operations notes, and security-relevant behavior grounded in the repository.

## Documents

| Document | Scope | Start here if you… |
|----------|--------|---------------------|
| [agent.md](./agent.md) | `panel/agent/` — `arc-agent`, Tokio/Axum, Unix socket, Docker/ACME/host work | Operate or extend the **host agent**, phone-home, or agent TLS |
| [backend.md](./backend.md) | `panel/backend/` — `arc-api`, PostgreSQL, auth, email, agent orchestration | Work on the **control-plane API**, migrations, or sessions |
| [cli.md](./cli.md) | `panel/cli/` — `arc`, clap, HTTP over UDS to the agent | Build **operator CLI** flows or automation against the agent socket |
| [frontend.md](./frontend.md) | `panel/frontend/` — Vite SPA, React Router, API/WebSocket usage | Change the **web UI**, routing, or client API layer |

## How the pieces connect (mental model)

- **Browser** → nginx → **`arc-api`** (HTTP, Postgres, sessions) and proxied WebSockets where configured.
- **`arc-api`** → **`arc-agent`** (HTTP/1.1 over a Unix socket, bearer token) for privileged host operations.
- **`arc`** (CLI) → **`arc-agent`** on the same host (same socket pattern as the API’s agent client), not direct HTTP to `arc-api` for routine commands.

Read **agent.md** and **backend.md** together for the full API↔agent contract; read **cli.md** alongside **agent.md** for local operator paths.

## Repository map (from `AGENTS.md`)

| Path | Role |
|------|------|
| `panel/agent/` | Host agent (`arc-agent`) |
| `panel/backend/` | Control-plane API (`arc-api`) |
| `panel/cli/` | Operator CLI (`arc`) |
| `panel/frontend/` | Vite-built SPA |

For install paths and systemd layout on servers, see `scripts/setup.sh` and project `AGENTS.md` at the repository root.
