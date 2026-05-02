# Arcpanel public website — technical reference

**Scope:** `website/` only — marketing SPA (`client/`), small Express API (`server/`), and mdBook documentation sources (`docs/`).  
**Audience:** engineers deploying or extending the public site, installers hosted here, or documentation builds.

This tree is **not** the control-plane UI; that lives under `panel/frontend/` (see `docs/project-docs/frontend.md`).

---

## 1. Executive summary

| Aspect | Description |
|--------|-------------|
| **Role** | Public-facing marketing site (landing, legal pages), optional companion HTTP API for health/pricing-style endpoints, and **mdBook** sources for user-facing documentation (guides, API/CLI reference). Canonical domain referenced in HTML and `robots.txt` is **`https://arcpanel.top`**. |
| **Marketing UI** | Vite-built SPA: React 19, TypeScript, Vite 6, Tailwind 4, React Router 7. Animations via **Motion** (`motion`), icons via **lucide-react**. |
| **API** | Express 5 on **port 3061** by default (`PORT`); exposes `/api/health` and `/api/pricing`. Dependencies include **PostgreSQL** and **Stripe** clients in `package.json`, but the current `server/src/index.ts` implementation does not yet use the database or billing flows — compose still injects related env vars for future use. |
| **Docs book** | `website/docs/` is an **mdBook** project (`book.toml`, `SUMMARY.md`) whose built HTML is typically published separately from the Vite app (e.g. `docs.*` subdomain). |

---

## 2. Repository layout

| Path | Responsibility |
|------|----------------|
| `website/client/` | Marketing SPA: routes, pages, Tailwind styles, static `public/` assets (installer script, favicon, SEO files). |
| `website/server/` | Node/Express API: health and pricing JSON; Docker multi-stage build to `dist/index.js`. |
| `website/docs/` | mdBook markdown sources: getting started, configuration, guides, API/CLI reference, troubleshooting. |

---

## 3. Marketing client (`website/client/`)

### 3.1 Stack and scripts

| Package | Role |
|---------|------|
| `vite`, `@vitejs/plugin-react` | Dev server and production bundle. |
| `@tailwindcss/vite`, `tailwindcss` | Tailwind 4 pipeline (no separate PostCSS config). |
| `react-router-dom` | Client-side routes. |
| `motion` | Scroll/terminal animations on the landing page. |
| `lucide-react` | Icon set. |

Scripts (`package.json`): **`npm run dev`** (Vite), **`npm run build`** (`tsc && vite build`), **`npm run preview`**.

### 3.2 Entry and routing

Bootstrap and routes are defined in `main.tsx`:

```10:20:website/client/src/main.tsx
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Landing />} />
        <Route path="/privacy" element={<PrivacyPolicy />} />
        <Route path="/terms" element={<TermsOfService />} />
        <Route path="/security" element={<Security />} />
      </Routes>
    </BrowserRouter>
  </StrictMode>,
);
```

| Route | Page component |
|-------|------------------|
| `/` | `Landing.tsx` — hero, feature sections, animated installer preview, GitHub star count (fetches `api.github.com`), links to docs/install. |
| `/privacy` | `PrivacyPolicy.tsx` |
| `/terms` | `TermsOfService.tsx` |
| `/security` | `Security.tsx` |

### 3.3 Styling

- **Tailwind 4:** `@import "tailwindcss"` in `src/index.css`; global dark zinc palette, Inter / Space Grotesk / JetBrains Mono loaded from `index.html`.
- **Alias:** `@` → `src/` (`vite.config.ts` and `tsconfig.json` `paths`).

### 3.4 Development proxy

During `vite` dev, `/api` is proxied to the local marketing API:

```11:17:website/client/vite.config.ts
  server: {
    host: '0.0.0.0',
    port: 5173,
    proxy: {
      '/api': 'http://localhost:3061',
    },
  },
```

The current React pages do **not** call this API for rendering (the landing page uses GitHub’s public API for repo stats only). The proxy exists so future marketing features can use same-origin `/api` in development without CORS changes.

### 3.5 Static `public/` assets

| Asset | Purpose |
|-------|---------|
| `install.sh` | Copy of the quick installer; linked as `curl … \| bash` from marketing copy. Keeps branding and download URLs aligned with `scripts/` where applicable. |
| `favicon.svg`, `robots.txt`, `sitemap.xml` | SEO and crawlers; sitemap/robots reference `https://arcpanel.top`. |
| `og-image.png` | Referenced from Open Graph / Twitter meta tags in `index.html` (must exist at deploy root for social previews). |

### 3.6 Production container (nginx)

The client `Dockerfile` builds the Vite app and serves **`dist/`** with **nginx:alpine**, copying `nginx.conf` as the default server:

- SPA fallback: `try_files … /index.html`.
- Long cache for `/assets/`.
- gzip and baseline security headers (`X-Content-Type-Options`, `X-Frame-Options`, etc.).

There is **no** `/api` reverse-proxy in this nginx config; in Docker Compose the UI container listens on **80** inside the network and the API is a **separate** service on **3061**. Any future browser calls to `/api` on the same host as the static site would require an edge proxy (e.g. outer nginx) or extending `nginx.conf` to proxy `/api` to the `server` service.

---

## 4. Marketing API (`website/server/`)

### 4.1 Runtime

- **Express 5**, **helmet**, **cors**, **dotenv**, JSON body parser.
- Default listen: **`0.0.0.0:3061`** (`PORT` from environment, see `index.ts`).

### 4.2 Implemented routes

```15:27:website/server/src/index.ts
// Health check
app.get('/api/health', (_req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Pricing — Arcpanel is free and open source
app.get('/api/pricing', (_req, res) => {
  res.json({
    plan: 'free',
    price: 0,
    features: ['Unlimited servers', 'All features', 'Community support'],
  });
});
```

### 4.3 Dependencies vs. code

`package.json` lists **`pg`** and **`stripe`**, and `docker-compose.yml` passes **`DATABASE_URL`**, **`JWT_SECRET`**, and Stripe-related variables into the `server` service. The checked-in `src/` tree currently contains only `index.ts` and does not register database or webhook handlers. Treat these as **deployment scaffolding** until corresponding routes are implemented.

### 4.4 Build and Docker

- **Build:** `npm run build` runs `tsc`; output in `dist/`. **Start:** `node dist/index.js`.
- **Dockerfile:** multi-stage — compile TypeScript in a build stage, production stage runs as **`node`** user, exposes **3061**, health check hits **`/api/health`**.

---

## 5. Documentation book (`website/docs/`)

### 5.1 Tooling

- **mdBook** configuration: `book.toml` sets title *Arcpanel Documentation*, language `en`, source dir `.`, HTML output with navy theme, and `git-repository-url` pointing at the GitHub repo.

### 5.2 Navigation

`SUMMARY.md` defines the chapter list: Getting Started, Configuration, grouped **Guides** (WordPress, Git Deploy, Email, Multi-Server, Backups, Monitoring, Prometheus, ACME, Status Page, Incidents, Secrets, Webhooks, Notifications, Security Hardening, Image Scanning, SBOM, Themes, Sessions), plus **API Reference**, **CLI Reference**, and **Troubleshooting**.

### 5.3 Relationship to `website/client`

The mdBook sources are **markdown files**, not part of the Vite bundle. In production you typically:

1. Run `mdbook build` (from `website/docs/` or CI) to produce static HTML.
2. Publish that output on a docs host or path distinct from the marketing SPA.

Cross-links from the marketing site to `/docs/...` paths assume your hosting layout matches those URLs.

---

## 6. Docker Compose integration

Root `docker-compose.yml` defines three user-facing pieces relevant to `website/`:

| Service | Build context | Notes |
|---------|---------------|--------|
| `db` | `postgres:16-alpine` | Intended for future server-side features using `DATABASE_URL`. |
| `server` | `./website/server` | Listens on **127.0.0.1:3061:3061**; depends on healthy `db`. |
| `client` | `./website/client` | Nginx static site on **127.0.0.1:3060:80**; `depends_on` the `server` service health check. |

This layout binds services to **localhost** on the host; an external reverse TLS terminator typically fronts **3060** (and optionally **3061** if the API is exposed).

---

## 7. CI and quality gates

`.github/workflows/ci.yml` includes an **Audit Marketing Site** step:

```191:192:.github/workflows/ci.yml
      - name: Audit Marketing Site
        run: cd website/client && npm ci && npm audit --audit-level=high || true
```

Only **`website/client`** is audited in CI today; the server package has no equivalent step in that excerpt.

---

## 8. Operational checks

| Check | Command / URL |
|-------|----------------|
| Marketing dev server | `cd website/client && npm run dev` → Vite on port **5173** (with `/api` → **3061** if API running). |
| API dev server | `cd website/server && npm run dev` (tsx watch) or `npm start` after build. |
| Health (deployed API) | `GET /api/health` on the API port (**3061** in compose). |
| Static site (container) | `GET /` on client mapped port (**3060** in compose). |
| Docs build | Install mdBook, then `mdbook build` from `website/docs/`. |

---

## 9. Design decisions (summary)

| Decision | Rationale |
|----------|-----------|
| **Separate `website/` tree** | Keeps marketing, lightweight API, and mdBook sources versioned together without coupling them to the control-plane SPA in `panel/frontend/`. |
| **Vite + React for marketing** | Aligns with the main frontend toolchain (TypeScript, Tailwind 4) while remaining a small, route-limited SPA. |
| **Minimal Express API** | Provides a stable health endpoint for orchestration and a JSON pricing stub; allows incremental addition of server-driven marketing features. |
| **Installer in `public/`** | Lets users and docs link to a fixed HTTPS path for `install.sh` independent of repository raw URLs. |

---

## 10. Reading paths

| Reader goal | Start here |
|-------------|------------|
| Change landing copy or layout | `website/client/src/pages/Landing.tsx`, `index.css`. |
| Add a legal or static page | New component under `pages/`, route in `main.tsx`. |
| Extend marketing API | `website/server/src/index.ts`; align env vars with `docker-compose.yml`. |
| Edit user documentation | `website/docs/*.md` and `SUMMARY.md`; run mdBook locally to preview. |
| Deploy stack | Root `docker-compose.yml`, client `Dockerfile` + `nginx.conf`, server `Dockerfile`. |

---

## 11. Related references

- Control-plane UI: `docs/project-docs/frontend.md` (`panel/frontend/`).
- Repository map and stack overview: `AGENTS.md`.
- Installer script parity and branding audits may reference `website/client/public/install.sh` alongside `scripts/` (see `scripts/docs-audit.sh`).
