#!/usr/bin/env bash
# Откат одной командой:
#   ./rollback.sh              — на последнюю рабочую версию, отличную от текущей
#   ./rollback.sh sha-1a2b3c4  — на конкретную версию
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-$HOME/.todo-prod}"
current="$(cat "$STATE_DIR/current" 2>/dev/null || true)"

if [[ -n "${1:-}" ]]; then
  target="$1"
else
  # Ищем в журнале с конца последний успешный деплой, который не равен текущему тегу.
  target="$(awk -v cur="$current" '$4 == "ok" && $3 != cur { t = $3 } END { print t }' "$STATE_DIR/history.log" 2>/dev/null || true)"
fi

if [[ -z "$target" ]]; then
  echo "Не на что откатываться: в $STATE_DIR/history.log нет другой рабочей версии" >&2
  exit 1
fi

echo "==> Откат: $current -> $target"
started=$SECONDS
"$HERE/deploy.sh" "$target"
echo "==> Откат занял $((SECONDS - started)) с"
