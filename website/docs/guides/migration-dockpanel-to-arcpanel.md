# Migrating from DockPanel paths to Arcpanel

This guide is for operators upgrading an existing server from **DockPanel** binaries and directory layout to **Arcpanel** (`arc`, `arc-api`, `arc-agent`) and the **`arcpanel`** on-disk paths.

## Before you start

1. **Back up PostgreSQL** (adjust container name if yours still uses the legacy name):

   ```bash
   docker exec arc-postgres pg_dump -U arc -d arc_panel | gzip > /root/arcpanel-pre-migrate-$(date +%Y%m%d).sql.gz
   ```

   If the database user or database name is still the old defaults, use the credentials from your current `DATABASE_URL` in `/etc/dockpanel/api.env` or `/etc/arcpanel/api.env`.

2. **Back up file data**: tarball `/var/backups/dockpanel` (or `/var/backups/arcpanel` if you already moved backups) and any custom nginx/site data you rely on.

## Stop services

```bash
systemctl stop arc-agent arc-api
```

If you are mid-release and systemd units are still named `dockpanel-agent` / `dockpanel-api`, stop those instead:

```bash
systemctl stop dockpanel-agent dockpanel-api
```

## Move configuration and state directories

On a typical install, rename (not copy) the trees so permissions and contents stay intact:

```bash
mv /etc/dockpanel /etc/arcpanel
mv /var/lib/dockpanel /var/lib/arcpanel
mv /var/run/dockpanel /var/run/arcpanel
mv /var/backups/dockpanel /var/backups/arcpanel
mv /opt/dockpanel /opt/arcpanel
```

If a destination already exists (partial overlap), **stop** and merge manually: compare with `diff -qr` or move subdirectories only after inspection.

## Environment and API configuration

Edit `/etc/arcpanel/api.env` (or merge from your old `api.env`):

- Set **`DATABASE_URL`** to use user **`arc`**, database **`arc_panel`**, and the same password you configured for PostgreSQL (or migrate credentials in Postgres with `ALTER USER` / `CREATE DATABASE` + `pg_dump`/`pg_restore` if you are changing names in place).
- Set **`AGENT_SOCKET=/var/run/arcpanel/agent.sock`**.
- Rewrite any absolute paths that still mention `/etc/dockpanel`, `/var/lib/dockpanel`, etc.

## Nginx

- Rename panel snippets: `dockpanel-panel.conf` → **`arcpanel-panel.conf`** (and update `include` paths in your main nginx config).
- Update `root`, `alias`, TLS paths, and ACME webroot references from old paths to `/etc/arcpanel`, `/var/lib/arcpanel`, `/var/www`, as applicable.

## Docker and PostgreSQL

- **Container / volume names**: Prefer recreating the DB container with the new names (`arc-postgres`, volume `arc-pgdata`) and restoring from your `pg_dump` backup, or rename volumes/containers only if you know your orchestration supports it.
- **Managed workloads**: Containers and images using labels **`dockpanel.managed`** / **`dockpanel-git-*`** / **`dockpanel-snapshot:`** must be recreated or relabeled to **`arc.managed`**, **`arc-git-*`**, and **`arc-snapshot:`** respectively. Expect **downtime** for app containers during this transition.

## Prometheus and Grafana

- Replace metric selectors **`dockpanel_*`** with **`arc_*`** in dashboards and alerts.
- Regenerate the panel scrape token after upgrade (prefix is now **`arcms_`**, length **70**). Update Prometheus `bearer_token` accordingly.

## Start and verify

```bash
systemctl daemon-reload
systemctl start arc-agent arc-api
arc status
```

## Legacy domain redirects

HTTP redirects from **`dockpanel.dev`** / **`docs.dockpanel.dev`** to **`https://arcpanel.top`** and **`https://docs.arcpanel.top`** are **DNS / edge infrastructure**, not something this repository configures. Set an end date for legacy redirects (for example 12–24 months) with your ops team.
