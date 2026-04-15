# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Traefik v3.1-based API Gateway** configuration project. It provides a production-ready reverse proxy with:
- HTTPS termination via Let's Encrypt DNS-01 challenge (Cloudflare provider)
- Wildcard certificate support (`*.DOMAIN`)
- Cloudflare-only IP allowlist middleware (prevents direct server IP bypass)
- Docker label-based service discovery

## Common Commands

All operations go through `make`:

```bash
make init           # One-time setup: create docker network, acme.json, fetch CF IPs
make up             # Start Traefik in detached mode
make down           # Stop containers
make restart        # Restart (picks up config/env changes)
make logs           # Tail logs (useful for ACME debugging)
make ps             # Show container status
make config         # Print resolved docker-compose config
make reset-certs    # Delete acme.json to force certificate re-request
make update-cf-ips  # Manual force-refresh of Cloudflare IP ranges (normally handled automatically by cf-ip-updater sidecar)
```

Generate dashboard credentials:
```bash
htpasswd -nbB admin 'password' | sed 's/\$/\$\$/g'
```

## Environment Setup

Copy `.env.example` to `.env` and populate:

| Variable | Required | Notes |
|---|---|---|
| `DOMAIN` | yes | Base domain, e.g. `example.com` |
| `ACME_EMAIL` | yes | Let's Encrypt notification email |
| `CF_DNS_API_TOKEN` | yes | Cloudflare token with Zone:DNS:Edit + Zone:Zone:Read |
| `DASHBOARD_AUTH` | yes | Bcrypt-hashed credentials from `htpasswd` |
| `ACME_CA_SERVER` | no | Defaults to staging; switch to production after verification |
| `CF_IPS_UPDATE_INTERVAL` | no | Update interval for cf-ip-updater sidecar (default: `7d`); supports GNU sleep suffixes: `s`, `m`, `h`, `d` |
| `CF_IPS_UPDATER_IMAGE` | no | Alpine image tag for cf-ip-updater sidecar (default: `alpine:3.20`); pin for reproducibility |

**Staging-first workflow**: Always test with Let's Encrypt staging first, then delete `acme.json` (`make reset-certs`) and switch to production.

## Architecture

```
traefik/
  traefik.yml              # Static config: entry points, providers, ACME resolver
  dynamic/
    cloudflare-ips.yml     # Auto-generated IP allowlist (regenerate with make update-cf-ips)
    tls.yml                # TLS 1.2+ cipher suite policy
scripts/
  update-cf-ips.sh         # Fetches Cloudflare CIDR ranges and writes cloudflare-ips.yml
cf-ip-updater/
  # Sidecar service that runs alongside Traefik, automatically refreshing
  # traefik/dynamic/cloudflare-ips.yml every 7 days (configurable) by re-running
  # scripts/update-cf-ips.sh inside an Alpine container.
examples/
  whoami/docker-compose.yml  # Reference service registration template
```

**Entry points:**
- `web` (port 80) → permanent redirect to `websecure`
- `websecure` (port 443) → `cloudflare-only` IP allowlist middleware applied globally

**IP filtering strategy**: Uses TCP `RemoteAddr` (not `X-Forwarded-For`) because all HTTPS traffic arrives through a single Cloudflare hop, preventing client IP forgery.

## Registering a New Service

Add these Docker labels to the service's `docker-compose.yml`:

```yaml
networks:
  traefik_webgateway:
    external: true

services:
  myapp:
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_webgateway"
      - "traefik.http.routers.myapp.rule=Host(`myapp.${DOMAIN}`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=cloudflare"
      - "traefik.http.routers.myapp.tls.domains[0].main=${DOMAIN}"
      - "traefik.http.routers.myapp.tls.domains[0].sans=*.${DOMAIN}"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
```

The `examples/whoami/docker-compose.yml` is the canonical reference for this pattern.

## Dynamic Config Reloading

Changes to files under `traefik/dynamic/` are picked up automatically (watch mode enabled). Changes to `traefik/traefik.yml` or `docker-compose.yml` require `make restart`.

`cloudflare-ips.yml` is regenerated automatically by the `cf-ip-updater` sidecar (on schedule) or manually via `make update-cf-ips` (force-refresh). Avoid running both simultaneously to prevent a write race on the temp-file `mv` — in practice the risk is minimal since the sidecar sleeps most of the time.
