# API Gateway on Traefik — Implementation Plan

## Overview

Создать сервис `api-gateway` — конфигурационный docker-compose проект на базе Traefik v3.1, который:

- Регистрирует другие Docker-сервисы через стандартные traefik labels (subdomain в пределах сконфигурированного базового домена).
- Терминирует HTTPS на Traefik, проксирует во внутренний HTTP сервисов.
- Глобально редиректит HTTP → HTTPS (301).
- Использует wildcard TLS `*.${DOMAIN}` от Let's Encrypt через DNS-01 challenge Cloudflare.
- Опирается на ручную wildcard A-запись в Cloudflare с proxied=true (без рантайм-вызовов CF API).
- Предоставляет защищённый basic-auth dashboard на `${DASHBOARD_SUBDOMAIN}.${DOMAIN}`.
- **Защищает origin от direct-to-origin запросов**: глобальный IP allowlist middleware пропускает только запросы, TCP-источник которых принадлежит официальным диапазонам Cloudflare (`https://www.cloudflare.com/ips-v4`, `.../ips-v6`); всё остальное → 403.

Реализация — **тонкая обёртка над Traefik**: только конфиги, compose, Makefile, README. Никакого собственного кода.

## Context (from discovery)

- Директория проекта `/Users/vadim/Workspace/projects/api-gateway-dev` пустая — чистый старт.
- Не git-репозиторий (по `environment`); будет инициализирован при первом коммите.
- Паттерн общей сети `traefik_webgateway` соответствует skill `project-python-traefik`, используемому в других проектах пользователя.
- Пользовательские проекты подключаются к сети как `external: true` и регистрируются traefik-labels.

**Files/components involved:** вся новая структура (list в Implementation Steps).

**Dependencies identified:**
- Docker + docker compose v2.
- Образ `traefik:v3.1` (pinned).
- Образ `traefik/whoami` для acceptance smoke-теста.
- Домен в Cloudflare с настроенными NS-записями.
- Cloudflare API Token c правами `Zone:DNS:Edit` + `Zone:Zone:Read`.
- Утилита `htpasswd` (из `apache2-utils`) для генерации `DASHBOARD_AUTH`.

## Development Approach

- **Testing approach**: **Acceptance/smoke-тесты** (не unit). Проект — чистая инфра-конфигурация без своего кода, поэтому TDD-цикл не применим. Вместо этого каждая задача завершается проверяемым критерием (команда + ожидаемый результат).
- Работа ведётся последовательно, по одной задаче за раз.
- Маленькие, сфокусированные изменения.
- **Каждая задача включает verification step** — конкретную команду и ожидаемый вывод. Без прохождения verification нельзя переходить к следующей задаче.
- План обновляется при изменении scope.
- Backward compatibility не применима (greenfield).

## Testing Strategy

- **Unit tests**: н/п — нет собственного кода.
- **Acceptance / smoke tests**: на этапе Task "Verify acceptance criteria" прогоняется checklist из разделов `Overview` + бизнес-критериев. Тесты выполняются вручную через `curl`, `docker compose logs`, проверку заголовков. Каждый критерий из раздела "Acceptance criteria" ниже должен пройти.
- **E2E**: н/п (нет UI).
- **Configuration validation**: `docker compose config` для валидации compose-файла; `traefik` сам логирует ошибки dynamic config при старте.

## Acceptance criteria

1. `docker compose up -d` поднимает контейнер traefik без ошибок в логах.
2. `https://${DASHBOARD_SUBDOMAIN}.${DOMAIN}` отвечает 401 без auth и 200 с корректным basic-auth; сертификат валидный (Let's Encrypt).
3. Тестовый сервис `whoami` с traefik-labels в отдельном compose-проекте доступен на `https://whoami.${DOMAIN}`.
4. `curl -I http://whoami.${DOMAIN}` → `301` на `https://whoami.${DOMAIN}`.
5. В ответе `curl -sI https://whoami.${DOMAIN}` присутствуют заголовки `cf-ray:` и `server: cloudflare` (proxying через CF работает).
6. `docker compose restart traefik` не приводит к перевыпуску сертификата (`acme.json` сохраняется между рестартами).
7. Остановка/удаление контейнера `whoami` убирает роутер из traefik dashboard в течение нескольких секунд.
8. Валидный файл `.env.example` в репозитории; `.env`, `letsencrypt/acme.json` в `.gitignore`.
9. **CF-only фильтр:** прямой запрос на публичный IP сервера (минуя CF), напр. `curl -k --resolve whoami.${DOMAIN}:443:<server-ip> https://whoami.${DOMAIN}` с произвольного non-CF хоста возвращает `403 Forbidden`. Тот же запрос через `https://whoami.${DOMAIN}` (через CF) возвращает `200 OK`.
10. `make update-cf-ips` идемпотентно обновляет файл `traefik/dynamic/cloudflare-ips.yml`; после `make restart` изменённый список применяется.

## Progress Tracking

- Отмечать завершённые пункты `[x]` сразу.
- Новые обнаруженные задачи — с префиксом ➕.
- Блокеры — с префиксом ⚠️.
- Синхронизировать план с реальным состоянием работы.

## What Goes Where

- **Implementation Steps** (`[ ]`): файлы, конфиги, документация, локальная верификация.
- **Post-Completion** (без чекбоксов): разовые ручные действия в Cloudflare UI, DNS, развёртывание на целевом сервере, ручной end-to-end прогон боевого сценария.

## Implementation Steps

### Task 1: Базовая структура репозитория и .gitignore

**Files:**
- Create: `.gitignore`
- Create: `README.md` (заглушка, наполнится в Task 8)
- Create: `docs/plans/20260415-api-gateway-traefik.md` (этот файл — уже создан)

- [ ] создать `.gitignore` со строками: `.env`, `letsencrypt/acme.json`, `*.log`, `.DS_Store`
- [ ] создать пустой `README.md` с одним заголовком `# api-gateway` (полный контент в Task 8)
- [ ] verification: `ls -la` показывает `.gitignore`, `README.md`, `docs/`; `cat .gitignore` содержит требуемые строки

### Task 2: Переменные окружения

**Files:**
- Create: `.env.example`

- [ ] создать `.env.example` со всеми переменными и комментариями:
  - `DOMAIN=example.com`
  - `ACME_EMAIL=you@example.com`
  - `CF_DNS_API_TOKEN=` (комментарий: Zone:DNS:Edit + Zone:Zone:Read)
  - `DASHBOARD_AUTH=` (комментарий: сгенерировать через `htpasswd -nbB admin '<pass>' | sed -e 's/\$/\$\$/g'`)
  - `ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory` (**ВАЖНО** в комментарии: default = staging (для тестов и отладки, сертификаты недоверенные). После успешного smoke-теста ОБЯЗАТЕЛЬНО переключить на production: `https://acme-v02.api.letsencrypt.org/directory` и выполнить `make reset-certs && make restart`. Иначе в проде будут невалидные сертификаты.)
  - `LOG_LEVEL=INFO`
  - `DASHBOARD_SUBDOMAIN=traefik`
  - `HTTP_PORT=80`
  - `HTTPS_PORT=443`
  - `NETWORK_NAME=traefik_webgateway`
- [ ] verification: `cat .env.example` — все 9 переменных присутствуют

### Task 3: Static config traefik.yml

**Files:**
- Create: `traefik/traefik.yml`

- [ ] создать `traefik/traefik.yml` со следующими секциями:
  - `global`: `checkNewVersion: false`, `sendAnonymousUsage: false`
  - `log`: level из env (`${LOG_LEVEL}` — в Traefik static config env подставляются через environment в compose), format JSON
  - `accessLog`: format JSON, output stdout
  - `api`: `dashboard: true`, `insecure: false`
  - `entryPoints.web`: address `:80`, `http.redirections.entryPoint.to=websecure`, `scheme=https`, `permanent=true`
  - `entryPoints.websecure`: address `:443`, дефолтный tls с `certResolver=cloudflare`, `domains` с `main=${DOMAIN}` и `sans=*.${DOMAIN}`, `http.middlewares: [cloudflare-only@file]` (глобальный IP allowlist — применяется ко всем роутерам на этом entrypoint, включая dashboard)
  - `providers.docker`: `endpoint=unix:///var/run/docker.sock`, `exposedByDefault=false`, `network=traefik_webgateway`, `watch=true`
  - `providers.file`: `directory=/etc/traefik/dynamic`, `watch=true`
  - `certificatesResolvers.cloudflare.acme`:
    - `email`, `storage=/letsencrypt/acme.json`, `caServer` — все из env
    - `dnsChallenge.provider=cloudflare`
    - `dnsChallenge.resolvers=[1.1.1.1:53, 8.8.8.8:53]`
- [ ] verification: `docker run --rm -v $(pwd)/traefik/traefik.yml:/etc/traefik/traefik.yml traefik:v3.1 traefik --configfile=/etc/traefik/traefik.yml --help` проходит без синтаксических ошибок (выводит help)

### Task 4: Dynamic config — middlewares и TLS options

**Решение по env-подстановке (ранее был open question):** Traefik dynamic YAML **не выполняет env-подстановку**. Поэтому `dashboard-auth` middleware определяется **не в файле, а через labels на самом traefik-контейнере** в `docker-compose.yml` (Task 5) — там labels проходят через env-интерполяцию compose. Dynamic YAML-файлы используются только для статических элементов без секретов: TLS options и список CIDR Cloudflare.

**Files:**
- Create: `traefik/dynamic/tls.yml`
- Create: `traefik/dynamic/cloudflare-ips.yml` (заполняется командой `make update-cf-ips`)

- [ ] создать `traefik/dynamic/tls.yml`:
  - `tls.options.default`: `minVersion=VersionTLS12`, `cipherSuites` — современный набор (ECDHE+AES-GCM, ECDHE+CHACHA20).
  - `tls.options.default.sniStrict=false`.
- [ ] создать заготовку `traefik/dynamic/cloudflare-ips.yml`:
  - `http.middlewares.cloudflare-only.ipAllowList.sourceRange` — список CIDR (v4 + v6).
  - **`ipStrategy` НЕ задавать** — тогда проверяется RemoteAddr (TCP peer), а не `X-Forwarded-For`. Это корректно: весь HTTPS трафик на websecure приходит через **один хоп** от CF edge, поэтому source IP TCP-connection = CF edge IP. Если указать `depth: 1`, Traefik вместо peer'а будет брать последний IP из `X-Forwarded-For`, который клиент может подделать. Документировать это как комментарий в сгенерированном файле.
  - **Consistency guarantee:** имя middleware `cloudflare-only` должно точно совпадать с ссылкой `cloudflare-only@file` в `traefik.yml` (Task 3). См. Task 4b verification на grep trio.
  - Заполнение списка — отдельной Task (см. Task 4b).
- [ ] verification: после Task 5 → `docker compose up -d && docker compose logs traefik 2>&1 | grep -iE "error"` — не должно быть ERROR при парсинге dynamic.

### Task 4b: Скрипт и Makefile-цель для обновления Cloudflare IP списка

**Files:**
- Create: `scripts/update-cf-ips.sh`
- Modify: `Makefile`
- Modify: `traefik/dynamic/cloudflare-ips.yml` (через generation)

**Почему отдельный скрипт:** сложные shell-конструкции (heredoc, pipe в середине блока) хрупки внутри Makefile из-за экранирования и `.ONESHELL` семантики. Вынос в `.sh` устраняет класс багов.

**Атомарная запись:** Traefik watches directory `/etc/traefik/dynamic`. Если писать напрямую в `cloudflare-ips.yml`, во время `curl` файл будет пустой/частичный → Traefik подхватит невалидный YAML и сломает entrypoint. Решение: писать в `.tmp`, затем `mv` (атомарный rename на POSIX).

- [ ] создать `scripts/update-cf-ips.sh` (chmod +x):
  ```sh
  #!/usr/bin/env bash
  set -euo pipefail
  OUT="traefik/dynamic/cloudflare-ips.yml"
  TMP="$(mktemp "${OUT}.XXXXXX")"
  trap 'rm -f "$TMP"' EXIT

  {
    echo "# AUTO-GENERATED by scripts/update-cf-ips.sh"
    echo "# Source: https://www.cloudflare.com/ips-v4  https://www.cloudflare.com/ips-v6"
    echo "# DO NOT EDIT MANUALLY. Re-run 'make update-cf-ips' to refresh."
    echo "http:"
    echo "  middlewares:"
    echo "    cloudflare-only:"
    echo "      ipAllowList:"
    echo "        sourceRange:"
    curl -fsSL https://www.cloudflare.com/ips-v4 | sed 's/^/          - /'
    curl -fsSL https://www.cloudflare.com/ips-v6 | sed 's/^/          - /'
  } > "$TMP"

  # basic sanity: at least one CIDR line, otherwise abort
  if ! grep -Eq '^ *- [0-9a-fA-F:.]+/[0-9]+' "$TMP"; then
    echo "ERROR: no CIDR ranges fetched — aborting, not overwriting $OUT" >&2
    exit 1
  fi

  mv "$TMP" "$OUT"
  trap - EXIT
  echo "Updated $OUT"
  ```
- [ ] добавить в Makefile цель `update-cf-ips: ; @scripts/update-cf-ips.sh`
- [ ] добавить `update-cf-ips` в `.PHONY`
- [ ] `init` цель зависит от `update-cf-ips` (выполняется только если файл ещё не существует или пустой — чтобы не бить CF endpoint при каждом init):
  ```
  init:
  	@test -s traefik/dynamic/cloudflare-ips.yml || $(MAKE) update-cf-ips
  	@docker network create $${NETWORK_NAME:-traefik_webgateway} 2>/dev/null || true
  	@mkdir -p letsencrypt && touch letsencrypt/acme.json && chmod 600 letsencrypt/acme.json
  ```
- [ ] **проверка консистентности имени middleware** (требование из review round 2): имя `cloudflare-only` должно быть идентично в трёх местах:
  - `traefik/traefik.yml` → `entryPoints.websecure.http.middlewares: [cloudflare-only@file]`
  - `scripts/update-cf-ips.sh` → `echo "    cloudflare-only:"`
  - `traefik/dynamic/cloudflare-ips.yml` → `http.middlewares.cloudflare-only:` (result of script)
  Добавить в README раздел Troubleshooting пункт "если middleware не применяется — проверить grep этих трёх мест на одно и то же имя".
- [ ] verification:
  - `./scripts/update-cf-ips.sh && head -20 traefik/dynamic/cloudflare-ips.yml` — видим шапку и ≥3 CIDR
  - `grep "cloudflare-only" traefik/traefik.yml traefik/dynamic/cloudflare-ips.yml scripts/update-cf-ips.sh` — три совпадения
  - повторный запуск идемпотентен (файл перезаписывается тем же контентом; diff может показывать изменения только если CF реально обновил диапазоны)
  - симулировать "поломку": `scripts/update-cf-ips.sh` запущенный без интернета должен оставить старый файл нетронутым (проверка: создать файл, отключить сеть, запустить → `exit 1`, старый файл на месте).

### Task 5: docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

- [ ] объявить service `traefik`:
  - `image: traefik:v3.1`
  - `restart: unless-stopped`
  - `ports`: `${HTTP_PORT}:80`, `${HTTPS_PORT}:443`
  - `volumes`: `/var/run/docker.sock:/var/run/docker.sock:ro`, `./traefik/traefik.yml:/etc/traefik/traefik.yml:ro`, `./traefik/dynamic:/etc/traefik/dynamic:ro`, `./letsencrypt:/letsencrypt` (файл `acme.json` должен существовать с chmod 600 ДО запуска — создаётся в `make init`)
  - `environment`: `CF_DNS_API_TOKEN`, `LOG_LEVEL`, `DOMAIN`, `ACME_EMAIL`, `ACME_CA_SERVER`, `DASHBOARD_AUTH` (все из `.env` через `${VAR}`)
  - `networks`: `traefik_webgateway`
  - `labels` (dashboard router):
    - `traefik.enable=true`
    - `traefik.docker.network=${NETWORK_NAME}`
    - `traefik.http.routers.dashboard.rule=Host(\`${DASHBOARD_SUBDOMAIN}.${DOMAIN}\`)`
    - `traefik.http.routers.dashboard.entrypoints=websecure`
    - `traefik.http.routers.dashboard.tls=true`
    - `traefik.http.routers.dashboard.tls.certresolver=cloudflare`
    - `traefik.http.routers.dashboard.tls.domains[0].main=${DOMAIN}`
    - `traefik.http.routers.dashboard.tls.domains[0].sans=*.${DOMAIN}`
    - `traefik.http.routers.dashboard.service=api@internal`
    - `traefik.http.middlewares.dashboard-auth.basicauth.users=${DASHBOARD_AUTH}` (middleware определён прямо в labels — compose подставит значение из `.env`)
    - `traefik.http.routers.dashboard.middlewares=dashboard-auth@docker`
- [ ] объявить секцию `networks`:
  - `traefik_webgateway`: `external: true`, `name: ${NETWORK_NAME}`
- [ ] verification: `docker compose config` проходит без ошибок, показывает корректно распарсенный YAML с подставленными env.

### Task 6: Makefile

**Files:**
- Create: `Makefile`

- [ ] цели:
  - `init` — `docker network create ${NETWORK_NAME:-traefik_webgateway} || true`; `mkdir -p letsencrypt && touch letsencrypt/acme.json && chmod 600 letsencrypt/acme.json`; **также зависит от `update-cf-ips`** (см. Task 4b)
  - `up` — `docker compose up -d`
  - `down` — `docker compose down`
  - `restart` — `docker compose restart traefik`
  - `logs` — `docker compose logs -f traefik`
  - `ps` — `docker compose ps`
  - `config` — `docker compose config`
  - `reset-certs` — с подтверждением: `rm -f letsencrypt/acme.json && touch letsencrypt/acme.json && chmod 600 letsencrypt/acme.json`
- [ ] `.PHONY` для всех целей
- [ ] verification: `make -n up` показывает команду без выполнения; `make init` идемпотентно (повторный запуск не падает).

### Task 7: Первый smoke-тест (staging ACME)

**Files:**
- Modify: `.env` (локально, не коммитить)
- Create: `examples/whoami/docker-compose.yml`

**Преусловия (проверить ДО запуска):**
- В Cloudflare UI создана DNS-запись `* A → <публичный IP сервера>` со статусом `Proxied` (оранжевое облако). Без этого ни DNS-01 challenge не пройдёт, ни внешний трафик не попадёт на сервер.
- SSL/TLS mode в CF установлен `Full (strict)`.
- Порты 80/443 открыты на сервере (firewall / security group).

- [ ] скопировать `.env.example` → `.env`, заполнить реальными значениями
- [ ] **валидация CF API token** до запуска:
  ```
  curl -sX GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer $CF_DNS_API_TOKEN" | grep -q '"status":"active"' && echo OK || echo FAIL
  ```
  Должно вывести `OK`. Если `FAIL` — проверить scope токена (Zone:DNS:Edit + Zone:Zone:Read).
- [ ] убедиться что `ACME_CA_SERVER` указывает на staging URL
- [ ] создать `examples/whoami/docker-compose.yml` (тестовый сервис для smoke-теста) с labels по шаблону из Technical Details, используя `image: traefik/whoami`, имя router/service = `whoami`, subdomain = `whoami`, `loadbalancer.server.port=80`, network `traefik_webgateway` external
- [ ] `make init && make up`
- [ ] `make logs` — убедиться что traefik стартует без ERROR; ACME запрашивает wildcard сертификат от staging Let's Encrypt
- [ ] verification criterion 1: контейнер healthy; `docker compose ps` показывает `running`
- [ ] verification criterion 2: `curl -k https://${DASHBOARD_SUBDOMAIN}.${DOMAIN}/dashboard/` → 401 без auth, 200 с `-u admin:pass` (сертификат от staging, поэтому `-k`)
- [ ] переключить `ACME_CA_SERVER` на production, `make reset-certs && make restart`
- [ ] verification criterion 2 (prod): тот же curl без `-k` — валидный сертификат
- [ ] поднять тестовый сервис whoami: `cd examples/whoami && docker compose up -d`
- [ ] verification criteria 3–7 из раздела Acceptance criteria (curl 301, cf-ray header, restart без перевыпуска, удаление убирает роутер)
- [ ] verification criterion 9 (CF-only фильтр):
  - **Важно: тест запускать с ВНЕШНЕЙ машины**, не с самого сервера и не из одной с ним сети — loopback и локальные интерфейсы могут обойти проверку на уровне сети, а не middleware, что даст ложно-положительный результат.
  - С внешнего хоста:
    ```
    curl -kI --resolve whoami.${DOMAIN}:443:<public-server-ip> https://whoami.${DOMAIN}
    ```
    Ожидается `HTTP/2 403` (запрос ушёл с не-CF источника прямо на origin). Альтернативно можно использовать VPS или мобильный интернет.
  - Проверка позитивного сценария (через CF) с того же внешнего хоста: `curl -I https://whoami.${DOMAIN}` (обычный DNS резолв) → `HTTP/2 200` + заголовок `cf-ray`.
- [ ] verification criterion 10: `make update-cf-ips` отрабатывает; после этого `docker compose logs traefik | grep "Configuration loaded"` показывает успешную перезагрузку dynamic.

### Task 8: README.md — полная документация

**Files:**
- Modify: `README.md`

- [ ] раздел **Обзор**: что это, что умеет, чего не умеет (YAGNI)
- [ ] раздел **Предусловия**:
  - Cloudflare: домен делегирован (NS), wildcard A-запись `* → <server-ip>` с proxied=true, SSL/TLS mode `Full (strict)`
  - API Token: создать с правами `Zone:DNS:Edit` + `Zone:Zone:Read` на конкретную зону
  - Docker + compose v2 установлены
  - `htpasswd` установлен (`apt install apache2-utils` / `brew install httpd`)
  - команда валидации CF API token: `curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" -H "Authorization: Bearer $TOKEN"` → должна вернуть `"status":"active"`
- [ ] раздел **One-time setup**:
  - клонировать репозиторий
  - `cp .env.example .env` и заполнить
  - генерация `DASHBOARD_AUTH`: `htpasswd -nbB admin 'YourPassword' | sed -e 's/\$/\$\$/g'` (объяснить почему `$$`)
  - `make init` (создаёт сеть и acme.json)
  - первый запуск со staging, затем переключение на prod
- [ ] раздел **Запуск / управление**: `make up`, `down`, `logs`, `restart`, `reset-certs`
- [ ] добавить в README ссылку на готовый пример: `examples/whoami/docker-compose.yml` (создан в Task 7) — минимальный working reference
- [ ] раздел **Регистрация нового сервиса** — полный пример `docker-compose.yml` сервиса `myapp`:
  - комментарии построчно по labels
  - объяснение `traefik.docker.network` (важно при наличии нескольких сетей)
  - объяснение `loadbalancer.server.port` (внутренний порт приложения)
  - TLS labels с wildcard (`main=DOMAIN`, `sans=*.DOMAIN`) для переиспользования общего сертификата
  - упоминание что сервис должен быть в сети `traefik_webgateway` (external)
- [ ] раздел **Troubleshooting**:
  - сертификат не выпускается → проверить CF token права, DNS resolvers, логи ACME
  - "404 page not found" → traefik не видит контейнер: проверить `traefik.enable=true`, сеть, `exposedByDefault`
  - переход staging → prod требует `make reset-certs`
  - "403 Forbidden" на легитимном запросе → проверить что запрос идёт через CF (не напрямую по IP); обновить CF IP список через `make update-cf-ips && make restart`
  - локальный дебаг со своего IP (минуя CF) → временно убрать middleware с entrypoint или добавить свой IP в `cloudflare-ips.yml`
- [ ] раздел **Защита origin**:
  - объяснить зачем CF IP allowlist: без него origin-сервер можно обойти, зная прямой IP (CF proxying только защищает, если трафик физически идёт через CF)
  - упомянуть что middleware применяется на entrypoint `websecure` глобально → покрывает все сервисы автоматически
  - рекомендация периодически запускать `make update-cf-ips` (CF меняет диапазоны редко но регулярно); можно автоматизировать через cron
- [ ] раздел **Ограничения** (out-of-scope): нет rate-limit, нет метрик, нет multi-domain, нет HA
- [ ] verification: `grep -c "^##" README.md` ≥ 6 секций; все env из `.env.example` упомянуты в README.

### Task 9: Verify acceptance criteria (финальная проверка)

- [ ] пройти все 8 критериев из раздела **Acceptance criteria** последовательно
- [ ] зафиксировать результаты в комментарии к коммиту или в логе плана (галочками `[x]` напротив каждого критерия)
- [ ] если какой-то критерий не проходит — вернуться к соответствующей задаче, исправить, перепроверить

### Task 10: Финализация

- [ ] `git init && git add . && git status` — убедиться что `.env` и `letsencrypt/acme.json` игнорируются
- [ ] первый коммит: `feat: initial api-gateway configuration based on traefik v3.1`
- [ ] переместить этот план: `mkdir -p docs/plans/completed && git mv docs/plans/20260415-api-gateway-traefik.md docs/plans/completed/`
- [ ] коммит: `docs: mark api-gateway plan as completed`

## Technical Details

**Поток запроса:**
```
User → Cloudflare (HTTPS, proxied, CF edge cert)
      → Server:443 (HTTPS, Let's Encrypt wildcard cert, Traefik terminates TLS)
      → [entryPoint middleware: cloudflare-only ipAllowList]
        · Source IP ∈ CF ranges? → proceed
        · else                   → 403 Forbidden
      → docker network traefik_webgateway
      → container:<app-port> (plain HTTP)
```

**Поток HTTP → HTTPS redirect:**
```
User → :80 → Traefik entrypoint web → 301 → https://same-url
```

**ACME flow (один раз на wildcard, далее кеш в acme.json):**
```
Traefik → Let's Encrypt (ACME v2)
        → DNS-01 challenge: создаёт TXT _acme-challenge.example.com через Cloudflare API
        → LE проверяет TXT → issues wildcard *.example.com
        → сохраняется в /letsencrypt/acme.json
```

**Структура файлов итоговая:**
```
api-gateway-dev/
├── .env.example
├── .env                       (gitignored)
├── .gitignore
├── Makefile
├── README.md
├── docker-compose.yml
├── docs/plans/completed/20260415-api-gateway-traefik.md
├── letsencrypt/
│   └── acme.json              (gitignored, chmod 600)
├── examples/
│   └── whoami/
│       └── docker-compose.yml
└── traefik/
    ├── traefik.yml
    └── dynamic/
        ├── tls.yml
        └── cloudflare-ips.yml   (auto-generated, в git коммитится)
```

**Формат labels для регистрации сервиса (template):**
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=traefik_webgateway"
  - "traefik.http.routers.<name>.rule=Host(`<subdomain>.${DOMAIN}`)"
  - "traefik.http.routers.<name>.entrypoints=websecure"
  - "traefik.http.routers.<name>.tls=true"
  - "traefik.http.routers.<name>.tls.certresolver=cloudflare"
  - "traefik.http.routers.<name>.tls.domains[0].main=${DOMAIN}"
  - "traefik.http.routers.<name>.tls.domains[0].sans=*.${DOMAIN}"
  - "traefik.http.services.<name>.loadbalancer.server.port=<internal-port>"
```

## Post-Completion

*Пункты, требующие ручных действий вне этого репозитория — без чекбоксов.*

**Ручная настройка в Cloudflare UI:**
- делегировать домен на Cloudflare NS (если ещё не сделано)
- создать DNS-запись `*` типа A → публичный IP сервера, `Proxy status: Proxied`
- опционально: запись `@` и `www` для корневого домена
- SSL/TLS mode: `Full (strict)` для зоны
- создать API Token со scope `Zone:DNS:Edit` + `Zone:Zone:Read` для целевой зоны; записать в `.env`

**Развёртывание на целевом сервере:**
- открыть на хосте порты 80/443 во внешний мир (firewall / security group)
- разместить репозиторий на сервере, заполнить `.env`
- выполнить `make init && make up`
- добавить systemd unit или использовать `restart: unless-stopped` (уже в compose) для автозапуска после перезагрузки

**Manual verification** (после деплоя):
- проверить TLS Labs рейтинг для `https://<any-subdomain>.${DOMAIN}` (ожидаемо A+ при современных cipher suites)
- проверить что dashboard недоступен без basic-auth
- проверить что `http://...` везде редиректит на `https://...`
- проверить реальный end-to-end: поднять whoami сервис и обратиться из интернета

**External system updates**:
- н/п для первого релиза; при добавлении новых сервисов — обновлять их compose-файлы по шаблону из README
