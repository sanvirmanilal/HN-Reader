#!/usr/bin/env bash
# One-time VPS setup for the shared edge proxy and app deployments.
#
# Run as root on the VPS (Debian/Ubuntu), from a copy of this repo's infra/ dir:
#   sudo bash infra/bootstrap-vps.sh "ssh-ed25519 AAAA... github-actions"
#
# It is safe to re-run. It asks before stopping or removing anything.
set -euo pipefail

# Not "deploy": that user already exists for kindle-dash, with a key restricted
# to a single command, and must not gain Docker (root-equivalent) access.
DEPLOY_USER=apps
EDGE_DIR=/opt/edge
APPS_DIR=/opt/apps
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_PUBKEY=${1:-}

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }
# Without a terminal (e.g. `ssh host bash script`) every question is answered "no".
ask()  { local reply=""; { read -r -p "$1 [y/N] " reply </dev/tty; } 2>/dev/null || return 1; [[ $reply =~ ^[Yy]$ ]]; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v apt-get >/dev/null || { echo "This script expects Debian/Ubuntu (apt)." >&2; exit 1; }

# --- 1. Find and remove whatever already serves ports 80/443 -----------------
say "Checking what is listening on ports 80 and 443"
ss -ltnpH '( sport = :80 or sport = :443 )' || true

for svc in nginx apache2 httpd caddy traefik lighttpd haproxy; do
  if systemctl cat "$svc.service" >/dev/null 2>&1; then
    state=$(systemctl is-active "$svc" || true)
    warn "Found system service '$svc' ($state)."
    if ask "Stop and disable $svc?"; then
      systemctl disable --now "$svc" || true
      if dpkg -s "$svc" >/dev/null 2>&1 && ask "Also uninstall the $svc package (apt purge)?"; then
        apt-get purge -y "$svc" && apt-get autoremove -y
      fi
    fi
  fi
done

if command -v docker >/dev/null; then
  mapfile -t web_containers < <(docker ps --format '{{.Names}} {{.Ports}}' |
    grep -E ':(80|443)->' | grep -v '^edge-caddy ' | awk '{print $1}')
  for c in "${web_containers[@]}"; do
    warn "Container '$c' publishes port 80/443: $(docker ps --filter "name=^$c\$" --format '{{.Image}}')"
    if ask "Stop and remove container $c?"; then
      docker rm -f "$c"
    fi
  done
fi

if ss -ltnH '( sport = :80 or sport = :443 )' | grep -q . &&
   ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx edge-caddy; then
  warn "Something still listens on 80/443 (see above). The edge proxy will fail to start until it is gone."
fi

# --- 2. Docker -----------------------------------------------------------------
if ! command -v docker >/dev/null; then
  say "Installing Docker Engine + compose plugin"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
docker compose version >/dev/null

# --- 3. Deploy user for GitHub Actions ----------------------------------------
say "Setting up the '$DEPLOY_USER' user"
id "$DEPLOY_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
auth_keys=/home/$DEPLOY_USER/.ssh/authorized_keys
touch "$auth_keys"
if [ -n "$DEPLOY_PUBKEY" ] && ! grep -qxF "$DEPLOY_PUBKEY" "$auth_keys"; then
  echo "$DEPLOY_PUBKEY" >> "$auth_keys"
fi
chown "$DEPLOY_USER:$DEPLOY_USER" "$auth_keys"; chmod 600 "$auth_keys"
[ -s "$auth_keys" ] || warn "No SSH key for $DEPLOY_USER yet; re-run with the public key as the first argument."

# --- 4. Edge proxy -------------------------------------------------------------
say "Setting up the edge proxy in $EDGE_DIR"
docker network inspect edge >/dev/null 2>&1 || docker network create edge
install -d -m 755 "$EDGE_DIR" "$APPS_DIR"
install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$EDGE_DIR/sites"
install -d -m 700 "$EDGE_DIR/certs"
chown "$DEPLOY_USER:$DEPLOY_USER" "$APPS_DIR"
install -m 644 "$SCRIPT_DIR/edge/Caddyfile" "$SCRIPT_DIR/edge/compose.yaml" "$EDGE_DIR/"
install -m 644 "$SCRIPT_DIR/edge/sites/_example.caddy.txt" "$EDGE_DIR/sites/"

port_busy() {
  ss -ltnH '( sport = :80 or sport = :443 )' | grep -q . &&
    ! docker ps --format '{{.Names}}' | grep -qx edge-caddy
}
if port_busy; then
  warn "Ports 80/443 are still taken by something other than edge-caddy; not starting the proxy."
  warn "Stop that server (see DEPLOY.md for moving the Kindle dashboard), then: cd $EDGE_DIR && docker compose up -d"
elif [ -s "$EDGE_DIR/certs/origin.pem" ] && [ -s "$EDGE_DIR/certs/origin-key.pem" ]; then
  chmod 600 "$EDGE_DIR/certs/"*
  (cd "$EDGE_DIR" && docker compose up -d)
  say "Edge proxy running."
else
  warn "Cloudflare origin certificate missing. Save it as:"
  warn "  $EDGE_DIR/certs/origin.pem       (certificate)"
  warn "  $EDGE_DIR/certs/origin-key.pem   (private key)"
  warn "then run: cd $EDGE_DIR && docker compose up -d"
fi

# --- 5. Firewall -----------------------------------------------------------------
if command -v ufw >/dev/null; then
  say "Allowing SSH, HTTP and HTTPS in ufw"
  ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ufw status | head -1
fi

say "Done. Next: add the GitHub secrets and push to main (see DEPLOY.md)."
