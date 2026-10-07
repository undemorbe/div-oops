#!/usr/bin/env bash
set -uo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE=todo.local
SITE2=project2.local
EVIL=evil.local
IP=127.0.0.1
FAILOVER_INSTANCE="${FAILOVER_INSTANCE:-1}"

CURL=(curl -s --max-time 5
      --resolve "$SITE:80:$IP"  --resolve "$SITE:443:$IP"
      --resolve "$SITE2:80:$IP" --resolve "$SITE2:443:$IP"
      --resolve "$EVIL:80:$IP"  --resolve "$EVIL:443:$IP")
if command -v mkcert >/dev/null && [[ -f "$(mkcert -CAROOT)/rootCA.pem" ]]; then
    CURL+=(--cacert "$(mkcert -CAROOT)/rootCA.pem")
else
    CURL+=(-k)
fi

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else G= R= B= D= N=; fi

PASSED=0; FAILED=0
section() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
cmd()     { printf '%s$ %s%s\n' "$D" "$*" "$N"; }
ok()      { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; PASSED=$((PASSED + 1)); }
fail()    { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; FAILED=$((FAILED + 1)); }
check()   { local msg="$1"; shift; if "$@"; then ok "$msg"; else fail "$msg"; fi; }

code() { "${CURL[@]}" -o /dev/null -w '%{http_code}' "$@"; }
hdr()  { tr -d '\r' | awk -v h="$1" 'tolower($1) == tolower(h)":" {$1 = ""; sub(/^ /, ""); print}'; }

cooldown() { sleep 2.5; }
api_series() {
    local n="$1" h up
    for _ in $(seq 1 "$n"); do
        h="$("${CURL[@]}" -o /dev/null -D - "https://$SITE/api/whoami")"
        up="$(hdr X-Upstream <<<"$h")"
        printf '%s %s %s%s\n' \
            "$(head -1 <<<"$h" | awk '{print $2}')" \
            "${up##*, }" \
            "$(hdr X-Instance-Id <<<"$h")" \
            "$([[ "$up" == *,* ]] && echo "   (retry: $up)")"
    done
}

section "1. HTTP → HTTPS (301)"
cmd "curl -I http://$SITE/"
out="$("${CURL[@]}" -I "http://$SITE/some/path?x=1" | tr -d '\r')"
printf '%s\n' "$out" | grep -E '^(HTTP|Location)' | sed 's/^/  /'
check "статус 301"                          grep -q '^HTTP/1.1 301' <<<"$out"
check "Location: https://$SITE/some/path?x=1" grep -q "^Location: https://$SITE/some/path?x=1$" <<<"$out"

cmd "curl -I https://$SITE/"
check "по HTTPS фронт отдаётся (200)" test "$(code "https://$SITE/")" = 200


section "2. Балансировка /api между двумя инстансами"
cmd "for i in 1..6; curl -D - https://$SITE/api/whoami   # status upstream instance"
series="$(api_series 6)"
printf '%s\n' "$series" | sed 's/^/  /'
check "все ответы 200"            test "$(awk '$1 != 200' <<<"$series" | wc -l)" -eq 0
check "ответили оба upstream"     test "$(awk '{print $2}' <<<"$series" | sort -u | wc -l)" -eq 2
cooldown


section "3. Отказоустойчивость"
if [[ -n "${SKIP_FAILOVER:-}" ]]; then
    echo "  пропущено (SKIP_FAILOVER)"
else
    cmd "./lab.sh backend stop $FAILOVER_INSTANCE"
    "$LAB/lab.sh" backend stop "$FAILOVER_INSTANCE" | sed 's/^/  /'
    "$LAB/lab.sh" status | sed 's/^/  /'

    cmd "for i in 1..6; curl -D - https://$SITE/api/whoami"
    series="$(api_series 6)"
    printf '%s\n' "$series" | sed 's/^/  /'
    check "/api отвечает 200 на всех запросах" test "$(awk '$1 != 200' <<<"$series" | wc -l)" -eq 0
    check "весь трафик ушёл на живой инстанс"  test "$(awk '{print $2}' <<<"$series" | sort -u | wc -l)" -eq 1
    check "фронт по-прежнему 200"              test "$(code "https://$SITE/")" = 200

    cmd "./lab.sh backend start $FAILOVER_INSTANCE"
    "$LAB/lab.sh" backend start "$FAILOVER_INSTANCE" | sed 's/^/  /'
fi
cooldown


section "4. /admin под basic auth"
cmd "curl -I https://$SITE/admin/"
c="$(code "https://$SITE/admin/")"; echo "  → $c"
check "без пароля → 401"          test "$c" = 401
cmd "curl -I -u admin:wrong https://$SITE/admin/"
c="$(code -u admin:wrong "https://$SITE/admin/")"; echo "  → $c"
check "неверный пароль → 401"     test "$c" = 401
if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
    cmd "curl -I -u ${ADMIN_USER:-admin}:*** https://$SITE/admin/"
    c="$(code -u "${ADMIN_USER:-admin}:$ADMIN_PASSWORD" "https://$SITE/admin/")"; echo "  → $c"
    check "верный пароль → 200"   test "$c" = 200
else
    echo "  (верный пароль не проверяю — задай ADMIN_PASSWORD)"
fi


section "5. Rate limit на /api (флуд → 429)"
cmd "40 параллельных запросов на https://$SITE/api/tasks"
codes="$(seq 1 40 | xargs -P 20 -I{} "${CURL[@]}" -o /dev/null -w '%{http_code}\n' "https://$SITE/api/tasks" | sort | uniq -c)"
printf '%s\n' "$codes" | sed 's/^ */  /'
check "часть запросов получила 429" grep -qE '[0-9]+ 429$' <<<"$codes"
check "часть запросов прошла (200)" grep -qE '[0-9]+ 200$' <<<"$codes"
cooldown
check "после паузы /api снова 200" test "$(code "https://$SITE/api/tasks")" = 200


section "6. Виртуальные хосты и чужой Host"
cmd "curl https://$SITE2/"
body="$("${CURL[@]}" "https://$SITE2/")"
check "$SITE2 отдаёт свой проект"         grep -q 'Project Two' <<<"$body"
check "$SITE2 не отдаёт TODO List"        bash -c '! grep -q "<title>TODO List</title>" <<<"$1"' _ "$body"
cmd "curl https://$SITE/"
check "$SITE отдаёт TODO List, не project2" \
    grep -q '<title>TODO List</title>' <<<"$("${CURL[@]}" "https://$SITE/")"
cmd "curl -H 'Host: $SITE2' https://$SITE/"
check "Host: $SITE2 → его проект, не соседний" \
    grep -q 'Project Two' <<<"$("${CURL[@]}" -H "Host: $SITE2" "https://$SITE/")"
for p in /api/tasks /docs/ /admin/; do
    c="$(code "https://$SITE2$p")"
    check "$SITE2$p → 404 (чужие пути не протекают), получено $c" test "$c" = 404
done

cmd "curl --http1.1 -H 'Host: $EVIL' https://$SITE/   # известный SNI, чужой Host"
"${CURL[@]}" --http1.1 -o /dev/null -H "Host: $EVIL" "https://$SITE/"; rc=$?
check "соединение закрыто без ответа (444, curl exit 52), получено exit $rc" test "$rc" = 52
cmd "curl --http2 -H 'Host: $EVIL' https://$SITE/     # то же по HTTP/2"
c="$(code --http2 -H "Host: $EVIL" "https://$SITE/")"
check "HTTP/2: 421 Misdirected Request (Host ≠ SNI), получено $c" test "$c" = 421
cmd "curl https://$EVIL/                         # чужой SNI"
"${CURL[@]}" -o /dev/null "https://$EVIL/" 2>/dev/null; rc=$?
check "TLS-рукопожатие отклонено (curl exit 35), получено exit $rc" test "$rc" = 35
cmd "curl -I http://$EVIL/"
"${CURL[@]}" -o /dev/null "http://$EVIL/"; rc=$?
check "HTTP с чужим Host: обрыв без редиректа (exit 52), получено exit $rc" test "$rc" = 52


section "7. alias и своя страница 404"
cmd "curl https://$SITE/docs/"
check "/docs/ отдаётся из отдельной папки (alias)" \
    grep -q 'alias' <<<"$("${CURL[@]}" "https://$SITE/docs/")"
cmd "curl https://$SITE/no-such-page"
c="$(code "https://$SITE/no-such-page")"
body="$("${CURL[@]}" "https://$SITE/no-such-page")"
echo "  → $c, <title>$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' <<<"$body")</title>"
check "статус 404"                 test "$c" = 404
check "страница наша, не nginx-овская" grep -q 'Такой страницы нет' <<<"$body"
check "/_errors/ снаружи не открыть (internal)" test "$(code "https://$SITE/_errors/404.html")" = 404


printf '\n%sИтого: %s%d PASS%s, %s%d FAIL%s\n' "$B" "$G" "$PASSED" "$N" "$R" "$FAILED" "$N"
[[ "$FAILED" -eq 0 ]]
