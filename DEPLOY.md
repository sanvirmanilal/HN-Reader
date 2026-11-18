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
- creates a `deploy` user in the `docker` group with your key (note that
  Docker access is effectively root access on the VPS);
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
certificate files exist.

### 4. GitHub secrets

In the repo: **Settings → Secrets and variables → Actions → New repository
secret**:

| Secret            | Value                                                                    |
| ----------------- | ------------------------------------------------------------------------ |
| `VPS_HOST`        | VPS IP address (not the Cloudflare-proxied name; SSH can't go through it) |
| `VPS_USER`        | `deploy`                                                                 |
| `VPS_SSH_KEY`     | contents of the **private** key `~/.ssh/sanvir-vps-deploy`               |
| `VPS_KNOWN_HOSTS` | output of `ssh-keyscan -p 22 YOUR_VPS_IP` (run from your computer)       |
| `VPS_PORT`        | optional; only if SSH is not on port 22                                  |

### 5. Deploy

Merge to `main` (or run **Actions → Deploy → Run workflow**). The workflow:

1. checks `server.js` syntax and builds the image for amd64 and arm64;
2. pushes `ghcr.io/sanvirmanilal/hn-reader:<commit-sha>` and `:latest`;
3. copies `deploy/` to `/opt/apps/hn-reader`, pulls the image, restarts the
   app, waits for its health check, installs `hn-reader.caddy` into
   `/opt/edge/sites` and reloads Caddy;
4. checks that <https://hn-reader.sanvir.net> responds.

## Day-to-day

Logs and status, as `deploy` on the VPS:

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
   same four secrets (the same `deploy` key can be reused).

With the wildcard DNS record and wildcard origin certificate, there is nothing
to change in Cloudflare or on the VPS by hand.

To change the shared proxy itself, edit `infra/edge/` here, copy the files to
`/opt/edge` and run `docker compose up -d` there (or
`docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile` for a
Caddyfile-only change). If you add many apps, consider moving `infra/` into
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
