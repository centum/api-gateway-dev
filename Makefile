.PHONY: init up down restart logs ps config reset-certs update-cf-ips

update-cf-ips:
	@scripts/update-cf-ips.sh

init:
	@test -s traefik/dynamic/cloudflare-ips.yml || $(MAKE) update-cf-ips
	@docker network create $${NETWORK_NAME:-traefik_webgateway} 2>/dev/null || true
	@mkdir -p letsencrypt && touch letsencrypt/acme.json && chmod 600 letsencrypt/acme.json

up:
	@docker compose up -d

down:
	@docker compose down

restart:
	@docker compose restart traefik

logs:
	@docker compose logs -f traefik

ps:
	@docker compose ps

config:
	@docker compose config

reset-certs:
	@echo "This will delete letsencrypt/acme.json. Press Ctrl+C to abort, Enter to continue."
	@read _confirm
	@rm -f letsencrypt/acme.json && touch letsencrypt/acme.json && chmod 600 letsencrypt/acme.json
	@echo "Certificates reset. Run 'make restart' to re-request."
