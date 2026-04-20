-include .env
export

INGRESS_MODE ?= direct

ifeq ($(INGRESS_MODE),direct)
  COMPOSE_FILES := -f docker-compose.yml
else ifeq ($(INGRESS_MODE),tunnel)
  COMPOSE_FILES := -f docker-compose.yml -f docker-compose.tunnel.yml
else
  $(error INGRESS_MODE must be 'direct' or 'tunnel' (got '$(INGRESS_MODE)'))
endif

DC := docker compose $(COMPOSE_FILES)

.PHONY: init init-tunnel up down restart logs ps config reset-certs update-cf-ips

update-cf-ips:
ifneq ($(INGRESS_MODE),direct)
	@echo "update-cf-ips is only meaningful in direct mode (current: $(INGRESS_MODE))"; exit 1
endif
	@scripts/update-cf-ips.sh

init:
	@docker network create $${NETWORK_NAME:-traefik_webgateway} 2>/dev/null || true
ifeq ($(INGRESS_MODE),direct)
	@test -s traefik/dynamic/cloudflare-ips.yml || $(MAKE) update-cf-ips
	@mkdir -p letsencrypt && touch letsencrypt/acme.json && chmod 600 letsencrypt/acme.json
	@echo "Initialized in DIRECT mode."
else
	@[ -n "$${TUNNEL_TOKEN:-}" ] || { echo "ERROR: TUNNEL_TOKEN not set in .env. Run 'make init-tunnel' for setup steps."; exit 1; }
	@echo "Initialized in TUNNEL mode."
endif

init-tunnel:
	@echo "Tunnel mode bootstrap (one-time manual steps):"
	@echo "  1. Open https://one.dash.cloudflare.com/ -> Networks -> Tunnels"
	@echo "     Create a tunnel -> Cloudflared"
	@echo "  2. Name it (e.g. 'api-gateway'), copy the TUNNEL TOKEN"
	@echo "     (the string after --token in the shown Docker command),"
	@echo "     paste into .env as TUNNEL_TOKEN=..."
	@echo "  3. In the same tunnel, Public Hostnames tab -> Add a public hostname:"
	@echo "       Subdomain:    *"
	@echo "       Domain:       $${DOMAIN:-<your-domain>}"
	@echo "       Service type: HTTP"
	@echo "       URL:          traefik:80"
	@echo "  4. In .env set:"
	@echo "       INGRESS_MODE=tunnel"
	@echo "       COMPOSE_PROFILES=tunnel"
	@echo "  5. Run 'make init && make up'"
	@echo ""
	@echo "See docs/ingress-tunnel.md for a detailed walkthrough."

up:
	@$(DC) up -d

down:
	@$(DC) down

restart:
	@$(DC) restart traefik

logs:
	@$(DC) logs -f traefik

ps:
	@$(DC) ps

config:
	@$(DC) config

reset-certs:
ifneq ($(INGRESS_MODE),direct)
	@echo "reset-certs is only meaningful in direct mode (current: $(INGRESS_MODE))"; exit 1
endif
	@echo "This will delete letsencrypt/acme.json. Press Ctrl+C to abort, Enter to continue."
	@read _confirm
	@rm -f letsencrypt/acme.json && touch letsencrypt/acme.json && chmod 600 letsencrypt/acme.json
	@echo "Certificates reset. Run 'make restart' to re-request."
