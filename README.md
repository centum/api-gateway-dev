# api-gateway

Traefik v3.1-based API gateway for Docker services. Supports two ingress modes:
**direct** (public 80/443 with Let's Encrypt) and **tunnel** (outbound `cloudflared`, no public ports).

## Overview

A thin configuration wrapper over Traefik that:

- Routes subdomains to Docker services via standard Traefik labels (mode-agnostic).
- **Direct mode:** terminates HTTPS (wildcard `*.DOMAIN` via Let's Encrypt DNS-01 / Cloudflare), redirects HTTP → HTTPS, restricts origin to Cloudflare edge IPs only.
- **Tunnel mode:** establishes outbound `cloudflared` tunnel; TLS terminates at Cloudflare edge; no public ports on the origin host.
- Provides a dashboard at `DASHBOARD_SUBDOMAIN.DOMAIN` behind basic-auth (both modes).

**Out of scope:** rate limiting, metrics/tracing, multi-domain, HA/clustering.

## Choosing an Ingress Mode

**Direct mode** (default) — use when:
- You have a public IP on the origin host.
- Ports 80 and 443 are open to the internet.
- You want standard CF-proxy + Let's Encrypt + IP allowlist semantics.

**Tunnel mode** — use when:
- Origin is behind NAT / no public IP.
- You don't want to open inbound ports on the host (e.g. home server, corporate network, strict firewall).
- You want to hide the origin IP completely (tunnel goes outbound, CF never knows the origin address).

Switch between modes by changing `INGRESS_MODE` in `.env` and running `make down && make up`. Service registration labels are identical in both modes — no changes needed in consuming services. See [`docs/ingress-tunnel.md`](docs/ingress-tunnel.md) for tunnel-mode setup.

## Prerequisites

### Cloudflare (both modes)

1. Domain delegated to Cloudflare nameservers.
2. **Direct mode only:** DNS record `* A → <your-server-public-IP>` with **Proxy status: Proxied** (orange cloud), SSL/TLS mode set to **Full (strict)**, API Token with scopes `Zone:DNS:Edit` + `Zone:Zone:Read`.
3. **Tunnel mode only:** Cloudflare Zero Trust account (free tier is sufficient). DNS records are created automatically when you add a public hostname to the tunnel.

Validate the direct-mode token before starting:

```bash
curl -sX GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $CF_DNS_API_TOKEN" | grep '"status":"active"' && echo OK || echo FAIL
```

### Server

- Docker + Compose v2 installed.
- **Direct mode only:** ports **80** and **443** open to the internet.
- `htpasswd` available: `apt install apache2-utils` or `brew install httpd`.

## One-time Setup

### Direct mode

```bash
# 1. Clone and configure
cp .env.example .env
# Edit .env — required variables for direct mode:
#   INGRESS_MODE=direct (default), COMPOSE_PROFILES=direct
#   DOMAIN, ACME_EMAIL, CF_DNS_API_TOKEN, DASHBOARD_AUTH
# Optional overrides (defaults shown):
#   LOG_LEVEL=INFO  HTTP_PORT=80  HTTPS_PORT=443  NETWORK_NAME=traefik_webgateway

# 2. Generate DASHBOARD_AUTH (bcrypt)
# The sed replaces $ with $$ — required by docker compose for literal $ in values.
htpasswd -nbB admin 'YourPassword' | sed -e 's/\$/\$\$/g'
# Paste the output as DASHBOARD_AUTH in .env

# 3. Initialise (creates Docker network, acme.json, fetches Cloudflare IP list)
make init
make up
```

### Tunnel mode

```bash
# 1. Clone and configure
cp .env.example .env
# Set: INGRESS_MODE=tunnel, COMPOSE_PROFILES=tunnel, DOMAIN, DASHBOARD_AUTH.
# Generate DASHBOARD_AUTH the same way as above.

# 2. Print tunnel-mode setup instructions
make init-tunnel
# Follow the printed steps (or docs/ingress-tunnel.md) to create the tunnel in
# the CF Zero Trust dashboard, copy the TUNNEL_TOKEN into .env, and add the
# single catch-all public hostname rule `*.${DOMAIN} → http://traefik:80`.

# 3. Initialise and start
make init
make up
```

### First run: staging → production (direct mode)

Start with the **staging** CA (default in `.env.example`) to verify everything works
before requesting a real certificate:

```bash
# .env: ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
make up
make logs   # wait for "Configuration loaded" and ACME challenge success

# Test with -k (staging cert is untrusted)
curl -k https://traefik.yourdomain.com/dashboard/               # should 401
curl -ku admin:YourPassword https://traefik.yourdomain.com/dashboard/  # should 200
```

Once working, switch to production:

```bash
# .env: ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
make reset-certs && make restart
# Now curl without -k should work with a valid certificate.
```

## Usage

```bash
make up             # start containers in detached mode
make down           # stop and remove containers
make restart        # restart Traefik (picks up compose/env changes)
make logs           # tail Traefik logs
make ps             # show container status
make config         # print resolved docker-compose config
make init-tunnel    # print tunnel-mode setup instructions
make reset-certs    # delete acme.json (re-requests certificate on next start; direct mode only)
make update-cf-ips  # refresh Cloudflare IP list and reload dynamic config (direct mode only)
```

## Registering a New Service

Add these labels to your service's `docker-compose.yml`. The service **must** be on
the `traefik_webgateway` network. The label schema is **identical in both ingress
modes** — switching modes does not require changes in services.

```yaml
services:
  myapp:
    image: myapp:latest
    networks:
      - traefik_webgateway
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_webgateway"
      - "traefik.http.routers.myapp.rule=Host(`myapp.${DOMAIN}`)"
      - "traefik.http.routers.myapp.entrypoints=public"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"

networks:
  traefik_webgateway:
    external: true
    name: ${NETWORK_NAME:-traefik_webgateway}
```

TLS is centralized on the `public` entrypoint in `traefik/traefik.<mode>.yml`.
Services must **not** declare `tls.*` labels (e.g. `tls=true`, `tls.certresolver`,
`tls.domains`) — they're redundant in direct mode and break routing in tunnel mode.

See [`examples/whoami/docker-compose.yml`](examples/whoami/docker-compose.yml) for a minimal working example.

### Migrating from pre-tunnel-mode label schema

If you have services using the older label schema (with `entrypoints=websecure` and
`tls.*` labels), migrate them as follows:

1. **Rename entrypoint — mandatory.** Change `traefik.http.routers.<name>.entrypoints=websecure` to `...=public`. Without this the router no longer matches any entrypoint and the service becomes unreachable.
2. **Remove `tls.*` labels — mandatory before switching to tunnel mode.** Remove these four labels from each service:
   - `traefik.http.routers.<name>.tls=true`
   - `traefik.http.routers.<name>.tls.certresolver=cloudflare`
   - `traefik.http.routers.<name>.tls.domains[0].main=...`
   - `traefik.http.routers.<name>.tls.domains[0].sans=...`

   In direct mode they're harmless (duplicate what's already on the entrypoint), but in tunnel mode they attach TLS to a non-TLS entrypoint and Traefik drops the router.

Safe rollout: do **Step 1** while still in direct mode (zero effective change), verify everything works, then do **Step 2** and switch `INGRESS_MODE=tunnel`.

## Origin Protection

### Direct mode

All traffic on the `public` entrypoint passes through the `cloudflare-only`
IP allowlist middleware defined in `traefik/dynamic/cloudflare-ips.yml`.

**Why this matters:** Cloudflare proxying only protects your origin if traffic
physically flows through the CF edge. Anyone who discovers your server's public IP
can bypass CF by connecting directly. The IP allowlist ensures that only connections
originating from Cloudflare's edge nodes reach Traefik — everything else gets `403`.

**Implementation note:** `ipStrategy` is intentionally absent from the middleware
config. Traefik checks `RemoteAddr` (the TCP peer IP), not `X-Forwarded-For`. Since
all HTTPS traffic arrives via a single Cloudflare hop, `RemoteAddr` equals the CF
edge IP. Setting `depth: 1` would instead read the last `X-Forwarded-For` entry,
which a client could forge.

**Keeping the list current:** the `cf-ip-updater` sidecar refreshes the list every
7 days automatically. Force-refresh with `make update-cf-ips && make restart`.

### Tunnel mode

No IP allowlist is needed — there are no public ports on the origin. The only way
in is through the outbound `cloudflared` tunnel, which Cloudflare authenticates
via the `TUNNEL_TOKEN`. Origin IP is never exposed.

## Troubleshooting

**Certificate not issued (direct mode)**
- Verify CF token scopes (`Zone:DNS:Edit` + `Zone:Zone:Read`).
- Check logs: `make logs | grep -i acme`.
- Ensure DNS resolvers in `traefik.direct.yml` can reach Cloudflare (`1.1.1.1:53`).

**"404 page not found"**
Traefik can't see the container. Check:
1. `traefik.enable=true` label is present.
2. Container is on `traefik_webgateway` network.
3. `traefik.docker.network=traefik_webgateway` label matches the network name.
4. `exposedByDefault: false` in `traefik.<mode>.yml` requires explicit opt-in.
5. Router `entrypoints=public` (not the old `websecure`).

**Switching staging → production (direct mode)**
Must run `make reset-certs && make restart` after changing `ACME_CA_SERVER`.
Traefik caches the staging cert in `acme.json`; deleting it forces re-issuance.

**"403 Forbidden" on a legitimate request (direct mode)**
- Ensure the request goes through Cloudflare (not directly to the server IP).
- Refresh the IP list: `make update-cf-ips && make restart`.
- Check `traefik/dynamic/cloudflare-ips.yml` contains current ranges.

**Tunnel mode: "connection refused" from public URL**
- Check `docker compose logs cloudflared` — look for `Registered tunnel connection`.
- Verify `TUNNEL_TOKEN` is set and non-empty: `grep TUNNEL_TOKEN .env`.
- In CF Zero Trust dashboard, verify the tunnel shows "Healthy" status.
- Verify the public hostname in CF dashboard points to `http://traefik:80` (not `https://`, not a different port).

**Local development / debugging without Cloudflare (direct mode)**
Temporarily add your IP to `traefik/dynamic/cloudflare-ips.yml` under
`sourceRange`, or comment out the `cloudflare-only@file` middleware reference in
`traefik/traefik.direct.yml` for the duration of your testing.

**Middleware not applied — name mismatch**
The middleware name must be identical in three places. Verify with:

```bash
grep "cloudflare-only" traefik/traefik.direct.yml traefik/dynamic/cloudflare-ips.yml scripts/update-cf-ips.sh
```

All three lines must show the same name.

## License

MIT
