#!/usr/bin/env bash
# Деплой конкретной версии: ./deploy.sh sha-1a2b3c4
#
# Состояние прода хранится в $STATE_DIR (по умолчанию ~/.todo-prod):
#   prod.env    — DB_PASSWORD (chmod 600), чтобы откат работал одной командой без CI
#   current     — тег, который сейчас пытались/успели выкатить
#   last_good   — последний тег, который поднялся и прошёл healthcheck
#   history.log — журнал всех деплоев: время, тег, ok/FAILED
set -euo pipefail

TAG="${1:?usage: deploy.sh <tag>, например sha-1a2b3c4}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-$HOME/.todo-prod}"
COMPOSE=(docker compose -f "$HERE/docker-compose.yml" --env-file "$STATE_DIR/prod.env")

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Секрет приходит из окружения (в CI — secrets.DB_PASSWORD) и один раз сохраняется на хосте.
if [[ -n "${DB_PASSWORD:-}" ]]; then
  umask 077
  printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD" > "$STATE_DIR/prod.env"
fi
if [[ ! -s "$STATE_DIR/prod.env" ]]; then
  echo "Нет $STATE_DIR/prod.env и не задан DB_PASSWORD — нечем подключаться к БД" >&2
  exit 1
fi

export APP_TAG="$TAG"
started=$SECONDS
echo "==> Деплой $TAG (было: $(cat "$STATE_DIR/current" 2>/dev/null || echo '-'))"
echo "$TAG" > "$STATE_DIR/current"

"${COMPOSE[@]}" pull --quiet frontend backend

# --wait: команда вернёт ошибку, если контейнеры не стали healthy за отведённое время.
if "${COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 90; then
  echo "$TAG" > "$STATE_DIR/last_good"
  echo "$(date '+%F %T') $TAG ok" >> "$STATE_DIR/history.log"
  echo "==> $TAG поднят и healthy за $((SECONDS - started)) с"
else
  echo "$(date '+%F %T') $TAG FAILED" >> "$STATE_DIR/history.log"
  "${COMPOSE[@]}" ps -a
  "${COMPOSE[@]}" logs --tail 20 backend || true
  echo "==> $TAG НЕ поднялся. Последняя рабочая версия: $(cat "$STATE_DIR/last_good" 2>/dev/null || echo '-')" >&2
  echo "==> Откат: lab3/deploy/rollback.sh" >&2
  exit 1
fi
