#!/usr/bin/env bash
# Проверка живого сервиса снаружи — так же, как его видит пользователь (через nginx фронтенда).
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8088}"

# Сервису даём до 30 секунд: nginx может подняться раньше, чем бэкенд начнёт отвечать.
for i in $(seq 1 15); do
  curl -fsS -o /dev/null "$BASE_URL/api/whoami" && break
  echo "ждём сервис... ($i)"
  sleep 2
done

set -x
curl -fsS -o /dev/null -w 'GET / -> HTTP %{http_code}, %{size_download} байт\n' "$BASE_URL/"
curl -fsS -i "$BASE_URL/api/whoami"
echo
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"task\":{\"title\":\"smoke $(date '+%F %T')\"}}" \
  -w 'POST /api/task -> HTTP %{http_code}\n' "$BASE_URL/api/task"
curl -fsS "$BASE_URL/api/tasks"
echo
