# Tunnel mode setup — Cloudflare Zero Trust walkthrough

This document walks through setting up **tunnel mode** (`INGRESS_MODE=tunnel`), where traffic reaches your origin via an outbound `cloudflared` tunnel instead of public ports on the host.

## Overview

In tunnel mode, `cloudflared` runs as a sidecar alongside Traefik. It establishes an **outbound** connection to the Cloudflare edge and tunnels incoming HTTP requests back to Traefik on the internal docker network. No inbound ports are open on the origin host. TLS terminates at the Cloudflare edge; the path from `cloudflared` → Traefik → service is plain HTTP on the internal network.

Use tunnel mode when:
- The origin host has no public IP (NAT, home server, corporate network).
- You don't want to open ports 80/443 on the firewall.
- You want to hide the origin IP entirely (tunnel is outbound; CF never learns the origin address).

## Prerequisites

- Cloudflare account with the target domain added and delegated (DNS nameservers pointed to Cloudflare). This is the same requirement as direct mode.
- **Cloudflare Zero Trust** enabled on the account. The free tier is sufficient for one tunnel. Go to [one.dash.cloudflare.com](https://one.dash.cloudflare.com/) and complete the free-tier onboarding if you haven't already.
- Docker + Compose v2 installed on the origin host.

## Step 1 — Create the tunnel

1. Open [one.dash.cloudflare.com](https://one.dash.cloudflare.com/).
2. Navigate: **Networks → Tunnels** (sidebar on the left).
3. Click **Create a tunnel**.
4. Choose connector type: **Cloudflared**.
5. Name the tunnel (e.g. `api-gateway` or `api-gateway-prod`). Names are local to your account.
6. Click **Save tunnel**.

## Step 2 — Copy the token

On the next page ("Install and run a connector"):

1. Select the **Docker** tab.
2. You'll see a command that looks like `docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token eyJ...` (long base64-ish string).
3. **Copy the token only** — the long string after `--token `. Do not copy the whole command; the project already defines the Docker service.
4. Paste into `.env` on the origin host:

   ```
   TUNNEL_TOKEN=eyJ... (the whole long string)
   ```

**Security note:** the token grants full tunnel control. Treat it like any other secret — never commit `.env` to git, rotate if exposed.

Do **not** click "Next" in the dashboard yet — finish Step 3 first (the dashboard expects you to confirm the connector is healthy after adding the hostname, which requires the container to be running).

## Step 3 — Configure the public hostname

Still in the tunnel creation flow (or, if you navigated away, open the tunnel again and find the **Public Hostnames** tab):

1. Click **Add a public hostname**.
2. Fill in exactly one rule (catch-all):
   - **Subdomain:** `*`
   - **Domain:** select your domain from the dropdown (it must be added to the CF account).
   - **Path:** leave empty.
   - **Service Type:** `HTTP`
   - **URL:** `traefik:80`
3. Click **Save hostname**.

Cloudflare will automatically create a DNS CNAME record `*.<your-domain> → <tunnel-uuid>.cfargotunnel.com`. You do not need to create this manually.

**Why catch-all:** the single `*` subdomain rule sends all requests for `*.<domain>` through the tunnel to Traefik:80. From there, Traefik's docker-label routing takes over (exactly as in direct mode). Any new service you register via labels is immediately reachable — no further changes in the CF dashboard.

## Step 4 — Enable tunnel mode locally

On the origin host:

```bash
# .env
INGRESS_MODE=tunnel
COMPOSE_PROFILES=tunnel
TUNNEL_TOKEN=eyJ...  (from Step 2)
DOMAIN=<your-domain>
DASHBOARD_AUTH=<bcrypt-hashed-credentials>
```

`ACME_EMAIL`, `CF_DNS_API_TOKEN`, `ACME_CA_SERVER` are not needed in tunnel mode — leave them empty or omit.

Initialize and start:

```bash
make init
make up
```

## Step 5 — Verify

```bash
# Both containers running, no cf-ip-updater (direct-mode-only)
docker compose ps
# Should show: traefik, cloudflared — both in state "Up"

# cloudflared is connected to CF edge
docker compose logs cloudflared | grep -E "Registered tunnel connection|Connection .* registered"
# Should show 2-4 "Registered tunnel connection" lines (one per edge location)

# No ports bound on the host
ss -tln | awk '$4 ~ /:(80|443)$/'
# Should print nothing (no listeners)

# Service reachable via CF
curl https://whoami.<your-domain>
# Should return the whoami service response (after starting examples/whoami)

# Dashboard reachable via CF
curl -u admin:<password> https://traefik.<your-domain>/dashboard/
# Should return the dashboard HTML
```

If all of these pass, tunnel mode is working.

## Troubleshooting

**`make init` fails with "TUNNEL_TOKEN not set"**
→ Check `.env` has `TUNNEL_TOKEN=...` with a non-empty value. Re-copy from the CF dashboard if needed.

**`cloudflared` logs show authentication errors**
→ Token is invalid or was regenerated. Go to CF Zero Trust dashboard → Networks → Tunnels → your tunnel → Configure → Overview, and either use the existing token or delete and recreate the tunnel.

**`curl https://<subdomain>.<domain>` returns 502 Bad Gateway**
→ Traefik isn't reachable on `traefik:80` from the `cloudflared` container. Check `docker compose logs traefik` for startup errors. Verify both containers are on the `traefik_webgateway` network: `docker inspect cloudflared | grep traefik_webgateway`.

**`curl https://<subdomain>.<domain>` returns "DNS not found" or similar**
→ The public hostname rule in CF dashboard isn't saved, or DNS hasn't propagated yet (usually <1 minute). Check that `*.<domain>` resolves: `dig +short whoami.<domain> CNAME` should return `<tunnel-uuid>.cfargotunnel.com`.

**Tunnel shows as "Inactive" or "Down" in CF dashboard**
→ The `cloudflared` container isn't running or can't reach Cloudflare. Check `docker compose ps` and `docker compose logs cloudflared`. Ensure the host has outbound HTTPS (port 443) to `*.cloudflare.com`.

**I see "404 page not found" for a service that worked in direct mode**
→ Check the service's labels: `entrypoints` must be `public` (not `websecure`). See README "Migrating from pre-tunnel-mode label schema" for the full migration.

## Switching back to direct mode

1. In `.env`: `INGRESS_MODE=direct`, `COMPOSE_PROFILES=direct`, fill in `ACME_EMAIL` and `CF_DNS_API_TOKEN`.
2. `make down && make init && make up`.
3. Optional cleanup in CF Zero Trust: delete the tunnel (Networks → Tunnels → your tunnel → Delete) if you don't plan to switch back. This also removes the `*.<domain>` CNAME DNS record; you'll need to re-create the direct-mode DNS records (`* A → <origin-ip>` with Proxied status) if they were previously only created for tunnel mode.

Service labels and `examples/whoami` work unchanged across both modes — no service-side migration needed when switching.

## Architecture diagram

```
Direct mode:
  browser  ─https─►  CF edge  ─https─►  origin host :443  ─►  Traefik
                                        (public IP,
                                         CF IP allowlist)

Tunnel mode:
  browser  ─https─►  CF edge  ─┐
                               │ (tunnel)
                               └─outbound─►  cloudflared  ─http─►  Traefik :80
                                             (on origin host,
                                              no public ports)
```

In both cases Traefik → service is HTTP on the internal docker network.
