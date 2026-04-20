# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Traefik v3.1-based API Gateway** configuration project. It provides a production-ready reverse proxy with:
- HTTPS termination via Let's Encrypt DNS-01 challenge (Cloudflare provider)
- Wildcard certificate support (`*.DOMAIN`)
- Cloudflare-only IP allowlist middleware (prevents direct server IP bypass)
- Docker label-based service discovery

Supports two ingress modes: **direct** (public IP:443 + Let's Encrypt + CF IP allowlist — default) and **tunnel** (outbound `cloudflared` tunnel, no public ports needed). Selected via `INGRESS_MODE` env var.

## Ingress Modes

| Aspect                 | direct (default)                  | tunnel                           |
|------------------------|-----------------------------------|----------------------------------|
| Public ports           | 80/443 bound on host              | none                             |
| TLS termination        | Traefik (Let's Encrypt via CF DNS)| CF edge                          |
| Origin IP exposure     | visible to CF, allowlisted        | hidden                           |
| Required env vars      | `CF_DNS_API_TOKEN`, `ACME_EMAIL`  | `TUNNEL_TOKEN`                   |
| Traefik ↔ service      | HTTP on docker network            | HTTP on docker network (same)    |
| cloudflared ↔ Traefik  | —                                 | HTTP on docker network           |
| Dashboard (CF)         | —                                 | one catch-all public hostname    |
| Static config file     | `traefik/traefik.direct.yml`      | `traefik/traefik.tunnel.yml`     |
| Extra compose file     | —                                 | `docker-compose.tunnel.yml`      |

Mode is selected by `INGRESS_MODE=direct|tunnel` in `.env`. `COMPOSE_PROFILES` must match (`.env.example` keeps them in sync via `COMPOSE_PROFILES=${INGRESS_MODE}`). Switching mode: edit `.env`, then `make down && make up`.

Tunnel mode setup walkthrough: `docs/ingress-tunnel.md` or `make init-tunnel`.

## Common Commands

All operations go through `make`. The Makefile reads `INGRESS_MODE` from `.env` and picks the right compose files automatically.

```bash
make init           # One-time setup (mode-aware): network + (direct: acme.json/CF IPs; tunnel: TUNNEL_TOKEN check)
make init-tunnel    # Print tunnel-mode bootstrap instructions (CF Zero Trust dashboard setup)
make up             # Start containers in detached mode
make down           # Stop containers
make restart        # Restart Traefik (picks up config/env changes)
make logs           # Tail Traefik logs (useful for ACME debugging in direct mode)
make ps             # Show container status
make config         # Print resolved docker-compose config
make reset-certs    # Delete acme.json to force certificate re-request (direct mode only)
make update-cf-ips  # Force-refresh Cloudflare IP ranges (direct mode only; normally cf-ip-updater sidecar handles it)
```

`make reset-certs` and `make update-cf-ips` fail fast with an error if `INGRESS_MODE=tunnel` (they're meaningless in that mode).

Generate dashboard credentials:
```bash
htpasswd -nbB admin 'password' | sed 's/\$/\$\$/g'
```

## Environment Setup

Copy `.env.example` to `.env` and populate:

| Variable | Required in mode | Notes |
|---|---|---|
| `INGRESS_MODE` | both | `direct` (default) or `tunnel` |
| `COMPOSE_PROFILES` | both | Keep equal to `INGRESS_MODE` (set via `COMPOSE_PROFILES=${INGRESS_MODE}`) |
| `DOMAIN` | both | Base domain, e.g. `example.com` |
| `DASHBOARD_AUTH` | both | Bcrypt-hashed credentials from `htpasswd` |
| `ACME_EMAIL` | direct | Let's Encrypt notification email |
| `CF_DNS_API_TOKEN` | direct | Cloudflare token with Zone:DNS:Edit + Zone:Zone:Read |
| `ACME_CA_SERVER` | direct | Defaults to staging; switch to production after verification |
| `CF_IPS_UPDATE_INTERVAL` | direct | Update interval for cf-ip-updater sidecar (default `7d`); supports GNU sleep suffixes: `s`, `m`, `h`, `d` |
| `CF_IPS_UPDATER_IMAGE` | direct | Alpine image tag for cf-ip-updater sidecar (default `alpine:3.20`); pin for reproducibility |
| `TUNNEL_TOKEN` | tunnel | Token from CF Zero Trust dashboard (Networks → Tunnels → your tunnel) |
| `CLOUDFLARED_IMAGE_TAG` | tunnel | cloudflared image tag (default `latest`); pin for reproducibility |

**Staging-first workflow** (direct mode): Always test with Let's Encrypt staging first, then delete `acme.json` (`make reset-certs`) and switch to production.

## Architecture

```
traefik/
  traefik.direct.yml       # Static config for direct mode: web→public redirect, public:443+TLS+ACME+allowlist
  traefik.tunnel.yml       # Static config for tunnel mode: public:80 plain HTTP, no TLS/ACME/allowlist
  dynamic/
    cloudflare-ips.yml     # Auto-generated IP allowlist (direct mode); harmless in tunnel mode
    tls.yml                # TLS 1.2+ cipher suite policy (direct mode only)
scripts/
  update-cf-ips.sh         # Fetches Cloudflare CIDR ranges and writes cloudflare-ips.yml
cf-ip-updater/
  # Sidecar (direct mode only, profile=direct) that refreshes traefik/dynamic/cloudflare-ips.yml
  # every 7 days (configurable) by re-running scripts/update-cf-ips.sh in an Alpine container.
docker-compose.yml         # Base: traefik (always), cf-ip-updater (profile=direct), cloudflared (profile=tunnel)
docker-compose.tunnel.yml  # Tunnel-mode overlay: clears traefik.ports (no host port binding)
docs/
  ingress-tunnel.md        # Walkthrough for CF Zero Trust dashboard setup
examples/
  whoami/docker-compose.yml  # Reference service registration template (mode-agnostic, 5 labels)
```

**Entry point:**
- `public` — bound to `:443` with TLS+ACME+allowlist in direct mode, `:80` plain HTTP in tunnel mode. Same name in both modes so service labels are identical.
- `web` (direct mode only) — port 80, permanent redirect to `public`. In tunnel mode the redirect is handled at CF edge.

**IP filtering strategy (direct mode)**: Uses TCP `RemoteAddr` (not `X-Forwarded-For`) because all HTTPS traffic arrives through a single Cloudflare hop, preventing client IP forgery. In tunnel mode this middleware is defined in `dynamic/cloudflare-ips.yml` but not referenced by any entrypoint — harmless.

## Registering a New Service

Add these Docker labels to the service's `docker-compose.yml` (works identically in both ingress modes):

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
      - "traefik.http.routers.myapp.entrypoints=public"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
```

TLS is centralized on the `public` entrypoint in `traefik/traefik.<mode>.yml`. Services should not declare `tls.*` labels — they're redundant in direct mode (harmless) and incompatible with tunnel mode's HTTP-only entrypoint (router will be dropped).

The `examples/whoami/docker-compose.yml` is the canonical reference.

## Dynamic Config Reloading

Changes to files under `traefik/dynamic/` are picked up automatically (watch mode enabled). Changes to `traefik/traefik.{direct,tunnel}.yml` or `docker-compose.yml` require `make restart`.

`cloudflare-ips.yml` is regenerated automatically by the `cf-ip-updater` sidecar (direct mode, on schedule) or manually via `make update-cf-ips` (direct mode, force-refresh). In tunnel mode the file is still generated on `make init` but the `cloudflare-only` middleware it defines is not referenced by any entrypoint — harmless. Avoid running both sidecar and manual refresh simultaneously to prevent a write race on the temp-file `mv` — in practice the risk is minimal since the sidecar sleeps most of the time.
