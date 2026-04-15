# cf-ip-updater Sidecar Service

## Overview

Добавить sidecar-сервис `cf-ip-updater` в docker-compose стек, автоматически обновляющий файл `traefik/dynamic/cloudflare-ips.yml` на периодической основе (по умолчанию раз в 7 дней), заменяя ручной запуск `make update-cf-ips`.

**Решаемая проблема:** список официальных IP-диапазонов Cloudflare меняется со временем; текущая схема требует ручного запуска скрипта оператором. Без регулярного обновления IP-allowlist middleware может устареть, приводя к ложным блокировкам легитимного трафика от новых CF-узлов.

**Ключевые преимущества:**
- Zero-touch обслуживание allowlist'а.
- Переиспользование существующего `scripts/update-cf-ips.sh` (DRY — никакого дублирования).
- Нулевая инвазивность для Traefik (watcher директории `dynamic/` автоматически подхватит изменения).
- Сохранение ручного режима `make update-cf-ips` для первичной инициализации и force-refresh.

## Context (from discovery)

**Файлы, вовлечённые в изменения:**
- `docker-compose.yml` — добавить новый сервис `cf-ip-updater`.
- `.env.example` — добавить 2 новые переменные окружения.
- `CLAUDE.md` — обновить секции «Architecture» и «Environment Setup», пометить `make update-cf-ips` как force-refresh.

**Файлы БЕЗ изменений (переиспользуются как есть):**
- `scripts/update-cf-ips.sh` — монтируется read-only в контейнер.
- `Makefile` — таргет `update-cf-ips` сохраняется для ручного запуска.
- `traefik/traefik.yml` и `traefik/dynamic/*.yml` — без изменений.

**Обнаруженные паттерны:**
- Docker-compose с label-based service discovery для Traefik.
- Относительный путь `OUT="traefik/dynamic/cloudflare-ips.yml"` в shell-скрипте — требует корректного `working_dir` в контейнере.
- Sanity-check в скрипте (проверка наличия ≥1 CIDR) + атомарная замена через temp-файл + `mv` — ошибка curl не повреждает существующий файл.
- Traefik v3.1 с `providers.file.watch=true` — изменения в `dynamic/` подхватываются автоматически.

**Зависимости:**
- Никаких новых runtime-зависимостей. Sidecar использует `alpine:3.20` + устанавливает `bash curl coreutils` при старте через `apk add`.

## Development Approach

- **Testing approach:** Regular (ручное E2E). Автотесты — YAGNI для тонкой shell-обёртки над существующим скриптом; логика уже покрыта sanity-check внутри `update-cf-ips.sh`.
- Каждая задача выполняется полностью до перехода к следующей.
- Маленькие фокусные изменения.
- Для shell/compose-инфраструктуры «тесты» = ручные E2E-сценарии в отдельной задаче с чек-листом.
- Сохранять backward compatibility: `make update-cf-ips`, `make init`, существующий `.env` продолжают работать без обязательных правок.

## Testing Strategy

- **Unit tests:** неприменимо (shell-обёртка из 6 строк внутри compose-команды, логика целиком в существующем скрипте).
- **E2E tests (ручные):** отдельная задача с чек-листом сценариев:
  1. Smoke: контейнер стартует, обновляет файл при первом запуске, уходит в `sleep`.
  2. Интервал: с `CF_IPS_UPDATE_INTERVAL=60` пронаблюдать 2-3 цикла.
  3. Graceful degradation: симулировать недоступность CF — старый файл не перезаписывается, логируется ошибка, цикл продолжается.
  4. Traefik reload: после обновления `cloudflare-ips.yml` проверить перезагрузку конфига без рестарта Traefik.
  5. Регрессия: `make update-cf-ips` по-прежнему работает из хост-окружения.

## Progress Tracking

- Отмечать выполненные пункты `[x]` сразу после завершения.
- Новые обнаруженные задачи — с префиксом ➕.
- Блокеры — с префиксом ⚠️.
- Обновлять план, если реализация отклоняется от изначального замысла.

## What Goes Where

- **Implementation Steps** (`[ ]`): правки в `docker-compose.yml`, `.env.example`, `CLAUDE.md`, ручные E2E-проверки на dev-инстансе.
- **Post-Completion** (без чекбоксов): развёртывание в prod (`git pull && make restart` на сервере), мониторинг логов первые 1-2 цикла в prod.

## Implementation Steps

### Task 1: Добавить sidecar-сервис в docker-compose.yml

**Files:**
- Modify: `docker-compose.yml`

- [ ] добавить сервис `cf-ip-updater` под существующим `traefik` в `services:`
- [ ] указать `image: ${CF_IPS_UPDATER_IMAGE:-alpine:3.20}` с `restart: unless-stopped`
- [ ] смонтировать `./scripts/update-cf-ips.sh:/usr/local/bin/update-cf-ips.sh:ro` (read-only, переиспользование скрипта)
- [ ] смонтировать `./traefik/dynamic:/work/traefik/dynamic` (read-write для записи обновлённого yml)
- [ ] выставить `working_dir: /work`, чтобы относительный путь `OUT=` в скрипте разрешался корректно
- [ ] передать `UPDATE_INTERVAL=${CF_IPS_UPDATE_INTERVAL:-7d}` в `environment`
- [ ] прописать `entrypoint: ["/bin/sh", "-c"]` и `command` с sleep-loop (см. референсный фрагмент в Technical Details)
- [ ] **важно**: пакет `coreutils` в `apk add` обязателен — busybox `sleep` не поддерживает суффиксы `d/h/m`, а GNU `sleep` из `coreutils` поддерживает. Без него `sleep 7d` упадёт с `invalid time interval '7d'`
- [ ] НЕ подключать к сети `traefik_webgateway` (sidecar'у нужен только исходящий HTTPS на cloudflare.com; default bridge — достаточно)
- [ ] запустить `make config` — убедиться, что compose-файл валиден и новый сервис виден в resolved config

### Task 2: Расширить .env.example новыми переменными

**Files:**
- Modify: `.env.example`

- [ ] добавить `CF_IPS_UPDATE_INTERVAL=7d` с комментарием о поддерживаемых суффиксах (`s/m/h/d`, либо голые секунды)
- [ ] добавить `CF_IPS_UPDATER_IMAGE=alpine:3.20` с комментарием о pin'е версии для воспроизводимости
- [ ] сгруппировать новые переменные под заголовком-комментарием `# cf-ip-updater (sidecar)` для читаемости
- [ ] сверить, что `make up` без правки текущего `.env` по-прежнему работает (defaults покрывают оба новых ключа)

### Task 3: Обновить CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] в секции «Architecture» упомянуть `cf-ip-updater` одним предложением: что делает, периодичность, переиспользование скрипта
- [ ] в таблице «Environment Setup» добавить строки для `CF_IPS_UPDATE_INTERVAL` и `CF_IPS_UPDATER_IMAGE` (Required: no; дефолты; назначение)
- [ ] в секции «Common Commands» пометить `make update-cf-ips` как manual force-refresh (обычно не требуется — sidecar обновляет автоматически)
- [ ] в секции «Dynamic Config Reloading» добавить упоминание, что `cloudflare-ips.yml` регенерируется sidecar'ом (а не только вручную)
- [ ] добавить явную заметку: `cloudflare-ips.yml` генерируется либо sidecar'ом (автоматически), либо `make update-cf-ips` (вручную). Не запускать оба одновременно — во избежание гонки за `mv` на один файл (на практике sidecar спит большую часть времени, риск мал, но лучше избегать)

### Task 4: Ручные E2E-проверки на dev-инстансе

**Files:**
- Modify (временно, для теста интервала): `.env`

- [ ] `make down && make up`, затем `docker compose logs -f cf-ip-updater` — убедиться что появляется `[cf-ip-updater] running update` и затем `sleeping 7d`
- [ ] проверить mtime `traefik/dynamic/cloudflare-ips.yml` — должен быть свежим (после старта sidecar'а)
- [ ] временно выставить `CF_IPS_UPDATE_INTERVAL=60` в `.env`, `make restart`, пронаблюдать 2-3 цикла update → sleep → update, вернуть исходное значение
- [ ] симулировать ошибку сети надёжным способом: `docker network disconnect bridge cf-ip-updater` (или имя default-сети из `make config`), дождаться следующего цикла `running update`, убедиться что лог содержит `update failed, keeping previous file` и mtime `cloudflare-ips.yml` НЕ изменился; затем `docker network connect bridge cf-ip-updater` для восстановления
- [ ] проверить поведение при невалидном интервале: выставить `CF_IPS_UPDATE_INTERVAL=99x`, `make restart`, убедиться что контейнер падает с чётким сообщением `sleep: invalid time interval '99x'` (а не виснет молча); вернуть корректное значение
- [ ] проверить, что Traefik подхватывает обновление без рестарта: `docker compose logs traefik | tail -50` — искать записи о перечитывании конфигурации (точный формат зависит от версии Traefik v3.1; при отсутствии явного лога — проверить что `providers.file.watch=true` в `traefik/traefik.yml`)
- [ ] регрессия: `make update-cf-ips` запустить с хоста — файл перегенерирован корректно, `scripts/update-cf-ips.sh` работает без изменений

### Task 5: Verify acceptance criteria

- [ ] все пункты Overview реализованы: автоматическое обновление активно, ручной режим сохранён, переиспользование скрипта
- [ ] edge case покрыт: недоступность CF не ломает существующий allowlist
- [ ] backward compatibility: `make init`, `make update-cf-ips`, старый `.env` без новых ключей — всё работает
- [ ] нет changes в `scripts/update-cf-ips.sh`, `Makefile`, `traefik/traefik.yml`

### Task 6: Финализация плана

- [ ] `mkdir -p docs/plans/completed` (идемпотентно — директория уже может существовать)
- [ ] переместить этот файл в `docs/plans/completed/20260415-cf-ip-updater-sidecar.md`
- [ ] закоммитить все изменения одним коммитом `feat: add cf-ip-updater sidecar for periodic cloudflare ip refresh`

## Technical Details

**Референсный фрагмент для `docker-compose.yml` (Task 1):**

```yaml
  cf-ip-updater:
    image: ${CF_IPS_UPDATER_IMAGE:-alpine:3.20}
    restart: unless-stopped
    volumes:
      - ./scripts/update-cf-ips.sh:/usr/local/bin/update-cf-ips.sh:ro
      - ./traefik/dynamic:/work/traefik/dynamic
    working_dir: /work
    environment:
      - UPDATE_INTERVAL=${CF_IPS_UPDATE_INTERVAL:-7d}
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        apk add --no-cache bash curl coreutils >/dev/null
        while true; do
          echo "[cf-ip-updater] running update at $(date -Iseconds)"
          bash /usr/local/bin/update-cf-ips.sh || echo "[cf-ip-updater] update failed, keeping previous file"
          echo "[cf-ip-updater] sleeping ${UPDATE_INTERVAL}"
          sleep "${UPDATE_INTERVAL}"
        done
```

**Жизненный цикл:**
1. Старт контейнера → `apk add bash curl coreutils` (одноразово в сессии).
2. Итерация цикла: лог timestamp → `bash update-cf-ips.sh` (пишет/обновляет `cloudflare-ips.yml`, либо падает → wrapper ловит и логирует) → `sleep ${UPDATE_INTERVAL}`.
3. При рестарте хоста или контейнера: `restart: unless-stopped` поднимает sidecar заново; первая итерация снова обновляет файл сразу при старте.

**Формат интервала:** busybox `sleep` (дефолт в alpine) принимает ТОЛЬКО голые секунды. Поэтому обязательно `apk add coreutils` — он подменит `sleep` на GNU-версию, которая понимает суффиксы `s/m/h/d`. С coreutils `7d`, `24h`, `3600` — все валидны. При некорректном значении GNU sleep падает с `invalid time interval 'XXX'`, что приводит к exit кода команды и рестарту контейнера по политике — это ожидаемое поведение (fail-fast на misconfiguration).

**Обработка ошибок:**
- curl внутри скрипта запускается с `-fsSL` → ненулевой exit при HTTP-ошибке.
- `set -euo pipefail` в скрипте → скрипт завершается с non-zero.
- Sanity-check (`grep -Eq '^ *- [0-9a-fA-F:.]+/[0-9]+'`) → защищает от ситуации «curl 200 OK, но тело пустое/битое».
- Temp-файл создаётся через `mktemp`, атомарное `mv` в конце — либо полный валидный файл, либо ничего.
- Wrapper в compose `|| echo "...failed..."` → неудача логируется, loop продолжается.

**Сеть:** sidecar использует default bridge-сеть (не подключается к `traefik_webgateway`). Требуется только egress HTTPS на `www.cloudflare.com` (443). Никакой ingress, никакой видимости для других сервисов.

**Ресурсы:** образ ~8 MB, после `apk add` ~20 MB в памяти процессов, CPU near-zero (спит 99.99% времени). Лимиты не нужны.

## Post-Completion

**Ручная верификация в prod:**
- После мерджа и деплоя (`git pull && make restart` на prod-сервере) — проверить логи первого цикла sidecar'а: `docker compose logs cf-ip-updater | head -20`.
- Убедиться, что файл `traefik/dynamic/cloudflare-ips.yml` на prod-хосте обновился (сравнить mtime до/после деплоя).
- Дождаться следующего планового цикла (через 7 дней) и убедиться что он отработал без ошибок — разовая точечная проверка.

**Мониторинг (опционально, не входит в scope):**
- При желании — настроить алерт на основе `docker compose logs cf-ip-updater | grep "update failed"` через внешнюю систему (Loki/Promtail/etc.). В scope текущего плана не входит.
