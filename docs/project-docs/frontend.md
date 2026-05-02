# Arcpanel frontend — technical reference

**Scope:** `panel/frontend/` only — Vite 6, React 19, TypeScript, Tailwind 4, React Router 7.  
**Audience:** engineers extending the control-plane UI or debugging build/runtime behavior.

---

## 1. Executive summary

| Aspect | Description |
|--------|-------------|
| **Role** | Single-page application (SPA) for the Arcpanel control plane: sites, databases, monitoring, settings, terminal, logs, and related admin flows. |
| **Runtime** | Static assets produced by `vite build` (JS/CSS chunks, `index.html`, `public/` copies). Served by **nginx** on the host alongside the Rust API; the browser talks to **`/api`** on the **same origin** as the UI so cookies and relative URLs work without CORS for the primary API. |
| **Stack alignment** | Matches repository guidance (`AGENTS.md`): React 19 + TypeScript + Vite 6 + Tailwind 4 + React Router 7; terminal UX via **`@xterm/xterm`** and addons. |

The SPA does **not** embed the API URL from environment variables in production: HTTP calls use the fixed prefix **`/api`**, which nginx proxies to the backend (default API listen port is documented at **3080** in `AGENTS.md`; local Vite dev server proxies `/api` to **`http://127.0.0.1:3062`** in `vite.config.ts`).

---

## 2. Architecture overview

### 2.1 `src/` layout

| Path | Responsibility |
|------|----------------|
| `src/main.tsx` | App bootstrap: theme/layout init, providers, `BrowserRouter`, route table, lazy loading, chunk error boundary. |
| `src/index.css` | Tailwind 4 entry (`@import "tailwindcss"`), `@theme` tokens, multi-theme CSS (`data-theme`, `data-layout`), shared utilities (scrollbars, forms, xterm containment). |
| `src/api.ts` | Central **`fetch`** wrapper: `/api` base, JSON, cookies, `X-Server-Id`, `X-Requested-With`, 401 redirect to `/login`. |
| `src/constants.ts` | Small shared UI constants (e.g. status colors, runtime labels). |
| `src/context/` | `AuthContext`, `ServerContext`, `BrandingContext` — global session, multi-server selection, white-label branding. |
| `src/components/` | Shell layouts (`LayoutShell`, `CommandLayout`, lazy `GlassLayout` / `AtlasLayout`), command palette, layout switcher, provision log. |
| `src/pages/` | Route-level screens (many lazy-loaded). |
| `src/data/` | `navItems.ts` (sidebar structure), `icons.ts` (icon map for nav). |
| `src/hooks/` | e.g. `useLayoutState` for persisted theme/layout UI state. |
| `src/utils/` | `logger` (dev-only `error`/`warn`), `format` helpers. |

### 2.2 Routing (`react-router-dom`)

- **Router:** `BrowserRouter` in `src/main.tsx`.
- **Composition:** `Routes` / `Route`; authenticated chrome uses `<Route element={<LayoutShell />}>` with nested routes rendering **`Outlet`** inside layout components (`CommandLayout`, etc.).
- **Redirects:** Several legacy paths `Navigate` to canonical routes (e.g. `/extensions` → `/integrations`, `/activity` → `/logs`).
- **Public / unauthenticated:** `/login`, `/setup`, `/register`, `/forgot-password`, `/reset-password`, `/verify-email`, and **`/status`** (public status page) sit outside `LayoutShell`.
- **Fallback:** `path="*"` → `Navigate` to `/`.

### 2.3 State and data fetching

| Pattern | Usage |
|---------|--------|
| **React Context** | Auth (`user`, login, 2FA, logout), servers (`servers`, `activeServerId`, `refreshServers`), branding (`panelName`, `logoUrl`, OAuth list, etc.). |
| **localStorage** | Theme (`dp-theme`), layout (`dp-layout`), header/flat-nav flags, active server id (`dp-active-server`) — read/written from contexts, layouts, and `api.ts`. |
| **Server data** | Most pages call `api.get` / `api.post` / `api.put` / `api.delete` with path-local TypeScript generics or inline interfaces; no OpenAPI/codegen pipeline in this package. |
| **Live updates** | **WebSocket** on Dashboard (`/api/ws/metrics`), Logs streaming (agent URL + token), Terminal (agent WebSocket after token from API). Polling supplements WS when disconnected. |

---

## 3. Design decisions

### 3.1 Vite

| Decision | Detail |
|----------|--------|
| **Plugins** | `@vitejs/plugin-react`, `@tailwindcss/vite` (`vite.config.ts`). |
| **Dev proxy** | `server.proxy["/api"]` → `http://127.0.0.1:3062` so the SPA can call `/api/...` during development without configuring CORS. |
| **Alias** | `@` → `/src` (also mirrored in `tsconfig.json` `paths`). |
| **Build script** | `npm run build` runs **`tsc -b` then `vite build`** — typecheck gates production bundles. |

### 3.2 Code splitting and lazy routes

- **`React.lazy`** wraps most feature pages; a **`lazyRetry`** helper reloads the page once on chunk load failure (stale deploy), then retries import (`src/main.tsx`).
- **`ChunkErrorBoundary`** offers a manual reload UI if lazy loading still fails.
- **`Suspense`** wraps routed content with a full-screen spinner fallback.
- **Layout-level lazy:** `GlassLayout` and `AtlasLayout` are lazy-loaded inside `LayoutShell` to keep initial bundle smaller when those layouts are not selected.

### 3.3 Tailwind 4

- **Pipeline:** `@tailwindcss/vite` plugin (no separate PostCSS tailwind config file in-tree).
- **Theme:** Design tokens live in `src/index.css` under `@theme { ... }` (colors `rust-*`, `dark-*`, `accent-*`, radii, fonts). Semantic names like `rust-*` are used as the primary “accent” across themes for historical consistency.
- **Themes:** Multiple `[data-theme="..."]` blocks override CSS variables (terminal, midnight, arctic, ember, clean, clean-dark). `public/theme-init.js` runs before paint to set `data-theme` / `data-color-scheme` from `localStorage` and migrate legacy names.
- **Layouts:** `data-layout` on `<html>` (e.g. command, glass, atlas) drives structural CSS and body chrome.

---

## 4. Core components (file references)

### 4.1 Entry and providers

| File | Role |
|------|------|
| `panel/frontend/src/main.tsx` | `createRoot`, providers order: `BrandingProvider` → `AuthProvider` → `ServerProvider` → `BrowserRouter`, routes. |
| `panel/frontend/index.html` | Root mount, favicon, font preconnect, **`/theme-init.js`** for FOUC-free theme. |

### 4.2 Layouts and chrome

| File | Role |
|------|------|
| `panel/frontend/src/components/LayoutShell.tsx` | Picks **command** (default), **glass**, or **atlas** layout from `localStorage`; lazy-loads glass/atlas. |
| `panel/frontend/src/components/CommandLayout.tsx` | Primary shell: sidebar, nav from `navGroups`, server selector, command palette, auth-aware nav filtering. |
| `panel/frontend/src/components/GlassLayout.tsx` | Alternate shell (lazy). |
| `panel/frontend/src/components/AtlasLayout.tsx` | Alternate shell (lazy). |
| `panel/frontend/src/components/CommandPalette.tsx` | Quick navigation / actions. |
| `panel/frontend/src/components/LayoutSwitcher.tsx` | UI to change layout/theme (dispatches custom events / updates storage). |
| `panel/frontend/src/components/ProvisionLog.tsx` | Shared provisioning log UI. |
| `panel/frontend/src/components/NexusLayout.tsx` | Legacy layout module; **not** referenced by `LayoutShell` at time of writing — kept for reference or future use. |

### 4.3 Major routes (eager-loaded)

| Route | Component file |
|-------|----------------|
| `/login` | `src/pages/Login.tsx` |
| `/setup` | `src/pages/Setup.tsx` |
| `/` | `src/pages/Dashboard.tsx` |

### 4.4 Major routes (lazy-loaded, non-exhaustive)

Representative lazy pages (see `main.tsx` for the full list): `Register`, `ForgotPassword`, `ResetPassword`, `VerifyEmail`, `Sites`, `SiteDetail`, `Databases`, `Files`, `Terminal`, `Backups`, `Crons`, `Deploy`, `GitDeploys`, `Cdn`, `Dns`, `WordPress`, `WordPressToolkit`, `Logs`, `Apps`, `Extensions` (redirect), `Security`, `Settings`, `Mail`, `Servers`, `ResellerDashboard`, `Migration`, `ResellerUsers`, `BackupOrchestrator`, `PublicStatusPage`, `SecretsManager`, `Notifications`, `Integrations`, `Users`, `ContainerPolicies`, `System`, `Telemetry`, `Monitoring`.

### 4.5 API client layer

| File | Role |
|------|------|
| `panel/frontend/src/api.ts` | `ApiError`, `request()`, exported `api` object (`get`/`post`/`put`/`delete`). |

---

## 5. Data models and types

### 5.1 Representation

- **Hand-written TypeScript** at point of use: generic calls like `api.get<Server[]>("/servers")`, or inline `{ ... }` types in components and contexts.
- **No** checked-in OpenAPI client, **no** `zod`/`io-ts` runtime validation layer in the frontend package — correctness relies on backend contract discipline and manual updates when APIs change.

### 5.2 Shared context models

| Context | Notable types / fields |
|---------|-------------------------|
| `AuthContext` | `User`: `id`, `email`, `role`; 2FA: `temp_token` flow. |
| `ServerContext` | `Server`: `id`, `name`, `ip_address`, `agent_url`, `status`, `is_local`, resource metrics, `cert_fingerprint`, timestamps. |
| `BrandingContext` | `panelName`, `logoUrl`, `accentColor`, `hideBranding`, `oauthProviders`. |

### 5.3 WebSocket and terminal (`@xterm/xterm`)

| Area | Packages | Behavior |
|------|-----------|----------|
| **Terminal page** | `@xterm/xterm`, `@xterm/addon-fit`, `@xterm/addon-search` | Fetches short-lived token from **`GET /api/terminal/token`** (optional `?site_id=`), opens **`WebSocket`** to **`/agent/terminal/ws`** on the **page host** with query params (`token`, `domain`, `cols`, `rows`). Sends JSON messages for input and resize. Themes (mocha, dracula, light) defined in-component. |
| **Logs streaming** | — | Token from **`GET /api/logs/stream/token`**, then WS to **`/agent/logs/stream`** with token/type/domain. |
| **Dashboard metrics** | — | WS to **`/api/ws/metrics`**, JSON messages with `type === "metrics"` and nested payloads for system/processes/network. |

---

## 6. Integration points

### 6.1 HTTP API

| Item | Value / behavior |
|------|------------------|
| **Base path** | `const BASE = "/api"` in `src/api.ts`. |
| **Cookies** | `credentials: "same-origin"` on `fetch` — session cookies set by the backend on the same site are sent automatically. |
| **Headers** | `X-Requested-With: Arcpanel`; `Content-Type: application/json` when body present; **`X-Server-Id`** from `localStorage.getItem("dp-active-server")` when set (multi-server). |
| **401** | Redirects browser to `/login` unless path is `/login` or `/setup`; throws `ApiError`. |
| **Branding bootstrap** | `GET /api/branding` via raw `fetch` in `BrandingContext`. |
| **Session probe** | `GET /api/auth/me` on app load in `AuthContext`. |

### 6.2 WebSocket URLs (as wired)

All use **`window.location.host`** and **`ws:` / `wss:`** from page protocol:

| Feature | URL pattern |
|---------|-------------|
| Metrics | `` `${protocol}//${host}/api/ws/metrics` `` |
| Terminal | `` `${proto}//${host}/agent/terminal/ws?token=...&domain=...&cols=&rows=` `` |
| Log stream | `` `${proto}//${host}/agent/logs/stream?token=...&type=...` `` (+ optional `domain`) |

Nginx (or equivalent) must upgrade WebSocket for these paths and forward to the API/agent as in server deployment docs.

---

## 7. Build and deployment

| Command | Effect |
|---------|--------|
| `npm ci` | Install locked dependencies (CI/agents should prefer this). |
| `npm run dev` | Vite dev server with `/api` proxy. |
| `npm run build` | `tsc -b` + `vite build` → default **`dist/`** output at repo standard. |
| `npm run preview` | Serves production build locally. |

**Production API URL:** Not injected via `import.meta.env` in the current codebase; the UI assumes **`/api`** on the same host as the static files. Changing API origin requires reverse-proxy configuration (or a future env-based base URL change).

**Versioning:** `package.json` `version` aligns with other shipped Arcpanel artifacts when releases are cut (`AGENTS.md`).

---

## 8. Security and UX

| Topic | Implementation notes |
|-------|----------------------|
| **Authentication** | Cookie-based session; login and 2FA via `api.post` to `/auth/login` and `/auth/2fa/verify`; logout `POST /auth/logout`. |
| **WebSocket auth** | Terminal and log streams use **short-lived tokens** in query strings because browser WebSockets cannot set arbitrary headers; comments in `Logs.tsx` document this tradeoff. |
| **Multi-tenancy / multi-server** | `X-Server-Id` scopes API calls; switching server in UI forces full navigation to `/` to reset view state (`CommandLayout` server selector). |
| **Secrets in UI** | Settings and secrets pages may display sensitive configuration; no additional client-side encryption layer — rely on HTTPS, session hardening, and backend authorization. |
| **Logging** | `src/utils/logger.ts` suppresses `error`/`warn` console noise in production builds; avoid logging tokens or passwords. |
| **Chunk deploy UX** | Lazy retry + error boundary reduce “blank page” after deployments when hashed assets rotate. |

---

## 9. Appendices

### 9.1 Glossary

| Term | Meaning |
|------|---------|
| **SPA** | Single-page application; client-side routing without full page loads for internal navigation. |
| **Same-origin API** | UI and `/api` share scheme/host/port so cookies and relative `/api` paths work. |
| **`dp-*` keys** | Historical `localStorage` prefix for theme, layout, and server selection (Arcpanel rebrand retained keys for migration). |
| **`rust-*` (Tailwind)** | Primary semantic color scale in class names — not the Rust language; maps to theme-dependent CSS variables. |

### 9.2 `package.json` dependencies (rationale summary)

| Dependency | Role |
|--------------|------|
| `react`, `react-dom` | UI runtime (React 19). |
| `react-router-dom` | Declarative routing, `BrowserRouter`, `NavLink`, `useSearchParams`, etc. |
| `vite`, `@vitejs/plugin-react` | Bundler and React refresh / JSX. |
| `typescript`, `@types/react*`, `tailwindcss`, `@tailwindcss/vite` | Types and Tailwind 4 build integration. |
| `@xterm/xterm` | Terminal emulator widget. |
| `@xterm/addon-fit` | Resize terminal to container. |
| `@xterm/addon-search` | In-terminal search (Ctrl+F) on Terminal page. |

### 9.3 Reading order for a new frontend developer

1. `AGENTS.md` (repo root) — stack and commands.  
2. `panel/frontend/vite.config.ts` — dev proxy and aliases.  
3. `panel/frontend/src/main.tsx` — providers, routes, lazy loading.  
4. `panel/frontend/src/api.ts` — all HTTP behavior and headers.  
5. `panel/frontend/src/context/AuthContext.tsx` + `ServerContext.tsx` — session and scope.  
6. `panel/frontend/src/components/CommandLayout.tsx` + `data/navItems.ts` — navigation IA.  
7. `panel/frontend/src/index.css` — theming model.  
8. One complex page (e.g. `Dashboard.tsx`, `Terminal.tsx`, `Logs.tsx`) for data + WebSocket patterns.

---

*Document generated to reflect the `panel/frontend/` tree as of the authoring date; verify against `main.tsx` and `api.ts` when making structural changes.*
