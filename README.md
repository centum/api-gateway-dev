# api-gateway

Traefik v3.1-based API gateway for Docker services.

## Overview

A thin configuration wrapper over Traefik that:

- Routes subdomains to Docker services via standard Traefik labels.
- Terminates HTTPS (wildcard `*.DOMAIN` via Let's Encrypt DNS-01 / Cloudflare).
- Globally redirects HTTP → HTTPS (301).
- Protects the origin server: only requests from [Cloudflare edge IPs](https://www.cloudflare.com/ips-v4) are allowed through; everything else gets `403 Forbidden`.
- Provides a dashboard at `DASHBOARD_SUBDOMAIN.DOMAIN` behind basic-auth.

**Out of scope:** rate limiting, metrics/tracing, multi-domain, HA/clustering.

## Prerequisites

### Cloudflare

1. Domain delegated to Cloudflare nameservers.
2. DNS record `* A → <your-server-public-IP>` with **Proxy status: Proxied** (orange cloud).
3. SSL/TLS mode set to **Full (strict)**.
4. API Token with scopes `Zone:DNS:Edit` + `Zone:Zone:Read` for your zone.

Validate the token before starting:

```bash
curl -sX GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $CF_DNS_API_TOKEN" | grep '"status":"active"' && echo OK || echo FAIL
```

### Server

- Docker + Compose v2 installed.
- Ports **80** and **443** open to the internet (firewall / security group).
- `htpasswd` available: `apt install apache2-utils` or `brew install httpd`.

## One-time Setup

```bash
# 1. Clone and configure
cp .env.example .env
# Edit .env — required variables:
#   DOMAIN, ACME_EMAIL, CF_DNS_API_TOKEN, DASHBOARD_AUTH
# Optional overrides (defaults shown):
#   LOG_LEVEL=INFO  HTTP_PORT=80  HTTPS_PORT=443  NETWORK_NAME=traefik_webgateway

# 2. Generate DASHBOARD_AUTH (bcrypt)
# The sed replaces $ with $$ — required by docker compose for literal $ in values.
htpasswd -nbB admin 'YourPassword' | sed -e 's/\$/\$\$/g'
# Paste the output as DASHBOARD_AUTH in .env

# 3. Initialise (creates Docker network, acme.json, fetches Cloudflare IP list)
make init
```

### First run: staging → production

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
make up           # start Traefik in detached mode
make down         # stop and remove containers
make restart      # restart Traefik (picks up compose/env changes)
make logs         # tail Traefik logs
make ps           # show container status
make config       # print resolved docker-compose config
make reset-certs  # delete acme.json (re-requests certificate on next start)
make update-cf-ips  # refresh Cloudflare IP list and reload dynamic config
```

## Registering a New Service

Add these labels to your service's `docker-compose.yml`. The service **must** be on
the `traefik_webgateway` network.

```yaml
services:
  myapp:
    image: myapp:latest
    networks:
      - traefik_webgateway
    labels:
      # Enable Traefik for this container
      - "traefik.enable=true"
      # Tell Traefik which network to use for this container
      # (required when the container is on multiple networks)
      - "traefik.docker.network=traefik_webgateway"
      # Route requests for this subdomain to this service
      - "traefik.http.routers.myapp.rule=Host(`myapp.${DOMAIN}`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=cloudflare"
      # Reuse the shared wildcard certificate
      - "traefik.http.routers.myapp.tls.domains[0].main=${DOMAIN}"
      - "traefik.http.routers.myapp.tls.domains[0].sans=*.${DOMAIN}"
      # Internal port your application listens on
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"

networks:
  traefik_webgateway:
    external: true
    name: ${NETWORK_NAME:-traefik_webgateway}
```

See [`examples/whoami/docker-compose.yml`](examples/whoami/docker-compose.yml) for a minimal working example.

## Origin Protection

All traffic on the `websecure` entrypoint passes through the `cloudflare-only`
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

**Keeping the list current:** Cloudflare occasionally updates its IP ranges.
Periodically re-run:

```bash
make update-cf-ips && make restart
```

You can automate this with cron:

```
0 3 * * 1  cd /path/to/api-gateway && make update-cf-ips && make restart
```

## Troubleshooting

**Certificate not issued**
- Verify CF token scopes (`Zone:DNS:Edit` + `Zone:Zone:Read`).
- Check logs: `make logs | grep -i acme`.
- Ensure DNS resolvers in `traefik.yml` can reach Cloudflare (`1.1.1.1:53`).

**"404 page not found"**
Traefik can't see the container. Check:
1. `traefik.enable=true` label is present.
2. Container is on `traefik_webgateway` network.
3. `traefik.docker.network=traefik_webgateway` label matches the network name.
4. `exposedByDefault: false` in `traefik.yml` requires explicit opt-in.

**Switching staging → production**
Must run `make reset-certs && make restart` after changing `ACME_CA_SERVER`.
Traefik caches the staging cert in `acme.json`; deleting it forces re-issuance.

**"403 Forbidden" on a legitimate request**
- Ensure the request goes through Cloudflare (not directly to the server IP).
- Refresh the IP list: `make update-cf-ips && make restart`.
- Check `traefik/dynamic/cloudflare-ips.yml` contains current ranges.

**Local development / debugging without Cloudflare**
Temporarily add your IP to `traefik/dynamic/cloudflare-ips.yml` under
`sourceRange`, or comment out the `cloudflare-only@file` middleware reference in
`traefik/traefik.yml` for the duration of your testing.

**Middleware not applied — name mismatch**
The middleware name must be identical in three places. Verify with:

```bash
grep "cloudflare-only" traefik/traefik.yml traefik/dynamic/cloudflare-ips.yml scripts/update-cf-ips.sh
```

All three lines must show the same name.
