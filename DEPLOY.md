# Deploying to the VPS

Pushing to `main` builds a container image in GitHub Actions, pushes it to
GitHub Container Registry, and deploys it over SSH to the VPS, where it is
served at <https://hn-reader.sanvir.net>.

```
Browser ──HTTPS──▶ Cloudflare ──HTTPS (origin cert)──▶ VPS :443
                                                        edge-caddy  (/opt/edge)
                                                          │  docker network "edge"
                                         ┌────────────────┼────────────────┐
                                    hn-reader:4173   placeholder:…     next app…
                                   (/opt/apps/hn-reader)
```

- **`/opt/edge`**: one shared Caddy container owns ports 80/443 for every app.
  It reads one small file per app from `/opt/edge/sites/*.caddy`.
- **`/opt/apps/<app>`**: each app is its own Compose project on the shared
  `edge` Docker network. Nothing but Caddy publishes ports.
- **TLS**: a single Cloudflare Origin certificate for `*.sanvir.net` covers
  every subdomain, so new apps need no certificate work.
- **DNS**: a proxied wildcard `*` record means new subdomains need no DNS
  change either.

Repo files: `infra/` holds the one-time VPS setup and the shared edge proxy,
`deploy/` holds this app's Compose file, Caddy site and deploy script, and
`.github/workflows/deploy.yml` is the pipeline.

## One-time setup

### 1. Cloudflare

In the Cloudflare dashboard for **sanvir.net**:

1. **DNS → Records**: add an `A` record, name `*`, value = the VPS's IPv4
   address, **Proxied** (orange cloud). If the VPS has IPv6, add a matching
   `AAAA` record. (Prefer to add subdomains one at a time? Use name
   `hn-reader` instead of `*`.) Existing records such as `sanvir.net` or `www`
   are unaffected: a wildcard only answers for names with no record of their own.
2. **SSL/TLS → Overview**: set the encryption mode to **Full (strict)**.
3. **SSL/TLS → Origin Server → Create Certificate**: keep "Generate private
   key and CSR with Cloudflare", hostnames `*.sanvir.net` and `sanvir.net`,
   validity 15 years. Keep the page open; you need both the certificate and
   the private key in step 3 (the key is shown only once).

### 2. Deploy SSH key (on your own computer)

```bash
ssh-keygen -t ed25519 -N "" -C github-actions-deploy -f ~/.ssh/sanvir-vps-deploy
```

### 3. Bootstrap the VPS

Copy the `infra/` folder to the VPS and run the bootstrap script as root,
passing the **public** key from step 2:

```bash
scp -r infra root@YOUR_VPS_IP:/root/infra
```

```bash
ssh root@YOUR_VPS_IP
```

```bash
bash /root/infra/bootstrap-vps.sh "ssh-ed25519 AAAA...rest of sanvir-vps-deploy.pub... github-actions-deploy"
```

The script:

- shows what is listening on ports 80/443, and for each web server it finds
  (Nginx, Apache, Caddy, Traefik, HAProxy, lighttpd, or a container publishing
  80/443) **asks** before stopping, disabling or uninstalling it;
- installs Docker Engine and the Compose plugin if missing;
- creates an `apps` user in the `docker` group with your key (note that
  Docker access is effectively root access on the VPS). The existing `deploy`
  user belongs to kindle-dash and is left alone;
- creates `/opt/edge`, `/opt/apps`, and the `edge` Docker network;
- opens SSH, 80 and 443 in `ufw` if ufw is installed.

Then save the origin certificate from step 1.3 and start the proxy:

```bash
nano /opt/edge/certs/origin.pem
```

```bash
nano /opt/edge/certs/origin-key.pem
```

```bash
chmod 600 /opt/edge/certs/* && cd /opt/edge && docker compose up -d
```

The script is safe to re-run; re-running it also starts the proxy once the
certificate files exist and ports 80/443 are free.

### 3b. Move the Kindle dashboard onto the edge proxy (this VPS only)

Before this change the system Caddy (`caddy.service`) served the Kindle
dashboard at `2-31-153-195.sslip.io` and held ports 80/443, so the edge proxy
cannot start until it is retired. The edge container mounts
`/var/lib/kindle-dash` read-only, and kindle-dash's deploy (from
sanvirmanilal/kindle-dash#6) installs its site as
`/opt/edge/sites/kindle-dash.caddy` once `/opt/edge` exists. As root:

1. Install the updated `deploy/kindle-dash-deploy` from kindle-dash as
   `/usr/local/sbin/kindle-dash-deploy`, then run a kindle-dash deploy
   (**Actions → CI / Deploy → Run workflow** on `main`) so the site file is
   written.
2. Copy the existing Let's Encrypt certificate so there is no ACME gap, then
   swap the proxies:

   ```bash
   cd /opt/edge && docker compose create
   docker run --rm -v edge_caddy_data:/data -v /var/lib/caddy/.local/share/caddy:/src:ro alpine cp -a /src/. /data/caddy/
   systemctl disable --now caddy && docker compose up -d
   ```

Roll back with `docker compose down && systemctl enable --now caddy`. The
`caddy` package stays installed because kindle-dash's deploy uses
`caddy validate`.

### 4. GitHub secrets

In the repo: **Settings → Secrets and variables → Actions → New repository
secret**:

| Secret            | Value                                                                    |
| ----------------- | ------------------------------------------------------------------------ |
| `VPS_HOST`        | VPS IP address (not the Cloudflare-proxied name; SSH can't go through it) |
| `VPS_USER`        | `apps`                                                                   |
| `VPS_SSH_KEY`     | contents of the **private** key `~/.ssh/sanvir-vps-deploy`               |
| `VPS_KNOWN_HOSTS` | output of `ssh-keyscan -p 22 YOUR_VPS_IP` (run from your computer)       |
| `VPS_PORT`        | optional; only if SSH is not on port 22                                  |
| `ANTHROPIC_API_KEY` | optional; an Anthropic API key for AI summaries (omit to disable them) |

The workflow sends `ANTHROPIC_API_KEY` to the VPS over SSH stdin, and
`remote-deploy.sh` writes it to `/opt/apps/hn-reader/.env` (mode 600) for the
container. Set a monthly spend limit for that key's workspace in the
Anthropic Console.

### 5. Deploy

Merge to `main` (or run **Actions → Deploy → Run workflow**). The workflow:

1. checks `server.js` syntax and builds the image for amd64 and arm64;
2. pushes `ghcr.io/sanvirmanilal/hn-reader:<commit-sha>` and `:latest`;
3. copies `deploy/` to `/opt/apps/hn-reader`, pulls the image, restarts the
   app, waits for its health check, installs `hn-reader.caddy` into
   `/opt/edge/sites` and reloads Caddy;
4. checks that <https://hn-reader.sanvir.net> responds.

## Day-to-day

Logs and status, as `apps` on the VPS:

```bash
cd /opt/apps/hn-reader && docker compose ps && docker compose logs -f
```

Roll back to an earlier commit's image (any SHA from the Actions history):

```bash
cd /opt/apps/hn-reader && echo IMAGE_TAG=<older-sha> > .env && docker compose up -d
```

The next push to `main` deploys the latest commit again.

## Adding another app (e.g. placeholder.sanvir.net)

1. Give the app a `compose.yaml` that joins the external `edge` network with
   an alias and publishes **no** ports:

   ```yaml
   services:
     app:
       image: ghcr.io/sanvirmanilal/placeholder:${IMAGE_TAG:-latest}
       restart: unless-stopped
       networks:
         edge:
           aliases: [placeholder]
   networks:
     edge:
       external: true
   ```

2. Add a site file `placeholder.caddy`:

   ```
   placeholder.sanvir.net {
   	import app_defaults
   	reverse_proxy placeholder:8080
   }
   ```

3. Copy this repo's `.github/workflows/deploy.yml` and `deploy/remote-deploy.sh`
   into the new repo, replace `hn-reader` with the app's name, and add the
   same four secrets (the same `apps` key can be reused).

With the wildcard DNS record and wildcard origin certificate, there is nothing
to change in Cloudflare or on the VPS by hand.

To change the shared proxy itself, edit `infra/edge/` here, copy the files to
`/opt/edge` and run `docker compose up -d` there. For a Caddyfile-only change,
validate and then **restart** the container:

```bash
cd /opt/edge && docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile && docker restart edge-caddy
```

`Caddyfile` is bind-mounted as a single file, which pins the file as it was
when the container started; tools that replace the file (`install`, `cp` to a
new file, most editors) leave the running container on the old copy, so a
plain `caddy reload` may not see the change. Files in `sites/` are a directory
mount and reload normally. If you add many apps, consider moving `infra/` into
its own repository.

## Notes

- `GITHUB_TOKEN` is used to log the VPS in to GHCR only for the duration of
  the deploy, so no long-lived registry credentials are stored on the VPS,
  and the image package can stay private.
- The reader fetches arbitrary article URLs on behalf of visitors. It blocks
  private and local addresses, but anyone who finds the site can use it. To
  keep it to yourself, put it behind **Cloudflare Zero Trust → Access** (free
  for personal use) with an email-based policy; no app changes are needed.
- Optional hardening: allow ports 80/443 only from
  [Cloudflare's IP ranges](https://www.cloudflare.com/ips/) so the origin
  can't be reached directly.
