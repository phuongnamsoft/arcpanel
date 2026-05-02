# Local development on Windows with WSL2

This guide explains how to run **Arcpanel’s panel stack** (`panel/agent`, `panel/backend`, `panel/frontend`) on **Windows using WSL2** (recommended distribution: **Ubuntu**). It complements [CONTRIBUTING.md](../../CONTRIBUTING.md) with environment-specific choices: where to store the repo, Docker integration, ports, performance, and common failures.

**Audience:** contributors who develop on Windows and want a Linux-native build and runtime without a separate VM.

**Out of scope:** The marketing site and its compose stack under `website/` (see [website.md](./website.md)). This document focuses on the **control plane** in `panel/`.

---

## 1. Executive summary

| Item | Recommendation on WSL2 |
|------|-------------------------|
| **Repository location** | Clone under the **Linux filesystem** (e.g. `~/src/arcpanel`), **not** under `/mnt/c/...`, for acceptable Rust/`npm` performance and fewer permission quirks. |
| **PostgreSQL** | Run **PostgreSQL in Docker** (same pattern as [CONTRIBUTING.md](../../CONTRIBUTING.md)); ensure **Docker Desktop** uses the WSL2 backend and your distro is enabled for integration. |
| **API listen port** | Set **`LISTEN_ADDR=127.0.0.1:3062`** in `/etc/arcpanel/api.env` so it matches the Vite dev proxy in [`panel/frontend/vite.config.ts`](../../panel/frontend/vite.config.ts). The backend’s default if unset is `127.0.0.1:3080` ([`panel/backend/src/config.rs`](../../panel/backend/src/config.rs)); **3080 conflicts with the stock Vite proxy target (3062)** unless you change one side. See [§5.3](#53-api-list-port-and-vite-proxy). |
| **Shell** | Run all build and run commands **inside** your WSL distro (Ubuntu terminal), not in PowerShell/CMD, unless you use a specialized cross-environment setup. |

---

## 2. Prerequisites on Windows

1. **Windows 10** (2004+) or **Windows 11**, with **WSL2** installed.
2. A **Linux distribution** from the Microsoft Store (this guide assumes **Ubuntu 22.04 LTS** or newer).
3. **Docker Desktop for Windows** with:
   - **Use the WSL 2 based engine** enabled.
   - **Your Ubuntu distro** enabled under **Settings → Resources → WSL integration**.

After integration, `docker version` and `docker run hello-world` should succeed **inside WSL**.

---

## 3. WSL2 host tuning (recommended)

Rust release builds and `npm` installs are memory- and I/O-heavy. On constrained machines, increase WSL resources.

Create or edit **`%UserProfile%\.wslconfig`** on Windows:

```ini
[wsl2]
memory=8GB
processors=4
swap=4GB
```

Then run **`wsl --shutdown`** from PowerShell or CMD and reopen your Ubuntu session. Adjust values to your hardware.

> **Note:** Storing the Git working copy on **DrvFS** (`/mnt/c/...`) can make compiles and `node_modules` access noticeably slower than a tree under **`$HOME`** on the virtual disk. For day-to-day development, prefer **`~/...`**.

---

## 4. One-time setup inside Ubuntu (WSL)

### 4.1 Base packages

```bash
sudo apt update
sudo apt install -y build-essential cmake pkg-config \
  libssl-dev pkg-config libpq-dev \
  git curl
```

`libpq-dev` is useful if you ever run tooling that links against PostgreSQL client libraries; the stack as described in [CONTRIBUTING.md](../../CONTRIBUTING.md) primarily needs Docker for Postgres.

### 4.2 Rust (1.94+ per [CONTRIBUTING.md](../../CONTRIBUTING.md))

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
# Start a new shell or: source "$HOME/.cargo/env"
rustc --version
```

### 4.3 Node.js 20+

Use **nvm**, **NodeSource**, or your preferred method. Example with nvm:

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
source "$HOME/.nvm/nvm.sh"
nvm install 20
node --version
```

### 4.4 Git line endings (important on Windows checkouts)

If the repo is ever accessed from both Windows and WSL, avoid mixed CRLF/LF in sources. A common approach for Linux-primary work:

```bash
git config --global core.autocrlf input
```

**Re-clone** or re-normalize if you already have a working tree with wrong endings; otherwise Rust or frontend builds can fail in subtle ways.

---

## 5. Clone and configure the project

### 5.1 Clone (Linux path)

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/phuongnamsoft/arcpanel.git
cd arcpanel
```

### 5.2 PostgreSQL in Docker

Match [CONTRIBUTING.md](../../CONTRIBUTING.md) (port **5450** on the host maps to **5432** in the container):

```bash
docker run -d --name arc-postgres \
  -e POSTGRES_USER=arc \
  -e POSTGRES_PASSWORD=changeme \
  -e POSTGRES_DB=arc_panel \
  -p 5450:5432 \
  postgres:16
```

Verify:

```bash
docker ps --filter name=arc-postgres
```

If the container exits immediately, inspect logs with `docker logs arc-postgres` (common causes: port 5450 already in use, Docker not running).

### 5.3 API listen port and Vite proxy

The **Vite** dev server proxies browser calls to `/api` to **`http://127.0.0.1:3062`** (see [`panel/frontend/vite.config.ts`](../../panel/frontend/vite.config.ts)). The **API** binary defaults to **`127.0.0.1:3080`** if `LISTEN_ADDR` is not set.

**For local UI + API development, set the API to 3062** so you do not have to edit the frontend config:

```text
LISTEN_ADDR=127.0.0.1:3062
```

This matches the stock dev experience described in [frontend.md](./frontend.md) and the `panel/docker-compose.yml` host port mapping style (API exposed on **3062** on the host). If you prefer to keep the API on **3080**, change the `server.proxy["/api"]` target in `vite.config.ts` to `http://127.0.0.1:3080` **or** use a local override (Vite env) — but the path of least resistance is **3062** for `arc-api` on WSL.

### 5.4 API environment file

Create the config directory and `api.env` (same variable names as production-style docs; see [backend.md](./backend.md) for behavior):

```bash
sudo mkdir -p /etc/arcpanel
```

Write `api.env` with real secrets: `JWT_SECRET` must be **at least 32 characters** ([`panel/backend/src/config.rs`](../../panel/backend/src/config.rs)). If `uuidgen` is missing, install **`uuid-runtime`** or generate `AGENT_TOKEN` with `openssl rand -hex 32`.

```bash
JWT_SECRET=$(openssl rand -hex 32)
AGENT_TOKEN=$(uuidgen 2>/dev/null || openssl rand -hex 32)
sudo tee /etc/arcpanel/api.env > /dev/null <<EOF
DATABASE_URL=postgresql://arc:changeme@127.0.0.1:5450/arc_panel
JWT_SECRET=${JWT_SECRET}
AGENT_SOCKET=/var/run/arcpanel/agent.sock
AGENT_TOKEN=${AGENT_TOKEN}
LISTEN_ADDR=127.0.0.1:3062
EOF
sudo chmod 600 /etc/arcpanel/api.env
```

Ensure the **`AGENT_TOKEN`** value is shared between **agent** and **API** (both read it from the environment when you `source` this file).

### 5.5 Agent socket directory

The default **`AGENT_SOCKET`** is `/var/run/arcpanel/agent.sock`. Create the runtime directory:

```bash
sudo mkdir -p /var/run/arcpanel
sudo chmod 755 /var/run/arcpanel
```

---

## 6. Build

From the repository root (in WSL):

```bash
cargo build --release --manifest-path panel/agent/Cargo.toml
cargo build --release --manifest-path panel/backend/Cargo.toml
cargo build --release --manifest-path panel/cli/Cargo.toml

cd panel/frontend
npm ci
cd ../..
```

For faster iteration you may use `cargo build` without `--release`, but [CONTRIBUTING.md](../../CONTRIBUTING.md) and CI-style checks typically assume release builds for parity with production binaries.

**Lint (optional, matches repo guidance in [`AGENTS.md`](../../AGENTS.md)):**

```bash
cargo clippy --manifest-path panel/agent/Cargo.toml --release
cargo clippy --manifest-path panel/backend/Cargo.toml --release
cargo clippy --manifest-path panel/cli/Cargo.toml --release
cd panel/frontend && npx tsc --noEmit && cd ../..
```

---

## 7. Run the stack (three processes)

Load **`api.env`** into the shell so **`AGENT_TOKEN`**, **`JWT_SECRET`**, etc. are visible to both processes:

```bash
cd ~/src/arcpanel   # or your clone path
set -a
source /etc/arcpanel/api.env
set +a
```

### 7.1 Agent (`arc-agent`)

The agent performs **privileged host operations** (Docker, nginx, TLS, terminal, etc.). [CONTRIBUTING.md](../../CONTRIBUTING.md) runs it with **`sudo`** so it can bind the Unix socket and access the Docker daemon.

```bash
sudo -E env PATH="$PATH" AGENT_TOKEN="$AGENT_TOKEN" AGENT_SOCKET="$AGENT_SOCKET" \
  ./panel/agent/target/release/arc-agent
```

**Notes:**

- **`-E`** preserves the environment with respect to `sudo` policy; passing **`AGENT_TOKEN`** explicitly avoids losing it if your sudoers config strips env vars.
- Leave this running in a dedicated terminal tab, or background it (`&`) and follow logs.

### 7.2 API (`arc-api`)

In a **second** terminal (you can load `api.env` again or rely on the same user session):

```bash
set -a && source /etc/arcpanel/api.env && set +a
./panel/backend/target/release/arc-api
```

The API listens on **`LISTEN_ADDR`** (here **`127.0.0.1:3062`**). Quick check:

```bash
curl -sS http://127.0.0.1:3062/api/health
```

### 7.3 Frontend (Vite dev server)

```bash
cd panel/frontend
npm run dev
```

Vite typically serves on **`http://127.0.0.1:5173`** (see terminal output). The browser will call **`/api/...`**, which Vite forwards to **`127.0.0.1:3062`**.

### 7.4 Open the app from Windows

On recent WSL2 versions, **localhost** on Windows forwards to WSL. Open **Edge** or **Chrome** on Windows and go to the URL printed by Vite (e.g. `http://localhost:5173`). If connection fails, try the **WSL IP** (from `ip addr show eth0` in WSL) or enable **WSL mirror / localhost forwarding** per your Windows version’s networking mode.

---

## 8. CLI (`arc`) against the local agent

The operator CLI talks to the **agent Unix socket** with the **same** `AGENT_TOKEN`. After sourcing `api.env`:

```bash
./panel/cli/target/release/arc --help
# Example (adjust subcommand to what exists in your tree):
# ./panel/cli/target/release/arc diagnose
```

If you get **permission denied** on the socket, run with **`sudo -E`** consistent with how you started the agent, or adjust socket permissions only in dev (understand the security implications).

---

## 9. systemd on WSL (optional)

Recent WSL can run **systemd** (depending on `wsl.conf` and Windows/WSL version). Production hosts use systemd units from **`scripts/setup.sh`**, but **manual foreground processes** are enough for local development and match [CONTRIBUTING.md](../../CONTRIBUTING.md). Do not rely on systemd until you have verified `systemctl status` works in your distro.

---

## 10. Troubleshooting

| Symptom | Things to check |
|--------|-------------------|
| **`docker: command not found`** or cannot connect | Docker Desktop running? WSL integration enabled for your distro? |
| **`Permission denied` connecting to Docker socket** | User in **`docker`** group (`sudo usermod -aG docker "$USER"`) then **log out and back in**; or use `sudo docker` temporarily. |
| **Postgres connection refused** from `arc-api` | `docker ps` shows `arc-postgres` healthy; **`DATABASE_URL`** host port **5450** matches **`docker run -p`**. |
| **API starts but UI gets 502 / connection refused on `/api`** | **`LISTEN_ADDR`** must match Vite’s proxy (**3062** by default). **`curl http://127.0.0.1:3062/api/health`** from WSL. |
| **`JWT_SECRET` fatal** | Must be **≥ 32 characters**. Regenerate with `openssl rand -hex 32`. |
| **Agent and API disagree on token** | Both must use the **same** `AGENT_TOKEN` from `/etc/arcpanel/api.env`. |
| **Extremely slow `cargo` / `npm`** | Repo on **`/mnt/c`** → move to **`~/...`**. Increase **`.wslconfig`** memory. |
| **Port already in use** | Another process on **3062**, **5173**, or **5450** — `ss -tlnp \| grep -E '3062|5173|5450'` (package **iproute2**). |

---

## 11. Related documentation

| Resource | Purpose |
|----------|---------|
| [CONTRIBUTING.md](../../CONTRIBUTING.md) | Prerequisites, basic Postgres + build + run loop |
| [AGENTS.md](../../AGENTS.md) | Repo layout, commands, stack conventions |
| [features.md](./features.md) | Product capabilities vs. docs map |
| [backend.md](./backend.md) | API behavior, config, agent integration |
| [frontend.md](./frontend.md) | SPA architecture, `/api` proxy in dev |
| [agent.md](./agent.md) | Agent responsibilities and socket protocol |
| [cli.md](./cli.md) | Operator CLI and socket usage |
| [website/docs/getting-started.md](../../website/docs/getting-started.md) | End-user install (production-style), not required for `panel/` dev |

---

## 12. Security notes for local development

- **`api.env`** holds secrets (`JWT_SECRET`, `AGENT_TOKEN`). Keep **`chmod 600`** and do not commit it.
- Example passwords (**`changeme`**) are acceptable **only** on an isolated dev machine; use strong values if your WSL instance is shared or exposed.
- Running **`arc-agent`** as **root** is expected for full functionality; understand that this increases impact if malicious code runs in the dev environment.

This document reflects the repository layout and tooling as of the paths cited above; if `vite.config.ts` or defaults change, align **`LISTEN_ADDR`** (or the Vite proxy) accordingly.
