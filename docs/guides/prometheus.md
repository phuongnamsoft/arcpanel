# Prometheus Metrics Endpoint

Arcpanel can expose its operational metrics in [Prometheus exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/) so external Prometheus, VictoriaMetrics, Grafana Agent, or any OpenMetrics-compatible scraper can consume them.

The endpoint is **disabled by default** and gated by a scrape token. When disabled, the endpoint returns `404 Not Found` so a panel with metrics off does not advertise a scrape surface at all.

## Enable scraping

1. Go to **Settings** → scroll to **Prometheus Metrics**
2. Click **Enable**. A scrape token is generated automatically on first enable.
3. Copy the token from the banner (it won't be shown again).
4. Copy the generated `scrape_configs` block and paste it into your `prometheus.yml`.

### Rotating the token

Click **Rotate** to generate a new token. The old token becomes invalid immediately, so update your Prometheus config at the same time. Use this if you suspect the token has leaked or when rotating credentials on a schedule.

### Disabling

Click **Disable**. The existing token remains stored (re-enabling reuses it); only the endpoint stops responding with 200. Scrapers will see 404.

## Scrape config

```yaml
scrape_configs:
  - job_name: 'arcpanel'
    metrics_path: /api/metrics
    scheme: https
    bearer_token: arcms_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    static_configs:
      - targets: ['panel.example.com']
```

The token may also be sent as a query parameter (`?token=...`) for tools that can't inject a bearer header, but the header is strongly preferred because URLs are logged by intermediaries.

## Exposed metrics

All metric names are part of Arcpanel's public API and will not be renamed between minor versions. Units follow Prometheus / Node Exporter conventions (`_percent`, `_mb`, `_celsius`, `_watts`).

### System resources (per server)

| Metric | Type | Labels |
|--------|------|--------|
| `arc_cpu_percent` | gauge | `server_id`, `server` |
| `arc_memory_percent` | gauge | `server_id`, `server` |
| `arc_disk_percent` | gauge | `server_id`, `server` |

Backed by the 30-second metrics collector; each scrape returns the most recent row per server.

### GPU (per server, per GPU)

Emitted only when the server has NVIDIA GPUs and the agent has reported GPU data.

| Metric | Type | Labels |
|--------|------|--------|
| `arc_gpu_utilization_percent` | gauge | `server_id`, `server`, `gpu_index` |
| `arc_gpu_vram_used_mb` | gauge | `server_id`, `server`, `gpu_index` |
| `arc_gpu_vram_total_mb` | gauge | `server_id`, `server`, `gpu_index` |
| `arc_gpu_temperature_celsius` | gauge | `server_id`, `server`, `gpu_index` |
| `arc_gpu_power_draw_watts` | gauge | `server_id`, `server`, `gpu_index` |

Temperature and power draw are omitted if the GPU doesn't report them.

### Sites

| Metric | Type | Labels |
|--------|------|--------|
| `arc_site_count` | gauge | `status` |

`status` is typically `active` or `disabled`.

### Alerts

| Metric | Type | Labels |
|--------|------|--------|
| `arc_alerts_firing` | gauge | `severity` |

Emits `severity="none"` with value `0` when no alerts are firing, so scrapers can reliably write presence-based alert rules like `max(arc_alerts_firing) by (severity) > 0`.

### Build info

| Metric | Type | Labels |
|--------|------|--------|
| `arc_info` | gauge (always 1) | `version` |

Use this to pivot a Grafana dashboard on Arcpanel version for upgrade cutovers.

## Pre-built Grafana dashboard

A drop-in Grafana dashboard ships in the repo at [`dashboards/arcpanel-grafana.json`](https://github.com/phuongnamsoft/arcpanel/blob/main/dashboards/arcpanel-grafana.json). It covers:

- Header stats — Arcpanel version, servers reporting, sites, alerts firing by severity, GPUs reporting
- CPU / memory / disk timeseries per server (with thresholds at sensible levels)
- Top servers by CPU and memory (bar gauges)
- Sites by status (donut)
- Collapsible **GPUs** row with utilization, VRAM percentage, temperature, and power draw
- Alerts firing by severity (stacked bars)

A `Server` template variable lets you focus on a single host or any subset.

### Import

1. Grafana → **Dashboards** → **New** → **Import**
2. Upload `arcpanel-grafana.json` (or paste its contents)
3. Pick the Prometheus datasource that's scraping Arcpanel and click **Import**

The dashboard's UID is `arc-fleet` so direct links from your runbooks stay stable across re-imports.

## Example Grafana queries

If you want to build your own panels alongside the pre-built dashboard:

```promql
# CPU across the fleet
avg by (server) (arc_cpu_percent)

# VRAM pressure: % used per GPU
100 * arc_gpu_vram_used_mb / arc_gpu_vram_total_mb

# Firing alert budget
sum(arc_alerts_firing{severity!="none"})
```

## Why the data is 30s stale

Every scrape reads the latest row from the metrics tables written by the 30-second metrics collector. Arcpanel does **not** re-poll agents per scrape — that would make metrics expensive to collect and skew the existing collection cadence used for the dashboard charts. Prometheus default scrape intervals (15-60s) are well within this staleness window.

## Troubleshooting

**Scraper sees 404** — the endpoint is disabled. Enable it from Settings.

**Scraper sees 401** — the bearer token doesn't match the stored hash. Confirm you copied the whole token (69 characters including `arcms_`) and that Prometheus is sending it on `/api/metrics`, not some other path.

**No GPU metrics** — GPUs only appear after the collector has stored at least one row in `gpu_metrics_history`. On a fresh install, this takes up to 30 seconds after the agent first reports GPU info.

**Sites metric shows 0** — only ingested during a successful scrape; check that the panel's database has rows in the `sites` table.
