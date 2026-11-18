# Project Instructions

## Project at a glance

**Sidecar** is a lightweight, self-hosted Hacker News reader. It presents front-page and newest stories in a feed, and opens an article reader alongside the Hacker News discussion. The UI is intentionally dependency-free: a single HTML file with inline CSS and browser JavaScript, served by a small Node.js HTTP server.

## Repository map

- `index.html` — the complete frontend: layout, styling, theme, feed controls, story list, article extraction/display, website iframe, and recursive comments.
- `server.js` — Node built-in HTTP server, Hacker News/Algolia API proxy, and article fetcher.
- `Containerfile` — Node 24 Alpine image definition; copies only `server.js` and `index.html`.
- `compose.yaml` — app plus Caddy reverse proxy, publishing HTTP/HTTPS ports 80 and 443.
- `Caddyfile` — proxies requests to the `app` service on port 4173.
- `pod.yaml` — Podman Kubernetes pod manifest; publishes port 4173 and mounts the host CA bundle.
- `README.md` — current Podman/WSL setup and run instructions.
- `DEPLOY.md` — production deployment to the VPS (Cloudflare, GitHub Actions, shared edge proxy).
- `.github/workflows/deploy.yml` — builds the image, pushes it to GHCR and deploys over SSH on pushes to `main`.
- `deploy/` — production Compose file, Caddy site block for `hn-reader.sanvir.net`, and the script the workflow runs on the VPS.
- `infra/` — one-time VPS bootstrap script and the shared `edge` Caddy proxy used by all apps on the VPS (Cloudflare Origin certificate, `/opt/edge/sites/*.caddy`).

There is no package manifest, build step, frontend framework, or test suite. The server uses Node.js built-in modules and the global `fetch` API; do not assume dependencies need to be installed.

## Runtime and data flow

- Default server address is `127.0.0.1:4173`; `PORT` and `HOST` environment variables override it. The container sets `HOST=0.0.0.0` so published container ports work.
- The browser talks only to same-origin `/api/...` endpoints. `server.js` fetches data from the Hacker News Firebase API (`https://hacker-news.firebaseio.com/v0`) and Algolia HN Search (`https://hn.algolia.com/api/v1`).
- `GET /api/feed?view=top&page=N` fetches 15 stories per page from the Firebase top-stories list. `view=new` uses Algolia's `search_by_date` results (40 per page). Responses have `{ hits, hasMore }`.
- `GET /api/item/:id` fetches an Algolia item, including its comment tree.
- `GET /api/article/:id` fetches the story URL and returns `{ html, url }` for the reader. Text posts return HTTP 422 with an explanation.
- The frontend extracts readable text from fetched HTML and creates its own DOM nodes; it does not display fetched article HTML directly. Comments are separately sanitized into a small allowed set of elements. The optional Website view loads the original URL in a sandboxed iframe.
- Browser preferences are stored in `localStorage`: `sidecar-theme`, `sidecar-auto-refresh`, and `sidecar-refresh-interval`.

## Important implementation constraints

- Keep the app dependency-free unless a change explicitly justifies introducing and documenting a package manager/build process.
- Preserve the existing same-origin API design; do not make browser code call third-party APIs directly without a reason.
- Treat article URLs and upstream responses as untrusted. `server.js` validates article URLs, rejects non-public IP destinations, limits redirect count, applies timeouts, requires HTML, and caps response size. Preserve and carefully review these protections whenever changing article fetching or redirects. Do not remove DNS/IP checks or allow arbitrary local/private network access.
- Keep generated article content as text/constructed safe elements, and maintain comment sanitization. Avoid inserting upstream HTML with `innerHTML`.
- Keep external links opened in a new tab protected with `rel="noopener noreferrer"`; retain the iframe sandbox and no-referrer policy.
- The inline app is organized as one file by design. Keep CSS, markup, and browser-side code in `index.html` unless there is a concrete benefit to splitting them (which would also require updating the container copy rules).
- The Podman manifest expects the image tag `localhost/hn-reader:latest` and mounts `/home/user/.config/hn-reader/ca-bundle.pem` read-only as Node's extra CA bundle. It should combine the WSL distribution bundle with any required corporate TLS-inspection root CA. Keep this machine-specific bundle outside the repository; adjust `hostPath.path` if its location differs, and update the README when deployment assumptions change.

## Running and checking changes

### Local Node run

```sh
node --version
node server.js
```

Then open <http://127.0.0.1:4173>. `node --check server.js` checks server JavaScript syntax. There are currently no automated tests; for functional changes, exercise the relevant UI and API routes manually and check browser/server errors.

### Podman workflow (documented path)

From WSL with Podman installed:

```sh
podman build -t localhost/hn-reader:latest -f Containerfile .
podman kube play --publish 127.0.0.1:4173:4173 pod.yaml
```

To rebuild/recreate after edits:

```sh
podman build -t localhost/hn-reader:latest -f Containerfile .
podman kube play --replace --publish 127.0.0.1:4173:4173 pod.yaml
```

Useful commands: `podman pod ps`, `podman logs hn-reader-hn-reader`, and `podman kube down pod.yaml`.

### Compose/Caddy option

`compose.yaml` also defines a Caddy-backed deployment. `docker compose up --build` (or compatible Compose) builds the app and starts the proxy; Caddy exposes ports 80 and 443. This is a standalone local option; production uses `deploy/` and `infra/` instead (see `DEPLOY.md`).

## Working conventions

- Make focused changes and preserve responsive behavior, accessibility labels/keyboard controls, dark/light themes, and the feed/detail interaction.
- Update `README.md` when setup, ports, deployment, environment variables, or operational commands change. Update this file if architecture or important invariants change.
- Do not claim tests were run unless they were. Report manual checks and limitations clearly.
