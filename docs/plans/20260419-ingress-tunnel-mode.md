# Cloudflared Tunnel — optional ingress mode

## Overview

Добавить опциональный режим ingress через `cloudflared tunnel` как альтернативу текущему прямому прокси Cloudflare → публичный IP:443. Активируется env-флагом `INGRESS_MODE=tunnel` (дефолт — `direct`, обратная совместимость).

**Решаемая проблема:** существующая схема требует публичного IP и открытых портов 80/443 на хосте. Это не подходит для:
- хостов за NAT / без белого IP,
- сценариев, где нужно скрыть origin-IP полностью (даже за CF proxy),
- CI/dev-инстансов, где открывать порты не хочется.

`cloudflared tunnel` устанавливает исходящее соединение с edge Cloudflare, и весь входящий трафик идёт по этому туннелю — публичные порты на origin не нужны.

**Ключевые преимущества:**
- Оба режима живут в одном репо, переключение одним env-флагом + `make restart`.
- Сервисные лейблы Traefik mode-agnostic — регистрация сервиса выглядит одинаково в обоих режимах.
- В tunnel-режиме: никаких `CF_DNS_API_TOKEN` / ACME / Let's Encrypt / IP-allowlist'а. Минимум движущихся частей.
- Конфиг tunnel'я полностью remote-managed (Zero Trust dashboard) → в репо не попадают `credentials.json`, `cert.pem` и т.п.
- Docker labels как единственный интерфейс добавления новых сервисов сохраняется.

## Context (from discovery)

**Файлы, изменяемые в этом плане:**
- `docker-compose.yml` — профили для `cf-ip-updater`/`cloudflared`, интерполируемый путь к static-config, очистка dashboard-лейблов.
- `Makefile` — чтение `INGRESS_MODE` из `.env`, динамический выбор compose-файлов, новый target `init-tunnel`, гейтинг direct-only команд.
- `.env.example` — новые переменные (`INGRESS_MODE`, `COMPOSE_PROFILES`, `TUNNEL_TOKEN`, `CLOUDFLARED_IMAGE_TAG`), пометка direct-only переменных.
- `examples/whoami/docker-compose.yml` — миграция с 9 лейблов на 5 (mode-agnostic).
- `CLAUDE.md` — секции Overview, Ingress Modes (новая), Commands, Architecture, Registering a New Service, Environment Setup.
- `README.md` — секция Choosing an Ingress Mode (новая), Quickstart, шаблон лейблов.

**Файлы переименовываются/создаются:**
- `traefik/traefik.yml` → `traefik/traefik.direct.yml` (единственное смысловое изменение — переименование entrypoint `websecure` → `public`; TLS-конфиг в `entryPoints.*.http.tls` уже централизован в текущем файле, его не нужно «переносить»).
- `traefik/traefik.tunnel.yml` — новый, минимальный (`public:80` без TLS/ACME/middleware).
- `docker-compose.tunnel.yml` — новый overlay (`ports: !reset []` для traefik'а).
- `docs/ingress-tunnel.md` — новый, walkthrough по настройке CF Zero Trust dashboard.

**Наблюдение про текущий label-schema:** лейблы `tls=true`, `tls.certresolver=cloudflare`, `tls.domains[0].main/sans` в `docker-compose.yml` (dashboard) и `examples/whoami` сейчас **избыточны** — entrypoint `websecure` уже несёт полный TLS-конфиг в static-file'е, и router'ы на этом entrypoint автоматически получают TLS. Поэтому удаление этих лейблов — не потеря функциональности, а уборка мёртвого кода, который случайно работал и дублировался по историческим причинам.

**Файлы БЕЗ изменений:**
- `traefik/dynamic/cloudflare-ips.yml` — в direct-режиме используется, в tunnel-режиме определён middleware никто не ссылается (безвредно).
- `traefik/dynamic/tls.yml` — аналогично.
- `scripts/update-cf-ips.sh` — скрипт без изменений.
- `cf-ip-updater/` — код sidecar'а без изменений, только добавляется profile.

**Обнаруженные паттерны (наследуются из проекта):**
- Docker label-based service discovery через Traefik.
- Compose-файл с env-интерполяцией и дефолтами через `${VAR:-default}`.
- Ручные E2E smoke-тесты (в проекте нет автотестов — см. `20260415-cf-ip-updater-sidecar.md`).
- Документация в русско-английской технической смеси.

**Зависимости:**
- Новая runtime-зависимость: образ `cloudflare/cloudflared:latest` (~30 MB). Тянется только в tunnel-режиме (profile gating).
- Внешняя зависимость: Cloudflare Zero Trust account (бесплатный tier достаточен) + один раз настроенный tunnel в dashboard.

## Development Approach

- **Testing approach:** Regular (ручное E2E). Автотестов в проекте нет — следую паттерну `cf-ip-updater` плана: ручной smoke-чек-лист покрывает оба режима и переключение.
- Каждая задача выполняется полностью до перехода к следующей.
- Маленькие фокусные изменения; между задачами держим репо в рабочем состоянии (после Task 1 текущий `make up` в direct-режиме должен работать без изменений).
- Сохранять backward compatibility: `make up` без правки `.env` работает ровно как сейчас (direct mode).
- Миграция существующих deployed-сервисов — отдельный документированный шаг (не в scope этого плана, но с заметкой в README).

## Testing Strategy

- **Unit tests:** неприменимо (инфраструктурные изменения — compose/Makefile/YAML).
- **E2E tests (ручные):** один задача-чек-лист в конце (Task 8) с тремя секциями:
  1. **Direct mode regression** — поведение как было, ничего не сломалось.
  2. **Tunnel mode new behavior** — новый режим работает end-to-end.
  3. **Mode switching** — переключение в обе стороны без правки лейблов сервисов.
- Каждая задача, вносящая runtime-изменения, заканчивается пунктом «`make config` валиден» как быстрая sanity-проверка.

## Progress Tracking

- Отмечать выполненные пункты `[x]` сразу после завершения.
- Новые обнаруженные задачи — с префиксом ➕.
- Блокеры — с префиксом ⚠️.
- Обновлять план, если реализация отклоняется от изначального замысла.

## What Goes Where

- **Implementation Steps** (`[ ]`): правки в файлах репо, локальные sanity-проверки (`make config`), ручные E2E на dev-инстансе.
- **Post-Completion** (без чекбоксов): боевой деплой, настройка tunnel'я в CF Zero Trust dashboard на prod-аккаунте, миграция уже задеплоенных сервисов на новую label-схему.

## Implementation Steps

### Task 1: Переименовать entrypoint `websecure` → `public` в static-config

**Files:**
- Rename: `traefik/traefik.yml` → `traefik/traefik.direct.yml`
- Modify: `traefik/traefik.direct.yml` (после переименования)
- Modify: `docker-compose.yml` (временные точечные правки для ссылок на entrypoint)

Цель задачи — привести entrypoint к mode-neutral имени `public`. TLS-конфиг на entrypoint (certResolver, domains) **остаётся без изменений** — он уже там, переносить ничего не нужно.

- [ ] `git mv traefik/traefik.yml traefik/traefik.direct.yml`
- [ ] в `traefik.direct.yml` переименовать ключ entrypoint'а `websecure:` → `public:` в секции `entryPoints` (address `:443`, блок `http.tls`, middleware `cloudflare-only@file` — всё это остаётся на своих местах, только имя секции меняется)
- [ ] обновить редирект в entrypoint `web`: `to: websecure` → `to: public`
- [ ] остальные секции (`api`, `log`, `accessLog`, `providers`, `certificatesResolvers`, `global`) не трогать
- [ ] в `docker-compose.yml` временно обновить volume-монтирование: `./traefik/traefik.direct.yml:/etc/traefik/traefik.yml:ro` (жёстко, без интерполяции — на этом шаге ещё нет `INGRESS_MODE`)
- [ ] в `docker-compose.yml` обновить лейбл dashboard'а: `entrypoints=websecure` → `entrypoints=public`; **не трогать пока** `tls.*` лейблы dashboard'а (этим займётся Task 3)
- [ ] `make config` валиден (без ошибок парсинга)
- [ ] `make down && make up && make logs` — Traefik стартует, нет ошибок про неизвестные entrypoints; `curl -k https://traefik.$DOMAIN` с валидными credentials отвечает 200 (dashboard)

### Task 2: Создать `traefik.tunnel.yml`

**Files:**
- Create: `traefik/traefik.tunnel.yml`

- [ ] создать минимальный static-config: `entryPoints.public.address=":80"` (без TLS, без middleware)
- [ ] добавить те же `api`, `log`, `accessLog`, `providers` блоки что и в `traefik.direct.yml`
- [ ] НЕ добавлять `certificatesResolvers` (в tunnel-режиме ACME не нужен)
- [ ] НЕ добавлять entrypoint `web` (http→https редирект делает CF edge)
- [ ] добавить шапочный комментарий «Used when INGRESS_MODE=tunnel. Plain HTTP on :80, TLS terminates at CF edge. No ACME, no IP allowlist, no HTTP→HTTPS redirect (CF handles it)»
- [ ] sanity: валидность YAML — `python3 -c 'import yaml, sys; yaml.safe_load(open("traefik/traefik.tunnel.yml"))'` (exit 0 = валиден)
- [ ] полная валидация через Traefik произойдёт позже, когда Task 4 подключит интерполяцию `${INGRESS_MODE}` и можно будет запустить `INGRESS_MODE=tunnel make config` — на этом шаге достаточно YAML-валидности

### Task 3: Убрать избыточные `tls.*` лейблы с dashboard-роутера

**Files:**
- Modify: `docker-compose.yml`

Цель — удалить лейблы, которые дублируют то, что уже есть в entrypoint-конфиге `public`. В direct-режиме entrypoint `public` уже несёт `http.tls.{certResolver, domains}`, поэтому per-router'ные `tls.*` избыточны (работали они параллельно, но функционально бесполезны). В tunnel-режиме entrypoint TLS не имеет, и эти лейблы сломали бы dashboard.

- [ ] в `docker-compose.yml` удалить из лейблов dashboard'а следующие 4 лейбла:
  - `traefik.http.routers.dashboard.tls=true`
  - `traefik.http.routers.dashboard.tls.certresolver=cloudflare`
  - `traefik.http.routers.dashboard.tls.domains[0].main=${DOMAIN}`
  - `traefik.http.routers.dashboard.tls.domains[0].sans=*.${DOMAIN}`
- [ ] оставить `entrypoints=public` (уже переименовано в Task 1)
- [ ] `make config` валиден
- [ ] `make down && make up` — dashboard доступен через `https://traefik.$DOMAIN` с basic-auth, сертификат валиден (direct mode continues working); TLS на dashboard теперь обеспечивается только entrypoint-конфигом

### Task 4: Ввести `INGRESS_MODE` и интерполируемый путь к static-config

**Files:**
- Modify: `docker-compose.yml`
- Modify: `.env.example`

**Механизм gating'а Cloudflare-специфичных переменных:** в tunnel-режиме Traefik загружает `traefik.tunnel.yml`, который **не ссылается** на `CF_DNS_API_TOKEN` / `ACME_EMAIL` / `ACME_CA_SERVER` — именно это и есть механизм gating'а, а не пустые дефолты в compose-файле. Фолбэки `${VAR:-}` в `environment:` нужны только для того, чтобы docker-compose не ругался на неопределённые переменные при парсинге YAML (не для runtime-безопасности).

- [ ] в `docker-compose.yml`: заменить `./traefik/traefik.direct.yml:/etc/traefik/traefik.yml:ro` на `./traefik/traefik.${INGRESS_MODE:-direct}.yml:/etc/traefik/traefik.yml:ro`
- [ ] сделать опциональными env-переменные traefik'а (для compose-parsing в tunnel-режиме, когда пользователь не заполнил их в `.env`): `CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN:-}`, `ACME_EMAIL=${ACME_EMAIL:-}`, `ACME_CA_SERVER=${ACME_CA_SERVER:-}`
- [ ] в `.env.example` добавить в шапку:
  ```
  # Ingress mode: direct (public 443 + CF IP allowlist) or tunnel (cloudflared outbound)
  INGRESS_MODE=direct
  # Activates the compose profile matching INGRESS_MODE.
  # DO NOT edit directly — always keep it equal to INGRESS_MODE above.
  # (Exists because docker compose reads COMPOSE_PROFILES from .env natively,
  # while Makefile only needs INGRESS_MODE. This keeps `docker compose` commands
  # working without going through the Makefile.)
  COMPOSE_PROFILES=${INGRESS_MODE}
  ```
- [ ] в `.env.example` пометить `CF_DNS_API_TOKEN`, `ACME_EMAIL`, `ACME_CA_SERVER` комментарием `# direct mode only`
- [ ] `make config` валиден с `INGRESS_MODE=direct` (проверить что подставляется `traefik.direct.yml`)
- [ ] `make config` валиден с `INGRESS_MODE=tunnel` (проверить что подставляется `traefik.tunnel.yml`) — файл уже существует после Task 2
- [ ] `make down && make up` в direct-режиме — работает как до изменений

### Task 5: Добавить compose profiles и cloudflared-сервис

**Files:**
- Modify: `docker-compose.yml`
- Create: `docker-compose.tunnel.yml`

- [ ] в `docker-compose.yml` → сервис `cf-ip-updater`: добавить `profiles: ["direct"]`
- [ ] в `docker-compose.yml` добавить новый сервис:
  ```yaml
  cloudflared:
    profiles: ["tunnel"]
    image: cloudflare/cloudflared:${CLOUDFLARED_IMAGE_TAG:-latest}
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
    networks:
      - traefik_webgateway
    depends_on:
      - traefik
  ```
- [ ] в `.env.example` добавить:
  ```
  # Tunnel mode only: token from CF Zero Trust dashboard (Networks → Tunnels → your tunnel)
  TUNNEL_TOKEN=
  # cloudflared image pin (optional, default: latest)
  CLOUDFLARED_IMAGE_TAG=latest
  ```
- [ ] создать `docker-compose.tunnel.yml` с содержимым:
  ```yaml
  services:
    traefik:
      ports: !reset []
  ```
- [ ] sanity: `INGRESS_MODE=direct COMPOSE_PROFILES=direct docker compose config` — содержит `traefik` и `cf-ip-updater`, НЕ содержит `cloudflared`
- [ ] sanity: `INGRESS_MODE=tunnel COMPOSE_PROFILES=tunnel docker compose -f docker-compose.yml -f docker-compose.tunnel.yml config` — содержит `traefik` и `cloudflared`, НЕ содержит `cf-ip-updater`, `traefik.ports` пустой

### Task 6: Обновить Makefile под оба режима

**Files:**
- Modify: `Makefile`

- [ ] добавить в самое начало:
  ```makefile
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
  ```
  (`-include` вместо `include` — чтобы `make` не падал, если `.env` отсутствует на свежем клоне; `$(error ...)` ловит опечатки вроде `INGRESS_MODE=tunel` до запуска docker)
- [ ] заменить все прямые вызовы `docker compose` в таргетах на `$(DC)`:
  - `up`: `@$(DC) up -d`
  - `down`: `@$(DC) down`
  - `restart`: `@$(DC) restart traefik`
  - `logs`: `@$(DC) logs -f`
  - `ps`: `@$(DC) ps`
  - `config`: `@$(DC) config`
- [ ] обновить `init` — сделать mode-aware (tunnel-ветка реализует негативный тест «пустой TUNNEL_TOKEN → fail fast» из Task 8):
  ```makefile
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
  ```
- [ ] добавить новый target `init-tunnel`:
  ```makefile
  init-tunnel:
  	@echo "Tunnel mode bootstrap (one-time manual steps):"
  	@echo "  1. Open https://one.dash.cloudflare.com/ → Networks → Tunnels → Create a tunnel → Cloudflared"
  	@echo "  2. Name it (e.g. 'api-gateway'), copy the TUNNEL TOKEN, paste into .env as TUNNEL_TOKEN=..."
  	@echo "  3. In the same tunnel, Public Hostnames tab → Add a public hostname:"
  	@echo "       Subdomain: *"
  	@echo "       Domain:    $${DOMAIN:-<your-domain>}"
  	@echo "       Service:   http://traefik:80"
  	@echo "  4. Set INGRESS_MODE=tunnel in .env (and COMPOSE_PROFILES=tunnel)"
  	@echo "  5. Run 'make init && make up'"
  	@echo ""
  	@echo "See docs/ingress-tunnel.md for a detailed walkthrough."
  ```
- [ ] гейтить direct-only таргеты:
  ```makefile
  reset-certs:
  ifneq ($(INGRESS_MODE),direct)
  	@echo "reset-certs is only meaningful in direct mode (current: $(INGRESS_MODE))"; exit 1
  endif
  	# ... existing body ...

  update-cf-ips:
  ifneq ($(INGRESS_MODE),direct)
  	@echo "update-cf-ips is only meaningful in direct mode (current: $(INGRESS_MODE))"; exit 1
  endif
  	@scripts/update-cf-ips.sh
  ```
- [ ] добавить `init-tunnel` в `.PHONY`
- [ ] проверка: без `.env` — `make up` не падает на этапе `-include` (no-op), использует `INGRESS_MODE=direct` по умолчанию
- [ ] проверка: с `INGRESS_MODE=tunnel` в `.env` — `make config` показывает конфиг с overlay-файлом

### Task 7: Обновить `examples/whoami/docker-compose.yml` и шаблон лейблов

**Files:**
- Modify: `examples/whoami/docker-compose.yml`

Цель — обновить пример под новую 5-label схему. Ключевое для миграции: меняется **имя entrypoint** (`websecure` → `public`) — это breaking change для всех deployed-сервисов. Удаление `tls.*` лейблов — уборочная работа (они уже избыточны с entrypoint-TLS и раньше).

Поведение в обоих режимах после миграции:
- **Direct mode:** entrypoint `public` имеет `http.tls` → роутер автоматически HTTPS, браузер ↔ Traefik через TLS, Traefik ↔ сервис по HTTP через docker network.
- **Tunnel mode:** entrypoint `public` без TLS → роутер HTTP-only, TLS терминируется на CF edge, cloudflared → Traefik → сервис весь путь по HTTP. Для сервиса это прозрачно — лейблы идентичны.

- [ ] заменить текущие 9 лейблов на 5:
  ```yaml
  labels:
    - "traefik.enable=true"
    - "traefik.docker.network=traefik_webgateway"
    - "traefik.http.routers.whoami.rule=Host(`whoami.${DOMAIN}`)"
    - "traefik.http.routers.whoami.entrypoints=public"
    - "traefik.http.services.whoami.loadbalancer.server.port=80"
  ```
- [ ] добавить шапочный комментарий перед `labels:`:
  ```
  # Mode-agnostic labels: this example works unchanged in both INGRESS_MODE=direct and tunnel.
  # In direct mode, Traefik terminates TLS via the 'public' entrypoint's http.tls block.
  # In tunnel mode, CF edge terminates TLS; cloudflared → Traefik → service is all HTTP.
  ```
- [ ] проверка в direct-режиме: `cd examples/whoami && docker compose up -d`, затем `curl -k https://whoami.$DOMAIN` → 200 OK с телом от whoami
- [ ] `docker compose -f examples/whoami/docker-compose.yml down`

### Task 8: Ручные E2E smoke-тесты (оба режима + переключение)

**Files:**
- Modify (временно): `.env`

**Direct mode regression (должно работать как раньше):**
- [ ] `INGRESS_MODE=direct` (или не установлен) в `.env`, `make init && make down && make up`
- [ ] `docker compose ps` — `traefik` + `cf-ip-updater` запущены, `cloudflared` отсутствует
- [ ] `docker compose logs traefik | head -30` — нет ошибок, ACME работает (либо сразу валидный сертификат от staging/prod)
- [ ] из внешнего интернета: `curl -k https://whoami.$DOMAIN` (после `make up` whoami-примера) → 200 OK
- [ ] из внешнего интернета в обход CF (по IP хоста, через `curl --resolve whoami.$DOMAIN:443:<HOST_IP>`) → заблокировано (connection reset / 403) благодаря `cloudflare-only` middleware
- [ ] `https://traefik.$DOMAIN` — dashboard отвечает, basic-auth работает, сертификат валиден

**Tunnel mode (новое поведение):**
- [ ] создать tunnel в CF Zero Trust dashboard (см. `make init-tunnel`), скопировать `TUNNEL_TOKEN`, добавить catch-all public hostname `*.<DOMAIN> → http://traefik:80`
- [ ] в `.env` поставить `INGRESS_MODE=tunnel`, `COMPOSE_PROFILES=tunnel`, `TUNNEL_TOKEN=<копия>`
- [ ] `make down && make init && make up`
- [ ] `docker compose ps` — `traefik` + `cloudflared` запущены, `cf-ip-updater` отсутствует
- [ ] `docker compose logs cloudflared | grep -E "Registered tunnel connection|Connection [0-9]+ registered"` — tunnel подключён к ≥2 edge-локациям
- [ ] на хосте: `ss -tln | awk '$4 ~ /:(80|443)$/'` → **пусто** (порты не биндятся)
- [ ] из внешнего интернета: `curl https://whoami.$DOMAIN` → 200 OK (TLS терминируется на CF edge, Traefik получает HTTP от cloudflared)
- [ ] `https://traefik.$DOMAIN` — dashboard отвечает через tunnel, basic-auth работает
- [ ] `docker compose logs traefik | grep -i error` → пусто (нет ошибок про missing ACME / CF_DNS_API_TOKEN, т.к. в `traefik.tunnel.yml` они не упоминаются)

**Mode switching:**
- [ ] `INGRESS_MODE=tunnel → direct` в `.env`, `make down && make up`, без изменений в whoami-сервисе → `curl -k https://whoami.$DOMAIN` всё ещё 200 OK
- [ ] `INGRESS_MODE=direct → tunnel` обратно, `make down && make up` → `curl https://whoami.$DOMAIN` 200 OK
- [ ] лейблы в `examples/whoami/docker-compose.yml` не менялись между переключениями — это и есть главный UX-инвариант

**Negative tests:**
- [ ] `INGRESS_MODE=tunnel`, `TUNNEL_TOKEN` пустой в `.env`: `make init` → выводит понятную ошибку и exit 1
- [ ] `INGRESS_MODE=tunnel`, `make reset-certs` → выводит «только в direct-режиме», exit 1
- [ ] `INGRESS_MODE=tunnel`, `make update-cf-ips` → то же поведение

### Task 9: Обновить CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] в «Project Overview» добавить предложение: «Supports two ingress modes: **direct** (public IP:443 + Let's Encrypt + CF IP allowlist — default) and **tunnel** (outbound cloudflared tunnel, no public ports needed).»
- [ ] добавить новую секцию «Ingress Modes» перед «Common Commands» с таблицей:
  ```
  | Aspect               | direct                              | tunnel                        |
  |----------------------|-------------------------------------|-------------------------------|
  | Public ports         | 80/443 open on host                 | none                          |
  | TLS termination      | Traefik (Let's Encrypt via CF DNS)  | CF edge                       |
  | Origin IP exposure   | visible to CF, allowlisted          | hidden                        |
  | Required env vars    | CF_DNS_API_TOKEN, ACME_EMAIL        | TUNNEL_TOKEN                  |
  | Traefik ↔ service    | HTTP on docker network              | HTTP on docker network (same) |
  | cloudflared ↔ Traefik| —                                   | HTTP on docker network        |
  | Dashboard config     | —                                   | CF Zero Trust (one catch-all) |
  ```
- [ ] в «Common Commands» добавить `make init-tunnel` с пояснением; пометить `make reset-certs`/`make update-cf-ips` как direct-only
- [ ] в «Environment Setup» добавить колонку «Mode» (values: `both` / `direct` / `tunnel`) — пометить: `INGRESS_MODE`/`COMPOSE_PROFILES` — both; `CF_DNS_API_TOKEN`/`ACME_EMAIL`/`ACME_CA_SERVER` — direct; `TUNNEL_TOKEN`/`CLOUDFLARED_IMAGE_TAG` — tunnel; `DOMAIN`/`DASHBOARD_AUTH` — both
- [ ] в «Architecture» обновить ASCII-дерево: `traefik.yml` → `traefik.direct.yml` + `traefik.tunnel.yml`, добавить `docker-compose.tunnel.yml`, упомянуть опциональный `cloudflared` сервис
- [ ] в «Registering a New Service» переписать пример на 5-label схему (entrypoint=public, без tls.*), добавить явную заметку: «TLS is centralized on the `public` entrypoint in `traefik/traefik.<mode>.yml`. Services should not declare `tls.*` labels — they're redundant in direct mode (harmless) and incompatible with tunnel mode's HTTP-only entrypoint (router will be dropped).»
- [ ] в «Dynamic Config Reloading» добавить: в tunnel-режиме `cloudflare-ips.yml` и `tls.yml` остаются в `dynamic/`, но не используются (`cloudflare-only` middleware не применяется ни к одному entrypoint'у)

### Task 10: Обновить README.md + создать `docs/ingress-tunnel.md`

**Files:**
- Modify: `README.md`
- Create: `docs/ingress-tunnel.md`

- [ ] в README добавить секцию «Choosing an Ingress Mode» (перед Quickstart) с двумя подразделами:
  - **Direct (default)** — когда использовать: белый IP есть, 80/443 открыты, нужно классическое CF-proxy + Let's Encrypt.
  - **Tunnel** — когда использовать: нет белого IP / NAT, не хочется открывать порты, или хочется полностью скрыть origin-IP. Ссылка на `docs/ingress-tunnel.md`.
- [ ] в README Quickstart разделить на два подпункта: «Direct mode setup» (текущий flow) и «Tunnel mode setup» (→ `make init-tunnel`, заполнить `TUNNEL_TOKEN`, `make up`)
- [ ] в README обновить «Registering a New Service» — тот же 5-label шаблон что и в CLAUDE.md
- [ ] в README добавить подсекцию «Migrating from pre-tunnel-mode label schema» с чётким разделением: «Rename `entrypoints=websecure` → `entrypoints=public` — обязательно, иначе сервис станет недоступен. Удаление `tls.*` лейблов — обязательно перед переключением в tunnel-режим, в direct-режиме они безвредны». Ссылка на Post-Completion порядок «Шаг A / Шаг B»
- [ ] создать `docs/ingress-tunnel.md` с разделами:
  - **Overview** — что такое cloudflared tunnel, когда его использовать (1 абзац).
  - **Prerequisites** — Cloudflare account с доменом, Zero Trust (бесплатный tier OK).
  - **Step 1: Create the tunnel** — Zero Trust dashboard → Networks → Tunnels → Create a tunnel → Cloudflared → имя `api-gateway`.
  - **Step 2: Copy the token** — на следующей странице «Install connector», выбрать Docker, скопировать строку после `--token` → вставить в `.env` как `TUNNEL_TOKEN=...`.
  - **Step 3: Configure the public hostname** — вкладка Public Hostnames → Add a public hostname → Subdomain: `*`, Domain: `${DOMAIN}`, Service: `HTTP`, URL: `traefik:80`. Сохранить.
  - **Step 4: Enable tunnel mode locally** — `INGRESS_MODE=tunnel` + `COMPOSE_PROFILES=tunnel` в `.env`; `make init && make up`.
  - **Step 5: Verify** — `docker compose logs cloudflared` (Registered tunnel connection), `curl https://<subdomain>.${DOMAIN}`.
  - **Troubleshooting** — частые ошибки: пустой TUNNEL_TOKEN, забыли `COMPOSE_PROFILES`, DNS для `*.${DOMAIN}` не проксируется через CF (должен — это делается автоматически при создании public hostname).
  - **Switching back to direct mode** — `INGRESS_MODE=direct` в `.env`, `make down && make up`. DNS-записи `*.${DOMAIN}` в CF можно оставить как есть — они не мешают в direct-режиме (но tunnel-CNAME лучше удалить, иначе возможен конфликт).
- [ ] перечитать оба файла — проверить что ссылки между README и `docs/ingress-tunnel.md` корректные

### Task 11: Verify acceptance criteria

- [ ] все требования Overview выполнены:
  - есть env-флаг для переключения ✓
  - лейблы сервисов mode-agnostic ✓
  - tunnel режим не требует CF_DNS_API_TOKEN/ACME/allowlist ✓
  - конфиг tunnel'я remote-managed (ни `config.yml`, ни `credentials.json` в репо) ✓
  - docker labels остаются единственным интерфейсом добавления сервиса ✓
- [ ] edge cases покрыты:
  - `make up` без `.env` → работает в direct (регрессия) ✓
  - пустой `TUNNEL_TOKEN` в tunnel-режиме → `make init` падает с понятной ошибкой ✓
  - direct-only таргеты гейтятся ✓
  - переключение режимов без правки сервисных лейблов ✓
- [ ] все задачи Task 1-10 отмечены `[x]`
- [ ] ручные E2E из Task 8 пройдены
- [ ] `git status` — нет мусорных файлов (например, старого `traefik/traefik.yml` после rename'а)

### Task 12: Финализация плана

- [ ] `mkdir -p docs/plans/completed`
- [ ] `git mv docs/plans/20260419-ingress-tunnel-mode.md docs/plans/completed/20260419-ingress-tunnel-mode.md`
- [ ] коммит — предпочитать несколько атомарных для bisectability и возможности откатить отдельные части:
  1. `refactor: rename websecure entrypoint to public` (Task 1)
  2. `feat: add traefik.tunnel.yml static config` (Task 2)
  3. `refactor: remove redundant TLS labels from dashboard router` (Task 3)
  4. `feat: add INGRESS_MODE toggle and interpolated static-config path` (Task 4)
  5. `feat: add cloudflared service and tunnel-mode compose overlay` (Task 5)
  6. `feat: make Makefile ingress-mode aware and add init-tunnel target` (Task 6)
  7. `refactor: migrate whoami example to 5-label mode-agnostic schema` (Task 7)
  8. `docs: document ingress modes (CLAUDE, README, ingress-tunnel guide)` (Task 9-10)
  9. `docs: complete ingress-tunnel-mode plan` (Task 12)

## Technical Details

**Итоговая структура ключевых файлов:**

```
traefik/
  traefik.direct.yml     # websecure renamed to public, TLS on entrypoint, cloudflare-only middleware
  traefik.tunnel.yml     # public:80 only, no TLS/ACME/middleware
  dynamic/
    cloudflare-ips.yml   # unchanged, unused in tunnel mode
    tls.yml              # unchanged, unused in tunnel mode
docker-compose.yml       # traefik (always), cf-ip-updater (profile=direct), cloudflared (profile=tunnel)
docker-compose.tunnel.yml # overlay: traefik.ports: !reset []
Makefile                 # reads INGRESS_MODE from .env, builds $(DC) dynamically
docs/ingress-tunnel.md   # step-by-step CF dashboard walkthrough
```

**Почему `public` а не `websecure`:** имя должно быть mode-neutral. В tunnel-режиме entrypoint слушает `:80` — `websecure` было бы откровенно вводящим в заблуждение. `public` подчёркивает «внешне доступный endpoint» независимо от протокола.

**Почему TLS на entrypoint, а не на router'ах:** Traefik v3 поддерживает `entryPoints.<name>.http.tls` в static-config, и любой router на этом entrypoint автоматически использует эту TLS-конфигурацию. Это убирает 4 дублирующихся `tls.*` лейбла с каждого сервиса. В tunnel-режиме entrypoint определён без `http.tls` — и router на нём будет HTTP-only, без изменений в сервисных лейблах.

**Почему remote-managed (а не locally-managed) tunnel:** при catch-all правиле `*.${DOMAIN} → http://traefik:80` в дашборде лежит ровно одно правило, которое не меняется после первичной настройки. Новые сервисы регистрируются через Traefik labels, не касаясь дашборда. «Дрейф конфигурации», обычно являющийся минусом remote-managed, в этом сценарии отсутствует. Token-аутентификация → в репо не попадают `credentials.json` / `cert.pem`.

**Почему overlay-файл для `ports: !reset []`:** compose не позволяет условно убирать секции через env-интерполяцию. Самый чистый способ — overlay-файл, включаемый через `-f` в tunnel-режиме. Makefile это оборачивает автоматически.

**Почему `cloudflared` в сети `traefik_webgateway`:** он должен резолвить `traefik` по DNS-имени (как указано в public hostname в дашборде: `http://traefik:80`). Подключение к общей сети — самый простой способ.

**Почему `depends_on: [traefik]` у `cloudflared`:** если cloudflared стартует раньше traefik'а, первые запросы могут упасть с connection refused. `depends_on` обеспечивает порядок старта (без healthcheck — достаточно для dev, в prod tunnel переподключится сам).

**CF Zero Trust dashboard — что там настраивается (для Post-Completion):**
1. Navigate: Networks → Tunnels → Create a tunnel → Cloudflared
2. Tunnel name: `api-gateway` (свободное)
3. «Install and run a connector» → выбрать Docker → **скопировать команду или токен** (токен — это длинная base64-строка после `--token`)
4. «Route Traffic» → Public Hostnames → Add a public hostname:
   - Subdomain: `*`
   - Domain: `${DOMAIN}` (выбрать из списка — должен быть добавлен в CF account)
   - Path: `(leave empty)`
   - Service Type: `HTTP`
   - URL: `traefik:80`
5. Save. CF автоматически создаст DNS CNAME-запись `*.${DOMAIN} → <tunnel-uuid>.cfargotunnel.com`.

**Migration для уже задеплоенных сервисов (критично!):** проект сейчас только с `whoami`-примером, но если где-то используется старая 9-label схема (форк/внешние сервисы), **обязательная** миграция — это:

1. **Rename entrypoint** (критично): `entrypoints=websecure` → `entrypoints=public`. Без этого роутер не матчится ни с одним entrypoint и сервис становится недоступен — это breaking change, не опциональная уборка.
2. **Удалить 4 избыточных лейбла** (можно отложить в direct-режиме, но надо сделать до переключения в tunnel-режим):
   - `tls=true`, `tls.certresolver=cloudflare`, `tls.domains[0].main=*`, `tls.domains[0].sans=*`
   - В direct-режиме эти лейблы безвредны (дублируют entrypoint-конфиг). В tunnel-режиме они вешают `tls=true` на non-TLS entrypoint — router будет отброшен.
3. `docker compose up -d` сервиса — Traefik подхватит новые лейблы без рестарта (docker provider watches events).

**Порядок безопасного перехода:**
- **Шаг A** (в direct-режиме, после мерджа этого PR): все сервисы мигрируются на 5-label схему. В direct всё продолжает работать одинаково.
- **Шаг B**: только после того, как ВСЕ сервисы перешли на новую схему, можно переключать `INGRESS_MODE=tunnel` без сюрпризов.

Миграционная заметка добавляется в README в подсекцию «Migrating from pre-tunnel-mode label schema» (Task 10).

## Post-Completion

**Настройка CF Zero Trust на prod-аккаунте** (разовая ручная операция при первом использовании tunnel-режима):
- Создать tunnel с именем (например) `api-gateway-prod` в CF Zero Trust dashboard.
- Скопировать `TUNNEL_TOKEN` в prod `.env` (через secure-канал, не через git).
- Добавить catch-all public hostname `*.${DOMAIN} → http://traefik:80`.
- CF сам создаст `*.${DOMAIN}` DNS CNAME-запись.
- Если у домена уже есть A-запись на origin IP — она станет нерелевантна после переключения на tunnel (запросы пойдут через CNAME). Лучше удалить или оставить как failover (DNS TTL вступит в силу).

**Деплой в prod:**
- Вариант «mixed rollout» (рекомендуется при первом переходе): один prod-инстанс остаётся в direct-режиме, параллельно поднимается второй инстанс в tunnel-режиме (разный `DOMAIN`/subdomain), проверяется работоспособность, затем переключается основной инстанс.
- Вариант «in-place»: `git pull && make down && vim .env && make init && make up` — downtime ~10-30 секунд на рестарт. Подходит для некритичных окружений.

**Миграция задеплоенных сервисов на 5-label схему:**
- В момент переключения на tunnel-режим все сервисы с `tls.*` лейблами начнут игнорироваться Traefik'ом с ошибкой (TLS-лейблы на non-TLS entrypoint'е).
- Предварительно (за 1+ pull request до переключения) мигрировать всех потребителей на новую схему, оставаясь в direct-режиме — это безопасно, потому что entrypoint `public` в `traefik.direct.yml` уже конфигурирует TLS на уровне entrypoint'а, и per-router `tls.*` становятся избыточными (но не ломающими).
- После того, как все сервисы мигрированы, переключать `INGRESS_MODE=tunnel` — без сюрпризов.

**Мониторинг (опционально, вне scope):**
- `docker compose logs cloudflared` — смотреть на `Connection .* registered` для health-индикатора.
- Метрики tunnel'я доступны в CF Zero Trust dashboard → Networks → Tunnels → Metrics.
- При желании — алерт на `docker inspect cloudflared --format '{{.State.Status}}'` ≠ `running` через внешний мониторинг.
